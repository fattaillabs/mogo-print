using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using Mogo.Core;

namespace MogoPrint;

/// <summary>
/// 자동 업데이트(맥 버전 AppUpdater와 같은 흐름). 앱을 열 때 GitHub 최신 릴리스를 확인하고, 새 버전이 있으면 화면 아래 한 줄로 알린다.
/// 업데이트하면 zip을 받아(GitHub가 알려 주는 SHA-256과 맞는지 확인) 안의 exe 버전을 확인한 뒤,
/// 실행 중인 exe를 .old로 옮기고 새 exe를 제자리에 두고 다시 실행한다. .old는 다음 실행 때 지운다.
/// </summary>
public sealed class AppUpdater : Observable
{
    public static AppUpdater Shared { get; } = new();

    public enum Phase { Idle, Checking, UpToDate, Available, Downloading, Installing, Failed }

    private Phase phase;
    public Phase State { get => phase; private set { if (Set(ref phase, value)) Raise(nameof(IsBusy)); } }

    private UpdateCheck.Release? available;
    public UpdateCheck.Release? Available { get => available; set => Set(ref available, value); }

    private double progress;
    public double Progress { get => progress; private set => Set(ref progress, value); }

    private string? error;
    public string? Error { get => error; private set => Set(ref error, value); }

    /// <summary>수동 확인 결과를 창으로 보여 달라는 요청.</summary>
    public event Action? DialogRequested;

    public bool SnapshotMode { get; set; }
    public bool IsBusy => phase is Phase.Checking or Phase.Downloading or Phase.Installing;

    public static string CurrentVersion
    {
        get
        {
            var asm = Assembly.GetEntryAssembly() ?? typeof(AppUpdater).Assembly;
            var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            return info != null ? info.Split('+')[0] : asm.GetName().Version?.ToString(3) ?? "0";
        }
    }

    private static string SettingsPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MogoPrint", "update.json");

    private static string? SkippedVersion
    {
        get
        {
            try { using var d = JsonDocument.Parse(File.ReadAllText(SettingsPath)); return d.RootElement.GetProperty("skipped").GetString(); }
            catch { return null; }
        }
        set
        {
            try
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(SettingsPath)!);
                File.WriteAllText(SettingsPath, JsonSerializer.Serialize(new { skipped = value }));
            }
            catch { }
        }
    }

    /// <summary>앱을 열 때 조용히 확인한다(자동 점검 중이거나 MOGO_NO_UPDATE_CHECK=1이면 하지 않는다).</summary>
    public void CheckAutomatically()
    {
        if (SnapshotMode || Environment.GetEnvironmentVariable("MOGO_NO_UPDATE_CHECK") == "1") return;
        _ = CheckAsync(false);
    }

    public async Task CheckAsync(bool manual)
    {
        if (IsBusy) return;
        State = Phase.Checking;
        Error = null;
        try
        {
            var r = await UpdateCheck.LatestAsync();
            if (r == null || !UpdateCheck.IsNewer(r.Version, CurrentVersion) || !r.Assets.ContainsKey(UpdateCheck.WindowsAssetName))
            {
                Available = null;
                State = manual ? Phase.UpToDate : Phase.Idle;
            }
            else if (!manual && SkippedVersion == r.Version)
            {
                Available = null;
                State = Phase.Idle;
            }
            else
            {
                Available = r;
                State = Phase.Available;
            }
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            State = manual ? Phase.Failed : Phase.Idle;
        }
        if (manual) DialogRequested?.Invoke();
    }

    /// <summary>자동 점검(README 그림)용: 가짜 새 버전을 띄우거나 지운다.</summary>
    internal void ShowForSnapshot(UpdateCheck.Release? r)
    {
        Available = r;
        State = r == null ? Phase.Idle : Phase.Available;
    }

    public void Skip()
    {
        if (Available is { } r) SkippedVersion = r.Version;
        Available = null;
        State = Phase.Idle;
    }

    /// <summary>배포용 단일 exe이고, 그 폴더에 쓸 수 있으면 제자리에서 바꿀 수 있다.</summary>
    public static bool CanReplaceInPlace
    {
        get
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe) || !string.IsNullOrEmpty(typeof(AppUpdater).Assembly.Location)) return false; // 개발용 빌드
            try
            {
                var probe = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(exe)!, $".mogo-write-{Guid.NewGuid():N}");
                File.WriteAllText(probe, "");
                File.Delete(probe);
                return true;
            }
            catch { return false; }
        }
    }

    public static void OpenPage(string? url = null)
    {
        try { Process.Start(new ProcessStartInfo(url ?? UpdateCheck.ReleasesPage) { UseShellExecute = true }); } catch { }
    }

    public async Task InstallAsync()
    {
        if (Available is not { } r || !r.Assets.TryGetValue(UpdateCheck.WindowsAssetName, out var asset)) return;
        if (!CanReplaceInPlace)
        {
            OpenPage(r.Page);
            Error = "이 위치에서는 프로그램을 바꿀 수 없어요. 열린 페이지에서 새 버전을 받아 지금 쓰는 MogoPrint.exe와 바꿔 주세요.";
            State = Phase.Failed;
            return;
        }
        var exe = Environment.ProcessPath!;
        var dir = System.IO.Path.GetDirectoryName(exe)!;
        var zip = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"MogoPrint-update-{Guid.NewGuid():N}.zip");
        var staged = exe + ".new";
        try
        {
            State = Phase.Downloading;
            Progress = 0;
            await UpdateCheck.DownloadAsync(asset.Url, zip, new Progress<double>(p => Progress = p));
            State = Phase.Installing;
            await Task.Run(() => UpdateInstaller.Stage(zip, staged, asset, r.Version));
            UpdateInstaller.Swap(exe, staged);
            Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = dir });
            Application.Current.Shutdown();
        }
        catch (Exception ex)
        {
            try { File.Delete(staged); } catch { }
            Error = ex.Message;
            State = Phase.Failed;
        }
        finally
        {
            try { File.Delete(zip); } catch { }
        }
    }

    /// <summary>지난 업데이트가 남긴 .old·.new 파일을 지운다(앱 시작 때).</summary>
    public static void CleanupOld()
    {
        if (Environment.ProcessPath is not { } exe) return;
        // 업데이트 직후에는 앞 프로그램이 아직 닫히는 중이라 .old가 잠겨 있다. 시작을 막지 않게 뒤에서 잠깐씩 기다리며 다시 지운다.
        _ = Task.Run(async () =>
        {
            foreach (var leftover in new[] { exe + ".old", exe + ".new" })
                for (int i = 0; i < 60 && File.Exists(leftover); i++)
                {
                    try { File.Delete(leftover); }
                    catch { await Task.Delay(500); }
                }
        });
    }

    /// <summary>릴리스 설명(마크다운)을 글자로: 제목 표시(#)를 뗀다.</summary>
    public static string PlainNotes(string markdown) =>
        string.Join("\n", markdown.Replace("\r\n", "\n").Split('\n').Select(l => l.TrimStart().StartsWith('#') ? l.TrimStart().TrimStart('#').Trim() : l))
            .Replace("**", "").Replace("`", "");
}
