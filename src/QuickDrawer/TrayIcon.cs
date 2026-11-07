using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using QuickDrawer.Native;

namespace QuickDrawer;

/// <summary>
/// 系统托盘图标（M5）。
///
/// 用 Win32 `Shell_NotifyIcon`，不引入 WinForms。
///
/// 消息窗口：`HwndSource` 直接创建一个消息-only 窗口并 AddHook 接收
/// 托盘回调（WM_APP+1，lParam 低位是鼠标消息）。这比手工 CreateWindowEx
/// + SetWindowLongPtr 替换窗口过程简单可靠（第一版就是这么写的，委托
/// 签名对不上，作废）。
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private const uint WM_TRAY_CALLBACK = 0x8000 + 1;   // WM_APP + 1
    private const uint NIM_ADD = 0x0;
    private const uint NIM_DELETE = 0x2;
    private const uint NIF_MESSAGE = 0x1;
    private const uint NIF_ICON = 0x2;
    private const uint NIF_TIP = 0x4;
    private const uint WM_LBUTTONDBLCLK = 0x0203;
    private const uint WM_RBUTTONUP = 0x0205;

    private HwndSource? _source;
    private NOTIFYICONDATA _data;
    private bool _added;

    // CreateIconFromResourceEx 返回的 HICON 归调用方所有，必须 DestroyIcon。
    // Shell_NotifyIcon(NIM_DELETE) 只是让外壳不再显示它，不会释放句柄。
    private IntPtr _hIcon = IntPtr.Zero;

    /// <summary>左键双击：唤出/收起面板。</summary>
    public event Action? DoubleClick;

    /// <summary>右键：请求弹出菜单（参数为屏幕坐标）。</summary>
    public event Action<Point>? MenuRequested;

    public TrayIcon()
    {
        // 消息-only 窗口：不显示、不进任务栏，只用来收托盘回调
        var parameters = new HwndSourceParameters("QuickDrawerTray")
        {
            Width = 0,
            Height = 0,
            WindowStyle = unchecked((int)0x80000000),   // WS_POPUP
            ParentWindow = new IntPtr(-3)   // HWND_MESSAGE：消息-only
        };

        _source = new HwndSource(parameters);
        _source.AddHook(TrayWndProc);

        _data = new NOTIFYICONDATA
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _source.Handle,
            uID = 1,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_TRAY_CALLBACK,
            hIcon = CreateTrayHIcon(),
            szTip = "QuickDrawer"
        };

        _hIcon = _data.hIcon;
        _added = Shell_NotifyIcon(NIM_ADD, ref _data);
        DiagLog.Write("tray", _added
            ? $"icon added (hwnd=0x{_source.Handle:X8})"
            : $"Shell_NotifyIcon failed, err={Marshal.GetLastWin32Error()}");
    }

    private IntPtr TrayWndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_TRAY_CALLBACK)
        {
            return IntPtr.Zero;
        }

        // lParam 低位是鼠标消息（Shell_NotifyIcon 约定）
        uint mouse = unchecked((uint)(long)lParam) & 0xFFFF;

        switch (mouse)
        {
            case WM_LBUTTONDBLCLK:
                DoubleClick?.Invoke();
                handled = true;
                break;

            case WM_RBUTTONUP:
                // 用当前光标位置作为菜单弹出点（比 GetCursorPos 在菜单里再取更稳）
                (int x, int y) = NativeMethods.GetCursorScreenPos();
                MenuRequested?.Invoke(new Point(x, y));
                handled = true;
                break;
        }

        return IntPtr.Zero;
    }

    /// <summary>
    /// 程序化画托盘图标：圆角深色块 + 右侧金色竖条 + 三条抽屉线条。
    /// 图形必须与 assets/QuickDrawer.ico 是同一套（2026-11-06 换标，竖条 #F9C424）——
    /// 这两处是两份独立实现，改一处必须同时改另一处，否则任务栏和托盘会显示两个不同的图标。
    /// 比例全部取自 ico 的 1024px 画布：竖条 x=0.665S，线宽 0.105S，
    /// 三条线 y=0.315/0.475/0.635S、长度 0.40/0.40/0.24S，第三条用灰。
    /// </summary>
    private static IntPtr CreateTrayHIcon()
    {
        int size = GetSystemMetrics(49);   // SM_CXSMICON，通常 16（随 DPI 缩放）
        if (size <= 0)
        {
            size = 16;
        }

        double s = size;
        double radius = s * 0.225;
        double lineH = s * 0.105;
        double lineX = s * 0.125;

        var visual = new DrawingVisual();
        using (DrawingContext dc = visual.RenderOpen())
        {
            // 底色：与 ico 一致的竖直渐变（顶部略亮），纯色在 16px 下显得死板
            var body = new LinearGradientBrush(
                Color.FromRgb(0x2B, 0x30, 0x40),
                Color.FromRgb(0x1A, 0x1E, 0x2A),
                new Point(0, 0),
                new Point(0, 1));
            dc.DrawRoundedRectangle(body, null, new Rect(0, 0, s, s), radius, radius);

            // 右侧竖条：先整条画满再裁剪到圆角内，否则竖条会盖住右侧两个圆角
            dc.PushClip(new RectangleGeometry(new Rect(0, 0, s, s), radius, radius));
            dc.DrawRectangle(
                new SolidColorBrush(Color.FromRgb(0xF9, 0xC4, 0x24)),
                null,
                new Rect(s * 0.665, 0, s * 0.335, s));
            dc.Pop();

            var ink = new SolidColorBrush(Color.FromRgb(0xF7, 0xF9, 0xFC));
            var dim = new SolidColorBrush(Color.FromRgb(0x96, 0xA0, 0xB4));
            foreach ((double top, double len, Brush fill) in new[]
                     {
                         (0.315, 0.40, (Brush)ink),
                         (0.475, 0.40, ink),
                         (0.635, 0.24, dim),
                     })
            {
                dc.DrawRoundedRectangle(
                    fill,
                    null,
                    new Rect(lineX, s * top, s * len, lineH),
                    lineH / 2,
                    lineH / 2);
            }
        }

        var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap(
            size, size, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);

        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        byte[] png = ms.ToArray();

        // PNG 字节 → HICON
        return CreateIconFromResourceEx(png, (uint)png.Length, true, 0x00030000, size, size, 0);
    }

    public void Dispose()
    {
        if (_added)
        {
            _ = Shell_NotifyIcon(NIM_DELETE, ref _data);
            _added = false;
        }

        // 顺序有讲究：外壳已经通过 NIM_DELETE 不再引用这个句柄了，现在才能销毁。
        // 反过来做的话，托盘区可能还在画一个已经释放的图标。
        if (_hIcon != IntPtr.Zero)
        {
            _ = DestroyIcon(_hIcon);
            _hIcon = IntPtr.Zero;
            _data.hIcon = IntPtr.Zero;
        }

        _source?.RemoveHook(TrayWndProc);
        _source?.Dispose();
        _source = null;

        DiagLog.Write("tray", "icon removed");
    }

    // ---- Win32 ----

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr hIcon);


    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;

        public uint dwState;
        public uint dwStateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;

        public uint uTimeoutOrVersion;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;

        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Shell_NotifyIcon(uint dwMessage, ref NOTIFYICONDATA lpData);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreateIconFromResourceEx(byte[] pbiconBits, uint cbIconBits,
        bool fIcon, uint dwVer, int cxDesired, int cyDesired, uint flags);
}