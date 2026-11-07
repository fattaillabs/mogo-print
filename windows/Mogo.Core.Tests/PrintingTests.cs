using Mogo.Core;
using Xunit;
using static Mogo.Core.Tests.TestPdf;

namespace Mogo.Core.Tests;

/// <summary>윈도우 기본 가상 프린터 "Microsoft Print to PDF"로 파일에 인쇄해 결과를 다시 읽는다. 종이 없이 인쇄 경로 전체를 확인한다.</summary>
public class PrintingTests
{
    private const string PdfPrinter = "Microsoft Print to PDF";

    private static void RequirePdfPrinter()
    {
        if (!Printing.Printers().names.Contains(PdfPrinter)) Assert.Skip($"{PdfPrinter} 프린터 없음");
    }

    [Fact]
    public void PlanFollowsWhatDriverSupports()
    {
        RequirePdfPrinter();
        var plan = Printing.Plan(new PrintSettings(PdfPrinter) { Copies = 2 });
        Assert.True(plan.A4);
        Assert.False(plan.CanDuplex);  // 가상 PDF 프린터는 양면이 없어서 단면으로 내려간다
        Assert.False(plan.Duplex);
        Assert.True(plan.Grayscale);
        Assert.Equal(2, plan.Copies);
        Assert.True(plan.Collate);
        Assert.Contains("단면(양면 미지원)", plan.Describe());

        Assert.Equal(1, Printing.Plan(new PrintSettings(PdfPrinter) { Copies = 0 }).Copies);
        Assert.Equal(99, Printing.Plan(new PrintSettings(PdfPrinter) { Copies = 500 }).Copies);
        Assert.False(Printing.Plan(new PrintSettings(PdfPrinter)).Collate);
    }

    [Fact]
    public void UnknownPrinterIsRejected()
    {
        var e = Assert.Throws<InvalidOperationException>(() => Printing.Plan(new PrintSettings("없는 프린터 12345")));
        Assert.Contains("없는 프린터 12345", e.Message);
        Assert.Null(Printing.HardwareMarginMM("없는 프린터 12345"));
    }

    [Fact]
    public void HardwareMarginIsKnown()
    {
        RequirePdfPrinter();
        var m = Printing.HardwareMarginMM(PdfPrinter);
        Assert.NotNull(m);
        Assert.InRange(m!.Value, 0, 10);
    }

    /// <summary>A3 시험지를 A4로 만들어 파일로 인쇄하고, 결과 PDF의 용지·쪽수·여백·방향을 잰다.</summary>
    [Fact]
    public void PrintToFileKeepsA4AndMargins()
    {
        RequirePdfPrinter();
        // 쪽마다 위치가 다른 표시를 넣어 순서도 확인한다.
        var pages = Enumerable.Range(0, 3).Select(i => new TestPage(A3, Boxes: [Box(80, 70, 680, 1050), Box(80 + i * 200, 1150, 40, 30)])).ToList();
        using var f = Load(pages, "print.pdf");
        var imposed = Imposer.Impose([f], new ImpositionOptions { PaperMarginMM = 5 });
        var outPath = TempFile("printed.pdf");
        var plan = Printing.Print(imposed.Pdf, new PrintSettings(PdfPrinter), "모고 프린트 시험", outPath);
        Assert.True(plan.Grayscale);

        Assert.True(WaitForFile(outPath), "인쇄 결과 파일이 생기지 않음");
        using var printed = PdfDoc.Open(outPath);
        Assert.NotNull(printed);
        Assert.Equal(3, printed!.PageCount);
        using var expected = PdfDoc.FromBytes(imposed.Pdf)!;
        for (int i = 0; i < 3; i++)
        {
            var size = printed.Geometry(i).Size;
            Assert.InRange(size.Width, A4.Width - 1.5, A4.Width + 1.5);
            Assert.InRange(size.Height, A4.Height - 1.5, A4.Height + 1.5);
            // 인쇄된 잉크 위치가 만든 PDF의 잉크 위치와 같아야 한다(인쇄 불가 여백만큼 밀리거나 줄지 않음).
            var want = InkRect(expected, i, 144)!.Value;
            var got = InkRect(printed, i, 144)!.Value;
            AssertRect(got, want, 1.5, $"page {i}");
            Assert.True(got.MinX >= 5 * MM - 1 && A4.Width - got.MaxX >= 5 * MM - 1.5, $"page {i} 좌우 여백");
        }
    }

