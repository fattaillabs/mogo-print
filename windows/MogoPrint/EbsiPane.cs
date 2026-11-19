using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Mogo.Core;

namespace MogoPrint;

/// <summary>앱 안 EBSi 로그인 상태(쿠키 헤더). 로그인 창에서 로그인이 확인되면 채운다. 앱을 닫으면 사라진다.</summary>
public static class EbsiSession
{
    public static string Cookies { get; set; } = "";

    /// <summary>로그인 창의 웹 화면 저장소(로그인 유지가 되면 다음에 바로 로그인된 상태로 열린다)</summary>
    public static string UserDataFolder => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MogoPrint", "WebView2");
}

/// <summary>
/// '기출 받기' 창의 교육청 학력평가 탭(맥 버전 EBSiDownloadPane과 같은 흐름).
/// 문제지는 EBSi에서만 제공되므로 사용자가 앱 안 로그인 창에서 EBSi에 로그인한 상태(쿠키)로 목록을 읽어 받는다.
/// 로그인이 확인되기 전에는 목록을 부르지 않는다.
/// </summary>
public sealed class EbsiPane : UserControl
{
    private readonly AppModel model;
    private readonly Action<bool> finish;
    private readonly Action cancel;

    private int grade = 3;
    private EbsiArchive.PageInfo? info;
    private int? year;
    private List<(int Month, string Exam)> months = [];
    private int? month;
    private List<EbsiArchive.Paper> papers = [];
    private HashSet<string> checkedIds = [];
    private bool includeExplanations;
    private bool busy;
    private int loadVersion;

    private readonly StackPanel choosers = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
    private readonly ComboBox yearBox = new() { Width = 110, Margin = new Thickness(12, 0, 0, 0) };
    private readonly ComboBox examBox = new() { Width = 170, Margin = new Thickness(12, 0, 0, 0) };
    private readonly Grid listArea = new() { Height = 340 };
    private readonly TextBlock progressText = new() { VerticalAlignment = VerticalAlignment.Center, Foreground = Theme.Secondary };
    private readonly Button downloadButton;
    private bool filling;

    /// <summary>자동 점검(README 그림)용 예시 목록. 있으면 EBSi에 접속하지 않고 이것을 보여 준다.</summary>
    public static (string Page, string Rows)? Demo { get; set; }
    /// <summary>자동 점검용: 목록을 다 불러왔는지</summary>
    public bool Ready { get; private set; }

    public EbsiPane(AppModel model, Action<bool> finish, Action cancel)
    {
        this.model = model;
        this.finish = finish;
        this.cancel = cancel;

        var gradeSeg = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var g in new[] { 1, 2, 3 })
        {
            var rb = new RadioButton { Content = $"고{g}", GroupName = "ebsiGrade", IsChecked = g == grade };
            rb.SetResourceReference(StyleProperty, "Segment");
            int gg = g;
            rb.Checked += async (_, _) => { if (grade != gg) { grade = gg; year = null; month = null; await StartAsync(); } };
            gradeSeg.Children.Add(rb);
        }
        var gradeBox = new Border { Child = gradeSeg, HorizontalAlignment = HorizontalAlignment.Left };
        gradeBox.SetResourceReference(StyleProperty, "SegmentBox");
        choosers.Children.Add(gradeBox);
        choosers.Children.Add(yearBox);
        choosers.Children.Add(examBox);
        yearBox.SelectionChanged += async (_, _) =>
        {
            if (filling || yearBox.SelectedItem is not ComboBoxItem { Tag: int y } || y == year) return;
            year = y; month = null;
            await LoadMonthsAsync();
        };
        examBox.SelectionChanged += async (_, _) =>
        {
            if (filling || examBox.SelectedItem is not ComboBoxItem { Tag: int m } || m == month) return;
            month = m;
            await LoadPapersAsync();
        };

