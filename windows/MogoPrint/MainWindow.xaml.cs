using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Microsoft.Win32;
using Mogo.Core;

namespace MogoPrint;

public partial class MainWindow : Window
{
    public AppModel Model { get; }
    public ObservableCollection<PreviewPage> PreviewPages { get; } = new();
    /// <summary>자동 점검 중 나온 오류 문구(대화상자 대신 기록).</summary>
    public List<string> SnapshotErrors { get; } = [];
    public ManualCropView? ManualView => ManualHost.Content as ManualCropView;

    private const double A4Ratio = 841.89 / 595.28;
    private const double PageGap = 14;
    private ScrollViewer? pageScroll;
    private int currentPage;
    private int previewVersion;
    private bool syncingThumbs;
    private Point dragStart;
    private FileItem? dragItem;
    private int settingsBuild;

    public MainWindow(AppModel model)
    {
        Model = model;
        InitializeComponent();
        FileList.ItemsSource = model.Files;
        Pages.ItemsSource = PreviewPages;
        Thumbs.ItemsSource = PreviewPages;

        model.PropertyChanged += Model_PropertyChanged;
        model.Files.CollectionChanged += (_, _) => { BuildSettings(); UpdateChrome(); };
        model.OutputChanged += RefreshPreview;

        DragEnter += Window_DragOver;
        DragOver += Window_DragOver;
        DragLeave += (_, _) => SetDropHighlight(false);
        Drop += Window_Drop;

        InputBindings.Add(new KeyBinding(new Command(() => Open_Click(this, new RoutedEventArgs())), Key.O, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Command(() => Kice_Click(this, new RoutedEventArgs())), Key.O, ModifierKeys.Control | ModifierKeys.Shift));
        InputBindings.Add(new KeyBinding(new Command(() => { if (Model.CanPrint) Print_Click(this, new RoutedEventArgs()); }), Key.P, ModifierKeys.Control));

        Loaded += (_, _) =>
        {
            Pages.ApplyTemplate();
            pageScroll = Pages.Template.FindName("PART_Scroll", Pages) as ScrollViewer;
            if (pageScroll != null) pageScroll.ScrollChanged += (_, _) => UpdateCurrentPage();
        };
        BuildSettings();
        UpdateChrome();
    }

