using System.Drawing.Printing;
using System.Runtime.InteropServices;

namespace Mogo.Core;

public sealed record PrintSettings(string Printer)
{
    public int Copies { get; init; } = 1;
    public bool Duplex { get; init; } = true;
    public bool Grayscale { get; init; } = true;
}

/// <summary>프린터가 받아들인 실제 인쇄 설정(드라이버가 지원하지 않으면 꺼진다).</summary>
public sealed record PrintPlan(string Printer, bool A4, bool Duplex, bool CanDuplex, bool Grayscale, bool SupportsColor, int Copies, bool Collate)
{
    public string Describe() =>
        $"프린터 {Printer} · 용지 {(A4 ? "A4" : "기본(A4 없음)")} · {(Duplex ? "양면(긴 쪽 넘김)" : CanDuplex ? "단면" : "단면(양면 미지원)")} · " +
        $"{(Grayscale ? "흑백" : "컬러")} · {Copies}부{(Collate ? "(한 부씩)" : "")}";
}

/// <summary>윈도우 인쇄. PDFium이 프린터 장치에 쪽을 벡터 그대로 그린다. 대화상자 없이 바로 보낸다.</summary>
public static class Printing
{
    [DllImport("gdi32.dll")] private static extern int GetDeviceCaps(IntPtr hdc, int index);
    private const int LOGPIXELSX = 88, LOGPIXELSY = 90, PHYSICALOFFSETX = 112, PHYSICALOFFSETY = 113;

    /// <summary>설치된 프린터와 기본 프린터.</summary>
    public static (List<string> names, string? defaultName) Printers()
    {
        var names = PrinterSettings.InstalledPrinters.Cast<string>().ToList();
        string? def = null;
        try { def = new PrinterSettings().PrinterName; } catch { }
        return (names, names.Contains(def ?? "") ? def : names.FirstOrDefault());
    }

    // 주의: PrinterSettings.DefaultPageSettings는 읽을 때마다 새 객체를 돌려준다. 거기에 용지·색을 넣으면 버려지므로
    // PageSettings를 따로 만들어 PrintDocument.DefaultPageSettings에 넘긴다.
    private static (PrinterSettings printer, PageSettings page) Configure(PrintSettings s, out PrintPlan plan)
    {
        var ps = new PrinterSettings { PrinterName = s.Printer };
        if (!ps.IsValid) throw new InvalidOperationException($"프린터를 찾지 못했어요: {s.Printer}");
        var a4 = ps.PaperSizes.Cast<PaperSize>().FirstOrDefault(p => p.Kind == PaperKind.A4);
        int copies = Math.Clamp(s.Copies, 1, 99);

        // v4 드라이버(윈도우가 와이파이 프린터에 자동으로 붙이는 IPP 드라이버 등)는 색·양면을 공개 DEVMODE가 아니라
        // PrintTicket(드라이버 전용 영역)으로 받는다. PrintTicket으로 설정을 만들어 드라이버 DEVMODE로 바꿔 쓴다.
        var ticket = PrintTickets.Build(s.Printer, s.Duplex, s.Grayscale);
        if (ticket != null) ApplyDevMode(ps, ticket.DevMode);

        bool canDuplex = ps.CanDuplex || ticket?.CanDuplex == true;
        bool supportsColor = ps.SupportsColor || ticket?.SupportsColor == true;
        bool duplex = s.Duplex && canDuplex;
        bool gray = s.Grayscale || !supportsColor;
        ps.Duplex = duplex ? Duplex.Vertical : Duplex.Simplex; // 세로 쪽의 긴 쪽 넘김
        // 부수는 드라이버에 맡기지 않고 한 작업 안에서 문서를 되풀이해 보낸다(Print 참고). 그래서 드라이버에는 1부.
        ps.Copies = 1;
        ps.Collate = false;
        var page = new PageSettings(ps);
        if (ticket != null) ApplyDevMode(page, ticket.DevMode);
        page.Landscape = false;
        page.Margins = new Margins(0, 0, 0, 0);
        page.Color = !gray;
        if (a4 != null) page.PaperSize = a4;
        plan = new PrintPlan(s.Printer, a4 != null, duplex, canDuplex, gray, supportsColor, copies, copies > 1);
        return (ps, page);
    }

    private static void ApplyDevMode(object target, byte[] devMode)
    {
        var h = Marshal.AllocHGlobal(devMode.Length); // LocalAlloc(고정) 메모리라 GlobalLock에도 쓸 수 있다
        try
        {
            Marshal.Copy(devMode, 0, h, devMode.Length);
            if (target is PrinterSettings ps) ps.SetHdevmode(h); else ((PageSettings)target).SetHdevmode(h);
        }
        finally { Marshal.FreeHGlobal(h); }
    }

    /// <summary>보내지 않고 프린터가 받아들일 설정만 본다.</summary>
    public static PrintPlan Plan(PrintSettings s)
    {
        Configure(s, out var plan);
        return plan;
    }

