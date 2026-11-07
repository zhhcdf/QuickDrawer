using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Markup;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using QuickDrawer.Native;

namespace QuickDrawer.Selection;

/// <summary>
/// 选中文字后出现的悬浮提示词条（2026-10-30 需求）。
///
/// 关键约束：**不能抢焦点**。用户在别的程序里刚选好文字，
/// 这个条一激活，选区就会消失、原窗口也会失去焦点。
/// 所以：WindowStyle=None + ShowActivated=false + WS_EX_NOACTIVATE + WS_EX_TOOLWINDOW，
/// 用 SetWindowPos 以屏幕像素定位（绕开 DPI 换算），并且永不成为前台窗口。
///
/// 2026-10-31：最左侧加了一个固定「发送」按钮——它不直接发，
/// 而是让上层先弹自定义提示词编辑器（草稿存在 config.assistant.customPrompt）。
/// 按钮在 UIA 里的 Name 固定为 <see cref="SendButtonName"/>，
/// 探针靠它把「发送」和预设 chip 区分开（预设 chip 的 Name 就是它的 Label）。
/// </summary>
internal sealed class SelectionPopup : Window
{
    private const uint WS_EX_NOACTIVATE = 0x08000000;
    private const uint WS_EX_TOOLWINDOW = 0x00000080;
    private static readonly IntPtr HwndTopmost = new(-1);
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoActivate = 0x0010;

    /// <summary>「发送」按钮在 UIA 里的固定 Name（探针与自动化都用它）。</summary>
    public const string SendButtonName = "SendCustomPrompt";

    private readonly StackPanel _row;

    /// <summary>截图模式下的待发图片；文字选择模式恒为 null（2026-11-01 五次需求）。</summary>
    private BitmapSource? _shot;

    /// <summary>当前这次弹出是"截图提问"还是"选中文字"（上层据此决定发什么）。</summary>
    public bool IsShotMode => _shot is not null;

    /// <summary>截图模式下待发的图片；文字选择模式为 null。</summary>
    public BitmapSource? CurrentShot => _shot;

    /// <summary>弹出后多久没有鼠标停靠就自动收起（2026-11-01 四次需求：2 秒）。</summary>
    private const int AutoHideMs = 2000;

    private readonly DispatcherTimer _watch;
    private DateTime _shownAt;
    private bool _hovered;

    /// <summary>自动收起时触发，参数是原因（供上层写 diag 日志，探针靠它断言）。</summary>
    public event Action<string>? AutoHidden;

    /// <summary>用户点了某个提示词。</summary>
    public event Action<PromptPreset>? Chosen;

    /// <summary>用户点了最左侧的「发送」：上层应弹编辑器，改完再发。</summary>
    public event Action? SendRequested;

    public SelectionPopup()
    {
        WindowStyle = WindowStyle.None;
        // 留个标题：探针要靠 EnumWindows/FindWindow 找到这个无边框小窗（对用户不可见）
        Title = "QuickDrawer Selection";
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = -10000;
        Top = -10000;

        _row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(2, 0, 2, 0) };

