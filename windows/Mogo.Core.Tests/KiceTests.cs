using System.IO.Compression;
using System.Text;
using Mogo.Core;
using Xunit;
using static Mogo.Core.Tests.TestPdf;

namespace Mogo.Core.Tests;

public class ZipTests
{
    static ZipTests() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    /// <summary>시험용 ZIP을 직접 만든다. 평가원 ZIP처럼 UTF-8 표시 없이 CP949 이름을 넣을 수 있다.</summary>
    private static byte[] MakeZip(params (byte[] name, bool utf8, byte[] data, bool deflate)[] items)
    {
        static byte[] Le16(int v) => [(byte)(v & 0xFF), (byte)(v >> 8 & 0xFF)];
        static byte[] Le32(int v) => [.. Le16(v & 0xFFFF), .. Le16(v >> 16 & 0xFFFF)];
        var body = new List<byte>();
        var central = new List<byte>();
        foreach (var item in items)
        {
            var payload = item.data;
            if (item.deflate)
            {
                using var ms = new MemoryStream();
                using (var d = new DeflateStream(ms, CompressionLevel.Optimal, true)) d.Write(item.data);
                payload = ms.ToArray();
            }
            int flags = item.utf8 ? 0x800 : 0, method = item.deflate ? 8 : 0, offset = body.Count;
            var crc = (int)Crc32(item.data);
            body.AddRange([.. Le32(0x04034B50), .. Le16(20), .. Le16(flags), .. Le16(method), .. Le32(0), .. Le32(crc),
                           .. Le32(payload.Length), .. Le32(item.data.Length), .. Le16(item.name.Length), .. Le16(0), .. item.name, .. payload]);
            central.AddRange([.. Le32(0x02014B50), .. Le16(20), .. Le16(20), .. Le16(flags), .. Le16(method), .. Le32(0), .. Le32(crc),
                              .. Le32(payload.Length), .. Le32(item.data.Length), .. Le16(item.name.Length), .. Le16(0), .. Le16(0),
                              .. Le16(0), .. Le16(0), .. Le32(0), .. Le32(offset), .. item.name]);
        }
        var eocd = new List<byte>([.. Le32(0x06054B50), .. Le16(0), .. Le16(0), .. Le16(items.Length), .. Le16(items.Length),
                                   .. Le32(central.Count), .. Le32(body.Count), .. Le16(0)]);
        return [.. body, .. central, .. eocd];
    }

    private static uint Crc32(byte[] data)
    {
        uint c = 0xFFFFFFFF;
        foreach (var b in data)
        {
            c ^= b;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        }
        return ~c;
    }

    [Fact]
    public void ReadsCP949AndUTF8NamesStoredAndDeflated()
    {
        var cp949 = Encoding.GetEncoding(949);
        var text = Encoding.UTF8.GetBytes("%PDF-1.4 " + string.Concat(Enumerable.Repeat("모고 프린트 ", 400)));
        var zip = MakeZip(
            (cp949.GetBytes("07 경제_문제.pdf"), false, Encoding.ASCII.GetBytes("%PDF-1.4 a"), false),
            (Encoding.UTF8.GetBytes("폴더/"), true, [], false),
            (Encoding.UTF8.GetBytes("폴더/국어영역_홀수형.pdf"), true, text, true),
            (Encoding.UTF8.GetBytes("__MACOSX/폴더/._국어영역_홀수형.pdf"), true, [1, 2], false),
            (Encoding.UTF8.GetBytes("안내.txt"), true, [1, 2], false));
        var entries = KiceArchive.UnzipPdfs(zip);
        // 폴더 항목, __MACOSX, PDF 아닌 파일은 뺀다.
        Assert.Equal(["07 경제_문제.pdf", "국어영역_홀수형.pdf"], entries.Select(e => e.name));
        Assert.Equal(Encoding.ASCII.GetBytes("%PDF-1.4 a"), entries[0].data);
        Assert.Equal(text, entries[1].data);
    }

    [Fact]
    public void RejectsNonZipAndBrokenZip()
    {
        Assert.ThrowsAny<Exception>(() => KiceArchive.UnzipPdfs(Encoding.UTF8.GetBytes("<html>not found</html>")));
        var good = MakeZip((Encoding.UTF8.GetBytes("a.pdf"), true, Encoding.ASCII.GetBytes("%PDF"), false));
        Assert.ThrowsAny<Exception>(() => KiceArchive.UnzipPdfs([.. good.Take(20), .. good.TakeLast(22)])); // 몸통이 잘린 ZIP
    }

