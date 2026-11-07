using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using Mogo.Core;

namespace MogoPrint;

/// <summary>INotifyPropertyChanged 도우미.</summary>
public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>왼쪽 목록의 파일 한 줄.</summary>
public sealed class FileItem(SourceFile file) : Observable
{
    public SourceFile File { get; } = file;
    public string Name => File.Name;
    public bool IsCombined => File.HasBothVariants;

    private string detail = $"{file.PageCount}쪽";
    public string Detail { get => detail; set => Set(ref detail, value); }

    private string? electiveText;
    public string? ElectiveText { get => electiveText; set { if (Set(ref electiveText, value)) Raise(nameof(HasElective)); } }
    public bool HasElective => electiveText != null;

    private bool adjusted;
    public bool Adjusted { get => adjusted; set { if (Set(ref adjusted, value)) Raise(nameof(CropBrush)); } }

    private bool padsBlank;
    public bool PadsBlank { get => padsBlank; set => Set(ref padsBlank, value); }

    private bool cropActive;
    public bool CropActive { get => cropActive; set { if (Set(ref cropActive, value)) Raise(nameof(CropBrush)); } }

    /// <summary>여백 조정 아이콘 색: 손봤거나 조정 중이면 강조색.</summary>
    public Brush CropBrush => adjusted || cropActive ? Theme.Accent : Theme.Secondary;
}

/// <summary>선택과목 한 줄(국어·수학).</summary>
public sealed record ElectiveRow(ElectiveSubject Subject, string Title, string[] Labels);

/// <summary>앱 상태. 맥 버전 AppModel과 같은 일을 한다.</summary>
public sealed class AppModel : Observable
{
    public ObservableCollection<FileItem> Files { get; } = new();

    /// <summary>자동 점검(--snapshot-dir) 중이면 사용자 설정을 읽거나 쓰지 않는다.</summary>
    public bool SnapshotMode { get; init; }

    private ImpositionOptions options = new();
    public ImpositionOptions Options
    {
        get => options;
        set
        {
            var old = options;
            options = value;
            Raise();
            if (!SameElectives(old, value)) SaveElectives();
            if (!old.SameAs(value)) { RefreshFileRows(); Rebuild(); }
        }
    }

    // 인쇄 설정
    private string printer = "";
    public string Printer
    {
        get => printer;
        set
        {
            if (!Set(ref printer, value)) return;
            RefreshPrinterInfo();
        }
    }
    private bool duplex = true;
    public bool Duplex { get => duplex; set { var p = Padding; if (Set(ref duplex, value)) { Raise(nameof(SheetCount)); if (p != Padding) Rebuild(); } } }
    private bool grayscale = true;
    public bool Grayscale { get => grayscale; set => Set(ref grayscale, value); }
    private int copies = 1;
    public int Copies { get => copies; set { var p = Padding; if (Set(ref copies, Math.Clamp(value, 1, 50)) && p != Padding) Rebuild(); } }

    public List<string> Printers { get; private set; } = [];
    private double? hardwareMarginMM;
    public double? HardwareMarginMM { get => hardwareMarginMM; private set { if (Set(ref hardwareMarginMM, value)) Raise(nameof(MarginTooSmall)); } }
    /// <summary>고른 프린터가 양면을 지원하는지(모르면 true로 둔다).</summary>
    private bool canDuplex = true;
    public bool CanDuplex { get => canDuplex; private set { var p = Padding; if (Set(ref canDuplex, value)) { Raise(nameof(EffectiveDuplex)); Raise(nameof(SheetCount)); if (p != Padding) Rebuild(); } } }
    /// <summary>프린터 정보(양면 지원·인쇄 불가 여백)를 다 읽었는지, 못 읽었으면 그 이유.</summary>
    public bool PrinterInfoLoaded { get; private set; }
    public string? PrinterInfoError { get; private set; }
    /// <summary>실제로 양면으로 나가는지(사용자 선택 + 프린터 지원).</summary>
    public bool EffectiveDuplex => duplex && canDuplex;

    // 결과
    public byte[]? OutputPdf { get; private set; }
    /// <summary>화면 미리보기용으로 연 결과 문서. 결과가 바뀌면 새로 열고 앞의 것은 닫는다.</summary>
    public PdfDoc? PreviewDoc { get; private set; }
    public IReadOnlyList<ExamSection> Sections { get; private set; } = [];
    public int OutputPageCount { get; private set; }
    /// <summary>결과(미리보기)가 바뀌었을 때.</summary>
    public event Action? OutputChanged;

