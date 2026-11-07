using Mogo.Core;
using Xunit;
using static Mogo.Core.Tests.TestPdf;

namespace Mogo.Core.Tests;

public class ImposerTests
{
    [Fact]
    public void CropIsInkPlusPaddingAndScaleFitsA4()
    {
        var box = Box(80, 70, 680, 1050);
        using var f = Load([new(A3, Boxes: [box])]);
        var o = new ImpositionOptions { PaperMarginMM = 5, PaddingMM = 1.5 };
        var page = Imposer.Plan([f], o)[0].Pages[0];
        AssertRect(page.Crop, box.Inset(-1.5 * MM, -1.5 * MM), 1.5);
        double uw = A4.Width - 10 * MM, uh = A4.Height - 10 * MM;
        Assert.Equal(Math.Min(uw / page.Crop.Width, uh / page.Crop.Height), page.Scale, 4);
    }

    [Fact]
    public void OneCropForAllPagesOfSameSize()
    {
        using var f = Load([
            new(A3, Boxes: [Box(100, 100, 300, 300)]),
            new(A3, Boxes: [Box(400, 600, 300, 400)]),
        ]);
        var pages = Imposer.Plan([f], new ImpositionOptions())[0].Pages;
        // 글자 크기가 쪽마다 달라지지 않도록 합친 영역 하나로 자른다.
        Assert.Equal(pages[0].Crop, pages[1].Crop);
        Assert.Equal(pages[0].Scale, pages[1].Scale);
        Assert.True(pages[0].Crop.Contains(Box(100, 100, 600, 900)));
    }

    [Fact]
    public void NeverEnlargesBeyondOriginal()
    {
        // 정답표처럼 원래 A4이고 내용이 작으면 100%로 둔다.
        using var f = Load([new(A4, Boxes: [Box(100, 500, 300, 200)])]);
        Assert.Equal(1, Imposer.Plan([f], new ImpositionOptions())[0].Scale, 4);
    }

    [Fact]
    public void MixedPageSizesGetTheirOwnCrop()
    {
        using var f = Load([
            new(A3, Boxes: [Box(80, 70, 680, 1050)]),
            new(A4, Boxes: [Box(60, 60, 470, 720)]),
        ]);
        var pages = Imposer.Plan([f], new ImpositionOptions())[0].Pages;
        Assert.NotEqual(pages[0].Crop, pages[1].Crop);
        Assert.True(new RectD(0, 0, A4.Width, A4.Height).Contains(pages[1].Crop));
        AssertRect(pages[1].Crop, Box(60, 60, 470, 720).Inset(-1.5 * MM, -1.5 * MM), 1.5);
    }

    [Fact]
    public void CropAdjustment()
    {
        var box = Box(80, 70, 680, 1050);
        using var f = Load([new(A3, Boxes: [box])]);
        var o = new ImpositionOptions();
        var baseCrop = Imposer.Plan([f], o)[0].Pages[0].Crop;

        o = o.WithAdjustment(f.Path, new CropAdjustment(Top: 10, Bottom: -5, Left: 3, Right: 0));
        var adj = Imposer.Plan([f], o)[0].Pages[0].Crop;
        Assert.Equal(baseCrop.MaxY - 10 * MM, adj.MaxY, 2);
        Assert.Equal(baseCrop.MinY - 5 * MM, adj.MinY, 2);
        Assert.Equal(baseCrop.MinX + 3 * MM, adj.MinX, 2);
        Assert.Equal(baseCrop.MaxX, adj.MaxX, 2);

        o = o.WithAdjustment(f.Path, new CropAdjustment(WholePage: true));
        // PDFium은 쪽 크기를 float로 준다(841.89 → 841.8900146…).
        AssertRect(Imposer.Plan([f], o)[0].Pages[0].Crop, new RectD(0, 0, A3.Width, A3.Height), 0.01);

        // 잘라낸 결과가 페이지 밖으로 나가거나 뒤집히지 않는다.
        o = o.WithAdjustment(f.Path, new CropAdjustment(Top: -500, Bottom: 900));
        var silly = Imposer.Plan([f], o)[0].Pages[0].Crop;
        var pageRect = new RectD(0, 0, f.Geometry[0].Size.Width, f.Geometry[0].Size.Height); // PDFium이 준 실제 크기(float)
        Assert.True(pageRect.Contains(silly), $"{silly}");
        Assert.True(silly.Height > 0);

        // 경로 대소문자가 달라도 같은 파일의 조정으로 본다(윈도우 경로).
        o = new ImpositionOptions().WithAdjustment(f.Path.ToUpperInvariant(), new CropAdjustment(Top: 10));
        Assert.Equal(baseCrop.MaxY - 10 * MM, Imposer.Plan([f], o)[0].Pages[0].Crop.MaxY, 2);
    }

