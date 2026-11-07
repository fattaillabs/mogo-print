using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace Mogo.Core;

/// <summary>평가원 시험 종류.</summary>
public enum KiceExam { Suneung, June, September }

public static class KiceExamInfo
{
    public static readonly KiceExam[] All = Enum.GetValues<KiceExam>();
    public static string FullName(this KiceExam e) => e switch { KiceExam.June => "6월 모의평가", KiceExam.September => "9월 모의평가", _ => "대학수학능력시험" };
    public static string ShortName(this KiceExam e) => e switch { KiceExam.June => "6월 모평", KiceExam.September => "9월 모평", _ => "수능" };
    internal static string BoardId(this KiceExam e) => e == KiceExam.Suneung ? "1500234" : "1500236";
    internal static string? Month(this KiceExam e) => e switch { KiceExam.June => "6월", KiceExam.September => "9월", _ => null };
    /// <summary>받은 파일 이름 앞에 붙이는 말. 예: 2026수능, 2027_6월모평</summary>
    public static string FilePrefix(this KiceExam e, int year) => e.Month() is { } m ? $"{year}_{m}모평" : $"{year}수능";

    /// <summary>명령줄 이름: 수능, 6월, 9월(모평·모의평가를 붙여도 됨)</summary>
    public static KiceExam? Parse(string name)
    {
        var k = name.Replace(" ", "");
        if (k is "수능" or "대학수학능력시험") return KiceExam.Suneung;
        if (k.StartsWith("6월")) return KiceExam.June;
        if (k.StartsWith("9월")) return KiceExam.September;
        return null;
    }
}

public enum KiceKind { Paper, Answer, Listening }

public sealed record KiceAttachment(string Title, string FileSeq)
{
    public KiceKind Kind => KindOf(Title);
    public bool IsZip => Title.EndsWith(".zip", StringComparison.OrdinalIgnoreCase);

    /// <summary>'정답'이 들어가면 정답표, 듣기·음원·대본이면 듣기 자료, 나머지는 문제지.</summary>
    public static KiceKind KindOf(string title)
    {
        var t = title.Replace(" ", "");
        if (t.Contains("정답")) return KiceKind.Answer;
        if (t.Contains("듣기") || t.Contains("음원") || t.Contains("대본")) return KiceKind.Listening;
        return KiceKind.Paper;
    }
}

public sealed record KiceRow(string Id, int Year, string? Month, string Area, IReadOnlyList<KiceAttachment> Attachments)
{
    public IReadOnlyList<KiceAttachment> Papers => Attachments.Where(a => a.Kind == KiceKind.Paper).ToList();
    public IReadOnlyList<KiceAttachment> Answers => Attachments.Where(a => a.Kind == KiceKind.Answer).ToList();
    /// <summary>탐구·제2외국어처럼 과목 여러 개가 한 첨부에 묶여 오는 영역.</summary>
    public bool HasManySubjects => Area.Contains("탐구") || Area.Contains("외국어") || Area.Contains("한문");
}

/// <summary>평가원 수능 홈페이지 기출문제 게시판. 규칙은 docs/ALGORITHM.md 부록.</summary>
public static class KiceArchive
{
    public const string Site = "https://www.suneung.re.kr";
    private static readonly HttpClient Http = CreateClient();