    /// <summary>실제 평가원 ZIP(Samples/_zips에 있을 때만).</summary>
    [Fact]
    public void RealKiceZips()
    {
        var dir = SamplesDir is { } s ? System.IO.Path.Combine(s, "_zips") : null;
        if (dir == null || !Directory.Exists(dir)) Assert.Skip("Samples/_zips 없음");
        var social = KiceArchive.UnzipPdfs(File.ReadAllBytes(System.IO.Path.Combine(dir, "2026수능_사회탐구영역_문제지.zip")));
        Assert.Equal(9, social.Count);
        Assert.Contains("07 경제_문제.pdf", social.Select(e => e.name));
        Assert.All(social, e => Assert.Equal("%PDF"u8.ToArray(), e.data[..4]));
        var korean = KiceArchive.UnzipPdfs(File.ReadAllBytes(System.IO.Path.Combine(dir, "2022수능_1교시_국어영역_문제지.zip")));
        Assert.Equal(new HashSet<string> { "국어영역_홀수형.pdf", "국어영역_짝수형.pdf" }, korean.Select(e => e.name).ToHashSet());
        using var doc = PdfDoc.FromBytes(korean[0].data);
        Assert.NotNull(doc);
    }
}

public class KiceArchiveTests
{
    [Fact]
    public void AttachmentKinds()
    {
        Assert.Equal(KiceKind.Paper, KiceAttachment.KindOf("국어영역_문제지.pdf"));
        Assert.Equal(KiceKind.Paper, KiceAttachment.KindOf("국어영역.zip"));            // 2019: '문제지'라는 말이 없다
        Assert.Equal(KiceKind.Paper, KiceAttachment.KindOf("국어영역A형-홀수.pdf"));    // 2015: A·B형
        Assert.Equal(KiceKind.Answer, KiceAttachment.KindOf("1교시_국어영역_정답표.pdf"));
        Assert.Equal(KiceKind.Answer, KiceAttachment.KindOf("정답표_2015_수능_국어A_홀수.pdf"));
        Assert.Equal(KiceKind.Answer, KiceAttachment.KindOf("사회탐구영역_정답.zip"));
        Assert.Equal(KiceKind.Listening, KiceAttachment.KindOf("영어영역듣기평가음원.zip"));
        Assert.Equal(KiceKind.Listening, KiceAttachment.KindOf("영어영역듣기평가대본.pdf"));
        Assert.Equal(KiceKind.Listening, KiceAttachment.KindOf("듣기평가.zip"));
    }

    [Fact]
    public void ExamNamesAndUrls()
    {
        Assert.Equal(KiceExam.Suneung, KiceExamInfo.Parse("수능"));
        Assert.Equal(KiceExam.June, KiceExamInfo.Parse("6월"));
        Assert.Equal(KiceExam.September, KiceExamInfo.Parse("9월 모평"));
        Assert.Null(KiceExamInfo.Parse("7월"));
        Assert.Equal("2026수능", KiceExam.Suneung.FilePrefix(2026));
        Assert.Equal("2027_6월모평", KiceExam.June.FilePrefix(2027));

        var q = System.Web.HttpUtility.ParseQueryString(new Uri(KiceArchive.ListUrl(KiceExam.September, 2027)).Query);
        Assert.Equal("1500236", q["boardID"]);
        Assert.Equal("2027", q["C01"]);
        Assert.Equal("9월", q["C02"]);
        Assert.Equal("https://www.suneung.re.kr/boardCnts/fileDown.do?fileSeq=abc123",
                     KiceArchive.DownloadUrl(new KiceAttachment("a.pdf", "abc123")));
    }

