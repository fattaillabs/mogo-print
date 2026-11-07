using System.Runtime.InteropServices;
using Mogo.Core;
using Xunit;

// PDFium은 스레드 안전하지 않고, 인쇄 시험은 프린터 하나를 같이 쓴다. 테스트를 차례로 돌린다.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Mogo.Core.Tests;

/// <summary>시험용 PDF를 그리는 데 쓰는 PDFium 편집 함수.</summary>
internal static class Edit
{
    private const string Lib = "pdfium";
    public const int FillAlternate = 1, FontTrueType = 2;

    [DllImport(Lib)] public static extern IntPtr FPDFPageObj_CreateNewRect(float x, float y, float w, float h);
    [DllImport(Lib)] public static extern int FPDFPageObj_SetFillColor(IntPtr obj, uint r, uint g, uint b, uint a);
    [DllImport(Lib)] public static extern int FPDFPath_SetDrawMode(IntPtr path, int fillMode, int stroke);
    [DllImport(Lib)] public static extern void FPDFPage_InsertObject(IntPtr page, IntPtr obj);
    [DllImport(Lib)] public static extern IntPtr FPDFText_LoadFont(IntPtr doc, byte[] data, uint size, int fontType, int cid);
    [DllImport(Lib)] public static extern IntPtr FPDFPageObj_CreateTextObj(IntPtr doc, IntPtr font, float size);
    [DllImport(Lib, CharSet = CharSet.Unicode)] public static extern int FPDFText_SetText(IntPtr textObj, [MarshalAs(UnmanagedType.LPWStr)] string text);
    [DllImport(Lib)] public static extern void FPDFPageObj_Transform(IntPtr obj, double a, double b, double c, double d, double e, double f);
    [DllImport(Lib)] public static extern int FPDFPage_GenerateContent(IntPtr page);
    [DllImport(Lib)] public static extern void FPDFFont_Close(IntPtr font);
}

/// <summary>시험용 쪽 하나. 상자는 회전 전 쪽 좌표(왼쪽 아래 원점, pt)의 검은 사각형.</summary>
public sealed record TestPage(SizeD Size, string? Text = null, int Rotate = 0, RectD[]? Boxes = null);

/// <summary>시험용 PDF를 만들고 결과를 읽는 도우미. 맥 테스트의 TestPDF와 같은 일을 PDFium으로 한다.</summary>
public static class TestPdf
{
    public static readonly SizeD A3 = new(841.89, 1190.55);
    public static readonly SizeD A4 = Units.A4;
    public const double MM = Units.PointsPerMM;

    private static byte[]? font;

