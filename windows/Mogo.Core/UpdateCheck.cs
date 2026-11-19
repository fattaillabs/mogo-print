using System.Diagnostics;
using System.IO.Compression;
using System.Text.Json;

namespace Mogo.Core;

/// <summary>GitHub 릴리스로 새 버전을 확인한다(맥 버전 UpdateCheck와 같은 규칙). 릴리스 파일 이름은 고정이다.</summary>
public static class UpdateCheck
{
    public const string LatestUrl = "https://api.github.com/repos/fattaillabs/mogo-print/releases/latest";
    public const string ReleasesPage = "https://github.com/fattaillabs/mogo-print/releases/latest";
    public const string WindowsAssetName = "MogoPrint-windows-x64.zip";

    public sealed record Asset(string Name, string Url, long Size, string? Sha256);

    public sealed record Release(string Version, string Notes, string Page, IReadOnlyDictionary<string, Asset> Assets);

    /// <summary>GitHub 릴리스 JSON을 읽는다. 초안·시험판은 업데이트로 보지 않는다(null). 형식이 틀리면 예외.</summary>
    public static Release? Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var r = doc.RootElement;
        if (r.ValueKind != JsonValueKind.Object || !r.TryGetProperty("tag_name", out var tag) || !r.TryGetProperty("html_url", out var page))
            throw new FormatException("업데이트 정보를 읽지 못했어요.");
        if (Bool(r, "draft") || Bool(r, "prerelease")) return null;
        var assets = new Dictionary<string, Asset>(StringComparer.Ordinal);
        if (r.TryGetProperty("assets", out var list) && list.ValueKind == JsonValueKind.Array)
            foreach (var a in list.EnumerateArray())
            {
                var name = a.GetProperty("name").GetString() ?? "";
                var url = a.GetProperty("browser_download_url").GetString() ?? "";
                long size = a.TryGetProperty("size", out var s) && s.TryGetInt64(out var n) ? n : 0;
                // GitHub가 붙이는 파일 해시("sha256:…"). 없으면 null.
                string? sha = a.TryGetProperty("digest", out var d) && d.GetString() is { } dg && dg.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)
                    ? dg[7..].ToLowerInvariant() : null;
                if (name.Length > 0 && url.Length > 0) assets[name] = new Asset(name, url, size, sha);
            }
        return new Release(Normalized(tag.GetString() ?? ""), r.TryGetProperty("body", out var b) ? b.GetString() ?? "" : "",
                           page.GetString() ?? ReleasesPage, assets);
    }

    private static bool Bool(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    /// <summary>"v0.2.0" → "0.2.0"</summary>
    public static string Normalized(string tag)
    {
        var t = tag.Trim();
        return t.StartsWith('v') || t.StartsWith('V') ? t[1..] : t;
    }

    /// <summary>숫자 마디로 비교한다(0.10.0 &gt; 0.9.0). -beta 같은 꼬리가 있으면 같은 숫자의 정식판보다 낮다. '+' 뒤(빌드 정보)는 무시.</summary>
    public static int Compare(string a, string b)
    {
        static (int[] nums, bool pre) Split(string v)
        {
            var s = Normalized(v).Split('+')[0];
            var core = s.Split('-', 2)[0];
            var nums = core.Split('.').Select(p => int.TryParse(new string(p.Where(char.IsDigit).ToArray()), out var n) ? n : 0).ToArray();
            return (nums, s.Contains('-'));
        }
        var (x, xp) = Split(a);
        var (y, yp) = Split(b);
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int l = i < x.Length ? x[i] : 0, r = i < y.Length ? y[i] : 0;
            if (l != r) return l < r ? -1 : 1;
        }
        if (xp != yp) return xp ? -1 : 1;
        return 0;
    }

    public static bool IsNewer(string candidate, string current) => Compare(candidate, current) > 0;

    /// <summary>최신 릴리스 주소. 시험할 때는 MOGO_UPDATE_FEED로 다른 주소나 파일 경로를 준다.</summary>
    public static string FeedUrl => Environment.GetEnvironmentVariable("MOGO_UPDATE_FEED") is { Length: > 0 } f ? f : LatestUrl;

    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("MogoPrint-Updater");
        c.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return c;
    }

    /// <summary>최신 릴리스를 가져온다. 파일 경로(시험용)도 받는다.</summary>
    public static async Task<Release?> LatestAsync(string? feed = null, CancellationToken ct = default)
    {
        feed ??= FeedUrl;
        if (File.Exists(feed)) return Parse(await File.ReadAllTextAsync(feed, ct));
        if (Uri.TryCreate(feed, UriKind.Absolute, out var u) && u.IsFile) return Parse(await File.ReadAllTextAsync(u.LocalPath, ct));
        using var res = await Http.GetAsync(feed, ct);
        if (!res.IsSuccessStatusCode) throw new HttpRequestException($"업데이트를 확인하지 못했어요(HTTP {(int)res.StatusCode}).");
        return Parse(await res.Content.ReadAsStringAsync(ct));
    }

    /// <summary>받을 파일을 내려받는다(진행률 0~1). 파일 경로(시험용)면 복사한다.</summary>
    public static async Task DownloadAsync(string url, string dest, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var u) && u.IsFile) { File.Copy(u.LocalPath, dest, true); progress?.Report(1); return; }
        if (File.Exists(url)) { File.Copy(url, dest, true); progress?.Report(1); return; }
        using var res = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!res.IsSuccessStatusCode) throw new HttpRequestException($"새 버전을 받지 못했어요(HTTP {(int)res.StatusCode}).");
        long total = res.Content.Headers.ContentLength ?? 0, done = 0;
        await using var src = await res.Content.ReadAsStreamAsync(ct);
        await using var dst = File.Create(dest);
        var buf = new byte[1 << 16];
        int n;
        while ((n = await src.ReadAsync(buf, ct)) > 0)
        {
            await dst.WriteAsync(buf.AsMemory(0, n), ct);
            done += n;
            if (total > 0) progress?.Report((double)done / total);
        }
        progress?.Report(1);
    }

    public static string Sha256(string path)
    {
        using var f = File.OpenRead(path);
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(f)).ToLowerInvariant();
    }
}