    static KiceArchive() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    private static HttpClient CreateClient()
    {
        var c = new HttpClient(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All }) { Timeout = TimeSpan.FromSeconds(90) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0) MogoPrint");
        return c;
    }

    public static string ListUrl(KiceExam exam, int? year)
    {
        var q = $"boardID={exam.BoardId()}&m=0403&s=suneung";
        if (year is { } y) q += $"&C01={y}";
        if (exam.Month() is { } m) q += "&C02=" + Uri.EscapeDataString(m);
        return $"{Site}/boardCnts/list.do?{q}";
    }

    public static string DownloadUrl(KiceAttachment a) => $"{Site}/boardCnts/fileDown.do?fileSeq={a.FileSeq}";

    public static List<int> ParseYears(string html)
    {
        var m = Regex.Match(html, @"<select name=""C01""[\s\S]*?</select>");
        if (!m.Success) return new();
        return Regex.Matches(m.Value, @"<option value=""(\d{4})""").Select(x => int.Parse(x.Groups[1].Value)).OrderByDescending(x => x).ToList();
    }

    /// <summary>목록 표의 줄들. 머리줄에서 '학년도'·'월'·'영역' 열 위치를 찾는다(두 게시판의 열 순서가 다르다).</summary>
    public static List<KiceRow> ParseRows(string html)
    {
        var head = Regex.Match(html, @"<thead[\s\S]*?</thead>");
        if (!head.Success) return new();
        var headers = Regex.Matches(head.Value, @"<th[^>]*>([\s\S]*?)</th>").Select(x => Clean(x.Groups[1].Value)).ToList();
        int yearCol = headers.IndexOf("학년도"), areaCol = headers.IndexOf("영역"), monthCol = headers.IndexOf("월");
        if (yearCol < 0 || areaCol < 0) return new();
        var rows = new List<KiceRow>();
        foreach (Match tr in Regex.Matches(html, @"<tr[^>]*>([\s\S]*?)</tr>"))
        {
            var cells = Regex.Matches(tr.Groups[1].Value, @"<td[^>]*>([\s\S]*?)</td>").Select(x => x.Groups[1].Value).ToList();
            if (cells.Count <= Math.Max(yearCol, areaCol) || !int.TryParse(Clean(cells[yearCol]), out var year)) continue;
            var files = Regex.Matches(tr.Groups[1].Value, @"fn_fileDown\('([0-9a-fA-F]+)'\);?""\s*title='([^']+)'")
                .Select(x => new KiceAttachment(Decode(x.Groups[2].Value), x.Groups[1].Value)).ToList();
            if (files.Count == 0) continue;
            var id = Clean(cells[0]);
            rows.Add(new KiceRow(id.Length == 0 ? $"{year}-{Clean(cells[areaCol])}" : id, year,
                monthCol >= 0 ? Clean(cells[monthCol]) : null, Clean(cells[areaCol]), files));
        }
        return rows;
    }

    private static string Clean(string cell) =>
        string.Join(' ', Decode(Regex.Replace(cell, "<[^>]+>", "")).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static string Decode(string s) => WebUtility.HtmlDecode(s);

    private static async Task<byte[]> Get(string url, CancellationToken ct)
    {
        // 주소 조회·연결이 잠깐 실패하는 일이 있어(시험 서버에서 DNS 오류 한 번 실측) 연결 단계 오류만 한 번 더 시도한다.
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.Referrer = new Uri(ListUrl(KiceExam.Suneung, null));
                using var res = await Http.SendAsync(req, ct);
                if (res.StatusCode != HttpStatusCode.OK) throw new IOException($"평가원 홈페이지에 연결하지 못했어요(HTTP {(int)res.StatusCode}).");
                return await res.Content.ReadAsByteArrayAsync(ct);
            }
            catch (HttpRequestException ex) when (attempt < 2 && ex.InnerException is System.Net.Sockets.SocketException && !ct.IsCancellationRequested)
            {
                await Task.Delay(1500, ct);
            }
        }
    }

    public static async Task<List<int>> YearsAsync(KiceExam exam, CancellationToken ct = default) =>
        ParseYears(Encoding.UTF8.GetString(await Get(ListUrl(exam, null), ct)));

    public static async Task<List<KiceRow>> RowsAsync(KiceExam exam, int year, CancellationToken ct = default)
    {
        var html = Encoding.UTF8.GetString(await Get(ListUrl(exam, year), ct));
        return ParseRows(html).Where(r => r.Year == year && (exam.Month() == null || r.Month == exam.Month())).ToList();
    }

    public static string Folder(KiceExam exam, int year, string baseDir) => System.IO.Path.Combine(baseDir, $"{year}학년도 {exam.FullName()}");

    /// <summary>기본 저장 위치: 사용자 다운로드 폴더의 '모고 프린트'.</summary>
    public static string DefaultBaseDir =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "모고 프린트");

    /// <summary>첨부 하나를 받아 PDF로 저장한다. ZIP이면 안의 PDF만 푼다. 이미 받아 둔 파일이 있으면 다시 받지 않는다.</summary>
    public static async Task<List<string>> SaveAsync(KiceAttachment a, KiceExam exam, int year, string dir, CancellationToken ct = default)
    {
        Directory.CreateDirectory(dir);
        var baseName = $"{exam.FilePrefix(year)}_{Safe(System.IO.Path.GetFileNameWithoutExtension(a.Title))}";
        if (!a.IsZip)
        {
            var path = System.IO.Path.Combine(dir, baseName + ".pdf");
            if (File.Exists(path) && new FileInfo(path).Length > 0) return new() { path };
            var data = await Get(DownloadUrl(a), ct);
            if (!(data.Length > 4 && data[0] == '%' && data[1] == 'P' && data[2] == 'D' && data[3] == 'F'))
                throw new IOException($"{a.Title}을(를) 받지 못했어요. 잠시 뒤 다시 해 보세요.");
            await WriteAtomic(path, data, ct);
            return new() { path };
        }
        var folder = System.IO.Path.Combine(dir, baseName);
        var existing = FileExpander.ExpandPDFs(new[] { folder });
        if (existing.Count > 0) return existing;
        var zip = await Get(DownloadUrl(a), ct);
        if (!(zip.Length > 2 && zip[0] == 'P' && zip[1] == 'K')) throw new IOException($"{a.Title}을(를) 받지 못했어요. 잠시 뒤 다시 해 보세요.");
        Directory.CreateDirectory(folder);
        var saved = new List<string>();
        foreach (var (name, data) in UnzipPdfs(zip).OrderBy(x => x.name, Comparer<string>.Create(FileExpander.NaturalCompare)))
        {
            var path = System.IO.Path.Combine(folder, Safe(name));
            await WriteAtomic(path, data, ct);
            saved.Add(path);
        }
        return saved;
    }

    /// <summary>ZIP 안의 PDF를 꺼낸다. 평가원 ZIP은 파일 이름이 UTF-8 표시 없이 CP949로 들어 있다.</summary>
    public static List<(string name, byte[] data)> UnzipPdfs(byte[] zip)
    {
        using var archive = new ZipArchive(new MemoryStream(zip), ZipArchiveMode.Read, false, Encoding.GetEncoding(949));
        var outList = new List<(string, byte[])>();
        foreach (var e in archive.Entries)
        {
            var name = e.Name;
            if (string.IsNullOrEmpty(name) || name.StartsWith('.') || e.FullName.Contains("__MACOSX") ||
                !name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) continue;
            using var s = e.Open();
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            outList.Add((name, ms.ToArray()));
        }
        return outList;
    }

    /// <summary>받은 파일 중 목록에 기본으로 넣을 것. 과목 여러 개인 영역은 고르지 않고, 홀·짝 파일이 따로 오면 고른 형만.</summary>
    public static HashSet<string> Preselect(IEnumerable<(string path, string area)> files, ISet<string> manySubjectAreas, ExamVariant variant)
    {
        string? key = variant switch { ExamVariant.Odd => "홀", ExamVariant.Even => "짝", _ => null };
        return files.Where(f =>
        {
            if (manySubjectAreas.Contains(f.area)) return false;
            var name = System.IO.Path.GetFileNameWithoutExtension(f.path);
            if (key != null && (name.Contains('홀') || name.Contains('짝'))) return name.Contains(key);
            return true;
        }).Select(f => f.path).ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    internal static string Safe(string name)
    {
        foreach (var ch in System.IO.Path.GetInvalidFileNameChars()) name = name.Replace(ch, ch == '/' ? '·' : '-');
        return name;
    }

    private static async Task WriteAtomic(string path, byte[] data, CancellationToken ct)
    {
        var tmp = path + ".part";
        await File.WriteAllBytesAsync(tmp, data, ct);
        File.Move(tmp, path, true);
    }
}
