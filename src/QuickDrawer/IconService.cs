using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QuickDrawer.Native;

namespace QuickDrawer;

/// <summary>
/// 图标提取服务。给应用磁贴、盘符、目录、文件提供小图标。
///
/// 实现说明：用 SHGetFileInfo 拿系统 Shell 图标，转成 WPF 可用的 BitmapSource。
/// 这是 Win32 Shell 的标准做法，不需要引入第三方库。
/// </summary>
public static class IconService
{
    private static readonly Dictionary<string, BitmapSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// M9：Cache 与 CacheOrder 原来无锁。当前调用方都在 UI 线程，但
    /// AppPickerWindow 的扫描是 async 的，一旦哪天挪到后台就会撞。
    /// 锁住的是字典与队列的一致性，不是 SHGetFileInfo 本身（那在外层）。
    /// </summary>
    private static readonly object CacheGate = new();

    /// <summary>
    /// 图标缓存上限。超过后淘汰最旧的（近似 FIFO）。
    /// 见 AddToCache 的说明：这是 2026-10-19 内存问题（3-4GB）的防线之一。
    /// </summary>
    private const int MaxCacheEntries = 256;

    private static readonly Queue<string> CacheOrder = new();

    /// <summary>
    /// 取一个路径的图标。
    ///
    /// ⚠️ 清晰度要点（2026-10-18 用户反馈"图标模糊"）：
    /// 绝不能加 SHGFI_SMALLICON —— 它只返回 16×16 小图标，放大到 28px 显示必然糊。
    /// 这里改为取系统 large 图标并转成 32×32 BitmapSource，再由 WPF 缩放到显示尺寸。
    /// </summary>
    public static BitmapSource? GetIcon(string? path, string kind = "file")
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        string key = $"{kind}|{path}";
        lock (CacheGate)
        {
            // M10：只命中**非 null** 的缓存。原来取图失败也把 null 写进缓存，
            // 之后该路径永远直接返回 null，直到被 256 条 FIFO 挤出去 ——
            // 用户修好了文件（或插回了 U 盘）也不会恢复。
            if (Cache.TryGetValue(key, out BitmapSource? cached) && cached is not null)
            {
                return cached;
            }
        }

        BitmapSource? icon = null;
        try
        {
            uint flags = NativeMethods.SHGFI_ICON | NativeMethods.SHGFI_USEFILEATTRIBUTES;

            // 2026-10-23 用户反馈"文件夹显示的是盘符图标"（icon-probe 探针实锤）：
            // 原来的"空串 + FILE_ATTRIBUTE_DIRECTORY"方案在 Shell 里被解析为
            // 驱动器根图标，不是文件夹图标（探针像素对比 A≠C，A=B）。
            // 正确做法：传**真实路径** + USEFILEATTRIBUTES + FILE_ATTRIBUTE_DIRECTORY，
            // 无论目录是否存在，Shell 都返回标准文件夹图标（探针方案 B）。
            if (kind == "dir")
            {
                NativeMethods.SHFILEINFO info = new();

                IntPtr result = NativeMethods.SHGetFileInfo(
                    path!, NativeMethods.FILE_ATTRIBUTE_DIRECTORY, ref info,
                    (uint)System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.SHFILEINFO>(), flags);

                if (result != IntPtr.Zero && info.hIcon != IntPtr.Zero)
                {
                    icon = ToFrozenBitmap(info.hIcon);
                }
            }
            else
            {
                // 只用 SHGFI_ICON，取系统默认 large 图标；不要 SMALLICON
                NativeMethods.SHFILEINFO info = new();

                uint fileAttributes = 0;

                // M11：UNC 路径（\\server\share\...）的 File.Exists/Directory.Exists
                // 会**真的发起 SMB 连接**，向不可控主机泄露当前用户的 NTLM 哈希。
                // 对 UNC 一律不探测，按"普通文件"处理，让 Shell 自己决定。
                bool isUnc = path!.StartsWith(@"\\", StringComparison.Ordinal)
                          || path.StartsWith("//", StringComparison.Ordinal);

                if (!isUnc && !File.Exists(path) && !Directory.Exists(path))
                {
                    fileAttributes = NativeMethods.FILE_ATTRIBUTE_NORMAL;
                }

                IntPtr result = NativeMethods.SHGetFileInfo(path, fileAttributes, ref info,
                    (uint)System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.SHFILEINFO>(), flags);

                if (result != IntPtr.Zero && info.hIcon != IntPtr.Zero)
                {
                    icon = ToFrozenBitmap(info.hIcon);
                }
            }
        }
        catch (Exception ex)
        {
            DiagLog.Write("icon", $"failed for {path}: {ex.Message}");
        }

