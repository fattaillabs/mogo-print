using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Mogo.Core;
using Edge = Mogo.Core.CropGuides.Edge;

namespace MogoPrint;

/// <summary>
/// 여백 수동 조정 화면. 원본 쪽 전체를 보여 주고(잘려 나갈 부분은 흐리게), 네 변의 자르는 선을 점선으로 그려
/// 마우스로 끌게 한다. 손을 떼면 그 위치를 손 조정 값으로 저장한다. 맥 버전 ManualCropView와 같은 계산(CropGuides)을 쓴다.
/// </summary>
public sealed class ManualCropView : UserControl
{
    private readonly AppModel model;
    private readonly FileItem item;
    private int position;
    /// <summary>끄는 중인 범위(쪽 pt). 손을 떼면 저장하고 null로 돌린다.</summary>
    private RectD? draft;
    private Edge? dragging;

    private readonly Canvas canvas = new() { ClipToBounds = true };
    private readonly Image pageImage = new() { Stretch = Stretch.Fill };
    private readonly Rectangle pageShadow = new() { Fill = Brushes.White };
    private readonly System.Windows.Shapes.Path dim = new() { Fill = new SolidColorBrush(Color.FromArgb(0x38, 0, 0, 0)), IsHitTestVisible = false };
    private readonly Dictionary<Edge, Line> lines = new(), refs = new();
    private readonly Dictionary<Edge, (Border pill, TextBlock text)> labels = new();
    private readonly Dictionary<Edge, Rectangle> handles = new();
    private readonly TextBlock pageText = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0) };
    private readonly TextBlock scaleText = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
    private readonly Button prev, next, reset, done;
    private readonly ComboBox fileBox;
    private int renderedPage = -1;

    /// <summary>자동 점검용: 그림이 그려졌는지, 표시 중인 여백 문구.</summary>
    public bool ImageReady => pageImage.Source != null;
    public IReadOnlyDictionary<string, string> LabelTexts => labels.ToDictionary(kv => kv.Key.ToString(), kv => kv.Value.text.Text);
    public string ScaleText => scaleText.Text;

    private static readonly Edge[] Edges = [Edge.Top, Edge.Bottom, Edge.Left, Edge.Right];

    public ManualCropView(AppModel model, FileItem item, int startPosition)
    {
        this.model = model;
        this.item = item;
        position = startPosition;

        // 위쪽 막대
        fileBox = new ComboBox { ItemsSource = model.Files, DisplayMemberPath = nameof(FileItem.Name), SelectedItem = item };
        fileBox.SelectionChanged += (_, _) => { if (fileBox.SelectedItem is FileItem f && f != item) model.StartManualCrop(f); };
        prev = IconButton("", "앞 쪽", () => { position--; Redraw(); });
        next = IconButton("", "다음 쪽", () => { position++; Redraw(); });
        reset = new Button { Content = "원래대로", Margin = new Thickness(0, 0, 8, 0) };
        reset.Click += (_, _) => Reset();
        done = new Button { Content = "완료", Padding = new Thickness(16, 5, 16, 5), IsDefault = true };
        done.SetResourceReference(StyleProperty, "AccentButtonStyle");
        done.Click += (_, _) => model.ManualCrop = null;

        // [여백 조정] [파일 ▾ (줄어듦)] [‹ 1/3쪽 ›] … [글자 크기] [원래대로] [완료]
        var bar = new Grid { Margin = new Thickness(14, 7, 14, 7) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // 남는 폭은 파일 칸이 먼저 가져간다(최대 300).
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6, GridUnitType.Star), MaxWidth = 300 });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 10 });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock { Text = "여백 조정", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0), Foreground = Theme.Secondary };
        bar.Children.Add(title);
        fileBox.MinWidth = 90;
        fileBox.MaxWidth = double.PositiveInfinity;
        Grid.SetColumn(fileBox, 1);
        bar.Children.Add(fileBox);
        var pager = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 0, 0, 0) };
        pager.Children.Add(prev);
        pager.Children.Add(pageText);
        pager.Children.Add(next);
        Grid.SetColumn(pager, 2);
        bar.Children.Add(pager);
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(scaleText);
        right.Children.Add(reset);
        right.Children.Add(done);
        Grid.SetColumn(right, 4);
        bar.Children.Add(right);

        // 캔버스: 쪽 그림 → 흐린 덮개 → 기준선 → 점선 → 값 표시 → 잡는 손잡이 순서로 쌓는다.
        pageShadow.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 8, ShadowDepth = 1, Opacity = 0.25 };
        canvas.Children.Add(pageShadow);
        canvas.Children.Add(pageImage);
        canvas.Children.Add(dim);
        RenderOptions.SetBitmapScalingMode(pageImage, BitmapScalingMode.HighQuality);
        foreach (var edge in Edges)
        {
            var r = new Line { Stroke = Theme.Tertiary, StrokeThickness = 1, StrokeDashArray = [2, 4], IsHitTestVisible = false, Visibility = Visibility.Collapsed };
            refs[edge] = r;
            canvas.Children.Add(r);
        }
        foreach (var edge in Edges)
        {
            var l = new Line { Stroke = Theme.Accent, StrokeThickness = 2, StrokeDashArray = [3.5, 2.5], IsHitTestVisible = false };
            lines[edge] = l;
            canvas.Children.Add(l);
        }
        foreach (var edge in Edges)
        {
            var t = new TextBlock { Foreground = Theme.OnAccent, FontSize = 12 };
            var pill = new Border { Background = Theme.Accent, CornerRadius = new CornerRadius(9), Padding = new Thickness(7, 1, 7, 2), Child = t, IsHitTestVisible = false };
            labels[edge] = (pill, t);
            canvas.Children.Add(pill);
        }
        foreach (var edge in Edges)
        {
            // 잡기 쉬운 넓은 손잡이(보이지 않음). 올리면 양쪽 화살표 커서.
            var h = new Rectangle { Fill = Brushes.Transparent, Cursor = edge is Edge.Top or Edge.Bottom ? Cursors.SizeNS : Cursors.SizeWE, Tag = edge };
            h.MouseLeftButtonDown += Handle_Down;
            h.MouseMove += Handle_Move;
            h.MouseLeftButtonUp += Handle_Up;
            h.LostMouseCapture += (_, _) => { if (dragging != null) Commit(); };
            handles[edge] = h;
            canvas.Children.Add(h);
        }

        var host = new Border { Child = canvas };
        host.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorTertiaryBrush");
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);
        var divider = new Rectangle { Height = 1 };
        divider.SetResourceReference(Shape.FillProperty, "DividerStrokeColorDefaultBrush");
        DockPanel.SetDock(divider, Dock.Top);
        root.Children.Add(divider);
        root.Children.Add(host);
        Content = root;

        canvas.SizeChanged += (_, _) => Redraw();
        model.PropertyChanged += Model_PropertyChanged;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) model.ManualCrop = null; };
        Loaded += (_, _) => Redraw();
    }

    /// <summary>화면에서 내릴 때 모델 구독을 끊는다.</summary>
    public void Detach() => model.PropertyChanged -= Model_PropertyChanged;

    private void Model_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppModel.Options)) Redraw();
    }

    private static Button IconButton(string glyph, string tip, Action click)
    {
        var b = new Button { Content = glyph, ToolTip = tip, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 12, Padding = new Thickness(9, 6, 9, 6) };
        b.Click += (_, _) => click();
        return b;
    }

    // MARK: 계산

    private List<int> PageList
    {
        get
        {
            var p = item.File.PageIndices(model.Options).ToList();
            return p.Count > 0 ? p : [0];
        }
    }
    private int PageIndex => PageList[Math.Clamp(position, 0, PageList.Count - 1)];
    private SizeD PageSize => item.File.Geometry[PageIndex].Size;
    private RectD BaseCrop => Imposer.BaseCrop(item.File, PageIndex, model.Options);
    private RectD Committed => Imposer.Crop(item.File, PageIndex, model.Options);
    private RectD Current => draft ?? Committed;
    private CropAdjustment Adjust => model.Options.Adjustment(item.File.Path);
    private bool HasEdgeAdjustment => Adjust.Top != 0 || Adjust.Bottom != 0 || Adjust.Left != 0 || Adjust.Right != 0;

    private bool Moved(Edge e) => e switch
    {
        Edge.Top => Adjust.Top != 0,
        Edge.Bottom => Adjust.Bottom != 0,
        Edge.Left => Adjust.Left != 0,
        _ => Adjust.Right != 0,
    };

    /// <summary>화면 배치(쪽 → 화면 좌표). 원점은 쪽 그림의 왼쪽 위.</summary>
    private readonly record struct Layout(double Ox, double Oy, double S, SizeD Page)
    {
        public double W => Page.Width * S;
        public double H => Page.Height * S;
        public double X(double px) => Ox + px * S;
        public double Y(double py) => Oy + (Page.Height - py) * S;
        public double PageX(double vx) => (vx - Ox) / S;
        public double PageY(double vy) => Page.Height - (vy - Oy) / S;
    }

    private Layout layout;

    private Layout MakeLayout()
    {
        double cw = canvas.ActualWidth, ch = canvas.ActualHeight;
        var page = PageSize;
        // 오른쪽에는 위·아래 값 표시, 위쪽에는 좌우 값 표시 자리를 남긴다.
        double s = Math.Max(0.01, Math.Min((cw - 150) / page.Width, (ch - 90) / page.Height));
        double w = page.Width * s, h = page.Height * s;
        return new Layout((cw - w) / 2, (ch - h) / 2 + 10, s, page);
    }

    /// <summary>점선의 화면 위치(가로선이면 y, 세로선이면 x)와 여백 값(원본 쪽 가장자리에서 점선까지, pt).</summary>
    private static (double pos, double marginPt) Place(Edge edge, RectD r, Layout L) => edge switch
    {
        Edge.Top => (L.Y(r.MaxY), L.Page.Height - r.MaxY),
        Edge.Bottom => (L.Y(r.MinY), r.MinY),
        Edge.Left => (L.X(r.MinX), r.MinX),
        _ => (L.X(r.MaxX), L.Page.Width - r.MaxX),
    };

    private static string EdgeName(Edge e) => e switch { Edge.Top => "위", Edge.Bottom => "아래", Edge.Left => "왼쪽", _ => "오른쪽" };

    // MARK: 그리기

    private void Redraw()
    {
        var pages = PageList;
        position = Math.Clamp(position, 0, pages.Count - 1);
        pageText.Text = $"{position + 1} / {pages.Count}쪽";
        prev.IsEnabled = position > 0;
        next.IsEnabled = position < pages.Count - 1;
        reset.IsEnabled = HasEdgeAdjustment;
        scaleText.Text = $"원본 대비 글자 크기 {Math.Round(Imposer.Scale(Current, model.Options) * 100)}%";
        if (renderedPage != PageIndex) RenderPage();
        if (canvas.ActualWidth <= 0 || canvas.ActualHeight <= 0) return;

        var L = layout = MakeLayout();
        var c = Current;
        Place(pageShadow, L.Ox, L.Oy, L.W, L.H);
        Place(pageImage, L.Ox, L.Oy, L.W, L.H);
        // 잘려 나갈 부분은 흐리게 덮는다(여백이 다시 보이되 잘린다는 걸 알 수 있게).
        dim.Data = new GeometryGroup
        {
            FillRule = FillRule.EvenOdd,
            Children =
            {
                new RectangleGeometry(new Rect(L.Ox, L.Oy, L.W, L.H)),
                new RectangleGeometry(new Rect(L.X(c.MinX), L.Y(c.MaxY), c.Width * L.S, c.Height * L.S)),
            },
        };

        var b = BaseCrop;
        foreach (var edge in Edges)
        {
            bool horizontal = edge is Edge.Top or Edge.Bottom;
            var (pos, margin) = Place(edge, c, L);

            // 자동으로 잡은 위치(옮긴 변이나 끄는 중일 때만 연하게)
            var r = refs[edge];
            r.Visibility = draft != null || Moved(edge) ? Visibility.Visible : Visibility.Collapsed;
            var (bpos, _) = Place(edge, b, L);
            SetLine(r, horizontal, bpos, L, 0);

            SetLine(lines[edge], horizontal, pos, L, horizontal ? 14 : 10);

            var (pill, text) = labels[edge];
            text.Text = $"{EdgeName(edge)} 여백 {Math.Max(0, margin) / Units.PointsPerMM:0.0}mm";
            pill.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var ps = pill.DesiredSize;
            var (lx, ly) = horizontal ? (L.Ox + L.W + 14 + 58, pos) : (pos, L.Oy - 26);
            Canvas.SetLeft(pill, lx - ps.Width / 2);
            Canvas.SetTop(pill, ly - ps.Height / 2);

            var h = handles[edge];
            if (horizontal) Place(h, L.Ox - 14, pos - 8, L.W + 28, 16);
            else Place(h, pos - 8, L.Oy - 10, 16, L.H + 20);
        }
    }

    private static void Place(FrameworkElement e, double x, double y, double w, double h)
    {
        Canvas.SetLeft(e, x);
        Canvas.SetTop(e, y);
        e.Width = Math.Max(0, w);
        e.Height = Math.Max(0, h);
    }

    private static void SetLine(Line l, bool horizontal, double pos, Layout L, double overhang)
    {
        if (horizontal) { l.X1 = L.Ox - overhang; l.X2 = L.Ox + L.W + overhang; l.Y1 = l.Y2 = pos; }
        else { l.Y1 = L.Oy - overhang; l.Y2 = L.Oy + L.H + overhang; l.X1 = l.X2 = pos; }
    }

    private async void RenderPage()
    {
        int index = renderedPage = PageIndex;
        var size = PageSize;
        // 화면용 해상도(맥과 같은 폭 1400px). 원본 문서는 변환 작업과 같이 쓰지만 PDFium 잠금으로 차례를 지킨다.
        var bmp = await PageRenderer.RenderAsync(item.File.Doc, index, 1400);
        if (index == renderedPage) pageImage.Source = bmp;
        _ = size;
    }

    // MARK: 끌기

    private void Handle_Down(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Rectangle h || h.Tag is not Edge edge) return;
        dragging = edge;
        h.CaptureMouse();
        e.Handled = true;
    }

    private void Handle_Move(object sender, MouseEventArgs e)
    {
        if (dragging is not { } edge || e.LeftButton != MouseButtonState.Pressed) return;
        var p = e.GetPosition(canvas);
        double value = edge is Edge.Top or Edge.Bottom ? layout.PageY(p.Y) : layout.PageX(p.X);
        draft = CropGuides.Move(edge, value, draft ?? Committed, PageSize);
        Redraw();
    }

    private void Handle_Up(object sender, MouseButtonEventArgs e)
    {
        if (sender is Rectangle h) h.ReleaseMouseCapture();
        Commit();
    }

    private void Commit()
    {
        dragging = null;
        if (draft is not { } d) return;
        var a = CropGuides.Adjustment(d, BaseCrop, Adjust);
        draft = null;
        model.Options = model.Options.WithAdjustment(item.File.Path, a.IsDefault ? null : a);
        Redraw();
    }

    /// <summary>네 변 조정만 지우고 '자동 자르기 끄기'는 그대로 둔다.</summary>
    private void Reset()
    {
        var a = new CropAdjustment(WholePage: Adjust.WholePage);
        model.Options = model.Options.WithAdjustment(item.File.Path, a.IsDefault ? null : a);
    }

    /// <summary>자동 점검용: 한 변을 끈 것처럼 옮긴다(mm, +는 안쪽).</summary>
    public void SimulateDrag(Edge edge, double mmInward)
    {
        var c = Committed;
        double d = mmInward * Units.PointsPerMM;
        double value = edge switch { Edge.Top => c.MaxY - d, Edge.Bottom => c.MinY + d, Edge.Left => c.MinX + d, _ => c.MaxX - d };
        draft = CropGuides.Move(edge, value, c, PageSize);
        Commit();
    }
}
