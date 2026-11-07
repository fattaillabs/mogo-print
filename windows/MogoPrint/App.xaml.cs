using System.Windows;
using System.Windows.Threading;

namespace MogoPrint;

public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandled;

        if (e.Args.Contains("--snapshot-dir"))
        {
            await Snapshot.RunAsync(this, e.Args);
            return;
        }

        var model = new AppModel();
        var win = new MainWindow(model);
        MainWindow = win;
        win.Show();
        // 탐색기에서 PDF를 프로그램 아이콘에 놓거나 '연결 프로그램'으로 열면 경로가 인자로 온다.
        var files = e.Args.Where(a => !a.StartsWith("--")).ToList();
        if (files.Count > 0) await model.AddAsync(files);
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            var log = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "MogoPrint-error.log");
            File.AppendAllText(log, $"[{DateTime.Now:s}] {e.Exception}\n\n");
        }
        catch { }
        if (Snapshot.Active)
        {
            Snapshot.Fail(e.Exception);
            e.Handled = true;
            return;
        }
        MessageBox.Show(e.Exception.Message, "모고 프린트 오류", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
