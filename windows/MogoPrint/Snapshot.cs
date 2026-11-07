using System.Text.Encodings.Web;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Mogo.Core;

namespace MogoPrint;

/// <summary>
/// 개발용 자동 UI 점검. 화면 녹화 권한이나 원격 데스크톱 없이 앱이 스스로 창을 그려 PNG로 저장한다(맥 버전 DebugSnapshot과 같은 역할).
///
///   MogoPrint.exe --snapshot-dir C:\snap --snapshot-appearance light --snapshot-drop a.pdf --snapshot-drop b.pdf
///                 [--snapshot-size 1180x780] [--snapshot-copies 2] [--snapshot-elective 언매] [--snapshot-printer 이름]
///                 [--snapshot-kice 1] [--snapshot-drag-top 5] --snapshot-quit
///
/// 저장 파일: empty.png, main.png, manual.png, manual-drag.png(끌기 흉내를 줬을 때), confirm.png, kice.png, report.json.
/// PNG는 2배 해상도. 자동 점검 중에는 사용자가 저장해 둔 선택과목을 읽거나 쓰지 않는다.
/// 끌어다 놓기는 WPF가 DragEventArgs를 밖에서 만들 수 없게 해 두어서, 놓기 처리와 같은 AddAsync를 직접 부른다.
/// </summary>
public static class Snapshot
{
    public static bool Active { get; private set; }
    private static string dir = "";
    private static readonly Dictionary<string, object?> report = new();

    private sealed class Options
    {
        public string Dir = "";
        public string Appearance = "light";
        public double Width = 1180, Height = 780;
        public List<string> Drops = [];
        public List<string> Electives = [];
        public int Copies = 1;
        public string? Printer;
        public bool Kice;
        public double? DragTop;
    }