        // 2026-11-01 四次需求：弹出后 2 秒内鼠标没停靠上来就收起；停靠则保持；
        // 离开即收。用轮询而不是 MouseEnter/MouseLeave —— 这个窗口是
        // WS_EX_NOACTIVATE 的，且弹出瞬间鼠标还在拖动结束点（窗口外），
        // WPF 的进出事件在"从未进入过"和"首次进入"之间不可靠；
        // 光标屏幕坐标是唯一可靠的依据（同 Native.GetCursorScreenPos 的注释）。
        // 80ms 的 2px 级轮询，等待期开销可忽略。
        _watch = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(80)
        };
        _watch.Tick += (_, _) => WatchTick();

        var border = new Border
        {
            CornerRadius = new CornerRadius(9),
            Background = new SolidColorBrush(Color.FromArgb(0xF7, 0xFF, 0xFF, 0xFF)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0x60, 0x60, 0x60)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(4, 3, 4, 3),
            Child = _row,
            Effect = new DropShadowEffect
            {
                BlurRadius = 10,
                ShadowDepth = 2,
                Direction = 270,
                Opacity = 0.18,
                Color = Colors.Black
            }
        };

        Content = border;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        NativeMethods.AddWindowExStyle(this, WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
    }

    /// <summary>截图模式下缩略图在 UIA 里的 Name（探针靠它确认这次是截图模式）。</summary>
    public const string ShotThumbName = "ShotThumbnail";

    /// <summary>在指定屏幕坐标附近弹出。坐标是屏幕像素（左下角对齐光标上方一点点）。</summary>
    public void ShowFor(IReadOnlyList<PromptPreset> prompts, int screenX, int screenY, string selectionPreview)
    {
        BuildAndShow(prompts, null, screenX, screenY, selectionPreview);
    }

    /// <summary>
    /// 截图提问模式的弹出（2026-11-01 五次需求）。
    /// 与文字选择模式的差别只有一处：左边多一个缩略图，让用户确认截的是哪块；
    /// 其余（「发送」+ 预设 chip + 2 秒自动收起）完全一致。
    /// </summary>
    public void ShowForShot(IReadOnlyList<PromptPreset> prompts, BitmapSource shot, int screenX, int screenY)
    {
        BuildAndShow(prompts, shot, screenX, screenY, string.Empty);
    }

    private void BuildAndShow(
        IReadOnlyList<PromptPreset> prompts,
        BitmapSource? shot,
        int screenX,
        int screenY,
        string selectionPreview)
    {
        _shot = shot;
        _row.Children.Clear();

        if (shot is not null)
        {
            // 缩略图：截图往往比提示词条宽得多，先给个 56×34 的预览，
            // ToolTip 里写真实像素尺寸，用户悬停就能确认截到了什么。
            var thumb = new Image
            {
                Source = shot,
                Width = 56,
                Height = 34,
                Stretch = Stretch.UniformToFill,
                ToolTip = $"截图 {shot.PixelWidth} × {shot.PixelHeight} 像素"
            };
            AutomationProperties.SetName(thumb, ShotThumbName);

            // Border 本身不裁剪子元素，圆角靠 Clip 补：否则图像四角会盖住圆角边框。
            var clip = new RectangleGeometry(new Rect(0, 0, 56, 34), 3, 3);
            clip.Freeze();
            _row.Children.Add(new Border
            {
                Width = 58,
                Height = 36,
                Margin = new Thickness(1, 0, 6, 0),
                CornerRadius = new CornerRadius(3),
                BorderThickness = new Thickness(1),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0x60, 0x60, 0x60)),
                Background = new SolidColorBrush(Color.FromArgb(0x14, 0x00, 0x00, 0x00)),
                Clip = clip,
                Child = thumb
            });
        }

        // 最左侧固定「发送」：样式比预设 chip 重一档（蓝底白字），
        // 让人一眼看出它不是"直接发某个预设"，而是"先改一句再发"。
        // 2026-11-01（三次）用户要求"蓝色底纹改成圆角"：WPF 的 Button
        // 没有 CornerRadius 属性，默认模板画的是方角矩形，必须换 Template。
        // 圆角半径取 4，与主面板 chip（ProviderChip）一致，避免悬浮条上
        // 出现两种圆角语言。
        var send = new Button
        {
            Content = "发送",
            FontSize = 12,
            Padding = new Thickness(9, 2, 9, 2),
            Margin = new Thickness(1, 0, 4, 0),
            MinWidth = 34,
            Background = new SolidColorBrush(Color.FromRgb(0x3A, 0x7B, 0xD5)),
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Cursor = System.Windows.Input.Cursors.Hand,
            ToolTip = shot is null ? "自定义提示词后发送" : "输入提示词后发送这张截图",
            Template = CreateRoundedButtonTemplate()
        };
        AutomationProperties.SetName(send, SendButtonName);
        send.Click += (_, _) => SendRequested?.Invoke();
        _row.Children.Add(send);

        // 视觉分隔：一条 1px 竖线，把「发送」和预设 chip 分开
        _row.Children.Add(new Border
        {
            Width = 1,
            Margin = new Thickness(0, 2, 3, 2),
            Background = new SolidColorBrush(Color.FromArgb(0x33, 0x60, 0x60, 0x60))
        });

        foreach (PromptPreset preset in prompts)
        {
            PromptPreset captured = preset;
            var button = new Button
            {
                Content = captured.Label,
                FontSize = 12,
                Padding = new Thickness(9, 2, 9, 2),
                Margin = new Thickness(1, 0, 1, 0),
                MinWidth = 34,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = new SolidColorBrush(Color.FromRgb(0x1F, 0x1F, 0x1F)),
                Cursor = System.Windows.Input.Cursors.Hand,
                ToolTip = string.IsNullOrWhiteSpace(captured.Instruction) ? null : captured.Instruction
            };
            button.Click += (_, _) => Chosen?.Invoke(captured);
            _row.Children.Add(button);
        }

        if (_row.Children.Count == 0)
        {
            return;
        }

        if (!IsVisible)
        {
            Show();
        }

        UpdateLayout();

        // 用 Win32 定位：WPF 的 Left/Top 是 DIP，钩子拿到的是屏幕像素，直接换算容易在多屏/缩放上出错
        IntPtr hwnd = NativeMethods.GetHwnd(this);
        NativeMethods.GetWindowRect(hwnd, out NativeMethods.RECT rect);
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;

        Rect work = NativeMethods.GetWorkAreaForCursor();
        int left = screenX + 8;
        int top = screenY + 12;
        if (left + width > (int)work.Right - 8)
        {
            left = (int)work.Right - width - 8;
        }

        if (top + height > (int)work.Bottom - 8)
        {
            top = screenY - height - 10;
        }

        if (left < (int)work.Left + 4)
        {
            left = (int)work.Left + 4;
        }

        if (top < (int)work.Top + 4)
        {
            top = (int)work.Top + 4;
        }

        NativeMethods.SetWindowPos(hwnd, HwndTopmost, left, top, 0, 0, SwpNoSize | SwpNoActivate);
        _ = selectionPreview; // 预览暂时不用，保留参数方便以后加"选中 N 字"提示

        // 每次弹出都重置计时：上一轮的停靠状态不能沿用到这一轮。
        _shownAt = DateTime.UtcNow;
        _hovered = false;
        _watch.Start();
    }

    /// <summary>
    /// 80ms 一次的自动收起判定（2026-11-01 四次需求）。
    ///
    /// 规则：
    /// 1. 弹条不可见 → 什么都不用做（定时器仍跑着，代价可忽略）；
    /// 2. 光标落在弹条上 → 记 _hovered，保持显示；
    /// 3. 光标离开（曾经停靠过） → 立即收起；
    /// 4. 从未停靠过 → 等满 2 秒再收起。
    ///
    /// 用「曾经停靠过」而不是「当前不在上面就收」：弹出瞬间光标还在拖动结束点
    /// （窗口外），若按后一条判断会立刻收起，等于这个功能永远看不到弹条。
    /// </summary>
    private void WatchTick()
    {
        if (!IsVisible)
        {
            return;
        }

        (int x, int y) = NativeMethods.GetCursorScreenPos();
        if (Contains(x, y))
        {
            _hovered = true;
            return;
        }

        if (_hovered)
        {
            HideAndReport("pointer left");
            return;
        }

        if ((DateTime.UtcNow - _shownAt).TotalMilliseconds >= AutoHideMs)
        {
            HideAndReport("no hover within 2s");
        }
    }

    private void HideAndReport(string reason)
    {
        _watch.Stop();
        HidePopup();
        AutoHidden?.Invoke(reason);
    }

    /// <summary>把窗口藏起来（不销毁，下次直接复用）。</summary>
    public void HidePopup()
    {
        _watch.Stop();
        _hovered = false;
        if (IsVisible)
        {
            Hide();
        }
    }

    /// <summary>
    /// 「发送」按钮的圆角模板（2026-11-01 三次需求）。
    ///
    /// WPF 的 <see cref="Button"/> 没有 CornerRadius 属性——圆角只能靠换
    /// <see cref="ControlTemplate"/> 实现。这里用 XamlReader 解析一段模板字符串
    /// （比手搓 FrameworkElementFactory 可读得多），模板实例在多个悬浮条批次间
    /// 复用（ControlTemplate 是可共享的），只在首次用到时解析一次。
    ///
    /// 悬停/按下用更亮/更深的蓝，保持"这是按钮"的反馈；圆角半径 4 与主面板的
    /// ProviderChip 一致。
    /// </summary>
    private static ControlTemplate CreateRoundedButtonTemplate()
    {
        const string xaml = """
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                             TargetType="Button">
                <!-- xmlns:x 绝不能省：下面的 x:Name 依赖它，缺一行就在运行期抛
                     "'x' is an undeclared prefix"（构建期查不出来——这段是
                     XamlReader 解析的字符串，编译器看不到）。 -->
                <Border x:Name="Bd"
                        CornerRadius="4"
                        Background="{TemplateBinding Background}"
                        BorderThickness="0"
                        Padding="{TemplateBinding Padding}"
                        SnapsToDevicePixels="True">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Bd" Property="Background" Value="#FF4B8BE0"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="Bd" Property="Background" Value="#FF2F6BC0"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
            """;

        return (ControlTemplate)XamlReader.Parse(xaml);
    }

    public (int Left, int Top, int Right, int Bottom) ScreenRect()
    {
        if (!IsVisible)
        {
            return (0, 0, 0, 0);
        }

        IntPtr hwnd = NativeMethods.GetHwnd(this);
        if (!NativeMethods.GetWindowRect(hwnd, out NativeMethods.RECT rect))
        {
            return (0, 0, 0, 0);
        }

        return (rect.Left, rect.Top, rect.Right, rect.Bottom);
    }

    public bool Contains(int x, int y)
    {
        (int left, int top, int right, int bottom) = ScreenRect();
        return right > left && x >= left && x <= right && y >= top && y <= bottom;
    }
}