    private bool isWorking;
    public bool IsWorking { get => isWorking; private set => Set(ref isWorking, value); }
    private bool isPrinting;
    public bool IsPrinting { get => isPrinting; private set { if (Set(ref isPrinting, value)) Raise(nameof(CanPrint)); } }
    private int loadingCount;
    public int LoadingCount { get => loadingCount; private set => Set(ref loadingCount, value); }
    private string? status;
    public string? Status { get => status; set => Set(ref status, value); }
    private string? error;
    public string? Error { get => error; set => Set(ref error, value); }

    /// <summary>여백 수동 조정 중인 파일(없으면 꺼짐).</summary>
    private FileItem? manualCrop;
    public FileItem? ManualCrop
    {
        get => manualCrop;
        set
        {
            if (manualCrop == value) return;
            if (manualCrop != null) manualCrop.CropActive = false;
            manualCrop = value;
            if (manualCrop != null) manualCrop.CropActive = true;
            Raise();
        }
    }
    /// <summary>수동 조정을 켤 때 처음 보여 줄 쪽(그 파일의 고른 쪽 목록에서 몇 번째).</summary>
    public int ManualCropStartPosition { get; set; }

    private int generation;
    private readonly SemaphoreSlim renderGate = new(1, 1);
    private readonly HashSet<string> loadingPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<SourceFile> pendingDispose = [];

    public AppModel(bool snapshotMode = false)
    {
        SnapshotMode = snapshotMode;
        var (names, def) = Printing.Printers();
        Printers = names;
        printer = def ?? "";
        RefreshPrinterInfo();
        if (!SnapshotMode) options = options with { Electives = LoadElectives() };
    }

    // MARK: 선택과목 (학생마다 잘 안 바뀌어서 다음 실행 때도 기억한다)

    private static string SettingsPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MogoPrint", "settings.json");

