using System.Diagnostics;
using System.IO.Compression;
using Mogo.Core;
using Xunit;
using static Mogo.Core.Tests.TestPdf;

namespace Mogo.Core.Tests;

public class UpdateCheckTests
{
    [Fact]
    public void CompareVersions()
    {
        Assert.True(UpdateCheck.IsNewer("0.3.0", "0.2.0"));
        Assert.True(UpdateCheck.IsNewer("v0.10.0", "0.9.9"));
        Assert.True(UpdateCheck.IsNewer("1.0", "0.9.9"));
        Assert.False(UpdateCheck.IsNewer("0.2.0", "0.2.0"));
        Assert.False(UpdateCheck.IsNewer("0.2", "0.2.0"));
        Assert.False(UpdateCheck.IsNewer("0.1.9", "0.2.0"));
        Assert.True(UpdateCheck.IsNewer("0.3.0", "0.3.0-beta"));
        Assert.False(UpdateCheck.IsNewer("0.3.0-beta", "0.3.0"));
        Assert.Equal(0, UpdateCheck.Compare("0.3.0+abc123", "0.3.0")); // 빌드 정보는 무시
    }

    private static string Json(string tag = "v0.3.0", bool draft = false, bool pre = false) => $$"""
        {"tag_name": "{{tag}}", "draft": {{(draft ? "true" : "false")}}, "prerelease": {{(pre ? "true" : "false")}},
         "html_url": "https://github.com/fattaillabs/mogo-print/releases/tag/{{tag}}", "body": "## 바뀐 점\n- 자동 업데이트",
         "assets": [
           {"name": "MogoPrint.dmg", "size": 3258415, "browser_download_url": "https://example/MogoPrint.dmg"},
           {"name": "MogoPrint-windows-x64.zip", "size": 63360674, "digest": "sha256:ABCDEF",
            "browser_download_url": "https://example/MogoPrint-windows-x64.zip"}
         ]}
        """;

    [Fact]
    public void ParseRelease()
    {
        var r = UpdateCheck.Parse(Json())!;
        Assert.Equal("0.3.0", r.Version);
        Assert.Equal("## 바뀐 점\n- 자동 업데이트", r.Notes);
        var w = r.Assets[UpdateCheck.WindowsAssetName];
        Assert.Equal(63360674, w.Size);
        Assert.Equal("abcdef", w.Sha256);
        Assert.Null(r.Assets["MogoPrint.dmg"].Sha256);
        Assert.Null(UpdateCheck.Parse(Json(draft: true)));
        Assert.Null(UpdateCheck.Parse(Json(pre: true)));
        Assert.ThrowsAny<Exception>(() => UpdateCheck.Parse("<html>rate limited</html>"));
    }

    [Fact]
    public async Task LatestFromFile()
    {
        var f = TempFile("feed.json");
        File.WriteAllText(f, Json("v9.9.9"));
        Assert.Equal("9.9.9", (await UpdateCheck.LatestAsync(f, TestContext.Current.CancellationToken))!.Version);
    }

    [Fact]
    public async Task LiveLatestRelease()
    {
        if (Environment.GetEnvironmentVariable("MOGO_NETWORK_TESTS") != "1") Assert.Skip("MOGO_NETWORK_TESTS=1일 때만 GitHub에 접속한다");
        var r = await UpdateCheck.LatestAsync(UpdateCheck.LatestUrl, TestContext.Current.CancellationToken);
        Assert.NotNull(r);
        Assert.True(r!.Assets.ContainsKey(UpdateCheck.WindowsAssetName), "릴리스에 Windows zip이 없음");
    }

    /// <summary>MogoPrint.exe 하나가 든 zip. 내용은 버전 정보가 있는 진짜 exe(시험 프로그램 자신)를 쓴다.</summary>
    private static (string zip, string version) MakeUpdateZip(string? entryName = null, byte[]? content = null)
    {
        var self = Environment.ProcessPath!;
        var zip = TempFile("update.zip");
        using (var a = ZipFile.Open(zip, ZipArchiveMode.Create))
        {
            var e = a.CreateEntry(entryName ?? "MogoPrint.exe");
            using var s = e.Open();
            if (content != null) s.Write(content);
            else using (var src = File.OpenRead(self)) src.CopyTo(s);
        }
        return (zip, FileVersionInfo.GetVersionInfo(self).ProductVersion ?? "");
    }