    [Fact]
    public void BlankPagePadding()
    {
        var p = new TestPage(A3, Boxes: [Box(100, 100, 500, 800)]);
        using var three = Load([p, p, p], "three.pdf");
        using var two = Load([p, p], "two.pdf");
        using var one = Load([p], "one.pdf");

        var o = new ImpositionOptions { PadSectionsToEven = true };
        var plan = Imposer.Plan([three, two, one], o);
        Assert.Equal([true, false, false], plan.Select(s => s.PadsBlankPage)); // 마지막 파일 뒤에는 기본으로 안 넣는다
        Assert.Equal(3 + 1 + 2 + 1, Imposer.Render(plan).PageCount);

        o = o with { PadEndToEven = true }; // 양면으로 여러 부
        plan = Imposer.Plan([three, two, one], o);
        Assert.Equal([true, false, true], plan.Select(s => s.PadsBlankPage));
        var result = Imposer.Render(plan);
        Assert.Equal(8, result.PageCount);
        using var outDoc = PdfDoc.FromBytes(result.Pdf)!;
        Assert.Equal(8, outDoc.PageCount);
        Assert.Null(InkRect(outDoc, 3)); // 빈 쪽

        o = o with { PadSectionsToEven = false }; // 단면
        plan = Imposer.Plan([three, two, one], o);
        Assert.Equal([false, false, false], plan.Select(s => s.PadsBlankPage));
    }

    [Fact]
    public void RenderMakesA4PagesCenteredInsideMargin()
    {
        using var f = Load([new(A3, Boxes: [Box(80, 70, 680, 1050)])]);
        var result = Imposer.Impose([f], new ImpositionOptions { PaperMarginMM = 5 });
        using var outDoc = PdfDoc.FromBytes(result.Pdf)!;
        Assert.Equal(1, outDoc.PageCount);
        var g = outDoc.Geometry(0);
        Assert.Equal(0, g.Rotation);
        Assert.Equal(A4.Width, g.Size.Width, 2);
        Assert.Equal(A4.Height, g.Size.Height, 2);

        var ink = InkRect(outDoc, 0, 144)!.Value;
        double left = ink.MinX, right = A4.Width - ink.MaxX, bottom = ink.MinY, top = A4.Height - ink.MaxY;
        // 잉크는 여백(5mm) + 덧붙인 여유(1.5mm × 배율) 안쪽에, 좌우·위아래 대칭으로 놓인다.
        foreach (var m in new[] { left, right, bottom, top }) Assert.True(m >= 5 * MM, $"여백 {m / MM:F2}mm");
        // 감지는 50dpi라 한 변이 최대 1픽셀(1.44pt)까지 넓게 잡힐 수 있어서 그만큼의 비대칭은 허용한다.
        Assert.InRange(left - right, -2.5, 2.5);
        Assert.InRange(top - bottom, -2.5, 2.5);
        // 한쪽 방향은 꽉 차야 한다(배율을 최대로 썼는지).
        Assert.InRange(Math.Min(left, top) - (5 * MM + 1.5 * MM * result.Sections[0].Scale), -1.5, 1.5);
    }

    /// <summary>회전된 원본도 화면에 보이는 방향 그대로 A4에 놓여야 한다.</summary>
    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void RotatedSourceKeepsDisplayedOrientation(int rotate)
    {
        // 회전 전 기준 왼쪽 위에 작은 표시, 오른쪽 아래에 큰 상자.
        RectD[] boxes = [Box(20, 520, 40, 40), Box(250, 30, 120, 150)];
        using var f = Load([new(new SizeD(400, 600), Rotate: rotate, Boxes: boxes)], $"rot{rotate}.pdf");
        var result = Imposer.Impose([f], new ImpositionOptions());
        using var outDoc = PdfDoc.FromBytes(result.Pdf)!;
        Assert.Equal(0, outDoc.Geometry(0).Rotation);
        Assert.Equal(Quadrants(f.Doc, 0), Quadrants(outDoc, 0));
    }

