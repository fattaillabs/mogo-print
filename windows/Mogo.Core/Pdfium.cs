using System.Runtime.InteropServices;

namespace Mogo.Core;

/// <summary>PDFium 함수 선언. PDFium은 스레드 안전하지 않으므로 모든 호출은 <see cref="Pdfium.Sync"/> 잠금 안에서 한다.</summary>
internal static class Native
{
    private const string Lib = "pdfium";

    [StructLayout(LayoutKind.Sequential)]
    public struct FS_MATRIX { public float a, b, c, d, e, f; }

    [StructLayout(LayoutKind.Sequential)]
    public struct FS_RECTF { public float left, top, right, bottom; }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int WriteBlockFn(IntPtr pThis, IntPtr data, uint size);

    [StructLayout(LayoutKind.Sequential)]
    public struct FPDF_FILEWRITE { public int version; public IntPtr WriteBlock; }

    public const int FPDF_ANNOT = 0x01, FPDF_GRAYSCALE = 0x08, FPDF_PRINTING = 0x800;

    [DllImport(Lib)] public static extern void FPDF_InitLibrary();
    [DllImport(Lib)] public static extern uint FPDF_GetLastError();
    [DllImport(Lib)] public static extern IntPtr FPDF_LoadMemDocument64(IntPtr data, nuint size, [MarshalAs(UnmanagedType.LPStr)] string? password);
    [DllImport(Lib)] public static extern IntPtr FPDF_CreateNewDocument();
    [DllImport(Lib)] public static extern void FPDF_CloseDocument(IntPtr doc);
    [DllImport(Lib)] public static extern int FPDF_GetPageCount(IntPtr doc);
    [DllImport(Lib)] public static extern IntPtr FPDF_LoadPage(IntPtr doc, int index);
    [DllImport(Lib)] public static extern void FPDF_ClosePage(IntPtr page);
    [DllImport(Lib)] public static extern float FPDF_GetPageWidthF(IntPtr page);
    [DllImport(Lib)] public static extern float FPDF_GetPageHeightF(IntPtr page);
    [DllImport(Lib)] public static extern int FPDFPage_GetRotation(IntPtr page);
    [DllImport(Lib)] public static extern void FPDFPage_SetRotation(IntPtr page, int rotate);
    [DllImport(Lib)] public static extern int FPDFPage_GetCropBox(IntPtr page, out float l, out float b, out float r, out float t);
    [DllImport(Lib)] public static extern int FPDFPage_GetMediaBox(IntPtr page, out float l, out float b, out float r, out float t);
    [DllImport(Lib)] public static extern void FPDFPage_SetMediaBox(IntPtr page, float l, float b, float r, float t);
    [DllImport(Lib)] public static extern void FPDFPage_SetCropBox(IntPtr page, float l, float b, float r, float t);
    [DllImport(Lib)] public static extern void FPDFPage_SetBleedBox(IntPtr page, float l, float b, float r, float t);
    [DllImport(Lib)] public static extern void FPDFPage_SetTrimBox(IntPtr page, float l, float b, float r, float t);
    [DllImport(Lib)] public static extern void FPDFPage_SetArtBox(IntPtr page, float l, float b, float r, float t);
    [DllImport(Lib)] public static extern int FPDFPage_TransFormWithClip(IntPtr page, ref FS_MATRIX matrix, ref FS_RECTF clip);
    [DllImport(Lib)] public static extern void FPDFPage_TransformAnnots(IntPtr page, double a, double b, double c, double d, double e, double f);
    [DllImport(Lib)] public static extern IntPtr FPDFPage_New(IntPtr doc, int index, double width, double height);
    [DllImport(Lib)] public static extern int FPDF_ImportPagesByIndex(IntPtr dest, IntPtr src, int[] indices, uint length, int index);
    [DllImport(Lib)] public static extern int FPDF_SaveAsCopy(IntPtr doc, ref FPDF_FILEWRITE writer, uint flags);
    [DllImport(Lib)] public static extern IntPtr FPDFBitmap_Create(int width, int height, int alpha);
    [DllImport(Lib)] public static extern void FPDFBitmap_FillRect(IntPtr bitmap, int left, int top, int width, int height, uint color);
    [DllImport(Lib)] public static extern IntPtr FPDFBitmap_GetBuffer(IntPtr bitmap);
    [DllImport(Lib)] public static extern int FPDFBitmap_GetStride(IntPtr bitmap);
    [DllImport(Lib)] public static extern void FPDFBitmap_Destroy(IntPtr bitmap);
    [DllImport(Lib)] public static extern void FPDF_RenderPageBitmap(IntPtr bitmap, IntPtr page, int x, int y, int w, int h, int rotate, int flags);
    [DllImport(Lib)] public static extern void FPDF_RenderPage(IntPtr hdc, IntPtr page, int x, int y, int w, int h, int rotate, int flags);
    [DllImport(Lib)] public static extern IntPtr FPDFText_LoadPage(IntPtr page);
    [DllImport(Lib)] public static extern void FPDFText_ClosePage(IntPtr textPage);
    [DllImport(Lib)] public static extern int FPDFText_CountChars(IntPtr textPage);
    [DllImport(Lib)] public static extern int FPDFText_GetText(IntPtr textPage, int start, int count, [Out] ushort[] buffer);
}

