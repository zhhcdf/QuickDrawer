using Microsoft.Win32;

namespace QuickDrawer;

/// <summary>
/// 主题服务（M5 打磨）：
///   1. 启动时读注册表判断系统深/浅色模式
///      （HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme）
///   2. 把面板的两种配色各自做成资源字典（Dark/Light）
///   3. 替换进 Application.Resources.MergedDictionaries 即完成切换
///
/// 为什么不用 WPF 内置主题：WPF 没有内建"跟随系统深浅色"机制，
/// 硬编码颜色（33 处）在浅色系统上就是"黑底配浅色系统"的突兀观感——
/// 用户的原始诉求"太暗了"正是因为面板永远黑。
///
/// 换资源字典而非逐控件改色的原因：所有控件引用 DynamicResource，
/// 切字典即全局生效，无需遍历可视树。
/// </summary>
public static class ThemeService
{
    private const string PersonalizeKey =
        @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    /// <summary>当前是否深色模式。</summary>
    public static bool IsDarkTheme { get; private set; } = true;

    /// <summary>
    /// 应用主题到 Application.Resources。
    /// 在 App.OnStartup、窗口构造之前调用。
    /// </summary>
    public static void ApplySystemTheme()
    {
        IsDarkTheme = !IsLightTheme();
        Apply(IsDarkTheme);
        DiagLog.Write("theme", $"applied {(IsDarkTheme ? "dark" : "light")} theme (follow system)");
    }

    /// <summary>切换到指定主题（资源字典替换，DynamicResource 全局即时生效）。</summary>
    public static void Apply(bool dark)
    {
        IsDarkTheme = dark;
        string dictUri = dark
            ? "pack://application:,,,/Themes/Dark.xaml"
            : "pack://application:,,,/Themes/Light.xaml";

        var dict = new System.Windows.ResourceDictionary
        {
            Source = new Uri(dictUri)
        };

        var dictionaries = System.Windows.Application.Current.Resources.MergedDictionaries;

        // 移除旧主题字典（按 Source 匹配，避免叠加）
        for (int i = dictionaries.Count - 1; i >= 0; i--)
        {
            string? src = dictionaries[i].Source?.ToString();
            if (src is not null && src.Contains("/Themes/"))
            {
                dictionaries.RemoveAt(i);
            }
        }

        // 主题字典插最前：面板样式引用它的键，其他字典的键优先级更高不受影响
        dictionaries.Insert(0, dict);
    }

    /// <summary>
    /// 让走系统标题栏的窗口与主题一致。
    ///
    /// 在窗口的 SourceInitialized 事件里调用。
    /// 无标题栏的窗口（WindowStyle=None）调与不调都一样，不需要特意跳过。
    /// </summary>
    public static void ApplyWindowChrome(System.Windows.Window window)
    {
        try
        {
            IntPtr hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero) return;

            int dark = IsDarkTheme ? 1 : 0;
            const int DwmwaUseImmersiveDarkMode = 20;
            int hr = QuickDrawer.Native.NativeMethods.DwmSetWindowAttribute(
                hwnd, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));

            // 旧版 Windows 10（1809–1909）用的是另一个序号，只有在 20 失败时才回退
            if (hr != 0)
            {
                const int DwmwaUseImmersiveDarkModeBefore20h1 = 19;
                _ = QuickDrawer.Native.NativeMethods.DwmSetWindowAttribute(
                    hwnd, DwmwaUseImmersiveDarkModeBefore20h1, ref dark, sizeof(int));
            }
        }
        catch
        {
            // 标题栏颜色是锦上添花，任何异常都不应影响窗口打开
        }
    }

    /// <summary>系统是否浅色模式（AppsUseLightTheme==1）。读取失败按深色处理（与现状一致）。</summary>
    private static bool IsLightTheme()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue("AppsUseLightTheme") is int v && v == 1;
        }
        catch
        {
            return false;
        }
    }
}