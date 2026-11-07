using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Mogo.Core;
using Xunit;
using static Mogo.Core.Tests.TestPdf;

namespace Mogo.Core.Tests;

/// <summary>실제 평가원·교육청 기출 PDF로 하는 시험. 저장소 최상위 Samples/가 없으면 건너뛴다(저작권 때문에 git에 안 넣음).</summary>
public class SampleTests
{
    private static string Sample(string path)
    {
        var dir = SamplesDir;
        if (dir == null) Assert.Skip("Samples 폴더 없음");
        var full = System.IO.Path.Combine(dir, path.Replace('/', System.IO.Path.DirectorySeparatorChar));
        if (!File.Exists(full) && !Directory.Exists(full)) Assert.Skip($"{path} 없음");
        return full;
    }

    private static SourceFile Open(string path) => SourceFile.Load(Sample(path)) ?? throw new InvalidOperationException(path);

    [Fact]
    public void Suneung2026KoreanCombinedOddEven()
    {
        using var file = Open("2026수능_국어_문제지.pdf");
        Assert.Equal(40, file.PageCount);
        Assert.True(file.HasBothVariants);
        var odd = file.PageIndices(ExamVariant.Odd);
        var even = file.PageIndices(ExamVariant.Even);
        Assert.Equal(Enumerable.Range(0, 20), odd);
        Assert.Equal(Enumerable.Range(20, 20), even);
        Assert.Equal(ExamVariant.Odd, ExamAnalyzer.VariantLabel(file.Doc.Text(odd[0])));
        Assert.Equal(ExamVariant.Even, ExamAnalyzer.VariantLabel(file.Doc.Text(even[0])));

        var result = Imposer.Impose([file], new ImpositionOptions { Variant = ExamVariant.Even });
        Assert.Equal(20, result.PageCount);
        Assert.InRange(result.Sections[0].Scale, 0.785, 0.815);
        // 벡터 그대로 옮긴다. PDFium은 한컴 글자 대응표도 그대로 옮기므로(맥 Quartz와 달리) 본문 글자까지 읽힌다.
        using var outDoc = PdfDoc.FromBytes(result.Pdf)!;
        var text = outDoc.Text(0);
        Assert.Contains("저작권", text);
        Assert.Equal(ExamVariant.Even, ExamAnalyzer.VariantLabel(text));
    }

    /// <summary>2022~2027학년도 국어·수학은 공통 쪽 뒤에 선택과목 쪽이 이어진다. 고른 과목만 남는지 본다.</summary>
    [Fact]
    public void ElectivesOnRealExams()
    {
        using var korean = Open("2026수능_국어_문제지.pdf");
        using var math = Open("2026수능_수학_문제지.pdf");
        Assert.Equal([Elective.SpeechWriting, Elective.LanguageMedia], korean.Electives);
        Assert.Equal([Elective.Probability, Elective.Calculus, Elective.Geometry], math.Electives);

        var o = new ImpositionOptions()
            .WithElective(ElectiveSubject.Korean, Elective.LanguageMedia)
            .WithElective(ElectiveSubject.Math, Elective.Calculus);
        Assert.Equal(Enumerable.Range(0, 12).Concat(Enumerable.Range(16, 4)), korean.PageIndices(o)); // 공통 1~12쪽 + 언매 17~20쪽
        Assert.Equal(Enumerable.Range(0, 8).Concat(Enumerable.Range(12, 4)), math.PageIndices(o));    // 공통 1~8쪽 + 미적 13~16쪽
        o = (o with { Variant = ExamVariant.Even }).WithElective(ElectiveSubject.Math, Elective.Geometry);
        Assert.Equal(Enumerable.Range(20, 8).Concat(Enumerable.Range(36, 4)), math.PageIndices(o));   // 짝수형 공통 + 기하

        // 모의평가·교육청 학력평가도 같은 구조다.
        foreach (var path in new[] { "2027_6월모평_국어_문제지.pdf", "2027_9월모평_수학_문제지.pdf", "참고_2026_7월학평(교육청)_국어_문제지.pdf" })
        {
            using var f = Open(path);
            Assert.Equal(f.ElectiveSubject == ElectiveSubject.Korean ? 2 : 3, f.Electives.Count);
        }
        // 선택과목 이전(2019) 시험지는 판정하지 않는다.
        using var old = Open("2019수능_국어/국어_홀.pdf");
        Assert.Empty(old.Electives);
    }