/// <summary>PDFium 전역 잠금과 초기화.</summary>
public static class Pdfium
{
    /// <summary>PDFium 호출은 모두 이 잠금 안에서 한다(PDFium은 스레드 안전하지 않다).</summary>
    public static readonly object Sync = new();

    static Pdfium()
    {
        Native.FPDF_InitLibrary();
    }

    internal static void EnsureInit() { } // 정적 생성자를 부르기 위한 빈 함수
}

/// <summary>PDF 문서 하나(PDFium 핸들). 파일을 메모리로 읽어 열므로 한글 경로도 문제없다.</summary>
public sealed class PdfDoc : IDisposable
{
    internal IntPtr Handle { get; private set; }
    private IntPtr _memory;

    public int PageCount { get; }

    private PdfDoc(IntPtr handle, IntPtr memory)
    {
        Handle = handle;
        _memory = memory;
        PageCount = Native.FPDF_GetPageCount(handle);
    }

    public static PdfDoc? Open(string path)
    {
        byte[] data;
        try { data = File.ReadAllBytes(path); } catch { return null; }
        return FromBytes(data);
    }

    public static PdfDoc? FromBytes(byte[] data)
    {
        Pdfium.EnsureInit();
        var mem = Marshal.AllocHGlobal(Math.Max(data.Length, 1));
        Marshal.Copy(data, 0, mem, data.Length);
        lock (Pdfium.Sync)
        {
            var handle = Native.FPDF_LoadMemDocument64(mem, (nuint)data.Length, null);
            if (handle == IntPtr.Zero)
            {
                Marshal.FreeHGlobal(mem);
                return null; // 암호가 걸렸거나 손상된 파일
            }
            return new PdfDoc(handle, mem);
        }
    }

    /// <summary>쪽의 기하 정보(cropBox, 회전).</summary>
    public PageGeometry Geometry(int index)
    {
        lock (Pdfium.Sync)
        {
            var page = Native.FPDF_LoadPage(Handle, index);
            try { return GeometryOf(page); }
            finally { Native.FPDF_ClosePage(page); }
        }
    }

    internal static PageGeometry GeometryOf(IntPtr page)
    {
        float l, b, r, t;
        if (Native.FPDFPage_GetCropBox(page, out l, out b, out r, out t) == 0 &&
            Native.FPDFPage_GetMediaBox(page, out l, out b, out r, out t) == 0)
        {
            l = 0; b = 0; r = Native.FPDF_GetPageWidthF(page); t = Native.FPDF_GetPageHeightF(page);
        }
        var box = new RectD(Math.Min(l, r), Math.Min(b, t), Math.Abs(r - l), Math.Abs(t - b));
        return new PageGeometry(box, ((Native.FPDFPage_GetRotation(page) % 4) + 4) % 4);
    }