    private static Options Parse(string[] args)
    {
        var o = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            string? Next() => i + 1 < args.Length ? args[++i] : null;
            switch (args[i])
            {
                case "--snapshot-dir": o.Dir = Next() ?? ""; break;
                case "--snapshot-appearance": o.Appearance = Next() ?? "light"; break;
                case "--snapshot-size":
                    var parts = (Next() ?? "").Split('x');
                    if (parts.Length == 2 && double.TryParse(parts[0], out var w) && double.TryParse(parts[1], out var h)) { o.Width = w; o.Height = h; }
                    break;
                case "--snapshot-drop": if (Next() is { } d) o.Drops.Add(d); break;
                case "--snapshot-elective": if (Next() is { } el) o.Electives.Add(el); break;
                case "--snapshot-copies": o.Copies = int.TryParse(Next(), out var c) ? c : 1; break;
                case "--snapshot-printer": o.Printer = Next(); break;
                case "--snapshot-kice": o.Kice = Next() == "1"; break;
                case "--snapshot-drag-top": o.DragTop = double.TryParse(Next(), out var t) ? t : null; break;
            }
        }
        return o;
    }

    public static async Task RunAsync(App app, string[] args)
    {
        Active = true;
        var o = Parse(args);
        dir = o.Dir;
        Directory.CreateDirectory(dir);
        try
        {
            app.ThemeMode = o.Appearance == "dark" ? ThemeMode.Dark : ThemeMode.Light;
            var model = new AppModel(snapshotMode: true);
            if (o.Printer != null) model.Printer = o.Printer;
            model.Copies = o.Copies;
            var win = new MainWindow(model) { Width = o.Width, Height = o.Height, WindowStartupLocation = WindowStartupLocation.Manual, Left = 0, Top = 0 };
            app.MainWindow = win;
            win.Show();
            await Idle();
            await WaitPrinterInfo(model);
            Save(win, "empty.png");

            await model.AddAsync(o.Drops);
            foreach (var name in o.Electives)
                if (ElectiveInfo.Parse(name) is { } e) model.Options = model.Options.WithElective(e.Subject(), e);
            await model.WaitIdleAsync();
            await WaitFor(() => win.PreviewPages.Count > 0 && win.PreviewPages[0].Image != null && win.PreviewPages.Take(4).All(p => p.Thumb != null));
            await Idle();
            Save(win, "main.png");
            report["output_pages"] = model.OutputPageCount;
            report["sheets"] = model.SheetCount;
            report["display_scale"] = model.DisplayScale;
            report["summary"] = win.SummaryText.Text;
            report["page_indicator"] = win.PageIndicator.Text;
            report["printer"] = model.Printer;
            report["can_duplex"] = model.CanDuplex;
            report["printer_info_loaded"] = model.PrinterInfoLoaded;
            report["printer_info_error"] = model.PrinterInfoError;
            report["hardware_margin_mm"] = model.HardwareMarginMM;
            report["files"] = model.Files.Select(f => new Dictionary<string, object?>
            {
                ["name"] = f.Name, ["detail"] = f.Detail, ["combined"] = f.IsCombined, ["elective"] = f.ElectiveText,
                ["adjusted"] = f.Adjusted, ["pads_blank"] = f.PadsBlank,
            }).ToList();
            report["settings_rows"] = Texts(win.SettingsPanel);

            if (model.Files.Count > 0)
            {
                model.StartManualCrop(outputPage: 0);
                await Idle();
                await WaitFor(() => win.ManualView?.ImageReady == true);
                await Idle();
                Save(win, "manual.png");
                var mv = win.ManualView!;
                report["manual"] = new Dictionary<string, object?>
                {
                    ["labels"] = mv.LabelTexts, ["scale"] = mv.ScaleText, ["indicator"] = win.PageIndicator.Text,
                };
                if (o.DragTop is { } mm)
                {
                    var before = model.Options.Adjustment(model.ManualCrop!.File.Path);
                    mv.SimulateDrag(CropGuides.Edge.Top, mm);
                    await model.WaitIdleAsync();
                    await Idle();
                    Save(win, "manual-drag.png");
                    var after = model.Options.Adjustment(model.ManualCrop!.File.Path);
                    report["manual_drag"] = new Dictionary<string, object?>
                    {
                        ["top_before"] = before.Top, ["top_after"] = after.Top, ["labels"] = mv.LabelTexts, ["scale"] = mv.ScaleText,
                        ["file_adjusted_badge"] = model.ManualCrop!.Adjusted, ["summary"] = win.SummaryText.Text,
                    };
                }
                model.ManualCrop = null;
                await Idle();
            }

            if (model.CanPrint)
            {
                var confirm = new PrintConfirmWindow(model) { Owner = win };
                confirm.Show();
                await Idle();
                Save(confirm, "confirm.png");
                report["confirm"] = Texts((Panel)((Grid)confirm.Content).Children[0]);
                confirm.Close();
            }

            if (o.Kice)
            {
                var kice = new KiceWindow(model) { Owner = win };
                kice.Show();
                await WaitFor(() => kice.Loaded2, 30000);
                await Idle();
                Save(kice, "kice.png");
                report["kice"] = new Dictionary<string, object?> { ["loaded"] = kice.Loaded2, ["areas"] = kice.Rows.Select(r => r.Area).ToList() };
                kice.Close();
            }
            report["errors"] = win.SnapshotErrors;
            report["ok"] = true;
        }
        catch (Exception ex)
        {
            report["ok"] = false;
            report["exception"] = ex.ToString();
        }
        WriteReport();
        app.Shutdown(report.TryGetValue("ok", out var ok) && ok is true ? 0 : 1);
    }

    public static void Fail(Exception ex)
    {
        report["ok"] = false;
        report["exception"] = ex.ToString();
        WriteReport();
        Application.Current.Shutdown(1);
    }

    private static void WriteReport()
    {
        try
        {
            File.WriteAllText(System.IO.Path.Combine(dir, "report.json"), JsonSerializer.Serialize(report,
                new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
        }
        catch { }
    }

    private static async Task Idle()
    {
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        await Task.Delay(150);
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
    }

    private static async Task WaitFor(Func<bool> done, int timeoutMs = 20000)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (!done() && sw.ElapsedMilliseconds < timeoutMs) await Task.Delay(50);
    }

    private static async Task WaitPrinterInfo(AppModel model)
    {
        // 프린터 정보(양면 지원·인쇄 불가 여백)는 백그라운드로 읽는다. 다 읽을 때까지 기다려 화면에 반영되게.
        await WaitFor(() => model.PrinterInfoLoaded, 15000);
        await Idle();
    }

    /// <summary>창 내용을 2배 해상도 PNG로 저장한다(제목 표시줄 제외).</summary>
    private static void Save(Window w, string name)
    {
        if (w.Content is not FrameworkElement el) return;
        el.UpdateLayout();
        double width = el.ActualWidth, height = el.ActualHeight;
        if (width <= 0 || height <= 0)
        {
            el.Measure(new Size(w.Width, double.IsNaN(w.Height) ? double.PositiveInfinity : w.Height));
            el.Arrange(new Rect(el.DesiredSize));
            width = el.DesiredSize.Width;
            height = el.DesiredSize.Height;
        }
        const double scale = 2;
        var rtb = new RenderTargetBitmap((int)Math.Ceiling(width * scale), (int)Math.Ceiling(height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        rtb.Render(el);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        using var fs = File.Create(System.IO.Path.Combine(dir, name));
        enc.Save(fs);
    }

    /// <summary>패널 안의 글자들(보이는 것만)을 줄 단위로 모은다.</summary>
    private static List<string> Texts(DependencyObject root)
    {
        var outList = new List<string>();
        void Walk(DependencyObject d)
        {
            if (d is UIElement { Visibility: not Visibility.Visible }) return;
            if (d is TextBlock t && !string.IsNullOrWhiteSpace(t.Text)) outList.Add(t.Text);
            if (d is ContentControl { Content: string s }) outList.Add(s);
            if (d is ComboBox cb && cb.SelectedItem is string sel) outList.Add("[" + sel + "]");
            if (d is System.Windows.Controls.Primitives.ToggleButton tb && tb is not RadioButton) outList.Add(tb.IsChecked == true ? "[켜짐]" : "[꺼짐]");
            if (d is RadioButton rb && rb.IsChecked == true) outList.Add("[" + rb.Content + "]");
            int n = VisualTreeHelper.GetChildrenCount(d);
            for (int i = 0; i < n; i++) Walk(VisualTreeHelper.GetChild(d, i));
        }
        Walk(root);
        return outList;
    }
}