    [Fact]
    public void SeparateOddEvenFilesKeepAllPages()
    {
        using var odd = Open("2019수능_국어/국어_홀.pdf");
        using var even = Open("2019수능_국어/국어_짝.pdf");
        Assert.False(odd.HasBothVariants);
        Assert.False(even.HasBothVariants);
        // 형을 골라도 한 형만 든 파일은 통째로 쓴다.
        Assert.Equal([16, 16], Imposer.Plan([odd, even], new ImpositionOptions { Variant = ExamVariant.Odd }).Select(s => s.PageIndices.Count));
    }

    [Fact]
    public void InquirySubjectsHaveNarrowRightMargin()
    {
        var paths = FileExpander.ExpandPDFs([Sample("2026수능_사회탐구_문제지")]);
        Assert.Equal(9, paths.Count);
        var files = paths.Select(p => SourceFile.Load(p)!).ToList();
        try
        {
            foreach (var s in Imposer.Plan(files, new ImpositionOptions()))
            {
                Assert.Equal(4, s.Pages.Count);
                // 오른쪽 과목 탭 때문에 오른쪽 여백이 왼쪽보다 훨씬 좁다.
                var right = s.PageSize.Width - s.Crop.MaxX;
                Assert.True(right < s.Crop.MinX - 8 * MM, s.File.Name);
                Assert.InRange(s.Scale, 0.775, 0.805);
            }
        }
        finally { files.ForEach(f => f.Dispose()); }
    }

    [Fact]
    public void AnswerSheetSplitsByVariantAndIsNotEnlarged()
    {
        using var file = Open("2026수능_국어_정답표.pdf");
        Assert.Equal(2, file.PageCount);
        Assert.True(file.HasBothVariants, "정답표의 \"( 홀수 )형\" 표기를 인식해야 함");
        var plan = Imposer.Plan([file], new ImpositionOptions());
        Assert.Equal([0], plan[0].PageIndices);
        Assert.Equal(1, plan[0].Scale, 4);
    }

    /// <summary>모든 샘플을 한꺼번에 A4로 만들고, 모든 쪽이 A4이며 내용이 종이 여백 안에 있는지 본다.</summary>
    [Fact]
    public void AllSamplesFitInsideA4Margins()
    {
        var paths = FileExpander.ExpandPDFs([Sample("")]);
        Assert.True(paths.Count >= 20);
        var files = paths.Select(SourceFile.Load).ToList();
        try
        {
            Assert.All(files, f => Assert.NotNull(f));
            var result = Imposer.Impose(files.Select(f => f!).ToList(), new ImpositionOptions { Variant = ExamVariant.Odd, PaperMarginMM = 5 });
            using var outDoc = PdfDoc.FromBytes(result.Pdf)!;
            Assert.Equal(result.PageCount, outDoc.PageCount);
            Assert.Equal(result.Sections.Sum(s => s.OutputPageCount), result.PageCount);
            foreach (var s in result.Sections) Assert.InRange(s.Scale, 0.75, 1);
            // 30쪽마다 하나씩 그려서 여백을 잰다(전부 그리면 느리다).
            for (int i = 0; i < outDoc.PageCount; i += 30)
            {
                var size = outDoc.Geometry(i).Size;
                Assert.Equal(A4.Width, size.Width, 2);
                Assert.Equal(A4.Height, size.Height, 2);
                if (InkRect(outDoc, i) is not { } ink) continue; // 빈 쪽
                var margins = new[] { ink.MinX, A4.Width - ink.MaxX, ink.MinY, A4.Height - ink.MaxY };
                Assert.True(margins.Min() >= 5 * MM - 1, $"page {i} margins {string.Join(", ", margins.Select(m => (m / MM).ToString("F1")))}");
            }
        }
        finally { files.ForEach(f => f?.Dispose()); }
    }

    [Fact]
    public void MockExamFilesFromKiceAndEducationOffice()
    {
        foreach (var path in new[] { "2027_6월모평_국어_문제지.pdf", "2027_9월모평_수학_문제지.pdf", "참고_2026_7월학평(교육청)_국어_문제지.pdf" })
        {
            using var file = Open(path);
            Assert.Equal(20, file.PageCount);
            var s = Imposer.Plan([file], new ImpositionOptions())[0];
            Assert.InRange(s.PageSize.Width, 840.89, 842.89); // A3
            Assert.InRange(s.Scale, 0.79, 0.83);
        }
    }
}

