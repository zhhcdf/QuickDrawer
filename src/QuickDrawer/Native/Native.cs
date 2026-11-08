using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;

namespace QuickDrawer.Native;

/// <summary>
/// Win32 P/Invoke 声明与辅助方法。
/// 这些 API 的能力已在本机用 PowerShell 探针实测通过（见 docs/可行性方案.md §4）：
///   - RegisterHotKey / WM_HOTKEY        → PASS
///   - AddClipboardFormatListener / WM_CLIPBOARDUPDATE → PASS
///   - SetWindowPos HWND_TOPMOST          → PASS
///   - SHAppBarMessage ABM_QUERYPOS/SETPOS → PASS（预留 300px）
/// </summary>
internal static class NativeMethods
{
    // ---- 窗口样式常量 ----
    public const int GWL_EXSTYLE = -20;
    public const uint WS_EX_NOACTIVATE = 0x08000000;
    public const uint WS_EX_TRANSPARENT = 0x00000020;
    public const uint WS_EX_TOOLWINDOW = 0x00000080;

    public const int SW_HIDE = 0;
    public const int SW_SHOWNOACTIVATE = 4;

    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new(-2);

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;

    // ---- 消息常量 ----
    public const int WM_HOTKEY = 0x0312;
    public const int WM_CLIPBOARDUPDATE = 0x031D;
    public const int WM_DPICHANGED = 0x02E0;
    public const int WM_SETTINGCHANGE = 0x001A;

    // ---- 热键修饰符 ----
    public const uint MOD_ALT = 0x0001;
    public const uint MOD_CONTROL = 0x0002;
    public const uint MOD_SHIFT = 0x0004;
    public const uint MOD_WIN = 0x0008;
    public const uint MOD_NOREPEAT = 0x4000;

    // ---- 剪贴板 ----
    public const uint CF_UNICODETEXT = 13;

    /// <summary>
    /// CF_TEXT（ANSI 8 位文本）与 CF_OEMTEXT（OEM 码页）。
    ///
    /// 2026-11-05：少数老式 Win32 程序、部分终端 / 编辑器**只**放这两个格式，
    /// 不提供 CF_UNICODETEXT。原来格式探测只看 CF_UNICODETEXT，这类复制
    /// 一条都进不了历史（"复制了但剪贴板里没有"的成因之一）。
    /// </summary>
    public const uint CF_TEXT = 1;
    public const uint CF_OEMTEXT = 7;
    public const uint CF_BITMAP = 2;
    public const uint CF_DIB = 8;
    public const uint CF_DIBV5 = 17;
    public const uint CF_HDROP = 15;

    // CF_HTML / CF_RTF 不是固定常量：它们是 RegisterClipboardFormatW 动态分配的，
    // 编号从 0xC000 起、每个会话不同。实测本机 "HTML Format" = 0xC0F3、
    // "Rich Text Format" = 0xC095 —— 原代码写死 0x00000100 / 0x000004C8，
    // 永远匹配不上，所以 Word/Excel 表格的格式一直没被捕获（2026-11-01）。
    // 这几个值在同一进程内稳定，缓存一次即可。
    private static uint? _htmlFormat;
    private static uint? _rtfFormat;

    /// <summary>"HTML Format" 的动态 id；注册失败返回 0。</summary>
    public static uint HtmlFormat => _htmlFormat ??= RegisterClipboardFormatW("HTML Format");

    /// <summary>"Rich Text Format" 的动态 id；注册失败返回 0。</summary>
    public static uint RtfFormat => _rtfFormat ??= RegisterClipboardFormatW("Rich Text Format");

    // ---- AppBar ----
    public const uint ABM_NEW = 0x00000000;
    public const uint ABM_REMOVE = 0x00000001;
    public const uint ABM_QUERYPOS = 0x00000002;
    public const uint ABM_SETPOS = 0x00000003;
    public const uint ABE_LEFT = 0;
    public const uint ABE_RIGHT = 2;

    public const int SPI_GETWORKAREA = 0x0030;