    [Fact]
    public void StageChecksHashExeAndVersion()
    {
        var (zip, version) = MakeUpdateZip();
        var staged = TempFile("MogoPrint.exe.new");
        var good = new UpdateCheck.Asset("x", "x", 0, UpdateCheck.Sha256(zip));
        UpdateInstaller.Stage(zip, staged, good, version);
        Assert.True(File.Exists(staged));

        // GitHub 해시와 다르면 멈춘다.
        Assert.Throws<InvalidDataException>(() => UpdateInstaller.Stage(zip, staged, good with { Sha256 = new string('0', 64) }, version));
        // 버전이 다르면 멈춘다.
        Assert.Throws<InvalidDataException>(() => UpdateInstaller.Stage(zip, staged, good, "99.0.0"));
        // 실행 파일이 아니면 멈춘다.
        var (bad, _) = MakeUpdateZip(content: "not an exe"u8.ToArray());
        Assert.Throws<InvalidDataException>(() => UpdateInstaller.Stage(bad, staged, good with { Sha256 = null }, version));
        // MogoPrint.exe가 없으면 멈춘다.
        var (other, _) = MakeUpdateZip(entryName: "readme.txt");
        Assert.Throws<InvalidDataException>(() => UpdateInstaller.Stage(other, staged, good with { Sha256 = null }, version));
    }

    [Fact]
    public void SwapReplacesAndKeepsOld()
    {
        var dir = TempDir();
        var exe = System.IO.Path.Combine(dir, "MogoPrint.exe");
        var staged = exe + ".new";
        File.WriteAllText(exe, "old");
        File.WriteAllText(staged, "new");
        UpdateInstaller.Swap(exe, staged);
        Assert.Equal("new", File.ReadAllText(exe));
        Assert.Equal("old", File.ReadAllText(exe + ".old"));
        Assert.False(File.Exists(staged));

        // 새 파일이 없으면 원래 exe를 되돌린다.
        Assert.ThrowsAny<IOException>(() => UpdateInstaller.Swap(exe, staged));
        Assert.Equal("new", File.ReadAllText(exe));
    }
}

/// <summary>EBSi 기출문제 페이지·목록 읽기(맥 EBSiTests와 같은 내용). 구조만 흉내 낸 HTML을 쓴다.</summary>
public class EbsiTests
{
    private const string Page = """
        <script>var loginTF = 'true'; var first = 'true';</script>
        <input type="checkbox" name="year" id="year2026" value="2026"><input type="checkbox" name="year" id="year2025" value="2025">
        <input type="hidden" name="korArOrd" value="1"/>
        <input type="checkbox" name="sFormPartKor" value="140117"><input type="checkbox" name="sFormPartKor" value="140118">
        <input type="checkbox" name="sFormPartKor" value="korPast">
        <input type="hidden" name="mathArOrd" value="2"/>
        <input type="checkbox" name="sFormPartMath" value="140119"><input type="checkbox" name="sFormPartMath" value="140120">
        <input type="hidden" name="engArOrd" value="3"/><input type="checkbox" name="sFormPartEng" value="80003">
        <input type="hidden" name="srch1ArOrd" value="5"/><input type="checkbox" name="sFormPartSoc" value="63002">
        """;

    private static string Row(string left, string calls) =>
        $"<div class=\"qus_box kor\"><div class=\"qus_inner left\"><p>{left}</p><span>자료다운</span>{calls}</div>"
        + "<div class=\"qus_inner right\"><a onclick=\"paperOn('1', 'x', '0', '2026');\">응시하기</a></div></div>";

    private static string P(string path, string subj, string even = "0") =>
        $"<a onclick=\"goDownLoadP('{path}', '/w', '202610203', '301', '2', '{subj}', '{even}', '{path[..^4]}', '1');\">문제</a>";