/// <summary>
/// 시험지별 기준값(docs/expected/samples.json, 맥 버전이 만듦)과 비교한다. 두 버전이 같은 결과를 내는지 보는 시험이다.
/// 허용 오차는 여백 ±1.5mm, 배율 ±0.01(docs/ALGORITHM.md). 쪽수·형·선택과목 판정은 정확히 같아야 한다.
/// 여백이 맥과 1mm 넘게 갈리는 이유: 평가원 시험지 아래 회색 저작권 문구가 50dpi에서 밝기 200 근처로 그려져,
/// CoreGraphics와 PDFium의 글자 안티에일리어싱 차이로 끝 픽셀 1~3개가 잉크로 잡히기도 하고 안 잡히기도 한다.
/// </summary>
public class GoldenTests
{
    private readonly ITestOutputHelper log;
    public GoldenTests(ITestOutputHelper log) => this.log = log;

    [Fact]
    public void SamplesMatchGolden()
    {
        var dir = SamplesDir;
        if (dir == null) Assert.Skip("Samples 폴더 없음");
        var golden = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(RepoRoot, "docs", "expected", "samples.json")))!;
        var expected = golden["files"]!.AsArray();

        var paths = FileExpander.ExpandPDFs([dir]);
        // 기준값 경로는 '/' 구분, NFC 한글.
        string Key(string p) => System.IO.Path.GetRelativePath(dir, p).Replace('\\', '/').Normalize(NormalizationForm.FormC);
        Assert.Equal(expected.Select(e => (string)e!["path"]!).Order(StringComparer.Ordinal), paths.Select(Key).Order(StringComparer.Ordinal));

        var failures = new List<string>();
        double worstMargin = 0, worstScale = 0;
        foreach (var path in paths)
        {
            var key = Key(path);
            var e = expected.First(x => (string)x!["path"]! == key)!;
            using var file = SourceFile.Load(path)!;
            var section = Imposer.Plan([file], new ImpositionOptions())[0];
            var size = section.PageSize;
            var crop = section.Crop;
            var labels = string.Concat(file.PageVariants.Select(v => v switch { ExamVariant.Odd => 'O', ExamVariant.Even => 'E', _ => '-' }));
            var electives = string.Concat(file.PageElectives.Select(x => x?.Code() ?? '-'));

            void Same<T>(string name, T actual, T want)
            {
                if (!EqualityComparer<T>.Default.Equals(actual, want)) failures.Add($"{key} {name}: {actual} ≠ {want}");
            }
            Same("pages", file.PageCount, (int)e["pages"]!);
            Same("labels", labels, (string)e["labels"]!);
            Same("elective_labels", electives, (string)e["elective_labels"]!);
            Same("both_variants", file.HasBothVariants, (bool)e["both_variants"]!);
            Same("odd_page_count", file.PageIndices(ExamVariant.Odd).Count, (int)e["odd_page_count"]!);
            Same("even_page_count", file.PageIndices(ExamVariant.Even).Count, (int)e["even_page_count"]!);

            var sizeMM = e["page_size_mm"]!.AsArray().Select(v => (double)v!).ToArray();
            if (Math.Abs(size.Width / MM - sizeMM[0]) > 0.1 || Math.Abs(size.Height / MM - sizeMM[1]) > 0.1)
                failures.Add($"{key} page_size_mm: {size.Width / MM:F1}×{size.Height / MM:F1} ≠ {sizeMM[0]}×{sizeMM[1]}");

            var scaleDiff = Math.Abs(section.Scale - (double)e["scale"]!);
            worstScale = Math.Max(worstScale, scaleDiff);
            if (scaleDiff > 0.01) failures.Add($"{key} scale: {section.Scale:F4} ≠ {(double)e["scale"]!}");

            var ec = e["crop_margin_mm"]!;
            var measured = new Dictionary<string, double>
            {
                ["left"] = crop.MinX / MM, ["top"] = (size.Height - crop.MaxY) / MM,
                ["right"] = (size.Width - crop.MaxX) / MM, ["bottom"] = crop.MinY / MM,
            };
            foreach (var (side, v) in measured)
            {
                var d = Math.Abs(v - (double)ec[side]!);
                worstMargin = Math.Max(worstMargin, d);
                if (d > 1.5) failures.Add($"{key} {side}: {v:F1} ≠ {(double)ec[side]!}");
            }
        }
        log.WriteLine($"{paths.Count}개 시험지, 여백 최대 차이 {worstMargin:F2}mm, 배율 최대 차이 {worstScale:F4}");
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }
}
