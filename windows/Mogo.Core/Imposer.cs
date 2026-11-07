using System.Runtime.InteropServices;

namespace Mogo.Core;

/// <summary>자를 범위·배율을 정하고 A4 PDF를 만든다. 규칙은 docs/ALGORITHM.md.</summary>
public static class Imposer
{
    public static IReadOnlyList<ExamSection> Plan(IReadOnlyList<SourceFile> files, ImpositionOptions options)
    {
        double margin = options.PaperMarginMM * Units.PointsPerMM;
        double pad = options.PaddingMM * Units.PointsPerMM;
        var usable = new SizeD(Units.A4.Width - 2 * margin, Units.A4.Height - 2 * margin);
        var nonEmpty = files.Where(f => f.PageIndices(options).Count > 0).ToList();
        var sections = new List<ExamSection>();
        for (int n = 0; n < nonEmpty.Count; n++)
        {
            var file = nonEmpty[n];
            var indices = file.PageIndices(options);
            var adjust = options.Adjustment(file.Path);
            var bases = AutoCrops(file, indices, adjust, pad);
            var pages = indices.Select(i =>
            {
                var crop = FinalCrop(bases.TryGetValue(file.Geometry[i].SizeKey, out var b) ? b : null, file.Geometry[i], adjust);
                double scale = Math.Min(Math.Min(usable.Width / crop.Width, usable.Height / crop.Height), options.MaxScale);
                return new PlacedPage(i, crop, scale, file.Geometry[i]);
            }).ToList();
            bool isLast = n == nonEmpty.Count - 1;
            sections.Add(new ExamSection(file, pages,
                options.PadSectionsToEven && pages.Count % 2 == 1 && (!isLast || options.PadEndToEven)));
        }
        return sections;
    }

    /// <summary>같은 크기 쪽끼리 내용 영역을 합쳐 자동 범위를 만든다(손 조정 전).</summary>
    internal static Dictionary<string, RectD> AutoCrops(SourceFile file, IReadOnlyList<int> indices, CropAdjustment adjust, double pad)
    {
        var union = new Dictionary<string, RectD>();
        foreach (var i in indices)
        {
            var g = file.Geometry[i];
            RectD? found = adjust.WholePage ? new RectD(0, 0, g.Size.Width, g.Size.Height) : file.InkBounds[i];
            if (found is not { } r) continue;
            union[g.SizeKey] = union.TryGetValue(g.SizeKey, out var u) ? u.Union(r) : r;
        }
        if (adjust.WholePage) return union;
        return union.ToDictionary(kv => kv.Key, kv => kv.Value.Inset(-pad, -pad));
    }

    /// <summary>자동 범위에 손 조정을 적용하고 쪽 안으로 맞춘다. 너무 작아지면 쪽 전체.</summary>
    internal static RectD FinalCrop(RectD? baseCrop, PageGeometry geo, CropAdjustment adjust)
    {
        var page = new RectD(0, 0, geo.Size.Width, geo.Size.Height);
        var crop = Apply(adjust, baseCrop ?? page).Intersect(page);
        if (crop.IsEmpty || crop.Width < 36 || crop.Height < 36) return page;
        return crop;
    }

    /// <summary>손 조정 값(mm)을 적용한다. +는 안으로 더 자르고 -는 밖으로 넓힌다.</summary>
    public static RectD Apply(CropAdjustment a, RectD r)
    {
        double mm = Units.PointsPerMM;
        double l = a.Left * mm, rt = a.Right * mm, t = a.Top * mm, b = a.Bottom * mm;
        return new RectD(r.X + l, r.Y + b, r.Width - l - rt, r.Height - t - b);
    }

    /// <summary>손 조정 전 자동 범위(수동 조정 화면의 기준).</summary>
    public static RectD BaseCrop(SourceFile file, int pageIndex, ImpositionOptions options)
    {
        var crops = AutoCrops(file, file.PageIndices(options), options.Adjustment(file.Path), options.PaddingMM * Units.PointsPerMM);
        var g = file.Geometry[pageIndex];
        return crops.TryGetValue(g.SizeKey, out var c) ? c : new RectD(0, 0, g.Size.Width, g.Size.Height);
    }