    /// <summary>A4 PDF를 인쇄한다. printToFile을 주면 그 파일로 출력한다("Microsoft Print to PDF" 시험용).</summary>
    public static PrintPlan Print(byte[] pdf, PrintSettings s, string title, string? printToFile = null)
    {
        var (ps, pageSettings) = Configure(s, out var plan);
        if (printToFile != null) { ps.PrintToFile = true; ps.PrintFileName = printToFile; }
        using var doc = PdfDoc.FromBytes(pdf) ?? throw new InvalidOperationException("인쇄할 PDF를 열지 못했어요.");
        // 부수: 드라이버마다 최대 부수(Microsoft Print to PDF는 1부)와 한 부씩 묶기 지원이 달라서, 한 작업 안에서
        // 문서를 부수만큼 되풀이한다. 양면으로 여러 부면 배치 단계에서 끝에 빈 쪽을 넣어 두었으므로 부마다 새 종이에서 시작한다.
        int total = doc.PageCount * plan.Copies, sent = 0;
        using var pd = new PrintDocument
        {
            DocumentName = title,
            PrinterSettings = ps,
            DefaultPageSettings = pageSettings,
            PrintController = new StandardPrintController(), // 진행 창을 띄우지 않는다
            OriginAtMargins = false,
        };
        pd.PrintPage += (_, e) =>
        {
            var hdc = e.Graphics!.GetHdc();
            try
            {
                int dx = GetDeviceCaps(hdc, LOGPIXELSX), dy = GetDeviceCaps(hdc, LOGPIXELSY);
                int ox = GetDeviceCaps(hdc, PHYSICALOFFSETX), oy = GetDeviceCaps(hdc, PHYSICALOFFSETY);
                int w = (int)Math.Round(Units.A4.Width / 72.0 * dx), h = (int)Math.Round(Units.A4.Height / 72.0 * dy);
                // 장치 원점은 인쇄 가능 영역의 왼쪽 위이므로 물리 여백만큼 당겨 종이 전체에 맞춘다.
                doc.RenderToDC(sent % doc.PageCount, hdc, -ox, -oy, w, h, plan.Grayscale);
            }
            finally { e.Graphics.ReleaseHdc(hdc); }
            sent++;
            e.HasMorePages = sent < total;
        };
        pd.Print();
        return plan;
    }

    /// <summary>프린터의 A4 인쇄 불가 여백(네 변 중 가장 큰 값, mm). 모르면 null.</summary>
    public static double? HardwareMarginMM(string printer)
    {
        try
        {
            var ps = new PrinterSettings { PrinterName = printer };
            if (!ps.IsValid) return null;
            var a4 = ps.PaperSizes.Cast<PaperSize>().FirstOrDefault(p => p.Kind == PaperKind.A4);
            var pg = new PageSettings(ps);
            if (a4 != null) pg.PaperSize = a4;
            var area = pg.PrintableArea; // 1/100인치
            double left = area.Left, top = area.Top;
            double right = pg.PaperSize.Width - area.Right, bottom = pg.PaperSize.Height - area.Bottom;
            return new[] { left, top, right, bottom }.Max() / 100.0 * 25.4;
        }
        catch { return null; }
    }
}

/// <summary>PrintTicket으로 인쇄 설정을 만들어 드라이버 DEVMODE(전용 영역 포함)로 바꾼다. 안 되면 null(공개 DEVMODE만 쓴다).</summary>
internal static class PrintTickets
{
    internal sealed record Result(byte[] DevMode, bool CanDuplex, bool SupportsColor, System.Printing.PrintTicket Ticket);

    public static Result? Build(string printer, bool duplex, bool gray)
    {
        try
        {
            using var queue = OpenQueue(printer);
            var baseTicket = queue.UserPrintTicket ?? queue.DefaultPrintTicket;
            var caps = queue.GetPrintCapabilities(baseTicket);
            bool canDuplex = caps.DuplexingCapability.Contains(System.Printing.Duplexing.TwoSidedLongEdge);
            bool color = caps.OutputColorCapability.Contains(System.Printing.OutputColor.Color);
            var t = new System.Printing.PrintTicket
            {
                PageMediaSize = new System.Printing.PageMediaSize(System.Printing.PageMediaSizeName.ISOA4),
                PageOrientation = System.Printing.PageOrientation.Portrait,
                CopyCount = 1, // 부수는 앱이 되풀이해 보낸다
            };
            if (duplex && canDuplex) t.Duplexing = System.Printing.Duplexing.TwoSidedLongEdge;
            else if (caps.DuplexingCapability.Contains(System.Printing.Duplexing.OneSided)) t.Duplexing = System.Printing.Duplexing.OneSided;
            // 맥(CUPS)의 print-color-mode=monochrome과 같은 '흑백'. 없으면 회색조.
            if (gray && caps.OutputColorCapability.Contains(System.Printing.OutputColor.Monochrome)) t.OutputColor = System.Printing.OutputColor.Monochrome;
            else if (gray && caps.OutputColorCapability.Contains(System.Printing.OutputColor.Grayscale)) t.OutputColor = System.Printing.OutputColor.Grayscale;
            else if (!gray && color) t.OutputColor = System.Printing.OutputColor.Color;
            var merged = queue.MergeAndValidatePrintTicket(baseTicket, t).ValidatedPrintTicket;
            using var conv = new System.Printing.Interop.PrintTicketConverter(queue.FullName, queue.ClientPrintSchemaVersion);
            var dm = conv.ConvertPrintTicketToDevMode(merged, System.Printing.Interop.BaseDevModeType.UserDefault);
            return new Result(dm, canDuplex, color, merged);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>드라이버 DEVMODE를 PrintTicket으로 되돌린다(시험에서 대기열 작업 설정 확인용).</summary>
    public static System.Printing.PrintTicket ToTicket(string printer, byte[] devMode)
    {
        using var queue = OpenQueue(printer);
        using var conv = new System.Printing.Interop.PrintTicketConverter(queue.FullName, queue.ClientPrintSchemaVersion);
        return conv.ConvertDevModeToPrintTicket(devMode);
    }

    private static System.Printing.PrintQueue OpenQueue(string name)
    {
        if (name.StartsWith(@"\\"))
        {
            int i = name.IndexOf('\\', 2);
            if (i > 2) return new System.Printing.PrintServer(name[..i]).GetPrintQueue(name[(i + 1)..]);
        }
        return new System.Printing.LocalPrintServer().GetPrintQueue(name);
    }
}