    /// <summary>한글 글자를 넣을 글꼴(맑은 고딕). PDF에 통째로 넣고 ToUnicode도 붙어 글자 추출이 된다.</summary>
    private static byte[] KoreanFont => font ??= File.ReadAllBytes(
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "malgun.ttf"));

    public static string TempDir()
    {
        var dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "MogoTests-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static string TempFile(string name) => System.IO.Path.Combine(TempDir(), name);

    /// <summary>쪽들을 그려 PDF 파일로 저장한다. 회전은 /Rotate로 넣는다.</summary>
    public static string Make(IEnumerable<TestPage> pages, string path)
    {
        Pdfium.EnsureInit();
        lock (Pdfium.Sync)
        {
            var doc = Native.FPDF_CreateNewDocument();
            var f = IntPtr.Zero;
            try
            {
                int i = 0;
                foreach (var p in pages)
                {
                    var page = Native.FPDFPage_New(doc, i++, p.Size.Width, p.Size.Height);
                    foreach (var b in p.Boxes ?? [])
                    {
                        var r = Edit.FPDFPageObj_CreateNewRect((float)b.X, (float)b.Y, (float)b.Width, (float)b.Height);
                        Edit.FPDFPageObj_SetFillColor(r, 0, 0, 0, 255);
                        Edit.FPDFPath_SetDrawMode(r, Edit.FillAlternate, 0);
                        Edit.FPDFPage_InsertObject(page, r);
                    }
                    if (p.Text != null)
                    {
                        if (f == IntPtr.Zero)
                        {
                            var data = KoreanFont;
                            f = Edit.FPDFText_LoadFont(doc, data, (uint)data.Length, Edit.FontTrueType, 1);
                            Assert.NotEqual(IntPtr.Zero, f);
                        }
                        var t = Edit.FPDFPageObj_CreateTextObj(doc, f, 14);
                        Edit.FPDFText_SetText(t, p.Text);
                        Edit.FPDFPageObj_Transform(t, 1, 0, 0, 1, p.Size.Width / 2 - 40, p.Size.Height - 60);
                        Edit.FPDFPage_InsertObject(page, t);
                    }
                    Edit.FPDFPage_GenerateContent(page);
                    if (p.Rotate != 0) Native.FPDFPage_SetRotation(page, p.Rotate / 90);
                    Native.FPDF_ClosePage(page);
                }
                File.WriteAllBytes(path, PdfDoc.Save(doc));
            }
            finally
            {
                if (f != IntPtr.Zero) Edit.FPDFFont_Close(f);
                Native.FPDF_CloseDocument(doc);
            }
        }
        return path;
    }

    public static SourceFile Load(IEnumerable<TestPage> pages, string name = "f.pdf") =>
        SourceFile.Load(Make(pages, TempFile(name))) ?? throw new InvalidOperationException("시험용 PDF를 열지 못함");

    /// <summary>쪽을 dpi로 그려 밝기 128 미만 픽셀의 영역(pt, 왼쪽 아래 원점, 화면 방향)을 구한다.</summary>
    public static RectD? InkRect(PdfDoc doc, int index, double dpi = 72)
    {
        var (dark, w, h, sx, sy) = DarkMap(doc, index, dpi);
        int minX = w, maxX = -1, minY = h, maxY = -1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (dark[y * w + x])
                {
                    minX = Math.Min(minX, x); maxX = Math.Max(maxX, x);
                    minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
                }
        if (maxX < 0) return null;
        var size = doc.Geometry(index).Size;
        return RectD.FromEdges(minX / sx, size.Height - (maxY + 1) / sy, (maxX + 1) / sx, size.Height - minY / sy);
    }

    /// <summary>쪽을 그려 어두운 픽셀 지도를 만든다. 0번째 행이 쪽 맨 위.</summary>
    public static (bool[] dark, int w, int h, double sx, double sy) DarkMap(PdfDoc doc, int index, double dpi)
    {
        var size = doc.Geometry(index).Size;
        int w = (int)Math.Ceiling(size.Width * dpi / 72), h = (int)Math.Ceiling(size.Height * dpi / 72);
        var (px, _, _) = doc.RenderBgra(index, w, h);
        var dark = new bool[w * h];
        for (int i = 0; i < w * h; i++)
            dark[i] = (px[i * 4 + 2] * 299 + px[i * 4 + 1] * 587 + px[i * 4] * 114) / 1000 < 128;
        return (dark, w, h, w / size.Width, h / size.Height);
    }

    /// <summary>저장소 최상위(docs/expected/samples.json이 있는 곳).</summary>
    public static string RepoRoot
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir != null && !File.Exists(System.IO.Path.Combine(dir.FullName, "docs", "expected", "samples.json")))
                dir = dir.Parent;
            return dir?.FullName ?? throw new InvalidOperationException("저장소 최상위를 찾지 못함");
        }
    }

    /// <summary>실제 시험지 폴더. 저작권 때문에 git에 없으며, 없으면 관련 테스트를 건너뛴다.</summary>
    public static string? SamplesDir
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("MOGO_SAMPLES");
            var dir = !string.IsNullOrEmpty(env) ? env : System.IO.Path.Combine(RepoRoot, "Samples");
            return Directory.Exists(dir) ? dir : null;
        }
    }

    public static string Fixture(string name) => System.IO.Path.Combine(AppContext.BaseDirectory, "Fixtures", name);

    public static void AssertRect(RectD? actual, RectD expected, double accuracy, string? what = null)
    {
        Assert.True(actual.HasValue, $"{what}: 영역 없음");
        var a = actual!.Value;
        var ok = Math.Abs(a.MinX - expected.MinX) <= accuracy && Math.Abs(a.MinY - expected.MinY) <= accuracy &&
                 Math.Abs(a.MaxX - expected.MaxX) <= accuracy && Math.Abs(a.MaxY - expected.MaxY) <= accuracy;
        Assert.True(ok, $"{what}: {a} ≠ {expected} (±{accuracy})");
    }

    public static RectD Box(double x, double y, double w, double h) => new(x, y, w, h);
}
