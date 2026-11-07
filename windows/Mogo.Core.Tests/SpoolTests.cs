using System.Runtime.InteropServices;
using Mogo.Core;
using Xunit;
using static Mogo.Core.Tests.TestPdf;

namespace Mogo.Core.Tests;

/// <summary>
/// 인쇄 대기열을 멈춰 두고 작업을 보내, 드라이버가 받은 설정(DEVMODE)을 읽은 뒤 작업을 지운다. 맥의 `lp -H hold` + `cancel`과 같은 확인.
/// 시험용 프린터 "Mogo Hold Test"가 있어야 한다(만드는 법은 windows/README.md). 관리자 권한이 필요하다.
/// </summary>
public class SpoolTests
{
    private const string HoldPrinter = "Mogo Hold Test";

    [Fact]
    public void SpooledJobCarriesA4AndRepeatsCopies()
    {
        if (!Printing.Printers().names.Contains(HoldPrinter)) Assert.Skip($"{HoldPrinter} 프린터 없음");
        using var printer = Winspool.Open(HoldPrinter);
        Winspool.Pause(printer.Handle);
        try
        {
            using var f = Load([new(A3, Boxes: [Box(80, 70, 680, 1050)]), new(A3, Boxes: [Box(80, 70, 680, 1050)])], "spool.pdf");
            var pdf = Imposer.Impose([f], new ImpositionOptions()).Pdf;
            var title = "모고 프린트 대기열 시험 " + Guid.NewGuid().ToString("N")[..6];
            Printing.Print(pdf, new PrintSettings(HoldPrinter) { Copies = 2, Grayscale = true }, title);

            var job = Winspool.WaitForJob(printer.Handle, title, expectedPages: 4);
            Assert.NotNull(job);
            var dm = job!.Value.devMode;
            Assert.Equal(9, dm.paperSize);        // DMPAPER_A4 (서버 기본 용지는 Letter)
            Assert.Equal(1, dm.orientation);      // DMORIENT_PORTRAIT
            // 부수는 앱이 되풀이해 보낸다: 드라이버에는 1부, 쪽은 2쪽 × 2부.
            Assert.Equal(1, dm.copies);
            Assert.Equal(4, job.Value.totalPages);
            // v4 드라이버는 용지·색을 PrintTicket(드라이버 전용 영역)으로 받는다. 작업의 DEVMODE를 PrintTicket으로 되돌려 본다.
            var ticket = PrintTickets.ToTicket(HoldPrinter, dm.raw!);
            Assert.Equal(System.Printing.PageMediaSizeName.ISOA4, ticket.PageMediaSize?.PageMediaSizeName);
            Assert.Equal(System.Printing.PageOrientation.Portrait, ticket.PageOrientation);
            Assert.NotEqual(System.Printing.OutputColor.Color, ticket.OutputColor); // 이 드라이버는 흑백 하나뿐이라 값이 비기도 한다
        }
        finally
        {
            Winspool.DeleteAllJobs(printer.Handle);
            Winspool.Resume(printer.Handle);
        }
    }
}

/// <summary>PrintTicket(v4 드라이버의 흑백·양면 설정)이 화면 스레드가 아닌 곳(CLI의 MTA 주 스레드)에서도 만들어지는지.</summary>
public class PrintTicketTests
{
    [Theory]
    [InlineData("Microsoft Print to PDF")]
    [InlineData("Mogo Hold Test")]
    public void TicketIsBuiltOnAnyThread(string printer)
    {
        if (!Printing.Printers().names.Contains(printer)) Assert.Skip($"{printer} 없음");
        Assert.Equal(ApartmentState.MTA, Thread.CurrentThread.GetApartmentState());
        var t = PrintTickets.Build(printer, duplex: true, gray: true);
        Assert.NotNull(t);
        Assert.True(t!.DevMode.Length > 0);
        Assert.Equal(System.Printing.PageMediaSizeName.ISOA4, t.Ticket.PageMediaSize?.PageMediaSizeName);
        // 양면을 못 하는 드라이버는 양면이 꺼진 채로 만든다.
        Assert.False(t.CanDuplex);
        Assert.NotEqual(System.Printing.Duplexing.TwoSidedLongEdge, t.Ticket.Duplexing);
    }
}