    private static Dictionary<ElectiveSubject, Elective> LoadElectives()
    {
        var outMap = new Dictionary<ElectiveSubject, Elective>();
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(SettingsPath));
            if (doc.RootElement.TryGetProperty("electives", out var e))
                foreach (var p in e.EnumerateObject())
                    if (Enum.TryParse<ElectiveSubject>(p.Name, out var s) && Enum.TryParse<Elective>(p.Value.GetString(), out var v) && v.Subject() == s)
                        outMap[s] = v;
        }
        catch { }
        return outMap;
    }

    private void SaveElectives()
    {
        if (SnapshotMode) return;
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(SettingsPath)!);
            var map = options.Electives.ToDictionary(kv => kv.Key.ToString(), kv => kv.Value.ToString());
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(new { electives = map }));
        }
        catch { }
    }

    private static bool SameElectives(ImpositionOptions a, ImpositionOptions b) =>
        a.Electives.Count == b.Electives.Count && a.Electives.All(kv => b.Electives.TryGetValue(kv.Key, out var v) && v == kv.Value);

    /// <summary>지금 목록에 선택과목이 있는 과목(국어, 수학 순).</summary>
    public List<ElectiveRow> ElectiveRows =>
        Enum.GetValues<ElectiveSubject>()
            .Where(s => Files.Any(f => f.File.ElectiveSubject == s))
            .Select(s => new ElectiveRow(s, $"{s.Korean()} 선택과목", ["전체", .. s.Electives().Select(e => e.ShortName())]))
            .ToList();

    public void SetElective(ElectiveSubject subject, int index)
    {
        Elective? e = index <= 0 ? null : subject.Electives().ElementAt(index - 1);
        Options = Options.WithElective(subject, e);
    }

    public int ElectiveIndex(ElectiveSubject subject) =>
        Options.Electives.TryGetValue(subject, out var e) ? subject.Electives().ToList().IndexOf(e) + 1 : 0;

    // MARK: 파일

    private static string Key(string path)
    {
        try { return System.IO.Path.GetFullPath(path); } catch { return path; }
    }

    /// <summary>파일을 목록에 넣는다. keepOrder가 아니면 한 묶음을 이름순(자연 정렬)으로 맞춘다.
    /// 평가원에서 받은 파일은 시험 순서(국어, 수학, 영어 …)를 지키려고 keepOrder로 넣는다.</summary>
    public async Task AddAsync(IEnumerable<string> inputs, bool keepOrder = false)
    {
        var list = inputs.ToList();
        var batch = keepOrder ? list : list.OrderBy(p => System.IO.Path.GetFileName(p), Comparer<string>.Create(FileExpander.NaturalCompare)).ToList();
        var existing = new HashSet<string>(Files.Select(f => Key(f.File.Path)).Concat(loadingPaths), StringComparer.OrdinalIgnoreCase);
        var pdfs = FileExpander.ExpandPDFs(batch).Where(p => !existing.Contains(Key(p))).ToList();
        if (pdfs.Count == 0)
        {
            if (list.Count > 0 && FileExpander.ExpandPDFs(list).Count == 0) Error = "PDF 파일(또는 PDF가 든 폴더)만 열 수 있어요.";
            return;
        }
        foreach (var p in pdfs) loadingPaths.Add(Key(p));
        LoadingCount += pdfs.Count;
        var loaded = await Task.Run(() => pdfs.Select(SourceFile.Load).ToList());
        LoadingCount -= pdfs.Count;
        foreach (var p in pdfs) loadingPaths.Remove(Key(p));
        foreach (var f in loaded) if (f != null) Files.Add(new FileItem(f));
        var failed = pdfs.Where((_, i) => loaded[i] == null).Select(System.IO.Path.GetFileName).ToList();
        if (failed.Count > 0) Error = "열지 못한 PDF가 있어요. 암호가 걸렸거나 손상된 파일일 수 있어요.\n" + string.Join("\n", failed);
        RefreshFileRows();
        Raise(nameof(ElectiveRows));
        Raise(nameof(HasCombinedVariants));
        Rebuild();
    }

    public void Remove(FileItem item)
    {
        if (ManualCrop == item) ManualCrop = null;
        Files.Remove(item);
        pendingDispose.Add(item.File);
        options = options.WithAdjustment(item.File.Path, null);
        Raise(nameof(Options));
        Raise(nameof(ElectiveRows));
        Raise(nameof(HasCombinedVariants));
        Rebuild();
    }

    public void Move(int from, int to)
    {
        if (from == to || from < 0 || to < 0 || from >= Files.Count || to >= Files.Count) return;
        Files.Move(from, to);
        Rebuild();
    }

    public void Clear()
    {
        ManualCrop = null;
        pendingDispose.AddRange(Files.Select(f => f.File));
        Files.Clear();
        Status = null;
        options = options with { Adjustments = new Dictionary<string, CropAdjustment>(StringComparer.OrdinalIgnoreCase) };
        Raise(nameof(Options));
        Raise(nameof(ElectiveRows));
        Raise(nameof(HasCombinedVariants));
        Rebuild();
    }

    // MARK: 변환

    public bool HasCombinedVariants => Files.Any(f => f.File.HasBothVariants);
    public int SheetCount => EffectiveDuplex ? (OutputPageCount + 1) / 2 : OutputPageCount;
    /// <summary>화면에 보여 줄 대표 배율(가장 작은 값, %).</summary>
    public int DisplayScale => Sections.Count == 0 ? 0 : (int)Math.Round(Sections.Min(s => s.Scale) * 100);
    public bool MarginTooSmall => HardwareMarginMM is { } hw && Options.PaperMarginMM + 0.05 < hw;

    /// <summary>결과 쪽 번호(0부터)가 어느 파일의 몇 번째 쪽인지. 빈 쪽이면 null.</summary>
    public (FileItem item, int position)? SourcePosition(int outputPage)
    {
        int start = 0;
        foreach (var s in Sections)
        {
            if (outputPage < start + s.Pages.Count)
            {
                var item = Files.FirstOrDefault(f => f.File == s.File);
                return item == null ? null : (item, outputPage - start);
            }
            start += s.OutputPageCount;
            if (outputPage < start) return null;
        }
        return null;
    }

    public void StartManualCrop(FileItem? item = null, int outputPage = 0)
    {
        if (item != null)
        {
            ManualCropStartPosition = 0;
            ManualCrop = item;
        }
        else if (SourcePosition(outputPage) is { } found)
        {
            ManualCropStartPosition = found.position;
            ManualCrop = found.item;
        }
        else if (Files.Count > 0)
        {
            ManualCropStartPosition = 0;
            ManualCrop = Files[0];
        }
    }

    private (bool, bool) Padding => (EffectiveDuplex, EffectiveDuplex && copies > 1);

    private void RefreshPrinterInfo()
    {
        var name = printer;
        if (string.IsNullOrEmpty(name)) { HardwareMarginMM = null; return; }
        // 드라이버 조회는 느릴 수 있어 백그라운드 STA 스레드에서 한다(System.Printing).
        PrinterInfoLoaded = false;
        _ = Sta.Run(() =>
        {
            double? hw = Printing.HardwareMarginMM(name);
            bool dup = true;
            string? err = null;
            try { dup = Printing.Plan(new PrintSettings(name)).CanDuplex; } catch (Exception ex) { err = ex.Message; }
            return (hw, dup, err);
        }).ContinueWith(t =>
        {
            if (name != printer) return;
            if (t.IsFaulted) { PrinterInfoError = t.Exception?.GetBaseException().Message; }
            else
            {
                HardwareMarginMM = t.Result.hw;
                CanDuplex = t.Result.dup;
                PrinterInfoError = t.Result.err;
            }
            PrinterInfoLoaded = true;
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// <summary>목록 줄의 쪽수·배율·꼬리표를 지금 결과에 맞춘다.</summary>
    private void RefreshFileRows()
    {
        foreach (var f in Files)
        {
            var s = Sections.FirstOrDefault(x => x.File == f.File);
            f.Detail = s != null ? $"{s.PageIndices.Count}쪽 · {Math.Round(s.Scale * 100)}%" : $"{f.File.PageCount}쪽";
            f.PadsBlank = s?.PadsBlankPage == true;
            f.ElectiveText = f.File.ElectiveSubject is { } sub && options.Electives.TryGetValue(sub, out var e) ? e.ShortName() : null;
            f.Adjusted = !options.Adjustment(f.File.Path).IsDefault;
        }
    }

    public async void Rebuild()
    {
        int gen = ++generation;
        var files = Files.Select(f => f.File).ToList();
        var opts = options with { PadSectionsToEven = EffectiveDuplex, PadEndToEven = EffectiveDuplex && copies > 1 };
        IsWorking = true;
        await renderGate.WaitAsync();
        try
        {
            if (gen != generation) return; // 기다리는 사이 더 새 요청이 들어왔다
            ImpositionResult? result = null;
            string? failure = null;
            if (files.Count > 0)
            {
                try { result = await Task.Run(() => Imposer.Impose(files, opts)); }
                catch (Exception ex) { failure = ex.Message; }
            }
            if (gen != generation) return; // 더 최신 요청이 있으면 버린다
            var oldDoc = PreviewDoc;
            Sections = result?.Sections ?? [];
            OutputPdf = result?.Pdf;
            OutputPageCount = result?.PageCount ?? 0;
            PreviewDoc = result != null ? PdfDoc.FromBytes(result.Pdf) : null;
            IsWorking = false;
            if (failure != null) Error = "A4로 바꾸지 못했어요: " + failure;
            RefreshFileRows();
            Raise(nameof(SheetCount));
            Raise(nameof(DisplayScale));
            Raise(nameof(CanPrint));
            OutputChanged?.Invoke();
            oldDoc?.Dispose();
            // 목록에서 뺀 파일은 그 파일을 쓰던 변환이 끝난 뒤에 닫는다.
            foreach (var f in pendingDispose) if (!Files.Any(x => x.File == f)) f.Dispose();
            pendingDispose.Clear();
        }
        finally
        {
            renderGate.Release();
        }
    }

    /// <summary>불러오기와 변환이 모두 끝날 때까지 기다린다(자동 점검용).</summary>
    public async Task WaitIdleAsync(int timeoutMs = 60000)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while ((LoadingCount > 0 || IsWorking) && sw.ElapsedMilliseconds < timeoutMs) await Task.Delay(50);
    }

    // MARK: 출력

    public string JobTitle => string.Join(", ", Files.Select(f => f.Name));
    public bool CanPrint => OutputPdf != null && !IsWorking && !IsPrinting && !string.IsNullOrEmpty(printer);

    public PrintSettings CurrentPrintSettings => new(printer) { Copies = copies, Duplex = duplex, Grayscale = grayscale };

    public async void PrintNow()
    {
        if (OutputPdf is not { } pdf || IsPrinting) return;
        var s = CurrentPrintSettings;
        var title = JobTitle;
        IsPrinting = true;
        Status = null;
        try
        {
            await Sta.Run(() => Printing.Print(pdf, s, title));
            Status = $"인쇄를 보냈어요. {s.Printer}";
        }
        catch (Exception ex)
        {
            Error = "인쇄하지 못했어요: " + ex.Message;
        }
        finally
        {
            IsPrinting = false;
        }
    }

    public string SuggestedFileName => (Files.Count == 1 ? Files[0].Name : "모의고사") + "_A4.pdf";

    public void SavePdf(string path)
    {
        if (OutputPdf == null) return;
        try
        {
            File.WriteAllBytes(path, OutputPdf);
            Status = "저장했어요: " + System.IO.Path.GetFileName(path);
        }
        catch (Exception ex)
        {
            Error = ex.Message;
        }
    }
}

/// <summary>STA 스레드에서 일을 돌린다. System.Printing(PrintTicket)과 GDI 인쇄를 화면 스레드 밖에서 하려고.</summary>
public static class Sta
{
    public static Task<T> Run<T>(Func<T> work)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var t = new Thread(() =>
        {
            try { tcs.SetResult(work()); }
            catch (Exception ex) { tcs.SetException(ex); }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        return tcs.Task;
    }
}
