using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using QuickDrawer.Native;

namespace QuickDrawer;

/// <summary>
/// 抽屉拉手（决策 #5，用户 2026-10-19 需求）：
/// 面板收起时，屏幕右边缘显示一条细的悬浮把手；
/// 鼠标停靠 → 自动展开；鼠标离开 → 自动收起；点击 → 弹出主面板。
///
/// 独立窗口实现（不是一个控件）：
///   - 主面板在屏幕外（Left = work.Right + 4），拉手必须在屏幕内可见；
///   - 两者都要 WS_EX_NOACTIVATE，否则鼠标悬停会抢焦点。
/// </summary>
public partial class HandleWindow : Window
{
    private readonly AppConfig _config;
    private bool _expanded;

    /// <summary>停靠即弹出面板（决策 #5）。</summary>
    private bool _autoExpand = true;

    /// <summary>用户点击拉手时触发（主面板弹出）。</summary>
    public event Action? ClickRequested;

    /// <summary>鼠标进入/离开时的悬停状态变化。</summary>
    public event Action<bool>? HoverChanged;

    /// <summary>鼠标停靠到拉手上（请求主面板弹出）。</summary>
    public event Action? HoverRequested;

    public HandleWindow(AppConfig config)
    {
        _config = config;
        InitializeComponent();

        Width = config.Dock.Handle.WidthPx;
        Height = config.Dock.Handle.HeightPx;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        ShowActivated = false;
    }

    private void Handle_Loaded(object sender, RoutedEventArgs e)
    {
        IntPtr hwnd = NativeMethods.GetHwnd(this);

        // 与主面板一致：NOACTIVATE 保证悬停不抢焦点；TOOLWINDOW 不进 Alt+Tab
        NativeMethods.AddWindowExStyle(this,
            NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW);

        PositionHandle();
        DiagLog.Write("handle", $"loaded, hwnd=0x{hwnd:X8}, pos=({Left},{Top})");
    }

    /// <summary>把拉手贴到屏幕右边缘，垂直居中。</summary>
    private void PositionHandle()
    {
        Rect work = NativeMethods.GetWorkAreaForCursor();

        Left = work.Right - Width;
        Top = work.Top + (work.Height - Height) / 2;
    }

    /* ==================== 悬停展开 / 离开收起 ==================== */

    private void Handle_MouseEnter(object sender, MouseEventArgs e)
    {
        Expand();
        HoverChanged?.Invoke(true);

        // 决策 #5："鼠标停靠自动弹出" —— 停靠即弹出主面板
        if (_autoExpand)
        {
            HoverRequested?.Invoke();
        }
    }

    private void Handle_MouseLeave(object sender, MouseEventArgs e)
    {
        Collapse();
        HoverChanged?.Invoke(false);
    }

    private void Handle_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        ClickRequested?.Invoke();
        e.Handled = true;
    }

    /// <summary>展开：拉长并显示提示图标。</summary>
    private void Expand()
    {
        if (_expanded)
        {
            return;
        }

        _expanded = true;

        Rect work = NativeMethods.GetWorkAreaForCursor();

        DoubleAnimation grow = new()
        {
            From = Width,
            To = 28,
            Duration = TimeSpan.FromMilliseconds(140),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        grow.Completed += (_, _) =>
        {
            // 宽度变了要重新贴边
            Left = work.Right - Width;
        };
        BeginAnimation(WidthProperty, grow);

        HandleGlyph.Visibility = Visibility.Visible;
        HandleGlyph.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)));

        DiagLog.Write("handle", "expanded");
    }

    /// <summary>收起：恢复成细条。</summary>
    private void Collapse()
    {
        if (!_expanded)
        {
            return;
        }

        _expanded = false;

        Rect work = NativeMethods.GetWorkAreaForCursor();

        DoubleAnimation shrink = new()
        {
            From = Width,
            To = _config.Dock.Handle.WidthPx,
            Duration = TimeSpan.FromMilliseconds(160),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
        };
        shrink.Completed += (_, _) =>
        {
            Left = work.Right - Width;
        };
        BeginAnimation(WidthProperty, shrink);

        HandleGlyph.BeginAnimation(OpacityProperty,
            new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(120)));
        HandleGlyph.Visibility = Visibility.Collapsed;

        DiagLog.Write("handle", "collapsed");
    }

    /// <summary>主面板弹出后隐藏拉手（避免重叠）。</summary>
    public void HideForPanel()
    {
        Visibility = Visibility.Hidden;
    }

    /// <summary>主面板收起后显示拉手。</summary>
    public void ShowForPanel()
    {
        PositionHandle();
        Visibility = Visibility.Visible;
    }

    /// <summary>
    /// 设置页改了拉手尺寸后调用：按新配置重新应用并贴边。
    /// </summary>
    public void RefreshSize(AppConfig config)
    {
        if (_expanded)
        {
            // 展开态下改尺寸容易错位：先收回再应用
            Collapse();
        }

        Width = config.Dock.Handle.WidthPx;
        Height = config.Dock.Handle.HeightPx;
        PositionHandle();
        DiagLog.Write("handle", $"resized to {Width}x{Height}");
    }

    /// <summary>
    /// 判断某个屏幕坐标是否"靠近"拉手。
    /// 面板展开时拉手被隐藏，但光标可能还停在拉手原位置 ——
    /// 自动收起判定必须把它算作"仍在面板附近"，否则刚弹出就被收起。
    /// </summary>
    public bool IsNear(int screenX, int screenY)
    {
        Rect work = NativeMethods.GetWorkAreaForCursor();

        double handleLeft = work.Right - _config.Dock.Handle.WidthPx;
        double handleTop = work.Top + (work.Height - _config.Dock.Handle.HeightPx) / 2;
        double handleBottom = handleTop + _config.Dock.Handle.HeightPx;

        const double tolerance = 24;

        return screenX >= handleLeft - tolerance
            && screenX <= work.Right + tolerance
            && screenY >= handleTop - tolerance
            && screenY <= handleBottom + tolerance;
    }
}
