using Mogo.Core;
using Xunit;
using static Mogo.Core.Tests.TestPdf;

namespace Mogo.Core.Tests;

public class AnalyzerTests
{
    [Fact]
    public void VariantLabelVariants()
    {
        Assert.Equal(ExamVariant.Odd, ExamAnalyzer.VariantLabel("제1교시 국어 영역 홀수형"));
        Assert.Equal(ExamVariant.Even, ExamAnalyzer.VariantLabel("짝 수 형"));
        // 정답표 표기 "( 홀수 )형"
        Assert.Equal(ExamVariant.Odd, ExamAnalyzer.VariantLabel("국어 영역 정답표\n( 홀수 )형"));
        Assert.Equal(ExamVariant.Even, ExamAnalyzer.VariantLabel("(짝수)형"));
        // 둘 다 있거나 없으면 라벨이 아니다.
        Assert.Null(ExamAnalyzer.VariantLabel("홀수형/짝수형을 확인하시오"));
        Assert.Null(ExamAnalyzer.VariantLabel("수학 영역"));
        Assert.Null(ExamAnalyzer.VariantLabel(""));
    }

    [Fact]
    public void PropagateKeepsLeadingPagesUnlabeled()
    {
        ExamVariant?[] labels = [null, ExamVariant.Odd, null, null, ExamVariant.Even, null];
        Assert.Equal([null, ExamVariant.Odd, ExamVariant.Odd, ExamVariant.Odd, ExamVariant.Even, ExamVariant.Even],
                     ExamAnalyzer.Propagate(labels));
    }

    [Fact]
    public void CombinedFileSplitsByVariantAndKeepsCover()
    {
        using var file = Load([
            new(A3, "표지"),
            new(A3, "국어 영역 홀수형"),
            new(A3, "2쪽"),
            new(A3, "국어 영역 짝수형"),
            new(A3, "2쪽"),
        ], "combined.pdf");
        Assert.Equal(5, file.PageCount);
        Assert.True(file.HasBothVariants);
        Assert.Equal([null, ExamVariant.Odd, ExamVariant.Odd, ExamVariant.Even, ExamVariant.Even], file.PageVariants);
        // 표지(라벨 앞)는 어느 형에도 들어간다.
        Assert.Equal([0, 1, 2], file.PageIndices(ExamVariant.Odd));
        Assert.Equal([0, 3, 4], file.PageIndices(ExamVariant.Even));
        Assert.Equal([0, 1, 2, 3, 4], file.PageIndices(ExamVariant.All));
    }

    [Fact]
    public void SingleVariantFileKeepsAllPages()
    {
        using var file = Load([new(A3, "홀수형"), new(A3, "2쪽")], "odd-only.pdf");
        Assert.False(file.HasBothVariants);
        // 짝수형을 골라도 한 형만 있는 파일은 통째로 쓴다.
        Assert.Equal([0, 1], file.PageIndices(ExamVariant.Even));
    }

    [Fact]
    public void InkBoundsMatchesDrawnBox()
    {
        var box = Box(100, 200, 150, 300);
        using var file = Load([new(A4, Boxes: [box])], "box.pdf");
        // 50dpi 렌더링이라 한 픽셀(1.44pt) 정도 오차.
        AssertRect(file.InkBounds[0], box, 1.5);
    }

    [Fact]
    public void BlankPageHasNoInk()
    {
        using var file = Load([new(A4)], "blank.pdf");
        Assert.Null(file.InkBounds[0]);
    }

