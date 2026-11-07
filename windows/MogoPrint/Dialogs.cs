using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Mogo.Core;

namespace MogoPrint;

/// <summary>대화상자 공통 모양.</summary>
public abstract class DialogBase : Window
{
    protected DialogBase(string title, double width)
    {
        Title = title;
        Width = width;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI, Malgun Gothic");
        FontSize = 14;
    }

    /// <summary>창 바탕(캡처해도 비치지 않게 단색).</summary>
    protected Grid Surface(UIElement content)
    {
        var g = new Grid();
        g.SetResourceReference(Panel.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        g.Children.Add(content);
        return g;
    }

    protected static TextBlock Heading(string text) => new() { Text = text, FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 14) };

    protected static TextBlock Caption(string text) => new()
    {
        Text = text, FontSize = 12, Foreground = Theme.Secondary, TextWrapping = TextWrapping.Wrap,
    };

    protected static Button Accent(string text)
    {
        var b = new Button { Content = text, Padding = new Thickness(18, 6, 18, 6), Margin = new Thickness(8, 0, 0, 0), IsDefault = true };
        b.SetResourceReference(StyleProperty, "AccentButtonStyle");
        return b;
    }

    protected static Button Plain(string text, bool cancel = false) =>
        new() { Content = text, Padding = new Thickness(16, 6, 16, 6), Margin = new Thickness(8, 0, 0, 0), IsCancel = cancel };
}

/// <summary>인쇄 전에 프린터·분량·설정·형·파일 목록을 보여 주고 확인받는다.</summary>
public sealed class PrintConfirmWindow : DialogBase
{
    public PrintConfirmWindow(AppModel m) : base("인쇄 확인", 470)
    {
        var root = new StackPanel { Margin = new Thickness(24, 20, 24, 20) };
        root.Children.Add(Heading("이대로 인쇄할까요?"));

        var grid = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        void Row(string title, string value)
        {
            int r = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var t = new TextBlock { Text = title, Foreground = Theme.Secondary, Margin = new Thickness(0, 0, 18, 8) };
            var v = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
            Grid.SetRow(t, r); Grid.SetRow(v, r); Grid.SetColumn(v, 1);
            grid.Children.Add(t); grid.Children.Add(v);
        }
        Row("프린터", m.Printer);
        Row("분량", $"A4 {m.OutputPageCount}쪽 · 종이 {m.SheetCount}장 × {m.Copies}부");
        Row("설정", $"{(m.EffectiveDuplex ? "양면 (긴 쪽 넘김)" : "단면")} · {(m.Grayscale ? "흑백" : "컬러")} · 원본 대비 글자 크기 {m.DisplayScale}%");
        if (m.HasCombinedVariants) Row("시험지 형", m.Options.Variant.Korean());
        var electives = m.ElectiveRows;
        if (electives.Count > 0)
            Row("선택과목", string.Join(" · ", electives.Select(r =>
                $"{r.Subject.Korean()} {(m.Options.Electives.TryGetValue(r.Subject, out var e) ? e.ShortName() : "전체")}")));
        root.Children.Add(grid);

        void Warn(string text) => root.Children.Add(new TextBlock
        {
            Text = "⚠ " + text, Foreground = Theme.Caution, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10), FontSize = 13,
        });
        if (m.MarginTooSmall && m.HardwareMarginMM is { } hw)
            Warn($"종이 여백 {m.Options.PaperMarginMM:0}mm가 프린터 인쇄 범위({hw:0.0}mm)보다 좁아서 가장자리가 잘릴 수 있어요.");
        if (m.Duplex && !m.CanDuplex)
            Warn("이 프린터는 양면 인쇄를 지원하지 않아 단면으로 보내요.");

        // 파일이 많으면 창이 길어지지 않게 앞의 몇 개만 보여 준다.
        foreach (var s in m.Sections.Take(8))
            root.Children.Add(new TextBlock { Text = $"• {s.File.Name}  {s.PageIndices.Count}쪽", Foreground = Theme.Secondary, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis });
        if (m.Sections.Count > 8)
            root.Children.Add(new TextBlock { Text = $"  외 {m.Sections.Count - 8}개 파일", Foreground = Theme.Secondary, FontSize = 13 });

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        var cancel = Plain("취소", cancel: true);
        var ok = Accent("인쇄");
        ok.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        root.Children.Add(buttons);
        Content = Surface(root);
    }
}