    /// <summary>쪽 글자(PDFium 텍스트 추출).</summary>
    public string Text(int index)
    {
        lock (Pdfium.Sync)
        {
            var page = Native.FPDF_LoadPage(Handle, index);
            var text = Native.FPDFText_LoadPage(page);
            try
            {
                int n = Native.FPDFText_CountChars(text);
                if (n <= 0) return "";
                var buf = new ushort[n + 1];
                int written = Native.FPDFText_GetText(text, 0, n, buf);
                var chars = new char[Math.Max(0, written - 1)];
                for (int i = 0; i < chars.Length; i++) chars[i] = (char)buf[i];
                return new string(chars);
            }
            finally
            {
                Native.FPDFText_ClosePage(text);
                Native.FPDF_ClosePage(page);
            }
        }
    }

    /// <summary>쪽을 흰 바탕 위에 그려 BGRA(4바이트) 픽셀로 돌려준다. 페이지 회전이 반영된 화면 방향이다.</summary>
    public (byte[] pixels, int width, int height) RenderBgra(int index, int width, int height, bool grayscale = false)
    {
        width = Math.Max(1, width);
        height = Math.Max(1, height);
        lock (Pdfium.Sync)
        {
            // 화면 미리보기는 새 결과로 바뀌면서 문서를 닫는다. 그사이 늦게 온 렌더 요청에는 흰 그림을 준다.
            if (Handle == IntPtr.Zero)
            {
                var white = new byte[width * 4 * height];
                Array.Fill(white, (byte)255);
                return (white, width, height);
            }
            var page = Native.FPDF_LoadPage(Handle, index);
            var bmp = Native.FPDFBitmap_Create(width, height, 0);
            try
            {
                Native.FPDFBitmap_FillRect(bmp, 0, 0, width, height, 0xFFFFFFFF);
                Native.FPDF_RenderPageBitmap(bmp, page, 0, 0, width, height, 0, grayscale ? Native.FPDF_GRAYSCALE : 0);
                int stride = Native.FPDFBitmap_GetStride(bmp);
                var src = Native.FPDFBitmap_GetBuffer(bmp);
                var dst = new byte[width * 4 * height];
                for (int y = 0; y < height; y++)
                    Marshal.Copy(src + y * stride, dst, y * width * 4, width * 4);
                return (dst, width, height);
            }
            finally
            {
                Native.FPDFBitmap_Destroy(bmp);
                Native.FPDF_ClosePage(page);
            }
        }
    }

    /// <summary>쪽을 dpi로 그렸을 때의 픽셀 크기(회전 반영).</summary>
    public (int width, int height) PixelSize(int index, double dpi)
    {
        var g = Geometry(index);
        double s = dpi / 72.0;
        return ((int)Math.Ceiling(g.Size.Width * s), (int)Math.Ceiling(g.Size.Height * s));
    }

    /// <summary>프린터 장치(HDC)에 벡터 그대로 그린다. 좌표는 장치 픽셀.</summary>
    internal void RenderToDC(int index, IntPtr hdc, int x, int y, int w, int h, bool grayscale)
    {
        lock (Pdfium.Sync)
        {
            var page = Native.FPDF_LoadPage(Handle, index);
            try
            {
                int flags = Native.FPDF_PRINTING | Native.FPDF_ANNOT | (grayscale ? Native.FPDF_GRAYSCALE : 0);
                Native.FPDF_RenderPage(hdc, page, x, y, w, h, 0, flags);
            }
            finally { Native.FPDF_ClosePage(page); }
        }
    }

    public void Dispose()
    {
        lock (Pdfium.Sync)
        {
            if (Handle != IntPtr.Zero) { Native.FPDF_CloseDocument(Handle); Handle = IntPtr.Zero; }
        }
        if (_memory != IntPtr.Zero) { Marshal.FreeHGlobal(_memory); _memory = IntPtr.Zero; }
    }

    // MARK: 저장

    internal static byte[] Save(IntPtr doc)
    {
        var output = new MemoryStream();
        Native.WriteBlockFn write = (_, data, size) =>
        {
            var chunk = new byte[size];
            Marshal.Copy(data, chunk, 0, (int)size);
            output.Write(chunk, 0, chunk.Length);
            return 1;
        };
        var writer = new Native.FPDF_FILEWRITE { version = 1, WriteBlock = Marshal.GetFunctionPointerForDelegate(write) };
        if (Native.FPDF_SaveAsCopy(doc, ref writer, 0) == 0) throw new IOException("PDF를 저장하지 못했어요.");
        GC.KeepAlive(write);
        return output.ToArray();
    }
}
