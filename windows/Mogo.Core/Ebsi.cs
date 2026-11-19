using System.Net;
using System.Text.RegularExpressions;

namespace Mogo.Core;

/// <summary>
/// EBSi 기출문제에서 교육청 전국연합학력평가(학평) 문제지를 받는다(맥 버전 EBSiArchive와 같은 규칙, docs/ALGORITHM.md 부록).
/// 학평 문제지는 시·도교육청이 EBSi에서만 제공하고, EBSi는 로그인한 회원에게만 기출문제 목록을 보여 준다.
/// 그래서 사용자가 앱 안 로그인 창(WebView2)에서 직접 로그인한 쿠키로만 목록을 읽는다.
/// 로그인 여부는 공개 페이지의 loginTF로 먼저 확인하고, 로그인이 아니면 목록을 부르지 않는다.
/// </summary>
public static class EbsiArchive
{
    public const string FileBase = "https://wdown.ebsi.co.kr/W61001/01exam";
    public const string LoginUrl = "https://www.ebsi.co.kr/ebs/pot/potl/login.ebs?alertYn=N&destination=%2Febs%2Fxip%2Fxipc%2FpreviousPaperList.ebs";
    public const string ListUrl = "https://www.ebsi.co.kr/ebs/xip/xipc/previousPaperListAjax.ajax";
    public const string SiteUrl = "https://www.ebsi.co.kr";
    private const int MaxPages = 12;

    public static string PageUrl(int grade) => $"https://www.ebsi.co.kr/ebs/xip/xipc/previousPaperList.ebs?targetCd=D{grade}00";

    public sealed class NotLoggedInException() : Exception("EBSi에 로그인해야 받을 수 있어요.");

    // MARK: 기출문제 페이지(검색 조건)

    public sealed record Area(string Name, string Order, IReadOnlyList<string> SubjectIds);

    public sealed record PageInfo(bool LoggedIn, IReadOnlyList<int> Years, IReadOnlyList<Area> Areas);

    /// <summary>페이지 검색 칸 이름 → 영역 이름(영역 번호 칸, 과목 체크박스 칸)</summary>
    private static readonly (string Name, string OrderField, string SubjectField)[] AreaFields =
    [
        ("국어", "korArOrd", "sFormPartKor"),
        ("수학", "mathArOrd", "sFormPartMath"),
        ("영어", "engArOrd", "sFormPartEng"),
        ("한국사", "hisArOrd", "sFormPartHis"),
        ("사회탐구", "srch1ArOrd", "sFormPartSoc"),
        ("과학탐구", "srch2ArOrd", "sFormPartSci"),
        ("직업탐구", "jobArOrd", "sFormPartCareer"),
        ("제2외국어/한문", "scndForgnlngArOrd", "sFormPartLang"),
    ];

    /// <summary>기출문제 페이지에서 로그인 여부, 고를 수 있는 연도, 영역·과목 번호를 읽는다.</summary>
    public static PageInfo ParsePage(string html)
    {
        bool login = Regex.Match(html, @"var\s+loginTF\s*=\s*['""](\w+)['""]").Groups[1].Value == "true";
        var years = Regex.Matches(html, @"name=[""']year[""'][^>]*value=[""'](\d{4})[""']").Select(m => int.Parse(m.Groups[1].Value)).Distinct().ToList();
        var areas = new List<Area>();
        foreach (var f in AreaFields)
        {
            var order = Regex.Match(html, $@"name=[""']{f.OrderField}[""'][^>]*value=[""'](\d+)[""']");
            if (!order.Success) continue;
            var ids = Regex.Matches(html, $@"name=[""']{f.SubjectField}[""'][^>]*value=[""']([^""']+)[""']").Select(m => m.Groups[1].Value).Distinct().ToList();
            if (ids.Count > 0) areas.Add(new Area(f.Name, order.Groups[1].Value, ids));
        }
        return new PageInfo(login, years, areas);
    }

    // MARK: 목록