    /// <summary>잉크 영역을 네 칸으로 나눠 칸마다 잉크가 있는지(왼위, 오위, 왼아래, 오아래).</summary>
    private static bool[] Quadrants(PdfDoc doc, int index)
    {
        var (dark, w, h, _, _) = DarkMap(doc, index, 72);
        int minX = w, maxX = -1, minY = h, maxY = -1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (dark[y * w + x]) { minX = Math.Min(minX, x); maxX = Math.Max(maxX, x); minY = Math.Min(minY, y); maxY = Math.Max(maxY, y); }
        int mx = (minX + maxX) / 2, my = (minY + maxY) / 2;
        bool Any(int x0, int x1, int y0, int y1)
        {
            for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) if (dark[y * w + x]) return true;
            return false;
        }
        // 비트맵 0번째 행이 위.
        return [Any(minX, mx, minY, my), Any(mx + 1, maxX, minY, my), Any(minX, mx, my + 1, maxY), Any(mx + 1, maxX, my + 1, maxY)];
    }

    /// <summary>원본 글자를 이미지로 굽지 않고 벡터 그대로 옮긴다. 그 증거로 결과 쪽에서 글자가 그대로 읽힌다.</summary>
    [Fact]
    public void RenderKeepsTextAsVector()
    {
        using var f = Load([new(A3, "국어 영역 홀수형 모고프린트", Boxes: [Box(100, 100, 600, 900)])]);
        var result = Imposer.Impose([f], new ImpositionOptions());
        using var outDoc = PdfDoc.FromBytes(result.Pdf)!;
        Assert.Contains("모고프린트", outDoc.Text(0));
        // 그림으로 구웠다면 수 MB가 된다. 글꼴(맑은 고딕)을 빼면 작은 파일이어야 한다.
        Assert.True(result.Pdf.Length < new FileInfo(f.Path).Length + 200_000, $"{result.Pdf.Length} bytes");
    }

    [Fact]
    public void VariantSelectionInPlan()
    {
        RectD[] box = [Box(100, 100, 600, 900)];
        using var f = Load([new(A3, "홀수형", Boxes: box), new(A3, "2", Boxes: box), new(A3, "짝수형", Boxes: box)]);
        Assert.Equal([2], Imposer.Plan([f], new ImpositionOptions { Variant = ExamVariant.Even })[0].PageIndices);
        Assert.Equal([0, 1, 2], Imposer.Plan([f], new ImpositionOptions { Variant = ExamVariant.All })[0].PageIndices);
    }

    [Fact]
    public void ExpandPDFs()
    {
        var dir = TempDir();
        foreach (var name in new[] { "1.pdf", "10.pdf", "2.pdf", "X.PDF", ".hidden.pdf", "._1.pdf", "note.txt" })
            File.WriteAllText(System.IO.Path.Combine(dir, name), "x");
        Directory.CreateDirectory(System.IO.Path.Combine(dir, "sub"));
        File.WriteAllText(System.IO.Path.Combine(dir, "sub", "3.pdf"), "x");
        // 윈도우 숨김 속성 파일도 뺀다.
        var hidden = System.IO.Path.Combine(dir, "숨김.pdf");
        File.WriteAllText(hidden, "x");
        File.SetAttributes(hidden, FileAttributes.Hidden);

        var names = FileExpander.ExpandPDFs([dir]).Select(p => System.IO.Path.GetRelativePath(dir, p)).ToList();
        Assert.Equal(["1.pdf", "2.pdf", "10.pdf", @"sub\3.pdf", "X.PDF"], names);

        // 같은 파일을 두 번 넣어도 한 번만, 없는 경로와 PDF 아닌 파일은 뺀다.
        var again = FileExpander.ExpandPDFs([System.IO.Path.Combine(dir, "2.pdf"), dir, System.IO.Path.Combine(dir, "nope.pdf"),
                                             System.IO.Path.Combine(dir, "note.txt"), System.IO.Path.Combine(dir, "2.PDF")]);
        Assert.Equal(5, again.Count);
        Assert.Equal("2.pdf", System.IO.Path.GetFileName(again[0]));
    }
}

public class CropGuidesTests
{
    private static SourceFile File2() => Load([
        new(A3, Boxes: [Box(80, 70, 680, 1050)]),
        new(A3, Boxes: [Box(90, 90, 600, 1000)]),
    ], "g.pdf");