/// <summary>Windows 업데이트 파일 다루기: zip 확인·exe 꺼내기, 실행 중인 exe 바꾸기.</summary>
public static class UpdateInstaller
{
    /// <summary>zip 해시를 확인하고 안의 MogoPrint.exe를 staged로 꺼낸 뒤 그 exe의 버전을 확인한다.</summary>
    public static void Stage(string zip, string staged, UpdateCheck.Asset asset, string version)
    {
        if (asset.Sha256 is { } sha && UpdateCheck.Sha256(zip) != sha)
            throw new InvalidDataException("받은 파일이 GitHub에 올라간 파일과 달라 업데이트를 멈췄어요.");
        using (var archive = ZipFile.OpenRead(zip))
        {
            var entry = archive.Entries.FirstOrDefault(e => e.Name.Equals("MogoPrint.exe", StringComparison.OrdinalIgnoreCase))
                ?? throw new InvalidDataException("받은 파일 안에 MogoPrint.exe가 없어요.");
            entry.ExtractToFile(staged, true);
        }
        using (var f = File.OpenRead(staged))
        {
            if (f.ReadByte() != 'M' || f.ReadByte() != 'Z') throw new InvalidDataException("받은 파일이 실행 파일이 아니에요.");
        }
        var v = FileVersionInfo.GetVersionInfo(staged).ProductVersion ?? "";
        if (UpdateCheck.Compare(v, version) != 0) throw new InvalidDataException($"받은 프로그램의 버전이 맞지 않아요({v}).");
    }

    /// <summary>실행 중인 exe는 지울 수 없지만 이름은 바꿀 수 있다. .old로 옮기고 새 exe를 제자리에 둔다. 실패하면 되돌린다.</summary>
    public static void Swap(string exe, string staged)
    {
        var old = exe + ".old";
        try { File.Delete(old); } catch { }
        File.Move(exe, old);
        try { File.Move(staged, exe); }
        catch
        {
            File.Move(old, exe);
            throw;
        }
    }
}
