using Microsoft.Win32;

namespace QuickDrawer;

/// <summary>
/// 开机自启（M5）：HKCU\Software\Microsoft\Windows\CurrentVersion\Run。
///
/// 选 HKCU 而不是 HKLM：不需要管理员权限，且自启是"当前用户"的偏好。
/// 发布形态是单文件 exe，直接指向 exe 全路径即可（无需快捷方式）。
/// </summary>
public static class AutoStart
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "QuickDrawer";

    /// <summary>当前 exe 的完整路径（单文件发布下 Assembly.Location 为空）。</summary>
    private static string? CurrentExePath()
    {
        string? exe = Compat.ProcessPath;
        if (string.IsNullOrEmpty(exe))
        {
            exe = AppContext.BaseDirectory.TrimEnd('\\') + "\\QuickDrawer.exe";
        }

        return string.IsNullOrEmpty(exe) ? null : exe;
    }

    /// <summary>
    /// 当前是否已注册开机自启。
    /// M12：原来只判断"值是不是字符串"。用户把 exe 挪了位置、或从旧版本升级到
    /// 新路径后，注册表里那条旧路径永远不会生效，而菜单却显示"已勾选"。
    /// 现在校验它确实指向当前 exe。
    /// </summary>
    public static bool IsEnabled()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            if (key?.GetValue(ValueName) is not string raw)
            {
                return false;
            }

            string? current = CurrentExePath();
            if (current is null)
            {
                return true;   // 解析不出自身路径时不做更严格的判断
            }

            // 注册表里写的是带引号的完整路径，去掉引号再比。
            string registered = raw.Trim().Trim('"');
            if (string.Equals(registered, current, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            DiagLog.Write("autostart", "registered path points elsewhere");
            return false;
        }
        catch (Exception ex)
        {
            DiagLog.Write("autostart", $"query failed: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// 把注册表里的自启路径修正为当前 exe（M13）。
    /// 场景：用户移动了 exe、或换版本后路径变了。原来那条记录会一直指向旧位置，
    /// 开机时启动失败且没有任何提示。启动时调用一次即可自愈。
    /// </summary>
    public static void RepairIfStale()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            if (key?.GetValue(ValueName) is not string raw)
            {
                return;
            }

            string? current = CurrentExePath();
            if (current is null)
            {
                return;
            }

            if (string.Equals(raw.Trim().Trim('"'), current, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            key.SetValue(ValueName, $"\"{current}\"");
            DiagLog.Write("autostart", "repaired stale path");
        }
        catch (Exception ex)
        {
            DiagLog.Write("autostart", $"repair failed: {ex.Message}");
        }
    }

    /// <summary>注册/取消开机自启。返回是否成功。</summary>
    public static bool SetEnabled(bool enabled)
    {
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath);

            if (enabled)
            {
                // ⚠️ 单文件发布下 Assembly.Location 返回空串（IL3000），
                // Environment.ProcessPath 才是可靠来源；再兜底 BaseDirectory。
                string? exe = CurrentExePath();
                if (exe is null)
                {
                    DiagLog.Write("autostart", "cannot resolve exe path");
                    return false;
                }

                key.SetValue(ValueName, $"\"{exe}\"");
                DiagLog.Write("autostart", $"enabled -> \"{exe}\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
                DiagLog.Write("autostart", "disabled");
            }

            return true;
        }
        catch (Exception ex)
        {
            DiagLog.Write("autostart", $"set failed: {ex.Message}");
            return false;
        }
    }
}