    /// <summary>수동 조정 화면이 쓰는 계산은 실제 배치와 같은 값을 내야 한다.</summary>
    [Fact]
    public void ScreenMathMatchesPlan()
    {
        using var f = File2();
        var o = new ImpositionOptions();
        foreach (var adjust in new[] { new CropAdjustment(), new CropAdjustment(Top: 12.5, Bottom: -3), new CropAdjustment(WholePage: true) })
        {
            o = o.WithAdjustment(f.Path, adjust);
            var placed = Imposer.Plan([f], o)[0].Pages[0];
            Assert.Equal(placed.Crop, Imposer.Crop(f, 0, o));
            Assert.Equal(placed.Scale, Imposer.Scale(placed.Crop, o), 9);
        }
        // 기준(자동) 범위는 손 조정과 상관없다.
        o = o.WithAdjustment(f.Path, new CropAdjustment(Top: 12.5));
        var baseCrop = Imposer.BaseCrop(f, 0, o);
        o = o.WithAdjustment(f.Path, null);
        Assert.Equal(baseCrop, Imposer.BaseCrop(f, 0, o));
    }

    [Fact]
    public void GuidesStayInsidePageAndApart()
    {
        var page = new SizeD(842, 1190);
        var c = Box(80, 100, 680, 900); // 왼80 오760 아래100 위1000
        var r = CropGuides.Move(CropGuides.Edge.Top, 5000, c, page);
        Assert.Equal(page.Height, r.MaxY);                          // 페이지 위로 못 나감
        Assert.Equal(c.MinY, r.MinY);                               // 나머지 변은 그대로
        Assert.Equal(c.MinX, r.MinX);
        Assert.Equal(c.MaxX, r.MaxX);
        r = CropGuides.Move(CropGuides.Edge.Top, 50, c, page);
        Assert.Equal(c.MinY + CropGuides.MinGap, r.MaxY, 3);        // 아래 점선과 최소 간격
        r = CropGuides.Move(CropGuides.Edge.Bottom, -40, c, page);
        Assert.Equal(0, r.MinY);
        r = CropGuides.Move(CropGuides.Edge.Bottom, 990, c, page);
        Assert.Equal(c.MaxY - CropGuides.MinGap, r.MinY, 3);
        r = CropGuides.Move(CropGuides.Edge.Left, -10, c, page);
        Assert.Equal(0, r.MinX);                                    // 페이지 왼쪽 밖으로 못 나감
        r = CropGuides.Move(CropGuides.Edge.Left, 755, c, page);
        Assert.Equal(c.MaxX - CropGuides.MinGap, r.MinX, 3);
        r = CropGuides.Move(CropGuides.Edge.Right, 2000, c, page);
        Assert.Equal(page.Width, r.MaxX);
        r = CropGuides.Move(CropGuides.Edge.Right, 100, c, page);
        Assert.Equal(c.MinX + CropGuides.MinGap, r.MaxX, 3);
        r = CropGuides.Move(CropGuides.Edge.Right, 700, c, page);
        Assert.Equal(Box(80, 100, 620, 900), r);
    }

    [Fact]
    public void GuidePositionToAdjustmentRoundTrip()
    {
        using var f = File2();
        var o = new ImpositionOptions();
        var b = Imposer.BaseCrop(f, 0, o);
        // 위 점선 10mm 아래로, 아래 점선 4mm 아래로(여백 더 남김), 왼쪽 6mm 안으로, 오른쪽 2mm 밖으로.
        var crop = new RectD(b.MinX + 6 * MM, b.MinY - 4 * MM, b.Width - 6 * MM + 2 * MM, b.Height - 10 * MM + 4 * MM);
        var a = CropGuides.Adjustment(crop, b, new CropAdjustment());
        Assert.Equal(10, a.Top);
        Assert.Equal(-4, a.Bottom);
        Assert.Equal(6, a.Left);
        Assert.Equal(-2, a.Right);
        // 그 값으로 배치하면 점선 위치가 그대로 자르는 선이 된다(페이지 안인 범위에서).
        o = o.WithAdjustment(f.Path, a);
        var placed = Imposer.Crop(f, 0, o);
        var expected = crop.Intersect(new RectD(0, 0, f.Geometry[0].Size.Width, f.Geometry[0].Size.Height));
        Assert.Equal(expected.MinX, placed.MinX, 2);
        Assert.Equal(expected.MaxX, placed.MaxX, 2);
        Assert.Equal(expected.MinY, placed.MinY, 2);
        Assert.Equal(expected.MaxY, placed.MaxY, 2);
        // 0.5mm 단위로 반올림하고, '자동 자르기 끄기'는 그대로 둔다.
        var r = CropGuides.Adjustment(b.Inset(1.2 * MM, 3.3 * MM), b, new CropAdjustment(WholePage: true));
        Assert.Equal(3.5, r.Top);
        Assert.Equal(1, r.Left);
        Assert.True(r.WholePage);
    }
}
