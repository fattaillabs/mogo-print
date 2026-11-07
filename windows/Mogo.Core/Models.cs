namespace Mogo.Core;

/// <summary>사각형(pt). 원점은 왼쪽 아래.</summary>
public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MinY => Y;
    public double MaxX => X + Width;
    public double MaxY => Y + Height;
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;
    public bool IsEmpty => Width <= 0 || Height <= 0;

    public static RectD FromEdges(double minX, double minY, double maxX, double maxY) => new(minX, minY, maxX - minX, maxY - minY);

    public RectD Union(RectD o) => FromEdges(Math.Min(MinX, o.MinX), Math.Min(MinY, o.MinY), Math.Max(MaxX, o.MaxX), Math.Max(MaxY, o.MaxY));

    public RectD Inset(double dx, double dy) => new(X + dx, Y + dy, Width - 2 * dx, Height - 2 * dy);

    /// <summary>겹치는 부분. 겹치지 않으면 빈 사각형.</summary>
    public RectD Intersect(RectD o)
    {
        double minX = Math.Max(MinX, o.MinX), minY = Math.Max(MinY, o.MinY);
        double maxX = Math.Min(MaxX, o.MaxX), maxY = Math.Min(MaxY, o.MaxY);
        return maxX <= minX || maxY <= minY ? new RectD(0, 0, 0, 0) : FromEdges(minX, minY, maxX, maxY);
    }

    public bool Contains(RectD o) => o.MinX >= MinX - 1e-6 && o.MinY >= MinY - 1e-6 && o.MaxX <= MaxX + 1e-6 && o.MaxY <= MaxY + 1e-6;
}

public readonly record struct SizeD(double Width, double Height);

public static class Units
{
    public const double PointsPerMM = 72.0 / 25.4;
    public static readonly SizeD A4 = new(595.28, 841.89);
}

/// <summary>쪽 기하: cropBox와 회전(0~3, 90도 단위 시계 방향). 화면 방향(회전 반영) 좌표계로 바꾸는 변환을 준다.</summary>
public readonly record struct PageGeometry(RectD Box, int Rotation)
{
    /// <summary>회전을 반영한 크기.</summary>
    public SizeD Size => Rotation % 2 == 1 ? new(Box.Height, Box.Width) : new(Box.Width, Box.Height);

    /// <summary>크기별로 묶을 때 쓰는 키(1pt 단위 반올림).</summary>
    public string SizeKey => $"{Math.Round(Size.Width)}x{Math.Round(Size.Height)}";

    /// <summary>PDF 사용자 공간 → 화면 방향 좌표계(원점 0,0). x' = a x + c y + e, y' = b x + d y + f.</summary>
    public (double a, double b, double c, double d, double e, double f) UprightTransform()
    {
        double x0 = Box.MinX, y0 = Box.MinY, x1 = Box.MaxX, y1 = Box.MaxY;
        return Rotation switch
        {
            1 => (0, -1, 1, 0, -y0, x1),   // 시계 방향 90도: 원래 왼쪽 아래 → 왼쪽 위
            2 => (-1, 0, 0, -1, x1, y1),
            3 => (0, 1, -1, 0, y1, -x0),
            _ => (1, 0, 0, 1, -x0, -y0),
        };
    }
}

/// <summary>시험지 형.</summary>
public enum ExamVariant { Odd, Even, All }

public static class ExamVariantText
{
    public static string Korean(this ExamVariant v) => v switch { ExamVariant.Odd => "홀수형", ExamVariant.Even => "짝수형", _ => "전체" };
    public static string Code(this ExamVariant v) => v switch { ExamVariant.Odd => "odd", ExamVariant.Even => "even", _ => "all" };
}

/// <summary>선택과목이 있는 과목(2022~2027학년도 국어·수학).</summary>
public enum ElectiveSubject { Korean, Math }

/// <summary>선택과목. 쪽 머리말에 "(화법과 작문)"처럼 괄호로 찍힌 과목명으로 알아본다.</summary>
public enum Elective { SpeechWriting, LanguageMedia, Probability, Calculus, Geometry }

public static class ElectiveInfo
{
    public static readonly Elective[] All = Enum.GetValues<Elective>();

    public static string FullName(this Elective e) => e switch
    {
        Elective.SpeechWriting => "화법과 작문",
        Elective.LanguageMedia => "언어와 매체",
        Elective.Probability => "확률과 통계",
        Elective.Calculus => "미적분",
        _ => "기하",
    };

    public static string ShortName(this Elective e) => e switch
    {
        Elective.SpeechWriting => "화작",
        Elective.LanguageMedia => "언매",
        Elective.Probability => "확통",
        Elective.Calculus => "미적",
        _ => "기하",
    };

    /// <summary>기준값 파일에 쓰는 한 글자 기호.</summary>
    public static char Code(this Elective e) => e switch
    {
        Elective.SpeechWriting => 'S',
        Elective.LanguageMedia => 'L',
        Elective.Probability => 'P',
        Elective.Calculus => 'C',
        _ => 'G',
    };