/// <summary>
/// 평가원 수능 홈페이지에서 시험지를 받아 목록에 넣는 창.
/// 1단계: 시험·학년도·영역 고르기 → 받기. 2단계(고를 게 있을 때만): 받은 파일 중 목록에 넣을 것 고르기.
/// </summary>
public sealed class KiceWindow : DialogBase
{
    private readonly AppModel model;
    private KiceExam exam = KiceExam.Suneung;
    private List<int> years = [];
    private int? year;
    private List<KiceRow> rows = [];
    private readonly HashSet<string> checkedAreas = [];
    private bool includeAnswers;
    private bool autoStepped;
    private int loadVersion;
    private readonly ContentControl body = new();
    private readonly Grid listArea = new() { Height = 330 };
    private readonly ComboBox yearBox = new() { Width = 150, Margin = new Thickness(12, 0, 0, 0) };
    private readonly TextBlock progressText = new() { VerticalAlignment = VerticalAlignment.Center, Foreground = Theme.Secondary };
    private readonly Button downloadButton;
    private bool busy;

    /// <summary>받을 저장 위치(자동 점검에서 바꿀 수 있게).</summary>
    public string BaseDir { get; init; } = KiceArchive.DefaultBaseDir;
    /// <summary>자동 점검용: 목록을 다 불러왔는지.</summary>
    public bool Loaded2 { get; private set; }
    public IReadOnlyList<KiceRow> Rows => rows;

    private sealed record Downloaded(string Path, string Area, bool IsAnswer)
    {
        public string Name => System.IO.Path.GetFileNameWithoutExtension(Path);
    }

    public KiceWindow(AppModel model) : base("평가원 기출 받기", 560)
    {
        this.model = model;
        downloadButton = Accent("받기");
        downloadButton.Click += async (_, _) => await DownloadAsync();
        ShowChoose();
        Content = Surface(new StackPanel
        {
            Margin = new Thickness(22, 18, 22, 18),
            Children = { Heading("평가원 기출 받기"), body },
        });
        Loaded += async (_, _) => await LoadYearsAsync();
    }

    // MARK: 1단계

    private void ShowChoose()
    {
        var panel = new StackPanel();
        var top = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        var seg = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var e in KiceExamInfo.All)
        {
            var rb = new RadioButton { Content = e.ShortName(), GroupName = "exam", IsChecked = e == exam };
            rb.SetResourceReference(StyleProperty, "Segment");
            var ex = e;
            rb.Checked += async (_, _) => { exam = ex; await LoadYearsAsync(); };
            seg.Children.Add(rb);
        }
        var segBox = new Border { Child = seg, HorizontalAlignment = HorizontalAlignment.Left };
        segBox.SetResourceReference(StyleProperty, "SegmentBox");
        top.Children.Add(segBox);
        yearBox.SelectionChanged += async (_, _) =>
        {
            if (yearBox.SelectedItem is ComboBoxItem { Tag: int y } && y != year) { year = y; await LoadRowsAsync(); }
        };
        top.Children.Add(yearBox);
        panel.Children.Add(top);