/// <summary>winspool 함수(대기열 멈춤·작업 조회·삭제).</summary>
internal static class Winspool
{
    public sealed class PrinterHandle(IntPtr handle) : IDisposable
    {
        public IntPtr Handle { get; } = handle;
        public void Dispose() => ClosePrinter(Handle);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PRINTER_DEFAULTS { public IntPtr pDatatype; public IntPtr pDevMode; public int DesiredAccess; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct JOB_INFO_2
    {
        public int JobId;
        public IntPtr pPrinterName, pMachineName, pUserName, pDocument, pNotifyName, pDatatype, pPrintProcessor, pParameters, pDriverName, pDevMode, pStatus, pSecurityDescriptor;
        public int Status, Priority, Position, StartTime, UntilTime, TotalPages, Size;
        public long Submitted0, Submitted1; // SYSTEMTIME 16바이트
        public int Time, PagesPrinted;
    }

    public readonly record struct DevMode(short orientation, short paperSize, short copies, short color, short duplex, short collate, int fields = 0, byte[]? raw = null);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool OpenPrinter(string name, out IntPtr handle, ref PRINTER_DEFAULTS defaults);
    [DllImport("winspool.drv", SetLastError = true)] private static extern bool ClosePrinter(IntPtr handle);
    [DllImport("winspool.drv", SetLastError = true)] private static extern bool SetPrinter(IntPtr handle, int level, IntPtr info, int command);
    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumJobs(IntPtr handle, int firstJob, int noJobs, int level, IntPtr buf, int cb, out int needed, out int returned);
    [DllImport("winspool.drv", SetLastError = true)] private static extern bool SetJob(IntPtr handle, int jobId, int level, IntPtr info, int command);

    private const int PRINTER_ALL_ACCESS = 0x000F000C, PRINTER_CONTROL_PAUSE = 1, PRINTER_CONTROL_RESUME = 2, JOB_CONTROL_DELETE = 5;

    public static PrinterHandle Open(string name)
    {
        var d = new PRINTER_DEFAULTS { DesiredAccess = PRINTER_ALL_ACCESS };
        if (!OpenPrinter(name, out var h, ref d)) throw new InvalidOperationException($"OpenPrinter 실패 {Marshal.GetLastWin32Error()} (관리자 권한 필요)");
        return new PrinterHandle(h);
    }

    public static void Pause(IntPtr h) => Assert.True(SetPrinter(h, 0, IntPtr.Zero, PRINTER_CONTROL_PAUSE), $"대기열 멈춤 실패 {Marshal.GetLastWin32Error()}");
    public static void Resume(IntPtr h) => SetPrinter(h, 0, IntPtr.Zero, PRINTER_CONTROL_RESUME);

    private static List<(int id, string doc, int totalPages, DevMode devMode)> Jobs(IntPtr h)
    {
        EnumJobs(h, 0, 100, 2, IntPtr.Zero, 0, out var needed, out _);
        if (needed == 0) return [];
        var buf = Marshal.AllocHGlobal(needed);
        try
        {
            if (!EnumJobs(h, 0, 100, 2, buf, needed, out _, out var n)) return [];
            var list = new List<(int, string, int, DevMode)>();
            int size = Marshal.SizeOf<JOB_INFO_2>();
            for (int i = 0; i < n; i++)
            {
                var j = Marshal.PtrToStructure<JOB_INFO_2>(buf + i * size);
                var dm = j.pDevMode;
                // DEVMODEW: dmDeviceName 64바이트, dmSpecVersion·dmDriverVersion·dmSize·dmDriverExtra(각 2), dmFields(4, 72~75)
                // → 76 dmOrientation, 78 dmPaperSize, 86 dmCopies, 92 dmColor, 94 dmDuplex, 100 dmCollate
                var devMode = dm == IntPtr.Zero ? default : new DevMode(
                    Marshal.ReadInt16(dm, 76), Marshal.ReadInt16(dm, 78), Marshal.ReadInt16(dm, 86),
                    Marshal.ReadInt16(dm, 92), Marshal.ReadInt16(dm, 94), Marshal.ReadInt16(dm, 100), Marshal.ReadInt32(dm, 72));
                byte[] bytes = [];
                if (dm != IntPtr.Zero)
                {
                    bytes = new byte[(ushort)Marshal.ReadInt16(dm, 68) + (ushort)Marshal.ReadInt16(dm, 70)]; // dmSize + dmDriverExtra
                    Marshal.Copy(dm, bytes, 0, bytes.Length);
                }
                list.Add((j.JobId, Marshal.PtrToStringUni(j.pDocument) ?? "", j.TotalPages, devMode with { raw = bytes }));
            }
            return list;
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    /// <summary>문서 이름으로 작업을 찾고, 쪽수가 다 적힐(스풀이 끝날) 때까지 기다린다.</summary>
    public static (int totalPages, DevMode devMode)? WaitForJob(IntPtr h, string document, int expectedPages = 1, int seconds = 30)
    {
        (int, DevMode)? last = null;
        for (int i = 0; i < seconds * 4; i++)
        {
            foreach (var j in Jobs(h))
                if (j.doc == document && j.totalPages > 0)
                {
                    last = (j.totalPages, j.devMode);
                    if (j.totalPages >= expectedPages) return last;
                }
            Thread.Sleep(250);
        }
        return last;
    }

    public static void DeleteAllJobs(IntPtr h)
    {
        foreach (var j in Jobs(h)) SetJob(h, j.id, 0, IntPtr.Zero, JOB_CONTROL_DELETE);
    }
}