    public static ElectiveSubject Subject(this Elective e) =>
        e is Elective.SpeechWriting or Elective.LanguageMedia ? ElectiveSubject.Korean : ElectiveSubject.Math;

    public static string Korean(this ElectiveSubject s) => s == ElectiveSubject.Korean ? "국어" : "수학";

    public static IEnumerable<Elective> Electives(this ElectiveSubject s) => All.Where(e => e.Subject() == s);

    /// <summary>줄임말·전체 이름(띄어쓰기 무시)으로 찾는다. 예: "언매", "언어와 매체", "미적분"</summary>
    public static Elective? Parse(string name)
    {
        var key = name.Replace(" ", "");
        foreach (var e in All)
            if (e.ShortName() == key || e.FullName().Replace(" ", "") == key) return e;
        return null;
    }
}

/// <summary>파일 하나에 대한 손 조정(mm). +는 더 잘라내고 -는 여백을 더 남긴다.</summary>
public readonly record struct CropAdjustment(double Top = 0, double Bottom = 0, double Left = 0, double Right = 0, bool WholePage = false)
{
    public bool IsDefault => this == default;
}

public sealed record ImpositionOptions
{
    /// <summary>A4 가장자리에 남길 최소 여백(mm).</summary>
    public double PaperMarginMM { get; init; } = 5;
    /// <summary>감지한 내용 영역 바깥에 덧붙일 여유(mm).</summary>
    public double PaddingMM { get; init; } = 1.5;
    public ExamVariant Variant { get; init; } = ExamVariant.Odd;
    /// <summary>과목별로 고른 선택과목. 없으면 그 과목의 선택과목 쪽을 모두 넣는다.</summary>
    public IReadOnlyDictionary<ElectiveSubject, Elective> Electives { get; init; } = new Dictionary<ElectiveSubject, Elective>();
    /// <summary>양면 인쇄 때 홀수 쪽 파일 뒤에 빈 쪽을 넣을지.</summary>
    public bool PadSectionsToEven { get; init; } = true;
    /// <summary>마지막 파일 뒤에도 빈 쪽을 넣을지(양면으로 여러 부).</summary>
    public bool PadEndToEven { get; init; }
    /// <summary>원본보다 크게 키우지 않는다.</summary>
    public double MaxScale { get; init; } = 1;
    /// <summary>파일별 손 조정(전체 경로 기준).</summary>
    public IReadOnlyDictionary<string, CropAdjustment> Adjustments { get; init; } = new Dictionary<string, CropAdjustment>(StringComparer.OrdinalIgnoreCase);

    public CropAdjustment Adjustment(string path) => Adjustments.TryGetValue(path, out var a) ? a : default;

    public ImpositionOptions WithAdjustment(string path, CropAdjustment? adjust)
    {
        var d = new Dictionary<string, CropAdjustment>(Adjustments, StringComparer.OrdinalIgnoreCase);
        if (adjust is { IsDefault: false } a) d[path] = a; else d.Remove(path);
        return this with { Adjustments = d };
    }

    public ImpositionOptions WithElective(ElectiveSubject subject, Elective? elective)
    {
        var d = new Dictionary<ElectiveSubject, Elective>(Electives);
        if (elective is { } e) d[subject] = e; else d.Remove(subject);
        return this with { Electives = d };
    }

    public bool SameAs(ImpositionOptions o) =>
        PaperMarginMM == o.PaperMarginMM && PaddingMM == o.PaddingMM && Variant == o.Variant &&
        PadSectionsToEven == o.PadSectionsToEven && PadEndToEven == o.PadEndToEven && MaxScale == o.MaxScale &&
        Electives.Count == o.Electives.Count && Electives.All(kv => o.Electives.TryGetValue(kv.Key, out var v) && v == kv.Value) &&
        Adjustments.Count == o.Adjustments.Count && Adjustments.All(kv => o.Adjustments.TryGetValue(kv.Key, out var v) && v == kv.Value);
}

/// <summary>A4 한 쪽에 놓일 원본 쪽.</summary>
public sealed record PlacedPage(int Index, RectD Crop, double Scale, PageGeometry Geometry);

/// <summary>한 파일에서 뽑은 쪽 묶음.</summary>
public sealed record ExamSection(SourceFile File, IReadOnlyList<PlacedPage> Pages, bool PadsBlankPage)
{
    public IReadOnlyList<int> PageIndices => Pages.Select(p => p.Index).ToList();
    public double Scale => Pages.Count == 0 ? 1 : Pages.Min(p => p.Scale);
    public RectD Crop => Pages.Count == 0 ? default : Pages[0].Crop;
    public SizeD PageSize => Pages.Count == 0 ? default : Pages[0].Geometry.Size;
    public int OutputPageCount => Pages.Count + (PadsBlankPage ? 1 : 0);
}

public sealed record ImpositionResult(IReadOnlyList<ExamSection> Sections, byte[] Pdf, int PageCount);
