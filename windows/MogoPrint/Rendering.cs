using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Mogo.Core;

namespace MogoPrint;

/// <summary>테마 색(Fluent 테마 이름이 없으면 무난한 기본색).</summary>
public static class Theme
{
    private static Brush Find(string key, Color fallback) =>
        Application.Current?.TryFindResource(key) as Brush ?? new SolidColorBrush(fallback);

    public static Brush Accent => Find("AccentFillColorDefaultBrush", Color.FromRgb(0x00, 0x67, 0xC0));
    public static Brush OnAccent => Find("TextOnAccentFillColorPrimaryBrush", Colors.White);
    public static Brush Secondary => Find("TextFillColorSecondaryBrush", Color.FromRgb(0x60, 0x60, 0x60));
    public static Brush Tertiary => Find("TextFillColorTertiaryBrush", Color.FromRgb(0x8A, 0x8A, 0x8A));
    public static Brush Primary => Find("TextFillColorPrimaryBrush", Color.FromRgb(0x1A, 0x1A, 0x1A));
    public static Brush Success => Find("SystemFillColorSuccessBrush", Color.FromRgb(0x0F, 0x7B, 0x0F));
    public static Brush Caution => Find("SystemFillColorCautionBrush", Color.FromRgb(0x9D, 0x5D, 0x00));
    public static Brush Canvas => Find("SolidBackgroundFillColorTertiaryBrush", Color.FromRgb(0xE6, 0xE6, 0xE6));
}

/// <summary>PDF 쪽을 WPF 그림으로 그린다(PDFium). 백그라운드 스레드에서 불러도 되도록 얼린(Freeze) 그림을 돌려준다.</summary>
public static class PageRenderer
{
    public static BitmapSource Render(PdfDoc doc, int index, int pixelWidth)
    {
        var size = doc.Geometry(index).Size;
        int w = Math.Max(1, pixelWidth), h = Math.Max(1, (int)Math.Round(pixelWidth * size.Height / size.Width));
        var (px, _, _) = doc.RenderBgra(index, w, h);
        var bmp = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, px, w * 4);
        bmp.Freeze();
        return bmp;
    }

    public static Task<BitmapSource> RenderAsync(PdfDoc doc, int index, int pixelWidth) =>
        Task.Run(() => Render(doc, index, pixelWidth));
}

/// <summary>미리보기의 A4 쪽 하나.</summary>
public sealed class PreviewPage(int index) : Observable
{
    public int Index { get; } = index;
    public int Number => Index + 1;

    private double width = 600, height = 848;
    public double Width { get => width; set => Set(ref width, value); }
    public double Height { get => height; set => Set(ref height, value); }

    private BitmapSource? image;
    public BitmapSource? Image { get => image; set => Set(ref image, value); }
    /// <summary>그림을 그린 픽셀 폭(창 크기가 많이 바뀌면 다시 그린다).</summary>
    public int ImagePixelWidth { get; set; }
    public bool Rendering { get; set; }

    private BitmapSource? thumb;
    public BitmapSource? Thumb { get => thumb; set => Set(ref thumb, value); }
}
