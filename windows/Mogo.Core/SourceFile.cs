using System.Text;
using System.Text.RegularExpressions;

namespace Mogo.Core;

/// <summary>불러온 PDF 한 개와 분석 결과.</summary>
public sealed class SourceFile : IDisposable
{
    public string Path { get; }
    public PdfDoc Doc { get; }
    public int PageCount => Doc.PageCount;
    /// <summary>쪽별 형 라벨. 라벨이 없는 쪽은 앞 쪽 라벨을 이어받고, 첫 라벨 전 쪽(표지 등)은 null.</summary>
    public IReadOnlyList<ExamVariant?> PageVariants { get; }
    /// <summary>쪽별 선택과목. 공통 쪽은 null.</summary>
    public IReadOnlyList<Elective?> PageElectives { get; }
    /// <summary>쪽별 내용(잉크) 영역, 화면 방향 좌표계. 빈 쪽은 null.</summary>
    public IReadOnlyList<RectD?> InkBounds { get; }
    public IReadOnlyList<PageGeometry> Geometry { get; }

    public string Name => System.IO.Path.GetFileNameWithoutExtension(Path);
    public bool HasBothVariants => PageVariants.Contains(ExamVariant.Odd) && PageVariants.Contains(ExamVariant.Even);
    public IReadOnlyList<Elective> Electives => PageElectives.Where(e => e != null).Select(e => e!.Value).Distinct().ToList();
    public ElectiveSubject? ElectiveSubject => Electives.Count > 0 ? Electives[0].Subject() : null;

    private SourceFile(string path, PdfDoc doc, List<ExamVariant?> labels, List<Elective?> electives, List<RectD?> ink, List<PageGeometry> geo)
    {
        Path = path;
        Doc = doc;
        PageVariants = ExamAnalyzer.Propagate(labels);
        PageElectives = electives;
        InkBounds = ink;
        Geometry = geo;
    }

    /// <summary>파일을 열고 쪽마다 형·선택과목·잉크 영역을 구한다. 열 수 없으면 null.</summary>
    public static SourceFile? Load(string path)
    {
        var doc = PdfDoc.Open(path);
        if (doc == null) return null;
        if (doc.PageCount <= 0) { doc.Dispose(); return null; }
        var labels = new List<ExamVariant?>();
        var electives = new List<Elective?>();
        var ink = new List<RectD?>();
        var geo = new List<PageGeometry>();
        for (int i = 0; i < doc.PageCount; i++)
        {
            var g = doc.Geometry(i);
            var text = doc.Text(i);
            geo.Add(g);
            labels.Add(ExamAnalyzer.VariantLabel(text));
            electives.Add(ExamAnalyzer.ElectiveLabel(text));
            ink.Add(ExamAnalyzer.InkBounds(doc, i, g));
        }
        return new SourceFile(path, doc, labels, electives, ink, geo);
    }

    /// <summary>선택한 형에 해당하는 쪽 번호(0부터).</summary>
    public IReadOnlyList<int> PageIndices(ExamVariant variant)
    {
        var all = Enumerable.Range(0, PageCount);
        if (variant == ExamVariant.All || !HasBothVariants) return all.ToList();
        return all.Where(i => PageVariants[i] == null || PageVariants[i] == variant).ToList();
    }

    /// <summary>배치 설정(형·선택과목)에 해당하는 쪽 번호. 공통 쪽은 언제나 들어간다.</summary>
    public IReadOnlyList<int> PageIndices(ImpositionOptions options)
    {
        var pages = PageIndices(options.Variant);
        if (ElectiveSubject is not { } subject || !options.Electives.TryGetValue(subject, out var chosen)) return pages;
        return pages.Where(i => PageElectives[i] == null || PageElectives[i] == chosen).ToList();
    }

    public void Dispose() => Doc.Dispose();
}

public static class ExamAnalyzer
{
    private static readonly HashSet<char> Brackets = new("()（）[]［］〔〕「」<>〈〉");

    /// <summary>텍스트에서 형 라벨을 찾는다. "홀수형", "홀 수 형", "( 홀수 )형" 모두 인식. 둘 다 있으면 라벨로 보지 않는다.</summary>
    public static ExamVariant? VariantLabel(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var ch in text) if (!char.IsWhiteSpace(ch) && !Brackets.Contains(ch)) sb.Append(ch);
        var s = sb.ToString();
        bool odd = s.Contains("홀수형"), even = s.Contains("짝수형");
        if (odd == even) return null;
        return odd ? ExamVariant.Odd : ExamVariant.Even;
    }

    /// <summary>쪽 글자에서 선택과목을 찾는다. 안내문 "선택과목(…)"은 빼고 괄호로 싼 과목명을 찾는다. 하나만 나올 때만.</summary>
    public static Elective? ElectiveLabel(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var ch in text) if (!char.IsWhiteSpace(ch)) sb.Append(ch);
        var t = sb.ToString().Replace('（', '(').Replace('）', ')');
        t = Regex.Replace(t, @"선택과목\([^)]*\)", "");
        var found = ElectiveInfo.All.Where(e => t.Contains("(" + e.FullName().Replace(" ", "") + ")")).ToList();
        return found.Count == 1 ? found[0] : null;
    }

    /// <summary>라벨이 없는 쪽은 앞 쪽 라벨을 이어받는다.</summary>
    public static List<ExamVariant?> Propagate(IEnumerable<ExamVariant?> labels)
    {
        ExamVariant? current = null;
        var outList = new List<ExamVariant?>();
        foreach (var l in labels)
        {
            if (l != null) current = l;
            outList.Add(current);
        }
        return outList;
    }

    /// <summary>쪽을 50dpi로 그려 밝기 200 미만 픽셀의 경계를 pt로 돌려준다(화면 방향 좌표, 원점 왼쪽 아래).</summary>
    public static RectD? InkBounds(PdfDoc doc, int index, PageGeometry geo, double dpi = 50, int threshold = 200)
    {
        double s = dpi / 72.0;
        int w = (int)Math.Ceiling(geo.Size.Width * s), h = (int)Math.Ceiling(geo.Size.Height * s);
        var (px, _, _) = doc.RenderBgra(index, w, h);
        int minX = w, maxX = -1, minRow = h, maxRow = -1;
        for (int row = 0; row < h; row++)
        {
            int o = row * w * 4;
            bool rowInk = false;
            for (int x = 0; x < w; x++, o += 4)
            {
                // BGRA → 밝기
                int lum = (px[o + 2] * 299 + px[o + 1] * 587 + px[o] * 114) / 1000;
                if (lum < threshold)
                {
                    rowInk = true;
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                }
            }
            if (rowInk) { if (row < minRow) minRow = row; maxRow = row; }
        }
        if (maxX < 0 || maxRow < 0) return null;
        // PDFium은 쪽을 정수 크기 비트맵(w×h)에 꽉 차게 그리므로 실제 배율은 축마다 w/폭, h/높이다
        // (dpi/72보다 살짝 크다). 이 배율로 바꿔야 맥(정확히 dpi로 그림)과 위치가 맞는다.
        double sx = w / geo.Size.Width, sy = h / geo.Size.Height;
        double x0 = minX / sx, x1 = Math.Min(geo.Size.Width, (maxX + 1) / sx);
        double yTop = geo.Size.Height - minRow / sy, yBottom = Math.Max(0, geo.Size.Height - (maxRow + 1) / sy);
        return RectD.FromEdges(x0, yBottom, x1, yTop);
    }
}
