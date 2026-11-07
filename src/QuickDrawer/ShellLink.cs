using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace QuickDrawer;

/// <summary>
/// 解析 .lnk（Shell Link），取出真实目标路径。
///
/// 为什么用 COM 而不是手工解析二进制：
/// 2026-10-18 实测，手工按 MS-SHLLINK 偏移解析在真实文件上 31/31 全部失败。
/// 根因是 IDList 的字节计数字段是否包含自身长度，不同 Windows 版本/生成器
/// 处理不一致，导致后续字段偏移差 1 个字符，路径被解码成乱码。
/// 与其赌偏移细节，不如用系统自己的 COM 解析器 —— IShellLinkW 是
/// Windows 官方保证正确的 API，能同时拿到目标路径、工作目录、参数、图标位置。
///
/// 用法：
///   var link = new ShellLinkResolver();
///   string? exePath = link.TryResolve(@"C:\Users\me\Desktop\VS Code.lnk");
/// </summary>
public sealed class ShellLinkResolver
{
    /// <summary>
/// CLSID_ShellLink (00021401-0000-0000-C000-000000000046)。
/// 用 Type.GetTypeFromCLSID + Activator 激活，不能直接 as 转 IShellLinkW。
/// </summary>
private static class ShellLinkClsid
{
    public static readonly Guid Id = new("00021401-0000-0000-C000-000000000046");
}

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath(
            [Out] [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszFile,
            int cch, IntPtr pfd, uint fFlags);

        void GetIDList(out IntPtr ppidl);

        void SetIDList(IntPtr pidl);

        void GetDescription(
            [Out] [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszName,
            int cch);

        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);

        void GetWorkingDirectory(
            [Out] [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszDir,
            int cch);

        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);

        void GetArguments(
            [Out] [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszArgs,
            int cch);

        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);

        void GetHotkey(out short pwHotkey);

        void SetHotkey(short wHotkey);

        void GetShowCmd(out int piShowCmd);

        void SetShowCmd(int iShowCmd);

        void GetIconLocation(
            [Out] [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszIconPath,
            int cch, out int piIcon);

        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);

        void SetRelativePath(
            [MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);

        void Resolve(IntPtr hwnd, uint fFlags);

        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    /// <summary>SLGP_RAWPATH = 1：不把环境变量展开成完整路径。</summary>
    private const uint SLGP_RAWPATH = 1;

    private const int MaxPathChars = 1024;

    /// <summary>
    /// 解析 .lnk，取出目标路径。
    /// 返回 null 表示解析失败或目标已不存在。
    /// </summary>
    public string? TryResolve(string lnkPath)
    {
        if (!File.Exists(lnkPath))
        {
            return null;
        }

        IShellLinkW? link = null;
        object? raw = null;
        try
        {
            // 标准 COM 激活方式：CLSID → Type → Activator
            Type t = Type.GetTypeFromCLSID(ShellLinkClsid.Id, throwOnError: true)!;
            raw = Activator.CreateInstance(t);
            if (raw is null)
            {
                return null;
            }

            link = (IShellLinkW)raw;

            // IPersistFile.Load —— 让 ShellLink 从磁盘读取
            if (link is not System.Runtime.InteropServices.ComTypes.IPersistFile persist)
            {
                return null;
            }

            persist.Load(lnkPath, 0);

            System.Text.StringBuilder sb = new(MaxPathChars);

            // 用系统解析器取路径。SLGP_RAWPATH 保留环境变量形式，
            // 之后统一用 ExpandEnvironmentVariables 展开。
            link.GetPath(sb, sb.Capacity, IntPtr.Zero, SLGP_RAWPATH);

            string path = sb.ToString();

            // 有些 lnk 的路径是环境变量形式（如 %ProgramFiles%\...），展开它
            path = Environment.ExpandEnvironmentVariables(path);

            if (string.IsNullOrWhiteSpace(path))
            {
                // 退回：用 WorkingDirectory + Arguments 拼不出可靠结果，
                // 只能认为该 lnk 指向非文件系统对象（如 UWP）
                return null;
            }

            // 目标不存在时也算失败，便于上层决定是否提示用户
            if (File.Exists(path) || Directory.Exists(path))
            {
                return Path.GetFullPath(path);
            }

            return null;
        }
        catch (Exception ex)
        {
            DiagLog.Write("shelllink", $"COM resolve failed for {lnkPath}: {ex.Message}");
            return null;
        }
        finally
        {
            // 只释放我们持有的 RCW
            if (raw != null && System.Runtime.InteropServices.Marshal.IsComObject(raw))
            {
                System.Runtime.InteropServices.Marshal.ReleaseComObject(raw);
            }
        }
    }

    /// <summary>取 .lnk 的显示名（不含扩展名）。</summary>
    public string GetDisplayName(string lnkPath)
    {
        try
        {
            return Path.GetFileNameWithoutExtension(lnkPath);
        }
        catch
        {
            return lnkPath;
        }
    }
}