    /// <summary>Microsoft Print to PDF는 최대 1부라서 드라이버에 부수를 맡기면 1부만 나온다. 앱이 되풀이해 보내는지 본다.</summary>
    [Fact]
    public void CopiesAreRepeatedInOrder()
    {
        RequirePdfPrinter();
        var pages = Enumerable.Range(0, 3).Select(i => new TestPage(A4, Boxes: [Box(100 + i * 100, 400, 50, 50)])).ToList();
        var pdf = File.ReadAllBytes(Make(pages, TempFile("copies.pdf")));
        var outPath = TempFile("copies-out.pdf");
        var plan = Printing.Print(pdf, new PrintSettings(PdfPrinter) { Copies = 2 }, "부수 시험", outPath);
        Assert.Equal(2, plan.Copies);
        Assert.True(WaitForFile(outPath));
        using var printed = PdfDoc.Open(outPath)!;
        Assert.Equal(6, printed.PageCount);
        // 한 부씩: 1,2,3,1,2,3 순서(표시 위치로 쪽을 알아본다).
        var order = Enumerable.Range(0, 6).Select(i => (int)Math.Round((InkRect(printed, i)!.Value.MinX - 100) / 100)).ToList();
        Assert.Equal([0, 1, 2, 0, 1, 2], order);
    }

    /// <summary>흑백으로 보내면 색이 있는 원본도 회색으로 나간다.</summary>
    [Fact]
    public void GrayscaleRemovesColor()
    {
        RequirePdfPrinter();
        var src = Make([new(A4, Boxes: [Box(100, 100, 300, 300)])], TempFile("color.pdf"));
        var colored = MakeRed(src);
        foreach (var gray in new[] { true, false })
        {
            var outPath = TempFile(gray ? "gray.pdf" : "color-out.pdf");
            Printing.Print(colored, new PrintSettings(PdfPrinter) { Grayscale = gray }, "색 시험", outPath);
            Assert.True(WaitForFile(outPath));
            using var printed = PdfDoc.Open(outPath)!;
            Assert.Equal(gray, !HasColor(printed, 0));
        }
    }

    private static byte[] MakeRed(string path)
    {
        // 빨간 상자 하나짜리 A4. 시험 도우미는 검은 상자만 그리므로 여기서 직접 만든다.
        Pdfium.EnsureInit();
        lock (Pdfium.Sync)
        {
            var doc = Native.FPDF_CreateNewDocument();
            try
            {
                var page = Native.FPDFPage_New(doc, 0, A4.Width, A4.Height);
                var r = Edit.FPDFPageObj_CreateNewRect(100, 100, 300, 300);
                Edit.FPDFPageObj_SetFillColor(r, 230, 20, 20, 255);
                Edit.FPDFPath_SetDrawMode(r, Edit.FillAlternate, 0);
                Edit.FPDFPage_InsertObject(page, r);
                Edit.FPDFPage_GenerateContent(page);
                Native.FPDF_ClosePage(page);
                return PdfDoc.Save(doc);
            }
            finally { Native.FPDF_CloseDocument(doc); }
        }
    }

    private static bool HasColor(PdfDoc doc, int index)
    {
        var (w, h) = doc.PixelSize(index, 36);
        var (px, _, _) = doc.RenderBgra(index, w, h);
        for (int i = 0; i < w * h; i++)
        {
            int b = px[i * 4], g = px[i * 4 + 1], r = px[i * 4 + 2];
            if (Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b)) > 40) return true;
        }
        return false;
    }

    /// <summary>스풀러가 파일을 다 쓸 때까지 기다린다.</summary>
    internal static bool WaitForFile(string path, int seconds = 60)
    {
        long last = -1;
        for (int i = 0; i < seconds * 4; i++)
        {
            if (File.Exists(path))
            {
                try
                {
                    long len = new FileInfo(path).Length;
                    if (len > 0 && len == last)
                    {
                        using var _ = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.None);
                        return true;
                    }
                    last = len;
                }
                catch (IOException) { }
            }
            Thread.Sleep(250);
        }
        return false;
    }
}