    private static string H(string path) => $"<a onclick=\"goDownLoadH('{path}', '/w', '202610203', '301', '2', '1', '0', 'x');\">해설</a>";

    [Fact]
    public void ParsePage()
    {
        var info = EbsiArchive.ParsePage(Page);
        Assert.True(info.LoggedIn);
        Assert.Equal([2026, 2025], info.Years);
        Assert.Equal(["국어", "수학", "영어", "사회탐구"], info.Areas.Select(a => a.Name));
        Assert.Equal(["140117", "140118", "korPast"], info.Areas[0].SubjectIds);
        Assert.False(EbsiArchive.ParsePage(Page.Replace("'true'", "'false'")).LoggedIn);
        Assert.False(EbsiArchive.ParsePage("<html>점검 중</html>").LoggedIn);
    }

    [Fact]
    public void ParseRows()
    {
        var html = "<p>기출문제 목록 총 5개가 검색 되었습니다.</p>"
            + Row("2026 10월 국어 고3 10월 학평(서울) 화법과 작문", P("/20261020/go3/korA_1_mun_AAA.pdf", "140117") + H("/20261020/go3/korA_1_hsj_BBB.pdf"))
            + Row("2026 10월 수학 고3 10월 학평(서울) 미적분", P("/20261020/go3/mathB_1_mun_CCC.pdf", "140120"))
            + Row("2026 10월 과탐 고1 10월 학평(경기) 통합과학", P("/20261020/go1/g_sci_mun_DDD.pdf", "1"))
            + Row("2025 11월 국어 2026학년도 대학수학능력시험 언어와 매체 짝수형", P("/20251113/go3/korB_2_mun_EEE.pdf", "140118", "1"))
            + Row("2026 10월 영어 고3 10월 학평(서울) 영어", "<a onclick=\"goDownLoadR('/x.mp3');\">듣기</a>");
        Assert.Equal(5, EbsiArchive.ParseTotal(html));
        var rows = EbsiArchive.ParseRows(html);
        Assert.Equal(4, rows.Count);
        var k = rows[0];
        Assert.Equal((2026, 10, "국어", 3), (k.Year, k.Month, k.Area, k.Grade!.Value));
        Assert.Equal("10월 학평(서울)", k.Exam);
        Assert.Equal("서울", k.Office);
        Assert.Equal("화법과 작문", k.Subject);
        Assert.Equal(Elective.SpeechWriting, k.Elective);
        Assert.True(k.IsEducationOffice);
        Assert.Equal("https://wdown.ebsi.co.kr/W61001/01exam/20261020/go3/korA_1_mun_AAA.pdf", k.PaperUrl);
        Assert.Equal("https://wdown.ebsi.co.kr/W61001/01exam/20261020/go3/korA_1_hsj_BBB.pdf", k.ExplanationUrl);
        Assert.Null(rows[1].ExplanationUrl);
        Assert.Equal(("경기", "통합과학", 1), (rows[2].Office!, rows[2].Subject, rows[2].Grade!.Value));
        var s = rows[3];
        Assert.False(s.IsEducationOffice);
        Assert.Null(s.Grade);
        Assert.Equal("2026학년도 대학수학능력시험", s.Exam);
        Assert.Equal("언어와 매체", s.Subject);
        Assert.Equal(ExamVariant.Even, s.Variant);
    }