    /// <summary>손 조정까지 적용한 최종 범위.</summary>
    public static RectD Crop(SourceFile file, int pageIndex, ImpositionOptions options) =>
        FinalCrop(BaseCrop(file, pageIndex, options), file.Geometry[pageIndex], options.Adjustment(file.Path));

    /// <summary>범위를 A4에 놓을 때의 배율.</summary>
    public static double Scale(RectD crop, ImpositionOptions options)
    {
        double margin = options.PaperMarginMM * Units.PointsPerMM;
        return Math.Min(Math.Min((Units.A4.Width - 2 * margin) / crop.Width, (Units.A4.Height - 2 * margin) / crop.Height), options.MaxScale);
    }

    /// <summary>A4 PDF를 만든다. 원본 쪽을 가져와 회전·배율·위치 변환과 자르기를 내용에 직접 걸므로 벡터 그대로다.</summary>
    public static ImpositionResult Render(IReadOnlyList<ExamSection> sections)
    {
        Pdfium.EnsureInit();
        lock (Pdfium.Sync)
        {
            var dest = Native.FPDF_CreateNewDocument();
            try
            {
                int index = 0;
                foreach (var section in sections)
                {
                    if (section.Pages.Count > 0)
                    {
                        // 한 파일의 쪽은 한 번에 가져와야 글꼴 같은 공유 자원이 한 번만 들어간다.
                        var indices = section.Pages.Select(p => p.Index).ToArray();
                        if (Native.FPDF_ImportPagesByIndex(dest, section.File.Doc.Handle, indices, (uint)indices.Length, index) == 0)
                            throw new InvalidOperationException($"{section.File.Name}의 쪽을 가져오지 못했어요.");
                        for (int k = 0; k < section.Pages.Count; k++)
                        {
                            var page = Native.FPDF_LoadPage(dest, index + k);
                            try { Place(page, section.Pages[k]); }
                            finally { Native.FPDF_ClosePage(page); }
                        }
                        index += section.Pages.Count;
                    }
                    if (section.PadsBlankPage)
                    {
                        Native.FPDF_ClosePage(Native.FPDFPage_New(dest, index, Units.A4.Width, Units.A4.Height));
                        index++;
                    }
                }
                return new ImpositionResult(sections, PdfDoc.Save(dest), index);
            }
            finally { Native.FPDF_CloseDocument(dest); }
        }
    }

    public static ImpositionResult Impose(IReadOnlyList<SourceFile> files, ImpositionOptions options) => Render(Plan(files, options));

    /// <summary>가져온 쪽 하나를 A4 한가운데에 배치한다.</summary>
    private static void Place(IntPtr page, PlacedPage placed)
    {
        var geo = PdfDoc.GeometryOf(page);
        var (ta, tb, tc, td, te, tf) = geo.UprightTransform();
        double s = placed.Scale, w = placed.Crop.Width * s, h = placed.Crop.Height * s;
        double offX = (Units.A4.Width - w) / 2, offY = (Units.A4.Height - h) / 2;
        // 배치 = 배율·이동 ∘ 화면 방향 변환
        double pe = offX - placed.Crop.MinX * s, pf = offY - placed.Crop.MinY * s;
        var m = new Native.FS_MATRIX
        {
            a = (float)(s * ta), b = (float)(s * tb), c = (float)(s * tc), d = (float)(s * td),
            e = (float)(s * te + pe), f = (float)(s * tf + pf),
        };
        var clip = new Native.FS_RECTF { left = (float)offX, top = (float)(offY + h), right = (float)(offX + w), bottom = (float)offY };
        Native.FPDFPage_SetRotation(page, 0);
        Native.FPDFPage_TransFormWithClip(page, ref m, ref clip);
        Native.FPDFPage_TransformAnnots(page, m.a, m.b, m.c, m.d, m.e, m.f);
        float aw = (float)Units.A4.Width, ah = (float)Units.A4.Height;
        Native.FPDFPage_SetMediaBox(page, 0, 0, aw, ah);
        Native.FPDFPage_SetCropBox(page, 0, 0, aw, ah);
        Native.FPDFPage_SetBleedBox(page, 0, 0, aw, ah);
        Native.FPDFPage_SetTrimBox(page, 0, 0, aw, ah);
        Native.FPDFPage_SetArtBox(page, 0, 0, aw, ah);
    }
}