    /// <summary>두 게시판의 표 모양(열 순서가 다르다)을 흉내 낸 HTML로 읽기를 확인한다.</summary>
    [Fact]
    public void ParseBoards()
    {
        static string Row(string[] cells, params (string seq, string title)[] files)
        {
            var links = string.Concat(files.Select(f => $"<a href='#;' onclick=\"fn_fileDown('{f.seq}');\" title='{f.title}'><img alt='{f.title}'></a>"));
            return "<tr style=\"text-align:center;\">" + string.Concat(cells.Select(c => $"<td >{c}</td>")) + $"<td>{links}</td></tr>";
        }
        var suneung = $"""
            <select name="C01" title="학년도"><option value="" >학년도</option><option value="2027" >2027</option><option value="2026" >2026</option></select>
            <table><thead><tr><th>번호</th><th>학년도</th><th>영역</th><th>제목</th><th>등록일</th><th>조회</th><th>파일</th></tr></thead><tbody>
            {Row(["5093801", "2026", "국어", "<a href='#'>문제 및 정답</a>", "2025-11-17", "250459"], ("aa11", "국어영역_문제지.pdf"), ("bb22", "국어영역_정답표.pdf"))}
            {Row(["5093796", "2026", "제2외국어/한문", "문제 및 정답", "2025-11-17", "10"], ("cc33", "제2외국어한문영역_문제지.zip"))}
            </tbody></table>
            """;
        Assert.Equal([2027, 2026], KiceArchive.ParseYears(suneung));
        var rows = KiceArchive.ParseRows(suneung);
        Assert.Equal(["국어", "제2외국어/한문"], rows.Select(r => r.Area));
        Assert.Equal(2026, rows[0].Year);
        Assert.Null(rows[0].Month);
        Assert.Equal(["aa11"], rows[0].Papers.Select(a => a.FileSeq));
        Assert.Equal(["국어영역_정답표.pdf"], rows[0].Answers.Select(a => a.Title));
        Assert.True(rows[1].HasManySubjects);
        Assert.True(rows[1].Papers[0].IsZip);

        // 모의평가 게시판: 학년도 다음에 '월' 열, 파일 열이 조회 앞에 있다.
        var mock = $"""
            <table><thead><tr><th>번호</th><th>학년도</th><th>월</th><th>영역</th><th>제목</th><th>등록일</th><th>파일</th><th>조회</th></tr></thead>
            <tbody>{Row(["5096543", "2027", "9월", "수학", "문제 및 정답", "2026-09-05"], ("dd44", "수학영역_문제지.pdf"))}</tbody></table>
            """;
        var m = KiceArchive.ParseRows(mock);
        Assert.Single(m);
        Assert.Equal("9월", m[0].Month);
        Assert.Equal("수학", m[0].Area);
        Assert.False(m[0].HasManySubjects);
    }

    [Fact]
    public void Preselect()
    {
        var d = @"C:\x";
        (string path, string area)[] files = [
            (System.IO.Path.Combine(d, "2026수능_국어영역_문제지.pdf"), "국어"),
            (System.IO.Path.Combine(d, "국어영역_홀수형.pdf"), "국어"),
            (System.IO.Path.Combine(d, "국어영역_짝수형.pdf"), "국어"),
            (System.IO.Path.Combine(d, "07 경제_문제.pdf"), "사회탐구"),
        ];
        var many = new HashSet<string> { "사회탐구" };
        Assert.Equal(new HashSet<string> { files[0].path, files[1].path }, KiceArchive.Preselect(files, many, ExamVariant.Odd));  // 홀수형만, 탐구는 고르지 않음
        Assert.Equal(new HashSet<string> { files[0].path, files[2].path }, KiceArchive.Preselect(files, many, ExamVariant.Even));
        Assert.Equal(4, KiceArchive.Preselect(files, new HashSet<string>(), ExamVariant.All).Count);
    }

    /// <summary>실제 평가원 홈페이지에서 받아 본다. MOGO_NETWORK_TESTS=1일 때만 돈다.</summary>
    [Fact]
    public async Task LiveDownload()
    {
        if (Environment.GetEnvironmentVariable("MOGO_NETWORK_TESTS") != "1")
            Assert.Skip("MOGO_NETWORK_TESTS=1일 때만 평가원 홈페이지에 접속한다");
        var ct = TestContext.Current.CancellationToken;
        Assert.Contains(2026, await KiceArchive.YearsAsync(KiceExam.Suneung, ct));
        var rows = await KiceArchive.RowsAsync(KiceExam.Suneung, 2026, ct);
        Assert.Equal(["국어", "수학", "영어", "한국사"], rows.Select(r => r.Area).Take(4));
        var dir = TempDir();
        var history = rows.First(r => r.Area == "한국사").Papers[0];
        var saved = await KiceArchive.SaveAsync(history, KiceExam.Suneung, 2026, dir, ct);
        Assert.Equal(["2026수능_한국사영역_문제지.pdf"], saved.Select(System.IO.Path.GetFileName));
        using (var f = SourceFile.Load(saved[0])) Assert.NotNull(f);

        // 2022학년도 국어는 홀·짝 PDF가 ZIP으로 묶여 있다.
        var old = await KiceArchive.RowsAsync(KiceExam.Suneung, 2022, ct);
        var zip = old.First(r => r.Area == "국어").Papers[0];
        var unzipped = await KiceArchive.SaveAsync(zip, KiceExam.Suneung, 2022, dir, ct);
        Assert.Equal(new HashSet<string> { "국어영역_홀수형.pdf", "국어영역_짝수형.pdf" }, unzipped.Select(p => System.IO.Path.GetFileName(p)!).ToHashSet());
        // 다시 받으면 이미 받은 파일을 그대로 돌려준다.
        Assert.Equal(saved, await KiceArchive.SaveAsync(history, KiceExam.Suneung, 2026, dir, ct));

        // 모의평가 게시판
        var june = await KiceArchive.RowsAsync(KiceExam.June, 2027, ct);
        Assert.All(june, r => Assert.Equal("6월", r.Month));
        Assert.Contains(june, r => r.Area == "국어");
    }
}