        AddToCache(key, icon);
        return icon;
    }

    /// <summary>把 HICON 转成冻结的 32×32 BitmapSource，并销毁源句柄。</summary>
    private static BitmapSource? ToFrozenBitmap(IntPtr hIcon)
    {
        try
        {
            // 固定 32×32，避免不同 DPI 下大小不一致
            BitmapSource bmp = Imaging.CreateBitmapSourceFromHIcon(
                hIcon, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(32, 32));

            // Freeze 让 BitmapSource 可跨线程使用（2026-10-18 预防）
            bmp.Freeze();
            return bmp;
        }
        finally
        {
            NativeMethods.DestroyIcon(hIcon);
        }
    }

    /// <summary>
    /// 取系统"文件夹"图标（用于目录项）。
    /// 用 SHGetFileInfo 传空串 + FILE_ATTRIBUTE_DIRECTORY，拿的是 Shell 的文件夹图标。
    /// </summary>
    private static BitmapSource? GetShellFolderIcon()
    {
        try
        {
            const uint flags = NativeMethods.SHGFI_ICON | NativeMethods.SHGFI_USEFILEATTRIBUTES;
            NativeMethods.SHFILEINFO info = new();

            IntPtr result = NativeMethods.SHGetFileInfo(
                string.Empty, NativeMethods.FILE_ATTRIBUTE_DIRECTORY, ref info,
                (uint)System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.SHFILEINFO>(), flags);

            if (result != IntPtr.Zero && info.hIcon != IntPtr.Zero)
            {
                return ToFrozenBitmap(info.hIcon);
            }
        }
        catch (Exception ex)
        {
            DiagLog.Write("icon", $"folder icon failed: {ex.Message}");
        }

        return null;
    }

    /// <summary>
    /// 带上限的缓存写入。超过上限就淘汰最旧的（近似 FIFO）。
    ///
    /// ⚠️ 2026-10-19 用户反馈内存 3-4GB：应用列表窗口会为 159 个应用取图标，
    /// 叠加 COM 句柄与 WPF 渲染资源会迅速膨胀。硬上限保证反复打开也不会持续增长。
    /// </summary>
    private static void AddToCache(string key, BitmapSource? icon)
    {
        // M10：失败结果不进缓存，下次调用会重新尝试。
        if (icon is null)
        {
            return;
        }

        lock (CacheGate)
        {
            if (Cache.ContainsKey(key))
            {
                Cache[key] = icon;
                return;
            }

            Cache[key] = icon;
            CacheOrder.Enqueue(key);

            while (CacheOrder.Count > MaxCacheEntries)
            {
                string oldest = CacheOrder.Dequeue();
                Cache.Remove(oldest);
            }
        }
    }

    /// <summary>应用磁贴用的图标（取 exe 自身图标）。</summary>
    public static BitmapSource? GetAppIcon(string? exePath) => GetIcon(exePath, "app");

    /// <summary>兜底图标：一个灰色圆角块，避免空图标让用户以为界面坏了。</summary>
    public static BitmapSource Fallback()
    {
        DrawingVisual visual = new();
        using (DrawingContext dc = visual.RenderOpen())
        {
            dc.DrawRectangle(System.Windows.Media.Brushes.Gray, null, new Rect(0, 0, 28, 28));
        }

        RenderTargetBitmap bmp = new(28, 28, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        return bmp;
    }
}