/// <summary>여백 수동 조정 화면의 네 변 점선 계산. 좌표는 쪽 기준 pt(왼쪽 아래 원점, 화면 방향).</summary>
public static class CropGuides
{
    public enum Edge { Top, Bottom, Left, Right }

    /// <summary>마주 보는 두 점선 사이 최소 길이(25mm).</summary>
    public static readonly double MinGap = 25 * Units.PointsPerMM;

    /// <summary>점선 하나를 옮긴다. 쪽 밖으로 나가지 않고 마주 보는 점선과 MinGap 이상 떨어진다.</summary>
    public static RectD Move(Edge edge, double value, RectD c, SizeD page, double? minGap = null)
    {
        double gap = minGap ?? MinGap;
        double minX = c.MinX, maxX = c.MaxX, minY = c.MinY, maxY = c.MaxY;
        switch (edge)
        {
            case Edge.Top: maxY = Math.Min(page.Height, Math.Max(value, minY + gap)); break;
            case Edge.Bottom: minY = Math.Max(0, Math.Min(value, maxY - gap)); break;
            case Edge.Left: minX = Math.Max(0, Math.Min(value, maxX - gap)); break;
            case Edge.Right: maxX = Math.Min(page.Width, Math.Max(value, minX + gap)); break;
        }
        return RectD.FromEdges(minX, minY, maxX, maxY);
    }

    /// <summary>점선으로 정한 범위를 손 조정 값(0.5mm 단위)으로 바꾼다. '자동 자르기 끄기'는 그대로.</summary>
    public static CropAdjustment Adjustment(RectD crop, RectD baseCrop, CropAdjustment old)
    {
        static double Half(double pt) => Math.Round(pt / Units.PointsPerMM * 2, MidpointRounding.AwayFromZero) / 2;
        return old with
        {
            Top = Half(baseCrop.MaxY - crop.MaxY),
            Bottom = Half(crop.MinY - baseCrop.MinY),
            Left = Half(crop.MinX - baseCrop.MinX),
            Right = Half(baseCrop.MaxX - crop.MaxX),
        };
    }
}

/// <summary>파일·폴더를 PDF 목록으로 펼친다.</summary>
public static class FileExpander
{
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    private static extern int StrCmpLogicalW(string a, string b);

    /// <summary>윈도우 탐색기와 같은 자연 정렬(숫자는 크기 순).</summary>
    public static int NaturalCompare(string a, string b) => StrCmpLogicalW(a, b);

    /// <summary>폴더면 하위 폴더까지 PDF를 상대 경로 자연 정렬로 펼친다. 숨김·'.'으로 시작하는 파일은 빼고, 같은 파일은 한 번만.</summary>
    public static List<string> ExpandPDFs(IEnumerable<string> inputs)
    {
        var outList = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        static bool IsPdf(string p) => p.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && !System.IO.Path.GetFileName(p).StartsWith('.');
        void Add(string p)
        {
            var full = System.IO.Path.GetFullPath(p);
            if (seen.Add(full)) outList.Add(full);
        }
        foreach (var input in inputs)
        {
            if (Directory.Exists(input))
            {
                var root = System.IO.Path.GetFullPath(input);
                var files = Directory.EnumerateFiles(root, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System })
                    .Where(IsPdf)
                    .Select(f => (full: f, rel: System.IO.Path.GetRelativePath(root, f)))
                    .ToList();
                files.Sort((x, y) => NaturalCompare(x.rel, y.rel));
                foreach (var f in files) Add(f.full);
            }
            else if (File.Exists(input) && IsPdf(input))
            {
                Add(input);
            }
        }
        return outList;
    }
}