        var border = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Child = listArea };
        border.SetResourceReference(Border.BorderBrushProperty, "ControlStrokeColorDefaultBrush");
        border.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");

        var explain = new CheckBox { Content = "해설지도 받기", Margin = new Thickness(0, 12, 0, 6) };
        explain.Checked += (_, _) => includeExplanations = true;
        explain.Unchecked += (_, _) => includeExplanations = false;

        downloadButton = new Button { Content = "받기", Padding = new Thickness(18, 6, 18, 6), Margin = new Thickness(8, 0, 0, 0), IsDefault = true };
        downloadButton.SetResourceReference(StyleProperty, "AccentButtonStyle");
        downloadButton.Click += async (_, _) => await DownloadAsync();
        var cancelButton = new Button { Content = "취소", Padding = new Thickness(16, 6, 16, 6), Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        cancelButton.Click += (_, _) => cancel();

        var bottom = new DockPanel { Margin = new Thickness(0, 16, 0, 0), LastChildFill = false };
        DockPanel.SetDock(progressText, Dock.Left);
        bottom.Children.Add(progressText);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(cancelButton);
        buttons.Children.Add(downloadButton);
        DockPanel.SetDock(buttons, Dock.Right);
        bottom.Children.Add(buttons);

        Content = new StackPanel
        {
            Children =
            {
                choosers, border, explain,
                new TextBlock
                {
                    Text = "EBSi 기출문제에서 받아 다운로드 폴더의 '모고 프린트' 폴더에 저장해요. 문제지 저작권은 시·도교육청에 있어요.",
                    FontSize = 12, Foreground = Theme.Secondary, TextWrapping = TextWrapping.Wrap,
                },
                bottom,
            },
        };
        UpdateButtons();
    }

    private void UpdateButtons() => downloadButton.IsEnabled = checkedIds.Count > 0 && !busy && papers.Count > 0;

    private void Message(string text, UIElement? extra = null)
    {
        listArea.Children.Clear();
        var p = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        p.Children.Add(new TextBlock { Text = text, Foreground = Theme.Secondary, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 440 });
        if (extra != null) p.Children.Add(extra);
        listArea.Children.Add(p);
    }

    private void ShowLoginPrompt()
    {
        choosers.Visibility = Visibility.Collapsed;
        var login = new Button { Content = "EBSi 로그인…", Padding = new Thickness(16, 7, 16, 7), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 10) };
        login.Click += async (_, _) =>
        {
            var w = new EbsiLoginWindow { Owner = Window.GetWindow(this) };
            w.ShowDialog();
            await StartAsync();
        };
        var stack = new StackPanel();
        stack.Children.Add(login);
        stack.Children.Add(new TextBlock
        {
            Text = "아이디와 비밀번호는 EBSi 화면에 직접 넣고, 모고 프린트는 저장하지 않아요.", FontSize = 12,
            Foreground = Theme.Tertiary, HorizontalAlignment = HorizontalAlignment.Center,
        });
        Message("교육청 학력평가 문제지는 EBSi에서만 제공돼요.\nEBSi에 로그인하면 여기서 바로 받을 수 있어요.", stack);
    }

    // MARK: 불러오기

    /// <summary>로그인 여부와 연도·영역을 읽고, 그 학년·연도에 학평이 있었던 달을 찾는다.</summary>
    public async Task StartAsync()
    {
        int v = ++loadVersion;
        Ready = false;
        papers = [];
        UpdateButtons();
        Message("EBSi에서 목록을 불러오는 중…");
        try
        {
            info = Demo is { } demo ? EbsiArchive.ParsePage(demo.Page) : await EbsiArchive.PageInfoAsync(grade, EbsiSession.Cookies);
            if (v != loadVersion) return;
            if (!info.LoggedIn) { ShowLoginPrompt(); Ready = true; return; }
            choosers.Visibility = Visibility.Visible;
            if (year == null || !info.Years.Contains(year.Value)) year = info.Years.FirstOrDefault();
            Fill(yearBox, info.Years.Select(y => ($"{y}년", y)), year);
            await LoadMonthsAsync();
        }
        catch (Exception ex)
        {
            if (v != loadVersion) return;
            Message("EBSi에 연결하지 못했어요.\n" + ex.Message);
            Ready = true;
        }
    }

    private void Fill(ComboBox box, IEnumerable<(string Text, int Tag)> items, int? selected)
    {
        filling = true;
        box.Items.Clear();
        foreach (var (text, tag) in items)
        {
            var it = new ComboBoxItem { Content = text, Tag = tag };
            box.Items.Add(it);
            if (tag == selected) box.SelectedItem = it;
        }
        filling = false;
    }

    private async Task LoadMonthsAsync()
    {
        if (info is not { LoggedIn: true } || year is not { } y) return;
        int v = ++loadVersion;
        Message("EBSi에서 목록을 불러오는 중…");
        try
        {
            months = Demo is { } demo
                ? EbsiArchive.EducationOfficeMonths(EbsiArchive.ParseRows(demo.Rows))
                : await EbsiArchive.MonthsAsync(grade, y, info, EbsiSession.Cookies);
            if (v != loadVersion) return;
            if (month == null || months.All(m => m.Month != month)) month = months.Count > 0 ? months[0].Month : null;
            Fill(examBox, months.Select(m => (m.Exam, m.Month)), month);
            if (months.Count == 0) { papers = []; Message("이 해에는 아직 올라온 학력평가가 없어요."); Ready = true; UpdateButtons(); return; }
            await LoadPapersAsync();
        }
        catch (EbsiArchive.NotLoggedInException) { EbsiSession.Cookies = ""; ShowLoginPrompt(); Ready = true; }
        catch (Exception ex) { if (v == loadVersion) { Message("목록을 불러오지 못했어요: " + ex.Message); Ready = true; } }
    }

    private async Task LoadPapersAsync()
    {
        if (info is not { LoggedIn: true } || year is not { } y || month is not { } m) return;
        int v = ++loadVersion;
        Message("EBSi에서 목록을 불러오는 중…");
        try
        {
            var found = Demo is { } demo
                ? EbsiArchive.ParseRows(demo.Rows).Where(p => p.Year == y && p.Month == m).ToList()
                : await EbsiArchive.PapersAsync(grade, y, m, info, EbsiSession.Cookies);
            if (v != loadVersion) return;
            papers = found;
            checkedIds = EbsiArchive.Preselect(found, model.Options.Electives);
            ShowPapers();
        }
        catch (EbsiArchive.NotLoggedInException) { EbsiSession.Cookies = ""; ShowLoginPrompt(); }
        catch (Exception ex) { if (v == loadVersion) Message("목록을 불러오지 못했어요: " + ex.Message); }
        Ready = true;
        UpdateButtons();
    }

    private void ShowPapers()
    {
        listArea.Children.Clear();
        if (papers.Count == 0) { Message("이 시험은 아직 올라온 문제지가 없어요."); return; }
        var list = new StackPanel { Margin = new Thickness(10, 4, 10, 8) };
        foreach (var area in papers.Select(p => p.Area).Distinct())
        {
            list.Children.Add(new TextBlock { Text = EbsiArchive.AreaName(area), FontWeight = FontWeights.SemiBold, Foreground = Theme.Secondary, Margin = new Thickness(0, 8, 0, 2) });
            foreach (var p in papers.Where(p => p.Area == area))
            {
                var id = p.Id;
                var c = new CheckBox
                {
                    Content = p.Variant is { } vv ? $"{p.Subject} {vv.Korean()}" : p.Subject,
                    IsChecked = checkedIds.Contains(id), Margin = new Thickness(0, 2, 0, 2),
                };
                c.Checked += (_, _) => { checkedIds.Add(id); UpdateButtons(); };
                c.Unchecked += (_, _) => { checkedIds.Remove(id); UpdateButtons(); };
                list.Children.Add(c);
            }
        }
        listArea.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
    }

    private async Task DownloadAsync()
    {
        var chosen = papers.Where(p => checkedIds.Contains(p.Id)).ToList();
        if (chosen.Count == 0 || busy) return;
        busy = true;
        UpdateButtons();
        var dir = EbsiArchive.Folder(chosen[0], KiceArchive.DefaultBaseDir);
        var saved = new List<string>();
        try
        {
            foreach (var p in chosen)
            {
                progressText.Text = $"{p.Subject} 받는 중…";
                if (await EbsiArchive.SaveAsync(p, false, dir) is { } a) saved.Add(a);
                if (includeExplanations && await EbsiArchive.SaveAsync(p, true, dir) is { } b) saved.Add(b);
            }
        }
        catch (Exception ex)
        {
            progressText.Text = "";
            busy = false;
            UpdateButtons();
            Message("받지 못했어요: " + ex.Message);
            return;
        }
        progressText.Text = "";
        busy = false;
        _ = model.AddAsync(saved, keepOrder: true);
        finish(true);
    }
}