    /// <summary>/Rotate가 있는 쪽은 화면에 보이는 방향(시계 방향 회전)으로 크기와 잉크 영역을 잡아야 한다.</summary>
    [Theory]
    [InlineData(90, 30, 320, 40, 60)]   // 400×600 쪽의 (20,30,60×40) 상자 → 600×400 화면에서 (30,320,40×60)
    [InlineData(180, 320, 530, 60, 40)]
    [InlineData(270, 530, 20, 40, 60)]
    public void RotatedPageInkBoundsFollowDisplayOrientation(int rotate, double x, double y, double w, double h)
    {
        using var file = Load([new(new SizeD(400, 600), Rotate: rotate, Boxes: [Box(20, 30, 60, 40)])], $"rot{rotate}.pdf");
        var expectedSize = rotate == 180 ? new SizeD(400, 600) : new SizeD(600, 400);
        Assert.Equal(expectedSize, file.Geometry[0].Size);
        AssertRect(file.InkBounds[0], Box(x, y, w, h), 1.5, $"rotate {rotate}");
        // 시험 도우미(PDFium 화면 방향 렌더링)로 잰 값과도 같다.
        AssertRect(file.InkBounds[0], InkRect(file.Doc, 0)!.Value, 2, $"rotate {rotate} display");
    }

    [Fact]
    public void LockedOrBrokenFileReturnsNull()
    {
        var broken = TempFile("broken.pdf");
        File.WriteAllText(broken, "not a pdf");
        Assert.Null(SourceFile.Load(broken));
        Assert.Null(SourceFile.Load(TempFile("없는파일.pdf")));
        // 맥 PDFKit으로 만든 암호(pw) 걸린 PDF
        Assert.Null(SourceFile.Load(Fixture("locked.pdf")));
    }

    [Fact]
    public void KoreanPathAndSpacesOpen()
    {
        var dir = System.IO.Path.Combine(TempDir(), "2026학년도 대학수학능력시험");
        Directory.CreateDirectory(dir);
        var path = Make([new(A4, "가나다", Boxes: [Box(50, 50, 100, 100)])], System.IO.Path.Combine(dir, "2026수능_국어영역_문제지.pdf"));
        using var file = SourceFile.Load(path);
        Assert.NotNull(file);
        Assert.Equal("2026수능_국어영역_문제지", file!.Name);
        Assert.Contains("가나다", file.Doc.Text(0));
    }

    /// <summary>쪽이 많은 합본: 형과 잉크 영역이 쪽마다 따로 맞게 잡히는지.</summary>
    [Fact]
    public void ManyPagesAnalysis()
    {
        var pages = Enumerable.Range(0, 40).Select(i => new TestPage(A3,
            i == 0 ? "홀수형" : i == 20 ? "짝수형" : $"{i}쪽",
            Boxes: [Box(50 + i, 60, 300, 400 + i)])).ToList();
        using var file = Load(pages, "big.pdf");
        Assert.Equal(20, file.PageIndices(ExamVariant.Odd).Count);
        Assert.Equal(20, file.PageIndices(ExamVariant.Even).Count);
        for (int i = 0; i < 40; i++)
        {
            var ink = file.InkBounds[i]!.Value;
            // 50dpi라 한 픽셀(1.44pt)까지 어느 쪽으로든 어긋날 수 있다.
            Assert.InRange(ink.MinX, 50 + i - 1.5, 50 + i + 1.5);
            Assert.InRange(ink.MinY, 60 - 1.5, 60 + 1.5);
        }
    }
}