        var border = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Child = listArea };
        border.SetResourceReference(Border.BorderBrushProperty, "ControlStrokeColorDefaultBrush");
        border.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
        panel.Children.Add(border);

        var answers = new CheckBox { Content = "정답표도 받기", Margin = new Thickness(0, 12, 0, 6), IsChecked = includeAnswers };
        answers.Checked += (_, _) => includeAnswers = true;
        answers.Unchecked += (_, _) => includeAnswers = false;
        panel.Children.Add(answers);
        panel.Children.Add(Caption("받은 파일은 다운로드 폴더의 '모고 프린트' 폴더에 저장돼요. 시험지 저작권은 한국교육과정평가원에 있어요."));

        var bottom = new DockPanel { Margin = new Thickness(0, 16, 0, 0), LastChildFill = false };
        DockPanel.SetDock(progressText, Dock.Left);
        bottom.Children.Add(progressText);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Plain("취소", cancel: true));
        buttons.Children.Add(downloadButton);
        DockPanel.SetDock(buttons, Dock.Right);
        bottom.Children.Add(buttons);
        panel.Children.Add(bottom);
        body.Content = panel;
        UpdateButtons();
    }

    private void SetListMessage(string text, Action? retry = null)
    {
        listArea.Children.Clear();
        var p = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        p.Children.Add(new TextBlock { Text = text, Foreground = Theme.Secondary, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 });
        if (retry != null)
        {
            var b = new Button { Content = "다시 시도", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
            b.Click += (_, _) => retry();
            p.Children.Add(b);
        }
        listArea.Children.Add(p);
    }

    private void ShowRows()
    {
        listArea.Children.Clear();
        var list = new StackPanel { Margin = new Thickness(10, 6, 10, 6) };
        foreach (var row in rows)
        {
            var area = row.Area;
            var content = new StackPanel();
            content.Children.Add(new TextBlock { Text = area });
            content.Children.Add(new TextBlock
            {
                Text = string.Join(", ", row.Papers.Select(a => a.Title)), FontSize = 12, Foreground = Theme.Secondary,
                TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 440,
            });
            var c = new CheckBox { Content = content, IsChecked = checkedAreas.Contains(area), Margin = new Thickness(0, 4, 0, 4) };
            c.Checked += (_, _) => { checkedAreas.Add(area); UpdateButtons(); };
            c.Unchecked += (_, _) => { checkedAreas.Remove(area); UpdateButtons(); };
            list.Children.Add(c);
        }
        listArea.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
    }

    private void UpdateButtons() => downloadButton.IsEnabled = checkedAreas.Count > 0 && !busy && Loaded2;

    private async Task LoadYearsAsync()
    {
        int v = ++loadVersion;
        Loaded2 = false;
        autoStepped = false;
        UpdateButtons();
        SetListMessage("평가원 홈페이지에서 목록을 불러오는 중…");
        try
        {
            var found = await KiceArchive.YearsAsync(exam);
            if (v != loadVersion) return;
            years = found;
            if (year == null || !years.Contains(year.Value)) year = years.FirstOrDefault();
            FillYears();
            await LoadRowsAsync();
        }
        catch
        {
            if (v != loadVersion) return;
            SetListMessage("평가원 홈페이지에 연결하지 못했어요.\n인터넷 연결을 확인한 뒤 다시 시도하세요.", () => _ = LoadYearsAsync());
        }
    }

    private bool fillingYears;

    private void FillYears()
    {
        fillingYears = true;
        yearBox.Items.Clear();
        foreach (var y in years)
        {
            var it = new ComboBoxItem { Content = $"{y}학년도", Tag = y };
            yearBox.Items.Add(it);
            if (y == year) yearBox.SelectedItem = it;
        }
        fillingYears = false;
    }

    private async Task LoadRowsAsync()
    {
        if (fillingYears || year is not { } y) return;
        int v = ++loadVersion;
        Loaded2 = false;
        UpdateButtons();
        SetListMessage("평가원 홈페이지에서 목록을 불러오는 중…");
        try
        {
            var found = await KiceArchive.RowsAsync(exam, y);
            if (v != loadVersion) return;
            // 최신 학년도에 아직 시험지가 없으면(예: 시험 전) 한 해 앞으로 옮긴다.
            if (found.Count == 0 && !autoStepped && years.Count > 1 && y == years[0])
            {
                autoStepped = true;
                year = years[1];
                FillYears();
                await LoadRowsAsync();
                return;
            }
            rows = found;
            checkedAreas.Clear();
            foreach (var a in found.Select(r => r.Area).Where(a => a is "국어" or "수학" or "영어" or "한국사")) checkedAreas.Add(a);
            if (rows.Count == 0) SetListMessage("이 시험은 아직 올라온 시험지가 없어요.");
            else ShowRows();
            Loaded2 = true;
            UpdateButtons();
        }
        catch (Exception ex)
        {
            if (v != loadVersion) return;
            rows = [];
            SetListMessage("목록을 불러오지 못했어요: " + ex.Message, () => _ = LoadRowsAsync());
        }
    }

    private async Task DownloadAsync()
    {
        if (year is not { } y || busy) return;
        busy = true;
        UpdateButtons();
        var dir = KiceArchive.Folder(exam, y, BaseDir);
        var got = new List<Downloaded>();
        var many = new HashSet<string>();
        try
        {
            foreach (var row in rows.Where(r => checkedAreas.Contains(r.Area)))
            {
                if (row.HasManySubjects) many.Add(row.Area);
                foreach (var a in row.Papers.Concat(includeAnswers ? row.Answers : []))
                {
                    progressText.Text = $"{row.Area} 받는 중…";
                    var saved = await KiceArchive.SaveAsync(a, exam, y, dir);
                    got.AddRange(saved.Select(p => new Downloaded(p, row.Area, a.Kind == KiceKind.Answer)));
                }
            }
        }
        catch (Exception ex)
        {
            progressText.Text = "";
            busy = false;
            UpdateButtons();
            SetListMessage("받지 못했어요: " + ex.Message, () => { ShowRows(); });
            return;
        }
        progressText.Text = "";
        busy = false;
        var defaults = KiceArchive.Preselect(got.Select(g => (g.Path, g.Area)), many, model.Options.Variant);
        if (defaults.Count == got.Count)
        {
            _ = model.AddAsync(got.Select(g => g.Path), keepOrder: true);
            DialogResult = true;
        }
        else ShowPick(got, defaults, dir);
    }

    // MARK: 2단계

    private void ShowPick(List<Downloaded> results, HashSet<string> picked, string dir)
    {
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = "목록에 넣을 파일을 고르세요", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 4) });
        panel.Children.Add(Caption("탐구는 응시할 과목만 고르면 돼요. 받은 파일은 모두 다운로드 폴더에 남아 있어요."));
        var list = new StackPanel { Margin = new Thickness(10, 6, 10, 6) };
        var add = Accent("목록에 추가");
        void Update() => add.IsEnabled = picked.Count > 0;
        foreach (var area in results.Select(r => r.Area).Distinct())
        {
            list.Children.Add(new TextBlock { Text = area, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 2), Foreground = Theme.Secondary });
            foreach (var r in results.Where(r => r.Area == area))
            {
                var path = r.Path;
                var c = new CheckBox
                {
                    Content = r.Name + (r.IsAnswer && !r.Name.Contains("정답") ? " (정답)" : ""),
                    IsChecked = picked.Contains(path), Margin = new Thickness(0, 2, 0, 2),
                };
                c.Checked += (_, _) => { picked.Add(path); Update(); };
                c.Unchecked += (_, _) => { picked.Remove(path); Update(); };
                list.Children.Add(c);
            }
        }
        var border = new Border
        {
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Height = 360, Margin = new Thickness(0, 10, 0, 0),
            Child = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
        border.SetResourceReference(Border.BorderBrushProperty, "ControlStrokeColorDefaultBrush");
        border.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
        panel.Children.Add(border);

        var bottom = new DockPanel { Margin = new Thickness(0, 16, 0, 0), LastChildFill = false };
        var show = new Button { Content = "탐색기에서 보기", Padding = new Thickness(12, 6, 12, 6) };
        show.Click += (_, _) => { try { Process.Start("explorer.exe", $"\"{dir}\""); } catch { } };
        DockPanel.SetDock(show, Dock.Left);
        bottom.Children.Add(show);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Plain("취소", cancel: true));
        add.Click += (_, _) =>
        {
            _ = model.AddAsync(results.Where(r => picked.Contains(r.Path)).Select(r => r.Path), keepOrder: true);
            DialogResult = true;
        };
        buttons.Children.Add(add);
        DockPanel.SetDock(buttons, Dock.Right);
        bottom.Children.Add(buttons);
        panel.Children.Add(bottom);
        body.Content = panel;
        Update();
    }
}