    // ---- DPI awareness ----
    // PerMonitorV2 = 2 (见 app.manifest；此处用于运行期查询)
    public const int MONITOR_DEFAULTTONEAREST = 2;

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool AddClipboardFormatListener(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RemoveClipboardFormatListener(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int x, int y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    // ---- 键盘模拟：点击剪贴板历史后自动粘贴（2026-10-25） ----
    // ⚠️ INPUT 在 x64 上是 40 字节（type 4 + 对齐 4 + 联合体 32）。
    // 联合体用 Explicit + Size=32 固定，否则 Marshal.SizeOf 会因
    // 内部字段（IntPtr）被压到 24，SendInput 直接返回 0 且不报错。
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit, Size = 32)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public INPUTUNION u;
    }

    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const ushort VK_CONTROL = 0x11;
    public const ushort VK_V = 0x56;
    public const ushort VK_C = 0x43;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    /// <summary>向当前前台窗口注入 Ctrl+V。返回实际注入的事件数（4 = 全部成功）。</summary>
    public static uint SendCtrlV()
    {
        INPUT[] inputs = new INPUT[4];
        inputs[0] = MakeKey(VK_CONTROL, false);
        inputs[1] = MakeKey(VK_V, false);
        inputs[2] = MakeKey(VK_V, true);
        inputs[3] = MakeKey(VK_CONTROL, true);
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    /// <summary>
    /// 向当前前台窗口注入 Ctrl+C：取"选中文字"的回退方案（UIA 拿不到时才用）。
    /// 会短暂改写剪贴板，调用方必须自己负责还原。
    /// </summary>
    public static uint SendCtrlC()
    {
        INPUT[] inputs = new INPUT[4];
        inputs[0] = MakeKey(VK_CONTROL, false);
        inputs[1] = MakeKey(VK_C, false);
        inputs[2] = MakeKey(VK_C, true);
        inputs[3] = MakeKey(VK_CONTROL, true);
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT MakeKey(ushort vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        u = new INPUTUNION
        {
            ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 }
        }
    };

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref RECT pvParam, uint fWinIni);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport("shcore.dll", SetLastError = true)]
    public static extern uint GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    // ---- 剪贴板读取 ----
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EmptyClipboard();

    [DllImport("user32.dll")]
    public static extern uint EnumClipboardFormats(uint format);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint RegisterClipboardFormatW(string lpszFormat);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetClipboardData(uint uFormat);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    // ---- 剪贴板来源与文件列表 ----
    // SetLastError 是给"剪贴板正被别的进程打开"这种失败情形取证用的：
    // GetClipboardOwner 在剪贴板被占用时返回 NULL 并把 last error 置 5(ACCESS_DENIED)。
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetClipboardOwner();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint DragQueryFile(IntPtr hDrop, uint iFile, IntPtr lpszFile, uint cch, uint flags);

    // 发布前审查 B4：这里原来声明了 DragQueryFileCount，但 shell32.dll 没有这个导出。
    // 实测调用抛 EntryPointNotFoundException，已删除。
    // 取文件总数请用 DragQueryFile(hDrop, 0xFFFFFFFF, IntPtr.Zero, 0, 0)。

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalFree(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern UIntPtr GlobalSize(IntPtr hMem);

    // ---- CF_BITMAP -> DIB 转换（截图工具只提供 CF_BITMAP 时用） ----
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAP
    {
        public int bmType;
        public int bmWidth;
        public int bmHeight;
        public int bmWidthBytes;
        public ushort bmPlanes;
        public ushort bmBitsPixel;
        public IntPtr bmBits;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    public const uint BI_RGB = 0;
    public const uint DIB_RGB_COLORS = 0;

    [DllImport("gdi32.dll", SetLastError = true)]
    public static extern int GetObject(IntPtr hgdiobj, int cbBuffer, ref BITMAP lpvObject);

    [DllImport("gdi32.dll", SetLastError = true)]
    public static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll", SetLastError = true)]
    public static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    public static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);

    [DllImport("gdi32.dll", SetLastError = true)]
    public static extern int GetDIBits(IntPtr hdc, IntPtr hbm, uint start, uint cLines,
        byte[] lpvBits, ref BITMAPINFOHEADER lpbmi, uint usage);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    public const uint GMEM_MOVEABLE = 0x0002;
    public const uint GMEM_ZEROINIT = 0x0040;

    // ---- Shell 图标 ----
    public const uint SHGFI_ICON = 0x000000100;
    public const uint SHGFI_SMALLICON = 0x000000001;
    public const uint SHGFI_USEFILEATTRIBUTES = 0x000000010;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    public const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes,
        ref SHFILEINFO psfi, uint cbSizeFileInfo, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    // ---- 仪表盘采样（2026-11-03 用户需求） ----

    /// <summary>
    /// 系统累计的 idle / kernel / user 时间（100ns 单位）。
    /// 注意 kernel 时间**包含** idle 时间（Win32 文档明确说明），
    /// 算 CPU 占用时总时间 = (kernel 增量 + user 增量)，不能把 idle 再加一遍。
    /// </summary>
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemTimes(out ulong lpIdleTime, out ulong lpKernelTime, out ulong lpUserTime);

    /// <summary>
    /// GlobalMemoryStatusEx 的内存状态结构。
    /// dwLength 必须由调用方先赋值为 sizeof(MEMORYSTATUSEX)，
    /// 否则函数直接返回 false（这是最容易漏的一步）。
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    /// <summary>取内存状态。失败（极少）时返回 false，调用方保留上一帧数值。</summary>
    public static bool TryGetMemoryStatus(out MEMORYSTATUSEX status)
    {
        status = new MEMORYSTATUSEX
        {
            dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>()
        };

        return GlobalMemoryStatusEx(ref status);
    }

    // ---- 启动进程 ----
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr ShellExecute(IntPtr hwnd, string lpOperation,
        string lpFile, string lpParameters, string lpDirectory, int nShowCmd);

    public const int SW_SHOWNORMAL = 1;

    /// <summary>取得 WPF 窗口的 Win32 HWND。</summary>
    public static IntPtr GetHwnd(Window window)
    {
        WindowInteropHelper helper = new(window);
        return helper.Handle;
    }

    /// <summary>为窗口追加扩展样式（保留原有样式）。</summary>
    public static void AddWindowExStyle(Window window, uint style)
    {
        IntPtr hwnd = GetHwnd(window);
        int current = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, current | (int)style);
    }

    /// <summary>取得当前鼠标所在显示器的工作区（已扣除任务栏）。</summary>
    public static Rect GetWorkAreaForCursor()
    {
        // 用光标位置找显示器（纯 Win32，不依赖 WinForms）
        if (!GetCursorPos(out POINT p))
        {
            return SystemParametersWorkArea();
        }

        IntPtr hmon = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        if (hmon == IntPtr.Zero)
        {
            return SystemParametersWorkArea();
        }

        MONITORINFO mi = new() { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(hmon, ref mi))
        {
            return SystemParametersWorkArea();
        }

        return new Rect(mi.rcWork.Left, mi.rcWork.Top,
            mi.rcWork.Right - mi.rcWork.Left, mi.rcWork.Bottom - mi.rcWork.Top);
    }

    private static Rect SystemParametersWorkArea() => new(0, 0,
        SystemParameters.WorkArea.Width, SystemParameters.WorkArea.Height);

    /// <summary>
    /// 取当前鼠标的屏幕坐标。用于"鼠标离开面板自动收起"的判定 ——
    /// 不能只靠 MouseEnter/MouseLeave 事件：面板展开时会正好盖住拉手，
    /// 事件时序不可靠，光标位置才是可靠依据。
    /// </summary>
    public static (int X, int Y) GetCursorScreenPos()
    {
        return GetCursorPos(out POINT p) ? (p.X, p.Y) : (0, 0);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    // 注意：Win32 原型是 MonitorFromPoint(POINT pt, DWORD dwFlags)，POINT 是 8 字节
    // 结构体按值传递。早期这里误写成 (int x, int y, uint dwFlags)，在 x86 上堆栈
    // 布局恰好等价所以看不出问题；本项目 PlatformTarget=x64，x64 下 POINT 只占
    // 一个寄存器，拆成两个 int 参数会让 dwFlags 错位到第三个参数槽，user32 看到
    // 的是垃圾 flags → 直接返回 NULL。表现就是 GetWorkAreaForCursor() 永远走进
    // SystemParametersWorkArea() 兜底（主屏工作区，且是 DIP 坐标），
    // 于是光标在副屏时拉手/面板仍贴到主屏 —— 2026-11-08 做全屏检测时被探针抓出来。
    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    /// <summary>注册全局热键。失败时抛出含 Win32 错误码的异常。</summary>
    public static void RegisterGlobalHotkey(Window window, int id, uint modifiers, uint vk)
    {
        IntPtr hwnd = GetHwnd(window);
        if (!RegisterHotKey(hwnd, id, modifiers, vk))
        {
            int err = Marshal.GetLastWin32Error();
            // 1409 = ERROR_HOTKEY_ALREADY_REGISTERED
            throw new InvalidOperationException(
                $"RegisterHotKey 失败（Win32 错误 {err}" +
                (err == 1409 ? "，ERROR_HOTKEY_ALREADY_REGISTERED：该热键已被其他程序占用" : "") + "）");
        }
    }

    public static void UnregisterGlobalHotkey(Window window, int id)
    {
        IntPtr hwnd = GetHwnd(window);
        UnregisterHotKey(hwnd, id);
    }

    /* ==================== 强制前台（2026-10-31 八次） ====================
       为什么不能只靠 Window.Activate()：
       悬浮条是 WS_EX_NOACTIVATE，点它时进程拿不到前台权限，
       ShowDialog() 的激活请求被 Windows 前台锁拒绝 —— 窗口只显示、不被激活，
       用户看到的就是"对话框开在当前激活窗口的下一层"，且输入框没有光标。
       做法：AttachThreadInput 把本线程挂到当前前台窗口的输入队列，
       借用它的前台权限 → BringWindowToTop + SetForegroundWindow + SetFocus，
       然后立刻解开挂接（不解开会让两个线程共享输入状态，是已知的卡死源）。 */

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    /// <summary>
    /// 把窗口强行提到前台并抢到键盘焦点。返回是否真的成了前台窗口。
    /// 只用于用户刚刚主动点击触发的模态框；不要拿它去抢用户的输入。
    /// </summary>
    public static bool ForceForeground(Window window)
    {
        IntPtr hwnd = GetHwnd(window);
        if (hwnd == IntPtr.Zero)
        {
            return false;
        }

        IntPtr foreground = GetForegroundWindow();
        if (foreground == hwnd)
        {
            return true;
        }

        uint targetThread = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, out _);
        uint selfThread = GetCurrentThreadId();

        bool attached = false;
        if (targetThread != 0 && targetThread != selfThread)
        {
            attached = AttachThreadInput(selfThread, targetThread, true);
        }

        try
        {
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            SetFocus(hwnd);
        }
        finally
        {
            if (attached)
            {
                AttachThreadInput(selfThread, targetThread, false);
            }
        }

        return GetForegroundWindow() == hwnd;
    }

    /// <summary>
    /// 把窗口设为置顶或取消置顶。
    /// 注意：不使用 WS_EX_TOPMOST 样式，只动态改 Z-Order，
    /// 这样全屏应用出现时可以降级（见方案 §8.1）。
    /// </summary>
    public static void SetTopmost(Window window, bool topmost)
    {
        IntPtr hwnd = GetHwnd(window);
        SetWindowPos(hwnd, topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
            0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    /* ==================== 遮挡区弹出（2026-10-26 需求 2） ====================
       面板固定（📌）时，把被面板压住的窗口移出面板区域：
       - 最大化窗口 → 以面板内侧为左边框铺满剩余工作区；
       - 普通窗口   → 左移/压窄，让右边界贴住面板内侧。
       还原靠 Get/SetWindowPlacement 保存的原始摆放（含最大化状态）。 */

    public const int GWL_STYLE = -16;
    public const uint WS_CHILD = 0x40000000;
    public const int GW_OWNER = 4;
    public const int SW_RESTORE = 9;
    public const int SW_SHOWMAXIMIZED = 3;

    /// <summary>
    /// WINDOWPLACEMENT.showCmd 的"最小化"取值。
    /// 2026-11-05：SetsWindowPlacement 会按 showCmd 显示窗口，若某窗口已被用户最小化，
    /// 用改动前的 showCmd（1/3）还原就会把它弹出来并抢前台 —— 见 WindowPushOut.End()。
    /// </summary>
    public const int SW_SHOWMINIMIZED = 2;
    public const uint SWP_NOZORDER = 0x0004;
    public const int DWMWA_CLOAKED = 14;

    /// <summary>窗口摆放信息（user32 WINDOWPLACEMENT），用于改动前存档、取消固定后原样还原。</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT
    {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);

    // 系统设定的双击间隔（毫秒）。WPF 的 MouseButtonEventArgs.ClickCount 就是按它累加的，
    // 我们这里要在自己的手势判定里复用同一个阈值，免得和系统设置不一致。
    [DllImport("user32.dll")]
    public static extern uint GetDoubleClickTime();

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetShellWindow();

    [DllImport("user32.dll")]
    public static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    /// <summary>
    /// 设置窗口属性。DWMWA_USE_IMMERSIVE_DARK_MODE = 20（2022-09 起的正式值，
    /// 在 Windows 11 22H2 / Windows 10 20H1+ 上生效；Windows 10 1809 到 1909 需要用 19）。
    /// 调用失败（旧系统）不影响窗口显示，只是标题栏保持系统默认。
    /// </summary>
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int dwAttribute, ref int pvAttribute, int cbAttribute);

    /// <summary>窗口所在显示器句柄（最近显示器）。</summary>
    public static IntPtr GetMonitorForWindow(IntPtr hwnd) => MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);

    /// <summary>取指定显示器的工作区（已扣除任务栏），单位：设备像素。</summary>
    public static bool TryGetMonitorWorkArea(IntPtr hMonitor, out Rect work)
    {
        work = default;
        if (hMonitor == IntPtr.Zero)
        {
            return false;
        }

        MONITORINFO mi = new() { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(hMonitor, ref mi))
        {
            return false;
        }

        work = new Rect(mi.rcWork.Left, mi.rcWork.Top,
            mi.rcWork.Right - mi.rcWork.Left, mi.rcWork.Bottom - mi.rcWork.Top);
        return true;
    }

    /// <summary>窗口类名（诊断日志用）。</summary>
    public static string ClassNameOf(IntPtr hwnd)
    {
        StringBuilder sb = new(256);
        int n = GetClassName(hwnd, sb, sb.Capacity);
        return n > 0 ? sb.ToString(0, n) : "?";
    }

    /* ==================== 全屏检测（2026-11-08 用户需求） ==================== */
    //
    // 需求："为了避免在全屏游戏等情况下误触拉手，影响游戏体验，
    //       我想在全屏游戏时能临时关闭拉手热区，全屏视频也隐藏。"
    //
    // 用两个互补信号，缺一不可：
    //   ① 几何：前台窗口矩形铺满它所在显示器的 **rcMonitor**（不是工作区）；
    //   ② 系统状态：SHQueryUserNotificationState 报 QUNS_RUNNING_D3D_FULL_SCREEN。
    //
    // 为什么几何要配 rcMonitor 而不是 rcWork：rcWork 是扣掉任务栏后的区域，
    // 普通最大化窗口正好铺满 rcWork —— 拿 rcWork 比会把所有最大化窗口误判成全屏。
    // WindowPushOut.cs:206-212 拿 work 比是因为它还要配 !IsZoomed 反筛，
    // 这里直接比 rcMonitor 更省一层判断（无边框全屏与最大化的真正分野就在任务栏那一条）。
    // 两处判定目标不同，各按各的需要取基准，没有"谁抄谁"的问题。

    /// <summary>
    /// 取指定显示器的**完整矩形**（含任务栏区域）。全屏判定的基准。
    /// </summary>
    public static bool TryGetMonitorRect(IntPtr hMonitor, out Rect monitor)
    {
        monitor = default;
        if (hMonitor == IntPtr.Zero)
        {
            return false;
        }

        MONITORINFO mi = new() { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(hMonitor, ref mi))
        {
            return false;
        }

        monitor = new Rect(mi.rcMonitor.Left, mi.rcMonitor.Top,
            mi.rcMonitor.Right - mi.rcMonitor.Left, mi.rcMonitor.Bottom - mi.rcMonitor.Top);
        return true;
    }

    /// <summary>光标所在显示器句柄（拉手贴在光标那块屏上，判定也必须按那块屏）。</summary>
    public static IntPtr GetMonitorForCursor()
    {
        return GetCursorPos(out POINT p) ? MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST) : IntPtr.Zero;
    }

    /// <summary>
    /// 是否是"桌面本身"那几层 shell 窗口（不是普通应用窗口）。
    /// 桌面/壁纸窗口天然铺满整屏，必须从全屏判定里排除。
    /// </summary>
    public static bool IsShellDesktopWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return false;
        }

        // WorkerW / Progman：壁纸层。点桌面或"显示桌面"后前台会变成它们，
        // 且有多层（顶层 Progman 下面挂 SHELLDLL_DefView，再下面还有 WorkerW）。
        string cls = ClassNameOf(hwnd);
        if (cls == "Progman" || cls == "WorkerW" || cls == "SHELLDLL_DefView"
            || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd")
        {
            return true;
        }

        // 兜底：桌面窗口 / shell 窗口本身
        if (hwnd == GetDesktopWindow() || hwnd == GetShellWindow())
        {
            return true;
        }

        return false;
    }

    /// <summary>
    /// 前台窗口是否在**光标所在显示器**上铺满了整块屏（无边框全屏 / 全屏视频）。
    /// 命中时 <paramref name="hwnd"/> 返回该窗口，便于写诊断日志。
    /// </summary>
    public static bool IsForegroundFullscreenOnCursorMonitor(out IntPtr hwnd, out string reason)
    {
        hwnd = GetForegroundWindow();
        reason = "";

        if (hwnd == IntPtr.Zero)
        {
            reason = "no foreground";
            return false;
        }

        // 自己的窗口（面板 / 拉手）绝不能算全屏，否则拉手会把自己藏起来
        GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id)
        {
            reason = "own process";
            return false;
        }

        if (!IsWindowVisible(hwnd))
        {
            reason = "not visible";
            return false;
        }

        // 2026-11-08 用户实测反馈：切到纯桌面（无任何窗口）时拉手被藏了。
        // 原因是"显示桌面"之后前台窗口变成了资源管理器铺壁纸的那层
        // （WorkerW / Progman），它天生就铺满整块屏 —— 几何判定必然命中，
        // 但它显然不是"全屏应用"，用户这时恰恰需要拉手。
        // 桌面/任务栏这几个 shell 窗口一律不算全屏。
        if (IsShellDesktopWindow(hwnd))
        {
            reason = $"shell desktop ({ClassNameOf(hwnd)})";
            return false;
        }

        // UWP 应用会留下"被隐藏但仍在 Z 序里"的幽灵窗口，几何上看着铺满屏
        try
        {
            if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
            {
                reason = "cloaked";
                return false;
            }
        }
        catch (DllNotFoundException)
        {
            // 老系统没有 dwmapi：跳过这一层，交给几何判定
        }
        catch (EntryPointNotFoundException)
        {
        }

        IntPtr hmon = GetMonitorForCursor();
        if (!TryGetMonitorRect(hmon, out Rect monitor))
        {
            reason = "no monitor rect";
            return false;
        }

        if (!GetWindowRect(hwnd, out RECT r))
        {
            reason = "no window rect";
            return false;
        }

        // 容差 2px：DPI 缩放下 rect 与 monitor 常差 1~2 像素
        bool fills = Math.Abs(r.Left - monitor.Left) <= 2
                     && Math.Abs(r.Top - monitor.Top) <= 2
                     && Math.Abs(r.Right - monitor.Right) <= 2
                     && Math.Abs(r.Bottom - monitor.Bottom) <= 2;

        if (!fills)
        {
            reason = $"rect {r.Left},{r.Top}-{r.Right},{r.Bottom} vs monitor {monitor.Left},{monitor.Top}-{monitor.Right},{monitor.Bottom}";
            return false;
        }

        reason = $"fills {r.Left},{r.Top}-{r.Right},{r.Bottom}";
        return true;
    }

    /// <summary>
    /// 系统是否正处于 D3D 独占全屏（QUNS_RUNNING_D3D_FULL_SCREEN = 3）。
    /// 这类窗口的矩形可能不是整屏（由显示驱动全屏翻转接管），几何判定会漏。
    /// </summary>
    public static bool IsD3DFullscreen()
    {
        try
        {
            int hr = SHQueryUserNotificationState(out int state);
            // S_OK = 0；失败时返回 HRESULT，此时按"不是全屏"处理（保守，不误藏拉手）
            return hr == 0 && state == QUNS_RUNNING_D3D_FULL_SCREEN;
        }
        catch (DllNotFoundException)
        {
            return false;
        }
        catch (EntryPointNotFoundException)
        {
            return false;
        }
    }

    /// <summary>QUNS_RUNNING_D3D_FULL_SCREEN（独占全屏运行中）。</summary>
    public const int QUNS_RUNNING_D3D_FULL_SCREEN = 3;

    [DllImport("shell32.dll")]
    private static extern int SHQueryUserNotificationState(out int pquns);
}
