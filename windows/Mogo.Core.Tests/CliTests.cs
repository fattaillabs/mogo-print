using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Mogo.Core;
using Xunit;
using static Mogo.Core.Tests.TestPdf;

namespace Mogo.Core.Tests;

/// <summary>빌드된 mogo-cli를 docs/demo 예시 문제지로 직접 실행한다.</summary>
public class CliTests
{
    private static readonly string Demo = System.IO.Path.Combine(RepoRoot, "docs", "demo");

    private static (int code, string output, string error) Run(params string[] args)
    {
        // 테스트 프로젝트가 Mogo.Cli를 참조하므로 mogo-cli.dll이 테스트 출력 폴더에 함께 있다.
        var dll = System.IO.Path.Combine(AppContext.BaseDirectory, "mogo-cli.dll");
        var psi = new ProcessStartInfo("dotnet")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            UseShellExecute = false,
        };
        psi.ArgumentList.Add(dll);
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var err = p.StandardError.ReadToEndAsync();
        var output = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        return (p.ExitCode, output, err.Result);
    }

    [Fact]
    public void Help()
    {
        var r = Run("--help");
        Assert.Equal(0, r.code);
        Assert.Contains("사용법", r.output);
        Assert.Contains("--print", r.output);
    }

    [Fact]
    public void SummaryOfDemoFolder()
    {
        var r = Run(Demo);
        Assert.True(r.code == 0, r.error);
        Assert.Contains("예시_국어_문제지: 8쪽 → 4쪽", r.output);
        Assert.Contains("홀·짝 합본→홀수형", r.output);
        Assert.Contains("선택과목→전체(화작·언매)", r.output);
        Assert.Contains("합계: A4 9쪽, 종이 5장", r.output);
    }

    [Fact]
    public void ElectiveOption()
    {
        var r = Run("--elective", "언매", "--elective", "미적", Demo);
        Assert.True(r.code == 0, r.error);
        Assert.Contains("예시_국어_문제지: 8쪽 → 3쪽", r.output);   // 공통 2 + 언매 1
        Assert.Contains("선택과목→언매", r.output);
        Assert.Contains("예시_수학_문제지: 5쪽 → 3쪽", r.output);   // 공통 2 + 미적 1
        // 국어가 3쪽(홀수)이라 뒤에 빈 쪽이 들어가 4 + 3 = 7쪽.
        Assert.Contains("합계: A4 7쪽, 종이 4장", r.output);
        Assert.Equal(1, Run("--elective", "물리", Demo).code);
    }

    [Fact]
    public void Json()
    {
        var r = Run("--json", "--variant", "even", Demo);
        Assert.True(r.code == 0, r.error);
        using var doc = JsonDocument.Parse(r.output);
        var root = doc.RootElement;
        Assert.Equal(9, root.GetProperty("output_pages").GetInt32());
        Assert.Equal("even", root.GetProperty("variant").GetString());
        var files = root.GetProperty("files");
        Assert.Equal(2, files.GetArrayLength());
        var f0 = files[0];
        Assert.Equal([5, 6, 7, 8], f0.GetProperty("used_pages").EnumerateArray().Select(e => e.GetInt32()));
        Assert.Equal(["화법과 작문", "언어와 매체"], f0.GetProperty("electives_in_file").EnumerateArray().Select(e => e.GetString()));
        Assert.True(f0.GetProperty("both_variants").GetBoolean());
        Assert.InRange(f0.GetProperty("scale").GetDouble(), 0.78, 0.82);
    }

    [Fact]
    public void OutputWritesA4PDF()
    {
        var output = TempFile("결과.pdf");
        var r = Run("--variant", "even", "-o", output, System.IO.Path.Combine(Demo, "예시_국어_문제지.pdf"));
        Assert.True(r.code == 0, r.error);
        using var doc = PdfDoc.Open(output);
        Assert.NotNull(doc);
        Assert.Equal(4, doc!.PageCount);
        Assert.Equal(595.28, doc.Geometry(0).Size.Width, 2);
        Assert.Equal(841.89, doc.Geometry(0).Size.Height, 2);
    }

    [Fact]
    public void PrintDryRunShowsSettings()
    {
        if (!Printing.Printers().names.Contains("Microsoft Print to PDF")) Assert.Skip("Microsoft Print to PDF 없음");
        // --dry-run이면 실제로 보내지 않고 프린터가 받아들일 설정만 보여 준다.
        var r = Run("-p", "--dry-run", "--printer", "Microsoft Print to PDF", "--copies", "2", Demo);
        Assert.True(r.code == 0, r.error);
        Assert.Contains("보낼 설정: 프린터 Microsoft Print to PDF · 용지 A4 · 단면(양면 미지원) · 흑백 · 2부(한 부씩)", r.output);
        // 양면이 안 되는 프린터라 빈 쪽 없이 단면으로 계산한다.
        Assert.Contains("합계: A4 9쪽, 종이 9장", r.output);
        Assert.DoesNotContain("+빈 쪽", r.output);

        Assert.Equal(4, Run("-p", "--dry-run", "--printer", "없는 프린터", Demo).code);
    }

    [Fact]
    public void PrintToFile()
    {
        if (!Printing.Printers().names.Contains("Microsoft Print to PDF")) Assert.Skip("Microsoft Print to PDF 없음");
        var output = TempFile("인쇄 결과.pdf");
        var r = Run("-p", "--printer", "Microsoft Print to PDF", "--print-to-file", output, "--elective", "언매", System.IO.Path.Combine(Demo, "예시_국어_문제지.pdf"));
        Assert.True(r.code == 0, r.error);
        Assert.Contains("인쇄를 보냈어요", r.output);
        Assert.True(PrintingTests.WaitForFile(output));
        using var doc = PdfDoc.Open(output)!;
        Assert.Equal(3, doc.PageCount); // 공통 2 + 언매 1, 단면이라 빈 쪽 없음
    }

    [Fact]
    public void BadArguments()
    {
        Assert.Equal(1, Run("--variant", "odd-ish", Demo).code);
        Assert.Equal(1, Run("--no-such-option", Demo).code);
        Assert.Equal(1, Run(@"C:\no\such\file.pdf").code);
        Assert.Equal(1, Run().code);
        Assert.Equal(1, Run("--copies", "0", Demo).code);
        Assert.Equal(1, Run("--trim", "1,2,3", Demo).code);
    }
}