public class ElectiveTests
{
    [Fact]
    public void ElectiveLabel()
    {
        Assert.Equal(Elective.SpeechWriting, ExamAnalyzer.ElectiveLabel("2026학년도 대학수학능력시험 문제지\n1\n(화법과 작문)\n제1교시"));
        Assert.Equal(Elective.LanguageMedia, ExamAnalyzer.ElectiveLabel("4 (언어와 매체) 홀수형"));
        Assert.Equal(Elective.Probability, ExamAnalyzer.ElectiveLabel("수학 영역（확률과 통계）")); // 전각 괄호
        Assert.Equal(Elective.Calculus, ExamAnalyzer.ElectiveLabel("( 미 적 분 )"));              // 띄어쓰기 무시
        Assert.Equal(Elective.Geometry, ExamAnalyzer.ElectiveLabel("(기하)"));
        // 공통 마지막 쪽의 안내문은 선택과목 쪽이 아니다.
        Assert.Null(ExamAnalyzer.ElectiveLabel("◦이어서, ｢선택과목(화법과 작문)｣ 문제가 제시되오니, 자신이 선택한 과목인지 확인하시오."));
        // 선택과목 쪽 안에 다음 과목 안내가 있어도 그 쪽의 과목으로 본다.
        Assert.Equal(Elective.SpeechWriting, ExamAnalyzer.ElectiveLabel("4 (화법과 작문) 홀수형 … 「선택과목(언어와 매체)」 문제가 제시되오니"));
        // 괄호 없이 지문에 나온 낱말, 두 과목이 함께 나오는 쪽은 판정하지 않는다.
        Assert.Null(ExamAnalyzer.ElectiveLabel("기하학적 무늬와 미적분의 역사"));
        Assert.Null(ExamAnalyzer.ElectiveLabel("(확률과 통계) (기하)"));
        Assert.Null(ExamAnalyzer.ElectiveLabel("국어 영역"));
    }

    [Fact]
    public void ElectiveNames()
    {
        Assert.Equal(Elective.LanguageMedia, ElectiveInfo.Parse("언매"));
        Assert.Equal(Elective.LanguageMedia, ElectiveInfo.Parse("언어와 매체"));
        Assert.Equal(Elective.Probability, ElectiveInfo.Parse("확률과통계"));
        Assert.Null(ElectiveInfo.Parse("물리학"));
        Assert.Equal([Elective.SpeechWriting, Elective.LanguageMedia], ElectiveSubject.Korean.Electives());
        Assert.Equal([Elective.Probability, Elective.Calculus, Elective.Geometry], ElectiveSubject.Math.Electives());
    }

    /// <summary>홀·짝 합본에 선택과목까지 든 파일: 형과 선택과목을 함께 고른다. 공통 쪽은 언제나 들어간다.</summary>
    [Fact]
    public void VariantAndElectiveTogether()
    {
        RectD[] box = [Box(100, 100, 600, 900)];
        var pages = new List<TestPage>();
        foreach (var v in new[] { "홀수형", "짝수형" })
        {
            pages.Add(new(A3, $"국어 영역 {v}", Boxes: box));
            pages.Add(new(A3, "이어서 「선택과목(화법과 작문)」", Boxes: box));
            pages.Add(new(A3, "(화법과 작문)", Boxes: box));
            pages.Add(new(A3, "(언어와 매체)", Boxes: box));
        }
        using var f = Load(pages, "k.pdf");
        Assert.Equal([null, null, Elective.SpeechWriting, Elective.LanguageMedia, null, null, Elective.SpeechWriting, Elective.LanguageMedia],
                     f.PageElectives);
        Assert.Equal([Elective.SpeechWriting, Elective.LanguageMedia], f.Electives);
        Assert.Equal(ElectiveSubject.Korean, f.ElectiveSubject);

        var o = new ImpositionOptions();
        Assert.Equal([0, 1, 2, 3], f.PageIndices(o));                 // 홀수형, 선택과목 전체
        o = o.WithElective(ElectiveSubject.Korean, Elective.LanguageMedia);
        Assert.Equal([0, 1, 3], f.PageIndices(o));
        o = o with { Variant = ExamVariant.Even };
        Assert.Equal([4, 5, 7], f.PageIndices(o));
        o = o.WithElective(ElectiveSubject.Math, Elective.Calculus);   // 다른 과목 선택은 영향 없음
        Assert.Equal([4, 5, 7], f.PageIndices(o));
        o = o with { Variant = ExamVariant.All };
        Assert.Equal([0, 1, 3, 4, 5, 7], f.PageIndices(o));
        Assert.Equal([0, 1, 3, 4, 5, 7], Imposer.Plan([f], o)[0].PageIndices);
    }
}
