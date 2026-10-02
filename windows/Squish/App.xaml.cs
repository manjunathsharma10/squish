using System.Windows;
using Microsoft.Win32;

namespace Squish;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ThemeManager.Apply(AppModel.Shared.Appearance);
        SystemEvents.UserPreferenceChanged += (_, _) => ThemeManager.Apply(AppModel.Shared.Appearance);

        var window = new MainWindow();
        MainWindow = window;
        window.Show();

        // Files passed on the command line, e.g. from "Open with".
        if (e.Args.Length > 0) AppModel.Shared.Add(e.Args);

#if DEBUG
        DebugSnapshot.RunIfRequested(window);
#endif
    }
}

/// Light, dark, or following Windows ("Auto").
public static class ThemeManager
{
    public static event Action? Changed;

    public static bool IsDark { get; private set; }

    public static void Apply(int appearance)
    {
        var dark = appearance switch { 1 => false, 2 => true, _ => SystemIsDark() };
        if (Application.Current.Resources.MergedDictionaries.Count > 0 && dark == IsDark && _applied) return;
        _applied = true;
        IsDark = dark;
        Application.Current.Resources.MergedDictionaries[0] = new ResourceDictionary
        {
            Source = new Uri($"pack://application:,,,/Squish;component/Themes/{(dark ? "Dark" : "Light")}.xaml"),
        };
        Changed?.Invoke();
    }

    static bool _applied;

    static bool SystemIsDark()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
    }
}