/// <summary>EBSi 로그인 창(WebView2). 사용자가 EBSi 화면에 직접 로그인하고, 기출문제 페이지로 돌아와 로그인이 확인되면 닫힌다.</summary>
public sealed class EbsiLoginWindow : DialogBase
{
    private readonly WebView2 web = new();
    private bool done;

    /// <summary>자동 점검용: 알림 창 없이 결과만 남긴다.</summary>
    public bool Quiet { get; init; }
    public string? LoadedUrl { get; private set; }
    public string? LoadedTitle { get; private set; }
    public string? StartError { get; private set; }

    public EbsiLoginWindow() : base("EBSi 로그인", 640)
    {
        SizeToContent = SizeToContent.Manual;
        Height = 760;
        ResizeMode = ResizeMode.CanResize;
        var top = new DockPanel { Margin = new Thickness(14, 10, 14, 10), LastChildFill = false };
        var close = new Button { Content = "닫기", Padding = new Thickness(14, 5, 14, 5), IsCancel = true };
        close.Click += (_, _) => Close();
        DockPanel.SetDock(close, Dock.Right);
        top.Children.Add(close);
        top.Children.Add(new TextBlock { Text = "아이디와 비밀번호는 모고 프린트가 저장하지 않아요", FontSize = 12, Foreground = Theme.Secondary, VerticalAlignment = VerticalAlignment.Center });
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        root.Children.Add(web);
        Content = Surface(root);
        Loaded += async (_, _) => await StartAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            var env = await CoreWebView2Environment.CreateAsync(null, EbsiSession.UserDataFolder);
            await web.EnsureCoreWebView2Async(env);
        }
        catch (WebView2RuntimeNotFoundException ex)
        {
            StartError = ex.Message;
            if (Quiet) return;
            MessageBox.Show(this, "EBSi 로그인 화면을 열려면 Microsoft Edge WebView2 런타임이 필요해요.\nWindows 업데이트를 하거나 Microsoft 사이트에서 설치해 주세요.",
                "확인해 주세요", MessageBoxButton.OK, MessageBoxImage.Warning);
            Close();
            return;
        }
        // 새 창으로 열리는 링크(간편 로그인 등)는 같은 화면에서 연다.
        web.CoreWebView2.NewWindowRequested += (_, e) => { e.Handled = true; web.CoreWebView2.Navigate(e.Uri); };
        web.CoreWebView2.NavigationCompleted += async (_, _) =>
        {
            LoadedUrl = web.CoreWebView2.Source;
            LoadedTitle = web.CoreWebView2.DocumentTitle;
            await CheckLoggedInAsync();
        };
        web.CoreWebView2.Navigate(EbsiArchive.LoginUrl);
    }

    /// <summary>기출문제 페이지로 돌아왔을 때 그 페이지의 로그인 표시(loginTF)를 확인하고 쿠키를 가져온다.</summary>
    private async Task CheckLoggedInAsync()
    {
        if (done || !web.CoreWebView2.Source.Contains("previousPaperList", StringComparison.OrdinalIgnoreCase)) return;
        var result = await web.CoreWebView2.ExecuteScriptAsync("typeof loginTF !== 'undefined' ? loginTF : ''");
        if (JsonSerializer.Deserialize<string>(result) != "true") return;
        done = true;
        var cookies = await web.CoreWebView2.CookieManager.GetCookiesAsync(EbsiArchive.SiteUrl);
        EbsiSession.Cookies = string.Join("; ", cookies.Select(c => $"{c.Name}={c.Value}"));
        Close();
    }
}