    private void Model_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppModel.Options):
            case nameof(AppModel.HardwareMarginMM):
            case nameof(AppModel.CanDuplex):
            case nameof(AppModel.Copies):
            case nameof(AppModel.Duplex):
            case nameof(AppModel.Printer):
            case nameof(AppModel.ElectiveRows):
            case nameof(AppModel.HasCombinedVariants):
                BuildSettings();
                break;
            case nameof(AppModel.ManualCrop):
                ShowManualCrop();
                break;
            case nameof(AppModel.Error):
                if (Model.Error is { } msg) Dispatcher.BeginInvoke(() => ShowError(msg));
                break;
        }
        UpdateChrome();
    }

    private void ShowError(string msg)
    {
        if (Model.Error == null) return;
        Model.Error = null;
        if (Model.SnapshotMode) { SnapshotErrors.Add(msg); return; }
        MessageBox.Show(this, msg, "확인해 주세요", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    // MARK: 화면 갱신

    private void UpdateChrome()
    {
        bool empty = Model.Files.Count == 0 && Model.LoadingCount == 0;
        DropZone.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        MainArea.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        LoadingRow.Visibility = Model.LoadingCount > 0 ? Visibility.Visible : Visibility.Collapsed;

        SummaryText.Text = Model.OutputPageCount > 0
            ? $"A4 {Model.OutputPageCount}쪽 · 종이 {Model.SheetCount}장 · 원본 대비 글자 크기 {Model.DisplayScale}%"
            : "";
        WorkingBar.Visibility = Model.IsWorking ? Visibility.Visible : Visibility.Collapsed;
        CropButton.IsEnabled = Model.Sections.Count > 0;
        SaveButton.IsEnabled = Model.OutputPdf != null;
        PrintButton.IsEnabled = Model.CanPrint;
        PrintButtonText.Text = Model.IsPrinting ? "보내는 중…" : "인쇄…";
        PrintingBar.Visibility = Model.IsPrinting ? Visibility.Visible : Visibility.Collapsed;
        StatusRow.Visibility = Model.Status != null ? Visibility.Visible : Visibility.Collapsed;
        StatusText.Text = Model.Status ?? "";
        UpdatePageIndicator();
    }

    private void UpdatePageIndicator()
    {
        if (Model.ManualCrop != null)
            PageIndicator.Text = "점선을 끌어서 자를 위치를 정하세요. 같은 위치가 이 파일의 모든 쪽에 적용돼요.";
        else if (Model.OutputPageCount > 0)
        {
            int n = Math.Min(currentPage, Model.OutputPageCount - 1);
            PageIndicator.Text = $"{n + 1} / {Model.OutputPageCount}쪽 · {Model.SourcePosition(n)?.item.Name ?? "빈 쪽"}";
        }
        else PageIndicator.Text = "";
    }

    // MARK: 설정 칸 (맥의 Form과 같은 줄들)

    private void BuildSettings()
    {
        settingsBuild++;
        var panel = SettingsPanel;
        panel.Children.Clear();
        void AddRow(string title, UIElement? control, string? note = null)
        {
            if (panel.Children.Count > 0)
                panel.Children.Add(new Rectangle { Height = 1, Margin = new Thickness(12, 0, 12, 0), Fill = (Brush)FindResource("DividerStrokeColorDefaultBrush") });
            var g = new Grid { Style = (Style)FindResource("SettingRow") };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var label = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 6, 10, 6) };
            label.Children.Add(new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis });
            if (note != null) label.Children.Add(new TextBlock { Text = note, Style = (Style)FindResource("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
            g.Children.Add(label);
            if (control is FrameworkElement fe)
            {
                fe.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(fe, 1);
                g.Children.Add(fe);
            }
            panel.Children.Add(g);
        }

        if (Model.HasCombinedVariants)
        {
            var variants = new[] { ExamVariant.Odd, ExamVariant.Even, ExamVariant.All };
            AddRow("시험지 형", Segmented(variants.Select(v => v.Korean()).ToArray(), Array.IndexOf(variants, Model.Options.Variant),
                i => Model.Options = Model.Options with { Variant = variants[i] }));
        }
        foreach (var row in Model.ElectiveRows)
        {
            var subject = row.Subject;
            AddRow(row.Title, Segmented(row.Labels, Model.ElectiveIndex(subject), i => Model.SetElective(subject, i)));
        }
        AddRow($"종이 여백 {Model.Options.PaperMarginMM:0}mm", Stepper(
            () => Model.Options = Model.Options with { PaperMarginMM = Math.Max(3, Model.Options.PaperMarginMM - 1) },
            () => Model.Options = Model.Options with { PaperMarginMM = Math.Min(15, Model.Options.PaperMarginMM + 1) },
            Model.Options.PaperMarginMM > 3, Model.Options.PaperMarginMM < 15),
            Model.MarginTooSmall && Model.HardwareMarginMM is { } hw ? $"⚠ 이 프린터는 가장자리 {hw:0.0}mm 안쪽만 찍혀요. 여백을 늘려 주세요." : null);

        if (Model.Printers.Count == 0)
            AddRow("프린터", new TextBlock { Text = "설치된 프린터가 없어요", Style = (Style)FindResource("Secondary") });
        else
        {
            var box = new ComboBox { ItemsSource = Model.Printers, SelectedItem = Model.Printer, MinWidth = 150, MaxWidth = 190 };
            box.SelectionChanged += (_, _) => { if (box.SelectedItem is string p) Model.Printer = p; };
            AddRow("프린터", box);
        }
        AddRow("양면 인쇄 (긴 쪽 넘김)", Toggle(Model.Duplex && Model.CanDuplex, v => Model.Duplex = v, Model.CanDuplex),
               Model.CanDuplex ? null : "이 프린터는 양면 인쇄를 지원하지 않아요");
        AddRow("흑백", Toggle(Model.Grayscale, v => Model.Grayscale = v, true));
        AddRow($"부수 {Model.Copies}", Stepper(() => Model.Copies--, () => Model.Copies++, Model.Copies > 1, Model.Copies < 50));
    }

    private FrameworkElement Segmented(string[] labels, int selected, Action<int> onSelect)
    {
        var group = $"seg{settingsBuild}-{Guid.NewGuid():N}";
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        for (int i = 0; i < labels.Length; i++)
        {
            var rb = new RadioButton { Content = labels[i], GroupName = group, Style = (Style)FindResource("Segment"), IsChecked = i == selected };
            int k = i;
            rb.Checked += (_, _) => onSelect(k);
            row.Children.Add(rb);
        }
        return new Border { Style = (Style)FindResource("SegmentBox"), Child = row };
    }

    private static FrameworkElement Stepper(Action down, Action up, bool canDown, bool canUp)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        Button B(string glyph, Action a, bool enabled, string tip)
        {
            var b = new Button { Content = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 11,
                                 Width = 34, Padding = new Thickness(0, 6, 0, 6), IsEnabled = enabled, ToolTip = tip, Margin = new Thickness(4, 0, 0, 0) };
            b.Click += (_, _) => a();
            return b;
        }
        row.Children.Add(B("", down, canDown, "줄이기"));
        row.Children.Add(B("", up, canUp, "늘리기"));
        return row;
    }

    private static FrameworkElement Toggle(bool value, Action<bool> set, bool enabled)
    {
        var c = new CheckBox { IsChecked = value, IsEnabled = enabled, MinWidth = 0, Padding = new Thickness(0) };
        c.Checked += (_, _) => set(true);
        c.Unchecked += (_, _) => set(false);
        return c;
    }

    // MARK: 미리보기

    private double PageWidth => Math.Clamp((Pages.ActualWidth > 0 ? Pages.ActualWidth : 800) - 56, 260, 1000);

    private void RefreshPreview()
    {
        previewVersion++;
        int keep = currentPage;
        double w = PageWidth, h = w * A4Ratio;
        PreviewPages.Clear();
        for (int i = 0; i < Model.OutputPageCount; i++) PreviewPages.Add(new PreviewPage(i) { Width = w, Height = h });
        currentPage = Math.Min(keep, Math.Max(0, Model.OutputPageCount - 1));
        Dispatcher.BeginInvoke(() => ScrollToPage(currentPage), System.Windows.Threading.DispatcherPriority.Loaded);
        UpdateChrome();
    }

    private void Pages_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        double w = PageWidth, h = w * A4Ratio;
        int keep = currentPage;
        foreach (var p in PreviewPages) { p.Width = w; p.Height = h; }
        foreach (var p in PreviewPages.Where(p => p.Image != null)) _ = EnsureImage(p);
        Dispatcher.BeginInvoke(() => ScrollToPage(keep), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    private double Dpi => VisualTreeHelper.GetDpi(this).DpiScaleX;

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is PreviewPage p) _ = EnsureImage(p);
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        // 화면 밖으로 나간 큰 그림은 버린다(쪽이 많을 때 메모리).
        if ((sender as FrameworkElement)?.DataContext is PreviewPage p) { p.Image = null; p.ImagePixelWidth = 0; }
    }

    private void Thumb_Loaded(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is PreviewPage p && p.Thumb == null) _ = EnsureThumb(p);
    }

    /// <summary>쪽 그림을 지금 크기에 맞게 그린다(이미 충분히 크면 그대로).</summary>
    public async Task EnsureImage(PreviewPage p)
    {
        int target = (int)Math.Ceiling(p.Width * Dpi);
        if ((p.Image != null && p.ImagePixelWidth >= target * 0.9) || p.Rendering) return;
        var doc = Model.PreviewDoc;
        if (doc == null || p.Index >= doc.PageCount) return;
        int version = previewVersion;
        p.Rendering = true;
        try
        {
            var bmp = await PageRenderer.RenderAsync(doc, p.Index, target);
            if (version != previewVersion) return;
            p.Image = bmp;
            p.ImagePixelWidth = target;
        }
        finally { p.Rendering = false; }
    }

    private async Task EnsureThumb(PreviewPage p)
    {
        var doc = Model.PreviewDoc;
        if (doc == null || p.Index >= doc.PageCount) return;
        int version = previewVersion;
        var bmp = await PageRenderer.RenderAsync(doc, p.Index, (int)(80 * Dpi));
        if (version == previewVersion) p.Thumb = bmp;
    }

    private double ItemHeight => (PreviewPages.FirstOrDefault()?.Height ?? PageWidth * A4Ratio) + PageGap;

    private void UpdateCurrentPage()
    {
        if (pageScroll == null || PreviewPages.Count == 0) return;
        int idx = Math.Clamp((int)((pageScroll.VerticalOffset + pageScroll.ViewportHeight * 0.3) / ItemHeight), 0, PreviewPages.Count - 1);
        if (idx == currentPage && Thumbs.SelectedIndex == idx) return;
        currentPage = idx;
        syncingThumbs = true;
        Thumbs.SelectedIndex = idx;
        Thumbs.ScrollIntoView(PreviewPages[idx]);
        syncingThumbs = false;
        UpdatePageIndicator();
    }

    private void ScrollToPage(int index)
    {
        if (pageScroll == null || PreviewPages.Count == 0) return;
        pageScroll.ScrollToVerticalOffset(Math.Max(0, index) * ItemHeight);
        currentPage = index;
        UpdatePageIndicator();
    }

    private void Thumbs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!syncingThumbs && Thumbs.SelectedIndex >= 0) ScrollToPage(Thumbs.SelectedIndex);
    }

    // MARK: 여백 수동 조정

    private void ShowManualCrop()
    {
        if (Model.ManualCrop is { } item)
        {
            ManualHost.Content = new ManualCropView(Model, item, Model.ManualCropStartPosition);
            ManualHost.Visibility = Visibility.Visible;
            PreviewGrid.Visibility = Visibility.Hidden;
        }
        else
        {
            (ManualHost.Content as ManualCropView)?.Detach();
            ManualHost.Content = null;
            ManualHost.Visibility = Visibility.Collapsed;
            PreviewGrid.Visibility = Visibility.Visible;
        }
        UpdatePageIndicator();
    }

    private void Crop_Click(object sender, RoutedEventArgs e)
    {
        if (Model.ManualCrop == null) Model.StartManualCrop(outputPage: currentPage);
        else Model.ManualCrop = null;
    }

    private void FileCrop_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not FileItem item) return;
        if (Model.ManualCrop == item) Model.ManualCrop = null;
        else Model.StartManualCrop(item);
    }

    private void FileRemove_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is FileItem item) Model.Remove(item);
    }

    // MARK: 버튼

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title = "모의고사 PDF 파일을 고르세요 (폴더는 창에 끌어다 놓으면 돼요)",
            Filter = "PDF 파일 (*.pdf)|*.pdf",
            Multiselect = true,
        };
        if (dlg.ShowDialog(this) == true) _ = Model.AddAsync(dlg.FileNames);
    }

    private void Kice_Click(object sender, RoutedEventArgs e) => new KiceWindow(Model) { Owner = this }.ShowDialog();

    private void Clear_Click(object sender, RoutedEventArgs e) => Model.Clear();

    private void StatusClose_Click(object sender, RoutedEventArgs e) => Model.Status = null;

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new SaveFileDialog { Filter = "PDF 파일 (*.pdf)|*.pdf", FileName = Model.SuggestedFileName, DefaultExt = ".pdf" };
        if (dlg.ShowDialog(this) == true) Model.SavePdf(dlg.FileName);
    }

    private void Print_Click(object sender, RoutedEventArgs e)
    {
        if (!Model.CanPrint) return;
        if (new PrintConfirmWindow(Model) { Owner = this }.ShowDialog() == true) Model.PrintNow();
    }

    // MARK: 끌어다 놓기 (탐색기 → 창, 목록 안 순서 바꾸기)

    private const string ItemFormat = "MogoPrint.FileItem";

    private void SetDropHighlight(bool on)
    {
        DropFrame.Stroke = on ? Theme.Accent : (Brush)FindResource("ControlStrongStrokeColorDefaultBrush");
        DropFrame.Opacity = on ? 1 : 0.55;
        DropIcon.Foreground = on ? Theme.Accent : Theme.Secondary;
    }

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(ItemFormat)) return;
        bool files = e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = files ? DragDropEffects.Copy : DragDropEffects.None;
        SetDropHighlight(files);
        e.Handled = true;
    }

    private void Window_Drop(object sender, DragEventArgs e)
    {
        SetDropHighlight(false);
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) _ = Model.AddAsync(paths);
    }

    private static T? Ancestor<T>(DependencyObject? d) where T : DependencyObject
    {
        while (d != null && d is not T) d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
        return d as T;
    }

    private void FileList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        dragItem = null;
        if (Ancestor<ButtonBase>(e.OriginalSource as DependencyObject) != null) return; // 아이콘 버튼은 끌지 않는다
        dragStart = e.GetPosition(FileList);
        dragItem = (Ancestor<ListBoxItem>(e.OriginalSource as DependencyObject))?.DataContext as FileItem;
    }

    private void FileList_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (dragItem == null || e.LeftButton != MouseButtonState.Pressed) return;
        var d = e.GetPosition(FileList) - dragStart;
        if (Math.Abs(d.Y) < SystemParameters.MinimumVerticalDragDistance && Math.Abs(d.X) < SystemParameters.MinimumHorizontalDragDistance) return;
        var item = dragItem;
        dragItem = null;
        DragDrop.DoDragDrop(FileList, new DataObject(ItemFormat, item), DragDropEffects.Move);
    }

    private void FileList_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(ItemFormat)) return; // 탐색기에서 온 파일은 창이 받는다
        e.Effects = DragDropEffects.Move;
        e.Handled = true;
    }

    private void FileList_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(ItemFormat) is not FileItem item) return;
        e.Handled = true;
        int from = Model.Files.IndexOf(item);
        var target = Ancestor<ListBoxItem>(e.OriginalSource as DependencyObject)?.DataContext as FileItem;
        int to = target != null ? Model.Files.IndexOf(target) : Model.Files.Count - 1;
        Model.Move(from, to);
    }
}

/// <summary>단축키용 간단한 명령.</summary>
public sealed class Command(Action run) : ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => run();
}