    /// <summary>목록 한 줄: 시험 하나의 과목 하나.</summary>
    public sealed record Paper(string Title, int Year, int Month, string Area, int? Grade, string Exam, string Subject,
                               ExamVariant? Variant, string SubjectId, string PaperPath, string? ExplanationPath)
    {
        public string Id => PaperPath;
        /// <summary>교육청 학력평가인지(수능·모평은 평가원에서 받는다)</summary>
        public bool IsEducationOffice => Exam.Contains("학평");
        /// <summary>주관 교육청. 예: "서울"</summary>
        public string? Office => Regex.Match(Exam, @"\(([^)]+)\)") is { Success: true } m ? m.Groups[1].Value : null;
        /// <summary>고3 국어·수학 선택과목 파일이면 그 과목</summary>
        public Elective? Elective => ElectiveInfo.Parse(Subject);
        public string PaperUrl => FileBase + PaperPath;
        public string? ExplanationUrl => ExplanationPath == null ? null : FileBase + ExplanationPath;
    }

    /// <summary>목록 응답(HTML 조각)에서 줄을 읽는다. 한 줄은 div.qus_box, 왼쪽 칸 글이 시험·과목, 버튼이 파일 경로를 들고 있다.</summary>
    public static List<Paper> ParseRows(string html)
    {
        var outList = new List<Paper>();
        foreach (var chunk in html.Split("class=\"qus_box").Skip(1))
        {
            // 나눈 자리가 여는 태그 한가운데라 앞에 ` kor">` 같은 태그 꼬리가 남는다. 첫 '>'까지 버린다.
            int gt = chunk.IndexOf('>');
            var block = gt >= 0 ? chunk[(gt + 1)..] : chunk;
            var calls = Regex.Matches(block, @"goDownLoad([PH])\(([^)]*)\)")
                .Select(m => (Kind: m.Groups[1].Value, Args: Regex.Matches(m.Groups[2].Value, "'([^']*)'").Select(a => a.Groups[1].Value).ToList()))
                .ToList();
            var p = calls.FirstOrDefault(c => c.Kind == "P");
            if (p.Args is not { Count: > 0 } || !p.Args[0].EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) continue;
            var h = calls.FirstOrDefault(c => c.Kind == "H").Args?.FirstOrDefault();
            var left = block.Split("qus_inner right")[0];
            var text = Clean(left);
            int cut = text.IndexOf("자료다운", StringComparison.Ordinal);
            if (cut >= 0) text = text[..cut];
            text = text.Trim();
            var m = Regex.Match(text, @"^(\d{4})\s+(\d{1,2})월\s+(\S+)\s+(?:고(\d)\s+)?(.+)$");
            if (!m.Success) continue;
            var rest = m.Groups[5].Value;
            ExamVariant? variant = null;
            foreach (var v in new[] { ExamVariant.Odd, ExamVariant.Even })
                if (rest.EndsWith(" " + v.Korean())) { variant = v; rest = rest[..^(v.Korean().Length + 1)]; }
            // "10월 학평(서울) 화법과 작문" → 시험 "10월 학평(서울)", 과목 "화법과 작문"
            string exam = rest, subject = "";
            var paren = Regex.Match(rest, @"^.*?\)\s*");
            if (paren.Success) { exam = paren.Value.Trim(); subject = rest[paren.Length..].Trim(); }
            else if (rest.IndexOf("대학수학능력시험", StringComparison.Ordinal) is var k and >= 0)
            {
                exam = rest[..(k + "대학수학능력시험".Length)];
                subject = rest[(k + "대학수학능력시험".Length)..].Trim();
            }
            if (subject.Length == 0) subject = m.Groups[3].Value;
            outList.Add(new Paper(text, int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), m.Groups[3].Value,
                m.Groups[4].Success ? int.Parse(m.Groups[4].Value) : null, exam, subject, variant,
                p.Args.Count > 5 ? p.Args[5] : "", p.Args[0], h != null && h.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ? h : null));
        }
        return outList;
    }

    /// <summary>목록 응답의 "총 N개"</summary>
    public static int? ParseTotal(string html) =>
        Regex.Match(Clean(html), @"총\s*(\d+)\s*개") is { Success: true } m ? int.Parse(m.Groups[1].Value) : null;

    /// <summary>한 해에 있었던 학평의 달과 시험 이름(최근 달부터)</summary>
    public static List<(int Month, string Exam)> EducationOfficeMonths(IEnumerable<Paper> papers)
    {
        var seen = new HashSet<int>();
        return papers.OrderByDescending(p => p.Month).Where(p => p.IsEducationOffice && seen.Add(p.Month)).Select(p => (p.Month, p.Exam)).ToList();
    }

    // MARK: 요청

    /// <summary>목록 요청에 보낼 칸. 화면에서 연도·월·과목을 체크하고 검색할 때와 같은 값이다.</summary>
    public static List<KeyValuePair<string, string>> ListForm(int grade, int year, IEnumerable<int> months, IEnumerable<Area> areas, int page)
    {
        var a = areas.ToList();
        return
        [
            new("targetCd", $"D{grade}00"), new("yearList", year.ToString()),
            new("monthList", string.Join(",", months.Select(x => x.ToString("00")))),
            new("arOrd", string.Join(",", a.Select(x => x.Order))),
            new("subjIdList", string.Join(",", a.SelectMany(x => x.SubjectIds))),
            new("sort", "recent"), new("paperId", ""), new("paperNo", ""), new("lvl", ""), new("currentPage", page.ToString()),
        ];
    }

    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        // 쿠키는 앱 안 로그인 창에서 가져와 요청마다 직접 붙인다.
        var c = new HttpClient(new HttpClientHandler { UseCookies = false, AutomaticDecompression = DecompressionMethods.All }) { Timeout = TimeSpan.FromSeconds(60) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0) MogoPrint");
        return c;
    }

    private static async Task<string> RequestAsync(string url, string cookies, IEnumerable<KeyValuePair<string, string>>? form, int grade, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(form == null ? HttpMethod.Get : HttpMethod.Post, url);
        if (cookies.Length > 0) req.Headers.TryAddWithoutValidation("Cookie", cookies);
        req.Headers.Referrer = new Uri(PageUrl(grade));
        if (form != null)
        {
            req.Content = new FormUrlEncodedContent(form);
            req.Headers.TryAddWithoutValidation("X-Requested-With", "XMLHttpRequest");
        }
        using var res = await Http.SendAsync(req, ct);
        if (res.StatusCode != HttpStatusCode.OK) throw new HttpRequestException($"EBSi에 연결하지 못했어요(HTTP {(int)res.StatusCode}).");
        return await res.Content.ReadAsStringAsync(ct);
    }

    /// <summary>기출문제 페이지를 읽어 로그인 여부와 검색 조건을 얻는다(공개 페이지).</summary>
    public static async Task<PageInfo> PageInfoAsync(int grade, string cookies, CancellationToken ct = default) =>
        ParsePage(await RequestAsync(PageUrl(grade), cookies, null, grade, ct));

    /// <summary>로그인한 상태로 목록을 쪽마다 받아 모은다. 로그인이 아니면 부르지 않는다.</summary>
    private static async Task<List<Paper>> ListAsync(int grade, int year, IEnumerable<int> months, IEnumerable<Area> areas, PageInfo info, string cookies, CancellationToken ct)
    {
        if (!info.LoggedIn) throw new NotLoggedInException();
        var all = new List<Paper>();
        int? total = null;
        var monthList = months.ToList();
        var areaList = areas.ToList();
        for (int page = 1; page <= MaxPages; page++)
        {
            var html = await RequestAsync(ListUrl, cookies, ListForm(grade, year, monthList, areaList, page), grade, ct);
            total ??= ParseTotal(html);
            var rows = ParseRows(html).Where(r => all.All(x => x.PaperPath != r.PaperPath)).ToList();
            all.AddRange(rows);
            if (rows.Count == 0 || all.Count >= (total ?? 0)) break;
        }
        return all;
    }

    /// <summary>그 학년·연도에 학평이 있었던 달(최근 달부터). 국어 영역만으로 찾는다(요청이 적다).</summary>
    public static async Task<List<(int Month, string Exam)>> MonthsAsync(int grade, int year, PageInfo info, string cookies, CancellationToken ct = default)
    {
        var korean = info.Areas.Where(a => a.Name == "국어").ToList();
        var rows = await ListAsync(grade, year, Enumerable.Range(3, 10), korean.Count > 0 ? korean : info.Areas, info, cookies, ct);
        return EducationOfficeMonths(rows);
    }

    /// <summary>그 달 학평의 모든 과목 줄</summary>
    public static async Task<List<Paper>> PapersAsync(int grade, int year, int month, PageInfo info, string cookies, CancellationToken ct = default) =>
        (await ListAsync(grade, year, [month], info.Areas, info, cookies, ct))
            .Where(p => p.IsEducationOffice && p.Year == year && p.Month == month).ToList();

    // MARK: 저장

    /// <summary>받은 파일을 둘 폴더. 예: &lt;base&gt;\2026년 10월 고3 학력평가(서울)</summary>
    public static string Folder(Paper p, string baseDir)
    {
        var office = p.Office is { } o ? $"({o})" : "";
        var grade = p.Grade is { } g ? $" 고{g}" : "";
        return System.IO.Path.Combine(baseDir, $"{p.Year}년 {p.Month}월{grade} 학력평가{office}");
    }

    /// <summary>파일 이름. 예: 2026_10월학평_고3_국어_화법과작문_문제지.pdf</summary>
    public static string FileName(Paper p, bool explanation)
    {
        var grade = p.Grade is { } g ? $"_고{g}" : "";
        var area = p.Area == p.Subject ? "" : "_" + AreaName(p.Area);
        var subject = p.Subject.Replace(" ", "");
        var variant = p.Variant is { } v ? "_" + v.Korean() : "";
        return KiceArchive.Safe($"{p.Year}_{p.Month}월학평{grade}{area}_{subject}{variant}_{(explanation ? "해설" : "문제지")}.pdf");
    }

    public static string AreaName(string a) => a switch { "사탐" => "사회탐구", "과탐" => "과학탐구", "직탐" => "직업탐구", _ => a };

    /// <summary>문제지(또는 해설) 하나를 받아 저장한다. 이미 받아 둔 파일이 있으면 다시 받지 않는다.</summary>
    public static async Task<string?> SaveAsync(Paper p, bool explanation, string dir, CancellationToken ct = default)
    {
        var url = explanation ? p.ExplanationUrl : p.PaperUrl;
        if (url == null) return null;
        Directory.CreateDirectory(dir);
        var dest = System.IO.Path.Combine(dir, FileName(p, explanation));
        if (File.Exists(dest) && new FileInfo(dest).Length > 0) return dest;
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.Referrer = new Uri(PageUrl(3));
        using var res = await Http.SendAsync(req, ct);
        var data = res.IsSuccessStatusCode ? await res.Content.ReadAsByteArrayAsync(ct) : [];
        if (!(data.Length > 4 && data[0] == '%' && data[1] == 'P' && data[2] == 'D' && data[3] == 'F'))
            throw new IOException($"{p.Title}을(를) 받지 못했어요. 잠시 뒤 다시 해 보세요.");
        var tmp = dest + ".part";
        await File.WriteAllBytesAsync(tmp, data, ct);
        File.Move(tmp, dest, true);
        return dest;
    }

    /// <summary>기본으로 고를 줄: 국어·수학·영어·한국사(탐구·제2외국어는 사용자가 고른다). 선택과목을 정해 두었으면 그 과목 파일만.</summary>
    public static HashSet<string> Preselect(IEnumerable<Paper> papers, IReadOnlyDictionary<ElectiveSubject, Elective> electives) =>
        papers.Where(p => p.Area is "국어" or "수학" or "영어" or "한국사"
                          && (p.Elective is not { } e || !electives.TryGetValue(e.Subject(), out var chosen) || e == chosen))
              .Select(p => p.Id).ToHashSet();

    private static string Clean(string html)
    {
        var s = Regex.Replace(html, @"<script[\s\S]*?</script>", " ");
        s = Regex.Replace(s, "<[^>]+>", " ").Replace("&nbsp;", " ").Replace("&amp;", "&");
        return Regex.Replace(s, @"\s+", " ").Trim();
    }
}