    [Fact]
    public void MonthsAndNames()
    {
        var rows = EbsiArchive.ParseRows(
            Row("2026 10월 국어 고3 10월 학평(서울) 언어와 매체", P("/a/k1.pdf", "1"))
            + Row("2026 10월 국어 고3 10월 학평(서울) 화법과 작문", P("/a/k2.pdf", "1"))
            + Row("2026 9월 국어 2027학년도 9월 모의평가 언어와 매체", P("/a/k3.pdf", "1"))
            + Row("2026 7월 국어 고3 7월 학평(인천) 화법과 작문", P("/a/k4.pdf", "1")));
        Assert.Equal(4, rows.Count);
        var months = EbsiArchive.EducationOfficeMonths(rows);
        Assert.Equal([10, 7], months.Select(m => m.Month));
        Assert.Equal(["10월 학평(서울)", "7월 학평(인천)"], months.Select(m => m.Exam));
        Assert.Equal("2026_10월학평_고3_국어_화법과작문_문제지.pdf", EbsiArchive.FileName(rows[1], false));
        Assert.Equal("2026_10월학평_고3_국어_화법과작문_해설.pdf", EbsiArchive.FileName(rows[1], true));
        Assert.Equal("2026년 7월 고3 학력평가(인천)", System.IO.Path.GetFileName(EbsiArchive.Folder(rows[3], @"C:\b")));
        var english = EbsiArchive.ParseRows(Row("2026 10월 영어 고1 10월 학평(경기) 영어", P("/a/e.pdf", "1")))[0];
        Assert.Equal("2026_10월학평_고1_영어_문제지.pdf", EbsiArchive.FileName(english, false));
        var social = EbsiArchive.ParseRows(Row("2026 10월 사탐 고1 10월 학평(경기) 통합사회", P("/a/s.pdf", "1")))[0];
        Assert.Equal("2026_10월학평_고1_사회탐구_통합사회_문제지.pdf", EbsiArchive.FileName(social, false));
    }

    [Fact]
    public void PreselectFollowsElectives()
    {
        var rows = EbsiArchive.ParseRows(
            Row("2026 10월 국어 고3 10월 학평(서울) 화법과 작문", P("/k/a.pdf", "1"))
            + Row("2026 10월 국어 고3 10월 학평(서울) 언어와 매체", P("/k/b.pdf", "1"))
            + Row("2026 10월 수학 고3 10월 학평(서울) 확률과 통계", P("/m/a.pdf", "1"))
            + Row("2026 10월 수학 고3 10월 학평(서울) 미적분", P("/m/b.pdf", "1"))
            + Row("2026 10월 영어 고3 10월 학평(서울) 영어", P("/e.pdf", "1"))
            + Row("2026 10월 사탐 고3 10월 학평(서울) 경제", P("/s.pdf", "1")));
        Assert.Equal(new HashSet<string> { "/k/a.pdf", "/k/b.pdf", "/m/a.pdf", "/m/b.pdf", "/e.pdf" },
                     EbsiArchive.Preselect(rows, new Dictionary<ElectiveSubject, Elective>()));
        Assert.Equal(new HashSet<string> { "/k/b.pdf", "/m/b.pdf", "/e.pdf" },
                     EbsiArchive.Preselect(rows, new Dictionary<ElectiveSubject, Elective> { [ElectiveSubject.Korean] = Elective.LanguageMedia, [ElectiveSubject.Math] = Elective.Calculus }));
    }

    [Fact]
    public void ListRequestForm()
    {
        var info = EbsiArchive.ParsePage(Page);
        var form = EbsiArchive.ListForm(1, 2025, [3, 10], info.Areas, 2).ToDictionary(kv => kv.Key, kv => kv.Value);
        Assert.Equal("D100", form["targetCd"]);
        Assert.Equal("2025", form["yearList"]);
        Assert.Equal("03,10", form["monthList"]);
        Assert.Equal("1,2,3,5", form["arOrd"]);
        Assert.Equal("140117,140118,korPast,140119,140120,80003,63002", form["subjIdList"]);
        Assert.Equal("2", form["currentPage"]);
    }

    /// <summary>로그인이 아니면 목록 요청을 보내지 않고 바로 실패한다(네트워크에 닿지 않는다).</summary>
    [Fact]
    public async Task DoesNotListWhenLoggedOut()
    {
        var info = EbsiArchive.ParsePage(Page.Replace("'true'", "'false'"));
        await Assert.ThrowsAsync<EbsiArchive.NotLoggedInException>(() => EbsiArchive.PapersAsync(3, 2026, 10, info, "", TestContext.Current.CancellationToken));
    }
}
