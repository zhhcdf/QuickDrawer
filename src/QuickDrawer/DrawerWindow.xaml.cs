using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using QuickDrawer.Assistant;
using QuickDrawer.Native;
using QuickDrawer.Selection;

namespace QuickDrawer;

/// <summary>
/// 抽屉主窗口。面板框架见 docs/可行性方案.md §8.0。
/// </summary>
public partial class DrawerWindow : Window
{
    private const int HotkeyIdToggle = 1;

    /// <summary>
    /// 截图提问热键的注册 id（2026-11-01 七次）。必须与 <see cref="HotkeyIdToggle"/> 不同：
    /// WM_HOTKEY 只带 id 不带"是哪个键"，id 撞了就没法区分是哪一路触发。
    /// </summary>
    private const int HotkeyIdShot = 2;

    private readonly AppConfig _config;
    private ShortcutsData _data;
    private HwndSource? _source;

    private bool _isOpen;
    private string _activeHotkey = "(未注册)";

    /// <summary>
    /// 本次运行**实际**注册成功的唤出热键。
    /// 首选组合被别的程序占用时会自动降级到备选，此时它和配置里的值不一样；
    /// 设置页需要把它显示出来，否则用户以为自己在用 Alt+N，其实用的是 Win+Shift+V。
    /// </summary>
    public string ActiveHotkeyLabel => _activeHotkey;

    /// <summary>
    /// 面板固定（2026-10-25 需求）：顶部栏 📌 按钮激活后，鼠标离开面板也不自动收起。
    /// 状态存 config.Dock.PinPanel，重启后保持。
    /// </summary>
    private bool _panelPinned;

    /// <summary>
    /// 面板固定期间把被压住的窗口弹出遮挡区（2026-10-26 需求 2）。
    /// 只在"已固定 + 面板展开"时看守，取消固定后还原原摆放。
    /// </summary>
    private readonly WindowPushOut _pushOut = new();

    /// <summary>选中文字 → 悬浮提示词 → 发给助手（2026-10-30 需求）。</summary>
    private SelectionWatcher? _selection;

    // 智能助手页（2026-10-26 需求）：懒加载的 WebView2 宿主，没点过助手页就完全不占内存。
    private AssistantService? _assistant;

    /// <summary>
    /// 助手页可见时按"已固定"对待：用户在网页里打字，鼠标难免滑出面板，
    /// 那种时候自动收起会把正在输入的对话打断，所以只要助手页在前台就不收起。
    /// </summary>
    private bool _assistantHold;
    private bool _assistantVisible;

    /// <summary>程序化切换站点 chip 时用来防止 Checked 递归。</summary>
    private bool _syncingChips;

    // 绑定源
    private readonly ObservableCollection<AppTileViewModel> _apps = new();
    private readonly ObservableCollection<CategoryViewModel> _categories = new();

    // 决策 #7：剪贴板未读角标计数
    private int _clipboardUnread;

    // M2：剪贴板服务
    private ClipboardService? _clipboard;

    // 2026-10-25：点击历史记录后自动粘贴 —— 记住"抽屉外的最后一个前台窗口"。
    // 用户点进面板时前台已经变成我们，所以要在面板显示/轮询时持续记录。
    private IntPtr _pasteTarget;
    private DateTime _lastPasteAt = DateTime.MinValue;

    // 抽屉拉手（决策 #5）
    private HandleWindow? _handle;

    // 2026-11-08 用户需求：全屏游戏 / 全屏视频时隐藏拉手，退出全屏自动恢复。
    private System.Windows.Threading.DispatcherTimer? _fullscreenTimer;
    private bool _handleSuppressedByFullscreen;
    private bool _handleVisible;

    // M4：便签卡片集合
    private NotesViewModel _notes = null!;

    // M5：系统托盘图标
    private TrayIcon? _tray;

    // M5：设置页（单实例，避免重复打开）
    private SettingsWindow? _settingsWindow;

    // 决策 #5：自动收起的轮询计时器
    private System.Windows.Threading.DispatcherTimer? _autoHideTimer;

    // 2026-11-03 用户需求：面板底部仪表盘（CPU / 内存 / 网速）采样器与刷新计时器
    private DashboardSampler? _dashboard;
    private System.Windows.Threading.DispatcherTimer? _dashboardTimer;

    // 光标最近一次是否在面板内 / 离开面板的时刻
    private bool _lastCursorInside;
    private DateTime _cursorLeftAt = DateTime.Now;



    // 剪贴板列表绑定源
    private readonly ObservableCollection<ClipEntry> _clipItems = new();

    /* ---------- 2026-11-01（发布前审查 B3）：搜索过滤 ---------- */

    /// <summary>当前搜索词（已 Trim）。空串表示未搜索。</summary>
    private string _searchQuery = string.Empty;

    /// <summary>
    /// 搜索期间 ListBox 的临时数据源。搜索结束时置回 null 并把
    /// ItemsSource 还原成 _clipItems / _notes.Cards。
    /// 之所以不在原集合上就地过滤：那 9 处索引级增删（RemoveAt/Insert）
    /// 一旦和过滤视图共用集合，索引就会和全量数据错位。
    /// </summary>
    private ObservableCollection<ClipEntry>? _clipFilterView;
    private ObservableCollection<NoteCardViewModel>? _noteFilterView;

    /// <summary>每个分类的全量路径项快照（key = 分类 Id）。仅在搜索期间存在。</summary>
    private readonly Dictionary<string, List<PathItemViewModel>> _allPathItems = new();

    public DrawerWindow(AppConfig config)
    {
        InitializeComponent();
        _config = config;
        Width = _config.Dock.Width;
        ApplyNoteFontSize();

        // 滑出时不激活（不抢焦点）；用户点击时仍会正常激活并接受键盘输入。
        // 2026-10-21：与"移除 WS_EX_NOACTIVATE"配套 —— 前者负责不抢，
        // 后者负责可点。两者缺一都会导致便签打不上字。
        ShowActivated = false;

        _data = ShortcutStore.Load();

        AppsList.ItemsSource = _apps;
        CategoriesList.ItemsSource = _categories;
        ClipboardList.ItemsSource = _clipItems;

        // 载入已保存的剪贴板历史（已 DPAPI 解密）
        foreach (ClipEntry e in ClipboardStore.Load())
        {
            _clipItems.Add(e);
        }

        // 便签（M4 卡片化）：载入并绑定
        _notes = new NotesViewModel(SaveNotesToDisk);
        NotesList.ItemsSource = _notes.Cards;
        _notes.LoadFrom(NoteStore.Load());
        _notes.Cards.CollectionChanged += (_, _) =>
        {
            UpdateNotesEmptyState();
            RefreshFilterViewsIfSearching();
        };

        // B3：搜索激活时，底层集合的任何增删都要反映到过滤视图上，
        // 否则搜索结果会停留在旧快照（新增的条目搜不到、删掉的还在）。
        _clipItems.CollectionChanged += (_, _) => RefreshFilterViewsIfSearching();

        RebuildBindings();
    }

    /* ==================== 窗口生命周期 ==================== */

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        IntPtr hwnd = NativeMethods.GetHwnd(this);

        // 关键（2026-10-21 修正）：
        // 不要再用 WS_EX_NOACTIVATE —— 它使窗口**无法通过点击激活**，
        // 而窗口不激活就收不到键盘输入，结果就是便签"没有光标、打不上字"。
        //
        // 原来的需求"滑出时不抢焦点"改由 ShowAnimated() 里的
        // "记录前台窗口 → Show() → 若被抢走则还原"来保证，
        // 这样既不会抢焦点，用户点击时又能正常激活并输入。
        //
        // WS_EX_TOOLWINDOW 保留：不进 Alt+Tab（拉手窗口仍保留 NOACTIVATE）。
        NativeMethods.AddWindowExStyle(this, NativeMethods.WS_EX_TOOLWINDOW);

        _source = HwndSource.FromHwnd(hwnd);
        _source?.AddHook(WndProc);

        // 支持从资源管理器拖入（决策 #8）
        AllowDrop = true;
        Drop += Drawer_Drop;
        DragOver += Drawer_DragOver;

        RegisterHotkeyWithFallback();

        // M2：启动剪贴板监听
        _clipboard = new ClipboardService(_config);
        _clipboard.EntryCaptured += Clipboard_EntryCaptured;
        _clipboard.EntryEvicted += Clipboard_EntryEvicted;

        // 2026-10-25：把磁盘载入的历史交给服务托管，容量控制才看得到全量，
        // 锁定条目也才会真正被保护（否则只统计本次运行新捕获的条目）。
        _clipboard.Seed(_clipItems);

        _clipboard.Start(hwnd, _source);

        PositionOffscreen();

        // 2026-10-25 需求 1：恢复"面板固定"状态（固定在先，ShowAnimated 里就不会挂上自动收起）
        _panelPinned = _config.Dock.PinPanel;
        UpdatePinPanelVisual();

        // 2026-10-26：助手页的"加宽"只有停在助手页才生效，启动时一律回到 dock.width
        UpdateAssistantWidenVisual();

        // 2026-10-30 需求：任何地方选中文字后弹提示词按钮
        StartSelectionWatcher();

        ShowAnimated();

        // 抽屉拉手（决策 #5）：主面板收起时贴在屏幕右边缘
        if (_config.Dock.Handle.Enabled)
        {
            _handle = new HandleWindow(_config);
            _handle.ClickRequested += () => Dispatcher.Invoke(ShowAnimated);
            _handle.HoverRequested += () => Dispatcher.Invoke(ShowAnimated);
            _handle.Show();

            // 2026-11-08：ShowAnimated() 在上面已经跑过（那会儿 _handle 还是 null），
            // 所以这里先按"已显示"记账，再让统一判定点决定它到底该不该露出来
            // —— 面板正开着就不该露，全屏中也不该露。
            _handleVisible = true;
            StartFullscreenWatch();
            UpdateHandleVisibility();
        }

        // M5：系统托盘图标
        _tray = new TrayIcon();
        _tray.DoubleClick += () => Dispatcher.Invoke(Toggle);
        _tray.MenuRequested += point => Dispatcher.Invoke(() => OpenAppMenu(null, point));

        // M5：开机自启 —— 配置说开就开（启动时同步一次注册表）
        // M13：先修一次过期路径。用户把 exe 挪了位置、或换版本后路径变了，
        // 注册表那条会一直指向旧位置，开机静默失败且没有任何提示。
        AutoStart.RepairIfStale();

        if (_config.StartWithWindows && !AutoStart.IsEnabled())
        {
            AutoStart.SetEnabled(true);
        }

        // 2026-10-23 修复"列表排列形式没有了"：
        // RebuildBindings() 在构造器里调用 ApplyPathLayout()，但那时 IsLoaded=false
        // → 直接 return，切换按钮 Content 从未设置（空白）。
        // Load 后 IsLoaded=true，这里再应用一次，按钮图标与列表/图标内容才会就位。
        ApplyPathLayout();

        // 2026-10-24：恢复用户上次拖动的分隔位置
        RestoreSplitter();

        DiagLog.Write("DrawerWindow loaded",
            $"hwnd=0x{hwnd:X8} hotkey={_activeHotkey} " +
            $"workArea={NativeMethods.GetWorkAreaForCursor()} " +
            $"apps={_apps.Count} categories={_categories.Count} " +
            $"clips={_clipItems.Count} isOpen={_isOpen} " +
            $"pinned={_panelPinned} " +
            $"handle={_handle is not null}");
    }

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        // 退出前保存数据（便签 + 快捷方式 + 剪贴板历史）
        SaveAll();

        StopDashboard();

        // 2026-11-08：全屏轮询必须停掉。DispatcherTimer 会把窗口对象钉在
        // Dispatcher 上，不停就一直有回调往已经关掉的窗口里跑。
        StopFullscreenWatch();
        // 被"遮挡区弹出"挪动过的窗口必须先还原，否则用户看到的布局会停在挪动后的状态
        _pushOut.End();
        NativeMethods.UnregisterGlobalHotkey(this, HotkeyIdToggle);

        // WebView2 的浏览器进程是独立的，必须显式释放，否则主进程退出后它可能残留
        _assistant?.Dispose();
        _assistant = null;

        // 全局鼠标钩子也要摘掉，否则进程退出时低级钩子会拖着一条空线程
        _selection?.Dispose();
        _selection = null;

        if (_clipboard is not null)
        {
            _clipboard.EntryCaptured -= Clipboard_EntryCaptured;
            _clipboard.EntryEvicted -= Clipboard_EntryEvicted;
            _clipboard.Dispose();
        }

        if (_handle is not null)
        {
            _handle.Close();
            _handle = null;
        }

        if (_tray is not null)
        {
            _tray.Dispose();
            _tray = null;
        }

        _source?.RemoveHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case NativeMethods.WM_HOTKEY when wParam.ToInt32() == HotkeyIdToggle:
                Toggle();
                handled = true;
                break;

            // 2026-11-01 七次：截图热键。与唤出热键共用 WM_HOTKEY，靠 id 区分。
            case NativeMethods.WM_HOTKEY when wParam.ToInt32() == HotkeyIdShot:
                _ = TakeScreenshotAsync("hotkey");
                handled = true;
                break;

            case NativeMethods.WM_CLIPBOARDUPDATE:
                // 剪贴板通知由 ClipboardService 自己挂钩处理（它自己 AddHook），
                // 这里不再重复处理，否则一条记录会被捕获两次。
                break;

            case NativeMethods.WM_DPICHANGED:
                if (_isOpen)
                {
                    PositionOpen();
                }
                else
                {
                    PositionOffscreen();
                }
                handled = true;
                break;
        }

        return IntPtr.Zero;
    }

    /* ==================== 抽屉滑出 / 收起 ==================== */

    public void Toggle()
    {
        if (_isOpen)
        {
            HideAnimated();
        }
        else
        {
            ShowAnimated();
        }
    }

    private void ShowAnimated()
    {
        Rect work = NativeMethods.GetWorkAreaForCursor();
        double targetLeft = work.Right - ActualWidth;

        if (!_isOpen)
        {
            Left = work.Right + 4;
            Top = work.Top;
            Height = work.Height;
        }

        NativeMethods.SetTopmost(this, true);

        // 滑出时不抢焦点（2026-10-21）：
        // 记下当前前台窗口，Show() 之后若前台被抢到本窗口就还原回去。
        // 这样"滑出不打断用户输入"与"点击可激活并输入"两者兼得 ——
        // 之前用 WS_EX_NOACTIVATE 实现前者，代价是后者永远做不到。
        IntPtr prevForeground = NativeMethods.GetForegroundWindow();
        IntPtr self = NativeMethods.GetHwnd(this);

        // 2026-10-25：把"抽屉外的前台窗口"记成粘贴目标。
        // 一旦用户点进面板，前台就变成我们自己了，那时再取就晚了。
        if (prevForeground != IntPtr.Zero && prevForeground != self && !IsOwnWindow(prevForeground))
        {
            _pasteTarget = prevForeground;
        }

        Show();

        IntPtr nowForeground = NativeMethods.GetForegroundWindow();
        if (nowForeground == self && prevForeground != IntPtr.Zero && prevForeground != self)
        {
            NativeMethods.SetForegroundWindow(prevForeground);
            DiagLog.Write("show", $"restored foreground 0x{prevForeground.ToInt64():X} (Show() had taken it)");
        }

        DoubleAnimation anim = new()
        {
            From = work.Right + 4,
            To = targetLeft,
            Duration = TimeSpan.FromMilliseconds(180),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        BeginAnimation(Window.LeftProperty, anim);

        _isOpen = true;

        // 面板展开时隐藏拉手，避免和面板重叠。
        // 2026-11-08：改走统一判定点，不要再直接调 HideForPanel —— 否则
        // _handleVisible 会和真实可见性脱节，全屏恢复时判断会错。
        UpdateHandleVisibility();

        // 决策 #5：启动自动收起监测（鼠标离开面板 800ms 后收起）
        StartAutoHideWatch();

        // 2026-10-26 需求 2：面板固定时把被压住的窗口弹出遮挡区
        RefreshPushOut();

        // 2026-11-03：面板展开才开始采仪表盘数据，收起时停掉
        StartDashboard();

        DiagLog.Write("show", $"animating Left {work.Right + 4} -> {targetLeft}, top={Top}, height={Height}");
    }

    public void HideAnimated()
    {
        if (!_isOpen)
        {
            return;
        }

        StopAutoHideWatch();

        // 2026-10-26 需求 2：面板收起 → 立刻把被挪动的窗口还原（不等动画结束）。
        _pushOut.End();

        Rect work = NativeMethods.GetWorkAreaForCursor();

        DoubleAnimation anim = new()
        {
            From = Left,
            To = work.Right + 4,
            // 收起比展开略快：2026-10-20 用户反馈"收起速度可以稍微快一点点"
            Duration = TimeSpan.FromMilliseconds(140),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
        };
        anim.Completed += (_, _) =>
        {
            // 2026-11-05 用户反馈：收起面板会把一个早已最小化的窗口激活显示。
            // 机理：base.Hide() 之后系统要把前台交给 Z 序下一个候选窗口，
            // 若候选里只剩最小化窗口，系统会把它恢复出来。
            // 对策：在隐藏自己之前，主动把前台交还给用户真正在用的窗口
            // （_pasteTarget = 打开面板前的前台窗口）。这时本进程是前台，
            // SetForegroundWindow 必然成功；交还之后 Hide() 不再触发前台重选。
            HandForegroundBack("hide");

            base.Hide();
            _isOpen = false;

            // 面板收起后显示拉手 —— 但全屏抑制期间不能弹出来，
            // 所以同样走统一判定点（2026-11-08）。
            UpdateHandleVisibility();

            // 2026-11-03：没人看着时不该继续每秒采样（省电、也免得 WMI 线程白跑）
            StopDashboard();

            DiagLog.Write("hide", "drawer collapsed");
        };
        BeginAnimation(Window.LeftProperty, anim);
    }

    /// <summary>
    /// 隐藏面板之前/之后，把前台交还给用户真正在用的窗口（2026-11-05）。
    ///
    /// 背景：面板一 Hide，系统就要把前台交给 Z 序里的下一个候选窗口；
    /// 候选里若只剩最小化窗口，系统会把它们**恢复并显示**，
    /// 用户看到的就是"收起面板把我最小化的窗口弹出来了"。
    /// 只要在隐藏前主动把前台交还给 <see cref="_pasteTarget"/>
    /// （= 打开面板前的前台窗口），这个重选过程就不会发生。
    ///
    /// 只在"前台仍然是我们自己"时动手：用户已经切到别处时插一脚就是抢焦点。
    /// </summary>
    private void HandForegroundBack(string reason)
    {
        IntPtr self = NativeMethods.GetHwnd(this);
        IntPtr foreground = NativeMethods.GetForegroundWindow();
        if (self == IntPtr.Zero || foreground != self)
        {
            return;
        }

        RestoreForeground(_pasteTarget, reason);
    }

    /// <summary>
    /// 把前台还给 <paramref name="target"/>，并逐条排除不该成为目标的窗口：
    /// 已销毁、属于本进程、已最小化（交还给它等于亲手把它弹出来）。
    /// </summary>
    private void RestoreForeground(IntPtr target, string reason)
    {
        IntPtr self = NativeMethods.GetHwnd(this);
        if (target == IntPtr.Zero || target == self || IsOwnWindow(target) || !NativeMethods.IsWindow(target))
        {
            return;
        }

        if (NativeMethods.GetForegroundWindow() == target)
        {
            return;
        }

        if (NativeMethods.IsIconic(target))
        {
            DiagLog.Write("hide",
                $"{reason}: skip foreground handback, target 0x{target.ToInt64():X} is minimized");
            return;
        }

        if (NativeMethods.SetForegroundWindow(target))
        {
            DiagLog.Write("hide", $"{reason}: handed foreground back to 0x{target.ToInt64():X}");
        }
        else
        {
            DiagLog.Write("hide",
                $"{reason}: SetForegroundWindow(0x{target.ToInt64():X}) refused (Windows foreground lock)");
        }
    }

    private void PositionOffscreen()
    {
        Rect work = NativeMethods.GetWorkAreaForCursor();
        BeginAnimation(Window.LeftProperty, null);
        Left = work.Right + 4;
        Top = work.Top;
        Height = work.Height;
    }

    private void PositionOpen()
    {
        Rect work = NativeMethods.GetWorkAreaForCursor();
        BeginAnimation(Window.LeftProperty, null);
        Left = work.Right - ActualWidth;
        Top = work.Top;
        Height = work.Height;
    }

    /* ==================== 热键注册（带降级） ==================== */

    /// <summary>面板当前是否展开（设置页用）。</summary>
    public bool IsOpen => _isOpen;

    /// <summary>按当前宽度重新贴边（设置页改宽度时用）。</summary>
    /* ==================== 便签字号（2026-11-03 用户需求） ==================== */

    /// <summary>便签正文字号下限 / 上限（DIP）。</summary>
    public const double NoteFontSizeMin = 10;
    public const double NoteFontSizeMax = 20;

    /// <summary>
    /// 把 <see cref="NotesConfig.FontSize"/> 写进 App 级资源，
    /// 卡片正文（<c>NoteBodyText</c> 阅读态与 <c>NoteBodyEditor</c> 编辑态）
    /// 都用 <c>DynamicResource</c> 取它，改一次全部即时生效。
    ///
    /// 行高必须跟着字号一起算：阅读态 TextBlock 用的是
    /// <c>LineStackingStrategy="BlockLineHeight"</c> + 显式 <c>LineHeight</c>，
    /// 字号涨了而 LineHeight 不动的话，每行文字会被行高裁掉下半截。
    /// 比例取自历史真实值 20 / 12。
    ///
    /// 正文区 MaxHeight 也同步放大，否则字号一大，能看到的行数骤减；
    /// 上限 240 DIP，避免单张卡片把整个便签区吃满。
    /// </summary>
    public void ApplyNoteFontSize()
    {
        double size = _config.Notes.FontSize;
        if (size < NoteFontSizeMin) size = NoteFontSizeMin;
        if (size > NoteFontSizeMax) size = NoteFontSizeMax;

        // 20 / 12 = 1.6667：历史字号 12 配行高 20，按同比例缩放。
        double lineHeight = Math.Round(size * 20.0 / 12.0, MidpointRounding.AwayFromZero);
        double maxHeight = Math.Min(Math.Round(size * 12.5, MidpointRounding.AwayFromZero), 240);

        ResourceDictionary res = Application.Current.Resources;
        res["NoteBodyFontSize"] = size;
        res["NoteBodyLineHeight"] = lineHeight;
        res["NoteBodyMaxHeight"] = maxHeight;

        DiagLog.Write("notes", $"note font size = {size}, line height = {lineHeight}, max height = {maxHeight}");
    }

    public void RepositionOpen()
    {
        if (_isOpen)
        {
            PositionOpen();
        }
    }

    /// <summary>
    /// 重新计算助手页的"宽度倍数 → 网页缩放"（设置页改常规宽度时用，2026-10-31）。
    /// </summary>
    public void RefreshAssistantZoom()
    {
        ApplyAssistantZoomScale(Width);
    }

    /// <summary>
    /// 按当前配置重新注册热键（设置页改热键后用）。
    /// 返回 null 表示成功，否则为失败原因。
    /// </summary>
    public string? ReregisterHotkey()
    {
        // 先注销旧的
        NativeMethods.UnregisterGlobalHotkey(this, HotkeyIdToggle);

        try
        {
            if (!TryParseVk(_config.Hotkey.Key, out uint vk))
            {
                return "无效按键名";
            }

            uint mods = 0;
            foreach (string m in _config.Hotkey.Mods)
            {
                mods |= m.ToLowerInvariant() switch
                {
                    "alt" => NativeMethods.MOD_ALT,
                    "ctrl" or "control" => NativeMethods.MOD_CONTROL,
                    "shift" => NativeMethods.MOD_SHIFT,
                    "win" => NativeMethods.MOD_WIN,
                    _ => 0u
                };
            }

            NativeMethods.RegisterGlobalHotkey(this, HotkeyIdToggle,
                mods | NativeMethods.MOD_NOREPEAT, vk);
            _activeHotkey = FormatHotkey(mods, vk);
            DiagLog.Write("hotkey", $"re-registered {_activeHotkey}");

            // 2026-11-01 七次：唤出热键改了之后，截图热键可能刚好落到同一个组合键上，
            // 而 RegisterHotKey 的冲突判定只在注册那一刻有效 —— 不在这里复核一次，
            // 用户会看到"设置里两个键不一样，但按截图键弹出的是面板"。
            _ = RegisterShotHotkey();

            return null;
        }
        catch (InvalidOperationException)
        {
            // 新热键被占用 → 恢复候选链注册（尽量有热键可用）
            RegisterHotkeyWithFallback();
            return "组合键被其他程序占用";
        }
    }

    private void RegisterHotkeyWithFallback()
    {
        TryRegisterToggleHotkey();

        // 2026-11-01 七次：截图热键单列一路，注册失败只影响截图，不拖累唤出抽屉。
        RegisterShotHotkey();
    }

    /// <summary>
    /// 注册/重注册截图提问热键。返回 null 表示成功（或按配置不启用），否则是失败原因。
    ///
    /// 与唤出热键不同，这里**没有备选链**：截图键是辅助入口，被占用时
    /// 静默降级（只留工具栏那个按钮）比占用一个用户没选的组合键更合理。
    /// </summary>
    public string? RegisterShotHotkey()
    {
        // 先注销旧的，避免改键后旧的还占着
        NativeMethods.UnregisterGlobalHotkey(this, HotkeyIdShot);

        HotkeyConfig cfg = _config.ShotHotkey;
        if (string.IsNullOrWhiteSpace(cfg.Key))
        {
            DiagLog.Write("hotkey", "shot hotkey disabled by config");
            return null;
        }

        if (!TryParseVk(cfg.Key, out uint vk))
        {
            DiagLog.Write("hotkey", $"shot hotkey has an invalid key '{cfg.Key}', not registered");
            return "无效按键名";
        }

        // 与唤出热键完全相同就不注册：同一组合键注册两次必然第二个失败，
        // 而且 WM_HOTKEY 会落到第一个（toggle）上，表现为"截图键唤出面板"。
        if (IsSameHotkey(cfg, _config.Hotkey))
        {
            DiagLog.Write("hotkey", "shot hotkey equals the toggle hotkey, not registered");
            return "与唤出热键相同";
        }

        try
        {
            NativeMethods.RegisterGlobalHotkey(this, HotkeyIdShot,
                BuildModifiers(cfg.Mods) | NativeMethods.MOD_NOREPEAT, vk);
            DiagLog.Write("hotkey", $"shot hotkey registered {FormatHotkey(BuildModifiers(cfg.Mods), vk)}");
            return null;
        }
        catch (InvalidOperationException)
        {
            DiagLog.Write("hotkey", "shot hotkey occupied by another program, screenshot hotkey unavailable");
            return "组合键被其他程序占用";
        }
    }

    private static uint BuildModifiers(IEnumerable<string> mods)
    {
        uint value = 0;
        foreach (string m in mods)
        {
            value |= m.ToLowerInvariant() switch
            {
                "alt" => NativeMethods.MOD_ALT,
                "ctrl" or "control" => NativeMethods.MOD_CONTROL,
                "shift" => NativeMethods.MOD_SHIFT,
                "win" => NativeMethods.MOD_WIN,
                _ => 0u
            };
        }

        return value;
    }

    /// <summary>比较两套热键配置是否等价（修饰键按集合比，key 忽略大小写）。</summary>
    private static bool IsSameHotkey(HotkeyConfig a, HotkeyConfig b)
    {
        if (!string.Equals(a.Key?.Trim(), b.Key?.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return BuildModifiers(a.Mods) == BuildModifiers(b.Mods);
    }

    private void TryRegisterToggleHotkey()
    {
        if (!TryParseVk(_config.Hotkey.Key, out uint vk))
        {
            vk = 0x4E; // 'N'
        }

        uint baseMods = 0;
        foreach (string m in _config.Hotkey.Mods)
        {
            baseMods |= m.ToLowerInvariant() switch
            {
                "alt" => NativeMethods.MOD_ALT,
                "ctrl" or "control" => NativeMethods.MOD_CONTROL,
                "shift" => NativeMethods.MOD_SHIFT,
                "win" => NativeMethods.MOD_WIN,
                _ => 0u
            };
        }

        var candidates = new List<(uint mods, uint vk, string label)>
        {
            (baseMods, vk, FormatHotkey(baseMods, vk)),
            (NativeMethods.MOD_WIN | NativeMethods.MOD_SHIFT, 0x56, "Win+Shift+V"),
            (NativeMethods.MOD_WIN | NativeMethods.MOD_ALT, 0x51, "Win+Alt+Q"),
            (NativeMethods.MOD_WIN | NativeMethods.MOD_ALT, 0x4D, "Win+Alt+M"),
            (NativeMethods.MOD_CONTROL | NativeMethods.MOD_ALT, 0x4E, "Ctrl+Alt+N"),
        };

        foreach (var (m, k, label) in candidates)
        {
            try
            {
                NativeMethods.RegisterGlobalHotkey(this, HotkeyIdToggle,
                    m | NativeMethods.MOD_NOREPEAT, k);
                _activeHotkey = label;
                DiagLog.Write("hotkey", $"registered {label}");
                return;
            }
            catch (InvalidOperationException)
            {
                continue;
            }
        }

        _activeHotkey = "(注册失败)";
        DiagLog.Write("hotkey", "ALL candidate hotkeys were occupied");
        MessageBox.Show(this,
            "所有备选热键均被其他程序占用。\n\n本次运行可用鼠标点击屏幕右边缘唤出抽屉，\n或在设置里更换热键后重启。",
            "QuickDrawer 热键注册失败", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    /* ==================== M3：拖拽重排 ==================== */

    // 应用区
    private void AppsList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        DragReorder.OnPreviewMouseLeftButtonDown(sender, e);
    }

    private void AppTile_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        DragReorder.OnPreviewMouseLeftButtonDown(sender, e);
    }

    private void AppsList_DragEnter(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
        e.Handled = true;
    }

    private void AppsList_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy
            : DragDropEffects.Move;
        e.Handled = true;
    }

    /// <summary>从资源管理器拖应用到应用区：加入应用列表；内部拖动则重排。</summary>
    private void AppsList_Drop(object sender, DragEventArgs e)
    {
        // ---- 内部重排（应用区） ----
        if (e.Data.GetData(DragReorder.DragFormat) is Button { DataContext: AppTileViewModel source })
        {
            ReorderAppInGrid(source, (ListBox)sender, e);
            return;
        }

        // ---- 从资源管理器拖文件进来 ----
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files)
        {
            return;
        }

        int added = 0;
        foreach (string file in files)
        {
            var item = ShortcutStore.Classify(file);
            if (item.Kind != "app")
            {
                continue;
            }

            if (_data.Apps.Any(a => a.Target.Equals(item.Target, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            item.Order = _data.Apps.Count;
            _data.Apps.Add(item);
            added++;
        }

        if (added > 0)
        {
            RebuildBindings();
            SaveAll();
            DiagLog.Write("drop", $"added {added} apps to app area");
        }
    }

    /// <summary>
    /// 应用区重排：按容器几何位置算插入下标。
    /// 与路径区同一套逻辑（DropPosition），保证"位移小 + 能放到末尾"。
    /// </summary>
    private void ReorderAppInGrid(AppTileViewModel source, ListBox host, DragEventArgs e)
    {
        Panel? panel = DropPosition.GetItemsPanel(host);
        if (panel is null)
        {
            return;
        }

        Point point = e.GetPosition(panel);
        List<FrameworkElement> visuals = DropPosition.GetVisualChildren(panel);
        int insertIndex = DropPosition.ComputeIndex(panel, point, visuals);

        int from = _apps.IndexOf(source);
        if (from < 0)
        {
            return;
        }

        int target = insertIndex;
        if (from < target)
        {
            target--;
        }

        _apps.RemoveAt(from);
        _apps.Insert(Compat.Clamp(target, 0, _apps.Count), source);

        for (int i = 0; i < _apps.Count; i++)
        {
            _apps[i].Model.Order = i;
        }

        SaveAll();
        DiagLog.Write("reorder", $"app moved to index {target}");
    }

    private void AppTile_DragOver(object sender, DragEventArgs e)
    {
        // 会话已在进行中，这里只声明允许的效果。
        // 注意：DoDragDrop 绝不能放这里（死锁，见 DragReorder 类注释）。
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy
            : DragDropEffects.Move;
        e.Handled = true;
    }

    /// <summary>启动拖拽：必须在 MouseMove 里（DoDragDrop 只能在这里启动）。</summary>
    private void AppTile_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (DragReorder.TryStartDrag(sender, e))
        {
            e.Handled = true;
        }
    }

    private void AppTile_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            // 外部文件拖到某个磁贴上：加到应用区
            AppsList_Drop(AppsList, e);
            return;
        }

        // 内部重排：委托给容器级逻辑（按容器几何算插入位置）
        if (e.Data.GetData(DragReorder.DragFormat) is Button { DataContext: AppTileViewModel source })
        {
            ReorderAppInGrid(source, AppsList, e);
        }
    }

    /// <summary>
    /// 分类内路径项容器级拖放。
    /// 落在两项之间的空白处、或最后一项之下，也能正确计算插入位置。
    /// </summary>
    private void PathItemsHost_DragOver(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.Copy;
        }
        else if (e.Data.GetDataPresent(DragReorder.DragFormat))
        {
            e.Effects = DragDropEffects.Move;
        }
        else
        {
            e.Effects = DragDropEffects.None;
        }

        e.Handled = true;
    }

    private void PathItemsHost_Drop(object sender, DragEventArgs e)
    {
        if (sender is not ItemsControl host)
        {
            return;
        }

        // 外部文件 → 加入该分类
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
        {
            AddFilesToCategory(files, host);
            return;
        }

        // 内部重排
        if (e.Data.GetData(DragReorder.DragFormat) is not Button { DataContext: PathItemViewModel source })
        {
            return;
        }

        if (host.DataContext is not CategoryViewModel cat)
        {
            return;
        }

        Panel? panel = DropPosition.GetItemsPanel(host);
        if (panel is null)
        {
            return;
        }

        // 指针在容器内的坐标
        Point point = e.GetPosition(panel);
        List<FrameworkElement> visuals = DropPosition.GetVisualChildren(panel);
        int insertIndex = DropPosition.ComputeIndex(panel, point, visuals);

        // 源在列表中的位置
        int from = cat.Items.IndexOf(source);
        if (from < 0)
        {
            return;
        }

        // 移除源后，落点下标要相应调整
        int target = insertIndex;
        if (from < target)
        {
            target--;
        }

        cat.Items.RemoveAt(from);
        cat.Items.Insert(Compat.Clamp(target, 0, cat.Items.Count), source);

        for (int i = 0; i < cat.Items.Count; i++)
        {
            cat.Items[i].Model.Order = i;
        }

        RebuildBindings();
        SaveAll();
        DiagLog.Write("reorder", $"path moved to index {target} in category '{cat.Name}'");
    }

    /// <summary>把外部文件加入某个分类容器对应的分类。</summary>
    private void AddFilesToCategory(string[] files, ItemsControl host)
    {
        if (host.DataContext is not CategoryViewModel cat)
        {
            return;
        }

        int added = 0;
        foreach (string file in files)
        {
            var item = ShortcutStore.Classify(file);
            if (item.Kind == "app")
            {
                continue;
            }

            item.CategoryId = cat.Id;
            item.Order = _data.Paths.Count(p => p.CategoryId == cat.Id);
            _data.Paths.Add(item);
            added++;
        }

        if (added > 0)
        {
            RebuildBindings();
            SaveAll();
            DiagLog.Write("drop", $"added {added} paths to category {cat.Name}");
        }
    }

    // ==================== 路径区 ====================

    private void PathItem_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        DragReorder.OnPreviewMouseLeftButtonDown(sender, e);
    }

    private void PathItem_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy
            : DragDropEffects.Move;
        e.Handled = true;
    }

    /// <summary>启动拖拽：必须在 MouseMove 里（DoDragDrop 只能在这里启动）。</summary>
    private void PathItem_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (DragReorder.TryStartDrag(sender, e))
        {
            e.Handled = true;
        }
    }

    private void PathItem_Drop(object sender, DragEventArgs e)
    {
        // ---- 分支 1：从资源管理器拖文件/目录进来 ----
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
        {
            if (sender is not FrameworkElement { DataContext: PathItemViewModel vm })
            {
                return;
            }

            int added = 0;
            foreach (string file in files)
            {
                var item = ShortcutStore.Classify(file);
                if (item.Kind == "app")
                {
                    continue;   // 应用应进第一区
                }

                item.CategoryId = vm.Model.CategoryId;
                item.Order = _data.Paths.Count(p => p.CategoryId == vm.Model.CategoryId);
                _data.Paths.Add(item);
                added++;
            }

            if (added > 0)
            {
                RebuildBindings();
                SaveAll();
                DiagLog.Write("drop", $"added {added} paths to category {vm.Name}");
            }

            return;
        }

        // ---- 分支 2：内部重排（路径项之间、或拖到另一个分类） ----
        if (e.Data.GetData(DragReorder.DragFormat) is not Button { DataContext: PathItemViewModel source })
        {
            return;
        }

        if (sender is not FrameworkElement { DataContext: PathItemViewModel target })
        {
            return;
        }

        if (ReferenceEquals(source, target))
        {
            return;
        }

        // 源与目标在同一个分类内 → 调整顺序
        if (source.Model.CategoryId == target.Model.CategoryId)
        {
            var list = FindCategoryItems(source.Model.CategoryId);
            if (list is null)
            {
                return;
            }

            int from = list.IndexOf(source);
            if (from < 0)
            {
                return;
            }

            // 统一走容器级算法：算出插入下标（位移小 + 能插到末尾）
            int insertIndex = ComputeInsertIndex(list, source, target, (FrameworkElement)sender, e);

            list.RemoveAt(from);

            int target2 = insertIndex;
            if (from < target2)
            {
                target2--;
            }

            list.Insert(Compat.Clamp(target2, 0, list.Count), source);

            // 写回 Order
            for (int i = 0; i < list.Count; i++)
            {
                list[i].Model.Order = i;
            }

            DiagLog.Write("reorder", $"path reordered in category {source.Model.CategoryId}");
        }
        else
        {
            // 拖到另一个分类 → 改归属
            source.Model.CategoryId = target.Model.CategoryId;
            source.Model.Order = _data.Paths.Count(p => p.CategoryId == target.Model.CategoryId);
            DiagLog.Write("reorder", $"path moved to category {target.Model.CategoryId}");
        }

        RebuildBindings();
        SaveAll();
    }

    /// <summary>
    /// 计算插入下标。优先用容器几何（精确、可插到末尾），
    /// 拿不到容器时退回"落点在目标前/后半"。
    /// </summary>
    private int ComputeInsertIndex(ObservableCollection<PathItemViewModel> list,
        PathItemViewModel source, PathItemViewModel target, FrameworkElement targetEl, DragEventArgs e)
    {
        Panel? panel = DropPosition.FindPanel(targetEl);
        if (panel is not null)
        {
            List<FrameworkElement> visuals = DropPosition.GetVisualChildren(panel);
            if (visuals.Count > 0)
            {
                Point p = e.GetPosition(panel);
                int idx = DropPosition.ComputeIndex(panel, p, visuals);
                return Compat.Clamp(idx, 0, list.Count);
            }
        }

        // 兜底：按落点在目标的前半/后半
        int targetIndex = list.IndexOf(target);
        if (targetIndex < 0)
        {
            return list.IndexOf(source);
        }

        Point dropPoint = e.GetPosition(targetEl);
        bool vertical = targetEl.ActualHeight >= targetEl.ActualWidth;
        double size = vertical ? targetEl.ActualHeight : targetEl.ActualWidth;
        double pos = vertical ? dropPoint.Y : dropPoint.X;

        return pos <= size / 2 ? targetIndex : targetIndex + 1;
    }

    /// <summary>找到某个分类下的路径项列表（同一分类内的重排需要就地修改该集合）。</summary>
    private ObservableCollection<PathItemViewModel>? FindCategoryItems(string? categoryId)
    {
        foreach (CategoryViewModel cat in _categories)
        {
            if (cat.Id == categoryId)
            {
                return cat.Items;
            }
        }

        return null;
    }

    /// <summary>
    /// 找到某个分类对应的 PathItemsHost（ItemsControl）实例。
    /// CategoriesList 按分类模板生成多份，靠遍历可视树 + DataContext 匹配。
    /// </summary>
    private ItemsControl? FindCategoryHost(CategoryViewModel cat)
    {
        return FindVisualItemsControl(CategoriesList, cat);
    }

    private static ItemsControl? FindVisualItemsControl(DependencyObject root, CategoryViewModel cat)
    {
        int count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
        for (int i = 0; i < count; i++)
        {
            DependencyObject child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);

            if (child is ItemsControl ic && ReferenceEquals(ic.DataContext, cat) && ic.Name == "PathItemsHost")
            {
                return ic;
            }

            ItemsControl? deeper = FindVisualItemsControl(child, cat);
            if (deeper is not null)
            {
                return deeper;
            }
        }

        return null;
    }

    private void Category_DragOver(object sender, DragEventArgs e)
    {
        // 拖到分类标题上：
        //   - 外部文件 → 复制（加入该分类）
        //   - 内部路径项 → 移动（改归属分类）
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.Copy;
        }
        else if (e.Data.GetDataPresent(DragReorder.DragFormat))
        {
            e.Effects = DragDropEffects.Move;
        }
        else
        {
            e.Effects = DragDropEffects.None;
        }

        e.Handled = true;
    }

    private void Category_Drop(object sender, DragEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: CategoryViewModel vm })
        {
            return;
        }

        // ---- 分支 1：内部路径项拖到分类标题 → 改归属分类 ----
        if (e.Data.GetData(DragReorder.DragFormat) is Button { DataContext: PathItemViewModel source })
        {
            if (source.Model.CategoryId == vm.Id)
            {
                return;   // 已在该分类
            }

            source.Model.CategoryId = vm.Id;
            source.Model.Order = _data.Paths.Count(p => p.CategoryId == vm.Id);

            RebuildBindings();
            SaveAll();
            DiagLog.Write("reorder", $"path moved to category '{vm.Name}'");
            return;
        }

        // ---- 分支 2：从资源管理器拖文件进来 ----
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files)
        {
            return;
        }

        int added = 0;
        foreach (string file in files)
        {
            var item = ShortcutStore.Classify(file);
            if (item.Kind == "app")
            {
                continue;
            }

            item.CategoryId = vm.Id;
            item.Order = _data.Paths.Count(p => p.CategoryId == vm.Id);
            _data.Paths.Add(item);
            added++;
        }

        if (added > 0)
        {
            RebuildBindings();
            SaveAll();
            DiagLog.Write("drop", $"added {added} paths to category {vm.Name}");
        }
    }

    /* ==================== 决策 #5：停靠弹出 / 离开自动收起 ==================== */

    /// <summary>
    /// 决策 #5："鼠标停靠自动弹出、离开自动收起"。
    ///
    /// ⚠️ 用**光标位置轮询**而不是 MouseEnter/MouseLeave 事件：
    /// 面板展开时正好盖住拉手（两者都在屏幕右边缘），
    /// 事件时序不可靠（MouseLeave 可能不触发、或在错误时机触发）。
    /// 光标坐标是唯一可靠依据。
    ///
    /// 轮询间隔 120ms，延迟 800ms 后收起（config: dock.handle.collapseDelayMs）。
    /// </summary>
    private void StartAutoHideWatch()
    {
        if (!_config.Dock.AutoHide)
        {
            return;   // 配置里关闭了自动隐藏
        }

        if (_panelPinned || _assistantHold)
        {
            // 面板被用户固定（2026-10-25），或助手页正在用（2026-10-26）：
            // 不启动自动收起轮询，但"点击即粘贴"的目标追踪还要用这个计时器。
            StartPinnedTracking();
            return;
        }

        _autoHideTimer ??= new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(120)
        };

        _autoHideTimer.Stop();
        _autoHideTimer.Tick -= AutoHideTimer_Tick;
        _autoHideTimer.Tick += AutoHideTimer_Tick;

        _lastCursorInside = false;
        _autoHideTimer.Start();

        DiagLog.Write("handle", $"auto-hide watch started (delay {_config.Dock.Handle.CollapseDelayMs}ms)");
    }

    private void StopAutoHideWatch()
    {
        _autoHideTimer?.Stop();
    }

    /* ==================== 全屏时隐藏拉手（2026-11-08 用户需求） ==================== */
    //
    // 需求原文："为了避免在全屏游戏等情况下误触拉手，影响游戏体验。
    //           我想在全屏游戏时能临时关闭拉手热区。"
    // 追加确认：全屏视频也隐藏；托盘菜单只给"开/关"开关，不做"暂停 N 分钟"。
    //
    // 恢复机制（用户专门问过"退出全屏后如何激活拉手"）：
    //   **由状态翻转驱动，不需要用户做任何事。**
    //   500ms 轮询发现"不再是全屏"→ 同一个 UpdateHandleVisibility() 就会把拉手显示回来。
    //   关键不是"进入全屏时隐藏"，而是"任何时刻只有一个地方决定拉手该不该显示"，
    //   否则 HideAnimated 里那句无条件 ShowForPanel 会在全屏中把拉手又弹回来。

    /// <summary>启动全屏监测（只在启用了拉手时才有意义）。</summary>
    private void StartFullscreenWatch()
    {
        if (_handle is null)
        {
            return;
        }

        _fullscreenTimer ??= new System.Windows.Threading.DispatcherTimer
        {
            // 500ms：比自动收起的 120ms 慢得多，因为这里只是"场景切换"，
            // 半秒延迟人眼几乎无感；三个廉价系统调用也不值得更密。
            Interval = TimeSpan.FromMilliseconds(500)
        };

        _fullscreenTimer.Stop();
        _fullscreenTimer.Tick -= FullscreenTimer_Tick;
        _fullscreenTimer.Tick += FullscreenTimer_Tick;
        _fullscreenTimer.Start();

        DiagLog.Write("handle", $"fullscreen watch started (hideInFullscreen={_config.Dock.Handle.HideInFullscreen})");
    }

    private void StopFullscreenWatch()
    {
        _fullscreenTimer?.Stop();
    }

    private void FullscreenTimer_Tick(object? sender, EventArgs e)
    {
        if (_handle is null)
        {
            return;
        }

        bool fullscreen = false;
        IntPtr culprit = IntPtr.Zero;
        string reason = "";

        if (_config.Dock.Handle.HideInFullscreen)
        {
            // 几何判定：前台窗口是否在光标所在显示器上铺满整块屏
            fullscreen = NativeMethods.IsForegroundFullscreenOnCursorMonitor(out culprit, out reason);

            // 独占全屏（D3D）可能不走普通窗口几何，补一条系统状态判定
            if (!fullscreen && NativeMethods.IsD3DFullscreen())
            {
                fullscreen = true;
                reason = "QUNS_RUNNING_D3D_FULL_SCREEN";
            }
        }

        // 只在状态翻转时动作 + 写日志，避免每 500ms 刷一行
        if (fullscreen != _handleSuppressedByFullscreen)
        {
            _handleSuppressedByFullscreen = fullscreen;

            if (fullscreen)
            {
                DiagLog.Write("handle",
                    $"hidden: fullscreen detected hwnd=0x{culprit:X} class={NativeMethods.ClassNameOf(culprit)} {reason}");
            }
            else
            {
                DiagLog.Write("handle", "restored: no longer fullscreen");
            }

            UpdateHandleVisibility();
        }
    }

    /// <summary>
    /// 拉手可见性的**唯一**判定点。
    /// 现在有三条路径会改变它（面板展开/收起、全屏状态翻转、托盘开关切换），
    /// 如果各自直接调 Show/Hide，就会出现"全屏中点一下面板再收起，拉手又冒出来"的问题。
    ///
    /// 显示条件必须同时满足：拉手存在 && 面板当前收起 && 不在全屏抑制中。
    /// </summary>
    private void UpdateHandleVisibility()
    {
        if (_handle is null)
        {
            return;
        }

        // 面板展开时一律藏（面板本身占着屏幕右缘，拉手会重叠）
        bool shouldShow = !_isOpen && !_handleSuppressedByFullscreen;

        if (shouldShow == _handleVisible)
        {
            return;
        }

        _handleVisible = shouldShow;

        if (shouldShow)
        {
            _handle.ShowForPanel();
        }
        else
        {
            _handle.HideForPanel();
        }
    }

    /// <summary>
    /// 面板被用户固定（2026-10-25 需求 1）时启动的"伪轮询"：
    /// 仍然跑 120ms 计时器，但 Tick 里命中 <see cref="_panelPinned"/> 就直接返回，
    /// 只保留 <see cref="TrackPasteTarget"/> 这一件事（"点击即粘贴"仍需要它）。
    /// </summary>
    private void StartPinnedTracking()
    {
        _autoHideTimer ??= new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(120)
        };

        _autoHideTimer.Stop();
        _autoHideTimer.Tick -= AutoHideTimer_Tick;
        _autoHideTimer.Tick += AutoHideTimer_Tick;

        _lastCursorInside = false;
        _autoHideTimer.Start();

        DiagLog.Write("panel", "auto-hide watch suppressed (panel pinned by user)");
    }

    /// <summary>
    /// 顶部栏"固定面板"按钮（2026-10-25 需求 1）：
    /// 激活后鼠标离开面板也不自动收起；状态写进 config.Dock.PinPanel，重启保持。
    /// </summary>
    private void PinPanelButton_Click(object sender, RoutedEventArgs e)    {
        _panelPinned = !_panelPinned;
        _config.Dock.PinPanel = _panelPinned;
        UpdatePinPanelVisual();
        SaveAll();

        if (_panelPinned)
        {
            TrackPasteTarget();
            StartPinnedTracking();
            RefreshPushOut();
            DiagLog.Write("panel", "pinned: auto-hide disabled until unpinned");
        }
        else
        {
            _lastCursorInside = false;
            _cursorLeftAt = DateTime.Now;
            StartAutoHideWatch();
            RefreshPushOut();
            DiagLog.Write("panel", "unpinned: auto-hide re-armed");
        }
    }

    /// <summary>固定按钮的外观：固定时高亮，配色与剪贴板锁定按钮一致。</summary>
    private void UpdatePinPanelVisual()
    {
        if (PinPanelButton is null)
        {
            return;
        }

        PinPanelButton.Opacity = _panelPinned ? 1.0 : 0.6;
        PinPanelButton.Background = _panelPinned
            ? new System.Windows.Media.SolidColorBrush(
                System.Windows.Media.Color.FromArgb(0x33, 0x89, 0xB4, 0xFA))
            : System.Windows.Media.Brushes.Transparent;
        PinPanelButton.ToolTip = _panelPinned
            ? "已固定：鼠标离开不会自动收起（点击取消固定）"
            : "固定面板（鼠标离开也不自动收起）";
    }

    /// <summary>
    /// 按当前状态开启/停止"遮挡区弹出"（2026-10-26 需求 2）：
    /// 已固定 + 面板展开 → 开始看守；其余情况 → 停止并还原被动过的窗口。
    /// 幂等，可重复调用。
    /// </summary>
    private void RefreshPushOut()
    {
        if (_panelPinned && _isOpen)
        {
            _pushOut.Begin(NativeMethods.GetHwnd(this));
        }
        else
        {
            _pushOut.End();
        }
    }

    private void AutoHideTimer_Tick(object? sender, EventArgs e)
    {
        if (!_isOpen)
        {
            return;
        }

        // 面板展开期间持续记录抽屉外的前台窗口，供"点击即粘贴"定位目标
        TrackPasteTarget();

        // 用户固定了面板（2026-10-25）或助手页正在用（2026-10-26）：只追踪粘贴目标，绝不自动收起
        if (_panelPinned || _assistantHold)
        {
            return;
        }

        // 用户正在输入时不要自动收起（2026-10-21）：
        // 否则"鼠标恰好移出面板"会把正在写的内容打断。
        // 此时由用户主动收起（热键）或点击别处后自然收起。
        if (Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase)
        {
            _cursorLeftAt = DateTime.Now;
            return;
        }

        (int cx, int cy) = NativeMethods.GetCursorScreenPos();

        // 面板矩形（屏幕坐标）
        double left = Left;
        double top = Top;
        double right = Left + ActualWidth;
        double bottom = Top + ActualHeight;

        // 拉手也算"在面板上"：它紧贴面板右边缘，
        // 面板展开时拉手被隐藏，但光标可能还停在那里。
        bool inHandle = _handle is not null && _handle.IsNear(cx, cy);

        bool inside = (cx >= left && cx <= right && cy >= top && cy <= bottom) || inHandle;

        if (inside)
        {
            _lastCursorInside = true;
            _cursorLeftAt = DateTime.Now;
            return;
        }

        // 鼠标在面板外
        if (!_lastCursorInside)
        {
            // 还没进过面板（比如面板是被热键唤出的，鼠标在别处）
            // → 也要收起，但给一个完整延迟
            _lastCursorInside = true;
            _cursorLeftAt = DateTime.Now;
            return;
        }

        double elapsed = (DateTime.Now - _cursorLeftAt).TotalMilliseconds;

        if (elapsed >= _config.Dock.Handle.CollapseDelayMs)
        {
            StopAutoHideWatch();
            HideAnimated();
            DiagLog.Write("handle",
                $"auto-hidden after {elapsed:F0}ms outside the panel " +
                $"(cursor=({cx},{cy}) rect=({left:F0},{top:F0})-({right:F0},{bottom:F0}) inHandle={inHandle})");
        }
    }

    /* ==================== 第一区：应用 ==================== */

    private void AppTile_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: AppTileViewModel vm })
        {
            return;
        }

        LaunchTarget(vm.Model);
    }

    /// <summary>
    /// 应用区 ＋ 按钮（问题 2：用户要求的添加主次顺序）。
    ///   首选：拖拽（无需入口，直接把桌面图标拖进面板）
    ///   次选：从快捷方式列表选择（一次可加多个，最省事）
    ///   兜底：打开资源管理器手动浏览 exe
    /// 拖拽是操作而非入口，所以不出现在菜单里，菜单项只提示它。
    /// </summary>
    private void AddApp_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();

        var fromList = new MenuItem { Header = "从快捷方式列表选择…" };
        fromList.Click += (_, _) => AddAppsFromList();

        var browse = new MenuItem { Header = "浏览文件…" };
        browse.Click += (_, _) => AddAppsByBrowsing();

        menu.Items.Add(fromList);
        menu.Items.Add(browse);
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Header = "也可直接把桌面图标拖进本区域", IsEnabled = false });

        menu.PlacementTarget = sender as Button;
        menu.IsOpen = true;
    }

    /// <summary>方式 2：快捷方式列表多选添加。</summary>
    private void AddAppsFromList()
    {
        var picker = new AppPickerWindow { Owner = this };
        if (picker.ShowDialog() != true)
        {
            return;
        }

        int added = 0;
        foreach (var app in picker.Selected)
        {
            if (_data.Apps.Any(a => a.Target.Equals(app.Target, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            app.Order = _data.Apps.Count;
            _data.Apps.Add(app);
            added++;
        }

        RebuildBindings();
        SaveAll();
        DiagLog.Write("app-add", $"added {added} apps from picker");
    }

    /// <summary>方式 3：浏览文件手动添加（兜底）。</summary>
    private void AddAppsByBrowsing()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择应用程序",
            Filter = "可执行文件 (*.exe)|*.exe|快捷方式 (*.lnk)|*.lnk",
            Multiselect = true
        };

        if (dlg.ShowDialog(this) != true)
        {
            return;
        }

        int added = 0;
        foreach (string f in dlg.FileNames)
        {
            var item = ShortcutStore.Classify(f);
            item.Kind = "app";
            item.Order = _data.Apps.Count;

            if (_data.Apps.Any(a => a.Target.Equals(item.Target, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            _data.Apps.Add(item);
            added++;
        }

        RebuildBindings();
        SaveAll();
        DiagLog.Write("app-add", $"added {added} apps by browsing");
    }

    /// <summary>
    /// 应用磁贴右键菜单（问题 5：缺少删除）。
    /// </summary>
    private void AppTile_RightClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Button { DataContext: AppTileViewModel vm })
        {
            return;
        }

        var menu = new ContextMenu();

        var openFolder = new MenuItem { Header = "打开所在位置" };
        openFolder.Click += (_, _) => RevealInExplorer(vm.Model.Target);

        var rename = new MenuItem { Header = "重命名…" };
        rename.Click += (_, _) => RenameItem(vm.Model, isApp: true);

        var remove = new MenuItem { Header = "删除" };
        remove.Click += (_, _) =>
        {
            if (MessageBox.Show(this,
                    $"从应用区移除「{vm.Name}」？\n\n只从面板移除，不会删除原始文件。",
                    "QuickDrawer", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            {
                return;
            }

            _data.Apps.Remove(vm.Model);
            RebuildBindings();
            SaveAll();
            DiagLog.Write("app-remove", $"removed {vm.Name}");
        };

        menu.Items.Add(openFolder);
        menu.Items.Add(rename);
        menu.Items.Add(new Separator());
        menu.Items.Add(remove);

        menu.PlacementTarget = sender as UIElement;
        menu.IsOpen = true;
        e.Handled = true;
    }

    /* ==================== 第二区：目录路径 ==================== */

    private void CategoryToggle_Click(object sender, RoutedEventArgs e)
    {
        // Expanded 已由 TwoWay 绑定写入 Model，这里只负责落盘。
        // XAML 解析阶段也可能提前触发本事件，此时 _data 可能未就绪，需判空。
        if (_data is null)
        {
            return;
        }

        SaveAll();
    }

    private void PathItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: PathItemViewModel vm })
        {
            return;
        }

        LaunchTarget(vm.Model);
    }

    /// <summary>
    /// 路径项 Button 的 Loaded 事件：把按钮实例回填给 ViewModel，
    /// 这样切换"图标 / 列表"布局时能直接替换 Content。
    /// 同时第一次加载时按当前配置渲染正确布局。
    /// </summary>
    private void PathItem_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: PathItemViewModel vm } btn)
        {
            return;
        }

        vm.Button = btn;

        // 2026-10-23：重建后按钮诞生时同样要应用对齐/行距，
        // 否则 RebuildBindings 后列表模式的 Stretch 会丢（只换 Content 不够）。
        // 分类级覆盖：盘符项（drive）或含盘符的分类永远走图标行 + 宽间距。
        bool drive = vm.Model.Kind == "drive";
        bool listMode = _config.Layout.Paths == "list" && !drive;
        btn.Content = listMode ? BuildListRow(vm) : BuildIconRow(vm);
        btn.HorizontalAlignment = listMode ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
        btn.Margin = listMode
            ? new Thickness(0, 0, 0, 2)
            : new Thickness(0, 0, drive ? 10 : 0, 0);
    }

    private void AddPath_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();

        var addFile = new MenuItem { Header = "添加文件…" };
        addFile.Click += (_, _) => AddPathViaDialog(false);
        var addDir = new MenuItem { Header = "添加目录…" };
        addDir.Click += (_, _) => AddPathViaDialog(true);
        var addCategory = new MenuItem { Header = "新建分类…" };
        addCategory.Click += (_, _) => AddNewCategory();

        menu.Items.Add(addFile);
        menu.Items.Add(addDir);
        menu.Items.Add(new Separator());
        menu.Items.Add(addCategory);

        menu.PlacementTarget = sender as Button;
        menu.IsOpen = true;
    }

    private void AddPathViaDialog(bool directory)
    {
        if (_data.Categories.Count == 0)
        {
            MessageBox.Show(this, "请先新建一个分类。", "QuickDrawer",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        string? path = null;

        if (directory)
        {
            // net48 没有 Microsoft.Win32.OpenFolderDialog（.NET 8+ 才有）。
            // 用 shell32 的 SHBrowseForFolder 等价替代：只能选目录、可新建文件夹。
            path = FolderPicker.Pick(this, "选择目录");
        }
        else
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Title = "选择文件" };
            if (dlg.ShowDialog(this) == true)
            {
                path = dlg.FileName;
            }
        }

        if (path is null)
        {
            return;
        }

        // ⚠️ 问题 4 的修复点：
        // 之前这里硬编码 `.First()`，导致不管加什么都进第一个分类"我的电脑"。
        // 现在让用户明确选择目标分类（可顺便新建）。
        var picker = new CategoryPickerDialog(_data.Categories, "添加到哪个分类？") { Owner = this };
        if (picker.ShowDialog() != true || picker.Selected is null)
        {
            return;
        }

        var target = picker.Selected;
        var item = ShortcutStore.Classify(path);
        item.CategoryId = target.Id;
        item.Order = _data.Paths.Count(p => p.CategoryId == target.Id);

        _data.Paths.Add(item);
        RebuildBindings();
        SaveAll();
        DiagLog.Write("path-add", $"added {item.Name} ({item.Kind}) to category {target.Name}");
    }

    /// <summary>路径项右键菜单（问题 5：缺少删除）。</summary>
    private void PathItem_RightClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Button { DataContext: PathItemViewModel vm })
        {
            return;
        }
        var menu = new ContextMenu();

        var openFolder = new MenuItem { Header = "打开所在位置" };
        openFolder.Click += (_, _) => RevealInExplorer(vm.Model.Target);

        var rename = new MenuItem { Header = "重命名…" };
        rename.Click += (_, _) => RenameItem(vm.Model, isApp: false);

        // 移动到其他分类（问题 4 的补充：不只是添加，移动也该支持）
        var moveTo = new MenuItem { Header = "移动到其他分类…" };
        moveTo.Click += (_, _) => MovePathToOtherCategory(vm);

        var remove = new MenuItem { Header = "删除" };
        remove.Click += (_, _) =>
        {
            if (MessageBox.Show(this,
                    $"从面板移除「{vm.Name}」？\n\n只从面板移除，不会删除原始文件。",
                    "QuickDrawer", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            {
                return;
            }

            _data.Paths.Remove(vm.Model);
            RebuildBindings();
            SaveAll();
            DiagLog.Write("path-remove", $"removed {vm.Name}");
        };

        menu.Items.Add(openFolder);
        menu.Items.Add(rename);
        menu.Items.Add(moveTo);
        menu.Items.Add(new Separator());
        menu.Items.Add(remove);

        menu.PlacementTarget = sender as UIElement;
        menu.IsOpen = true;
        e.Handled = true;
    }

    private void MovePathToOtherCategory(PathItemViewModel vm)
    {
        var picker = new CategoryPickerDialog(_data.Categories, "移动到哪个分类？") { Owner = this };
        if (picker.ShowDialog() != true || picker.Selected is null)
        {
            return;
        }

        if (picker.Selected.Id == vm.Model.CategoryId)
        {
            return;
        }

        vm.Model.CategoryId = picker.Selected.Id;
        RebuildBindings();
        SaveAll();
        DiagLog.Write("path-move", $"{vm.Name} -> {picker.Selected.Name}");
    }

    /// <summary>分类标题右键菜单：重命名 / 删除分类。</summary>
    private void Category_RightClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: CategoryViewModel vm })
        {
            return;
        }

        var menu = new ContextMenu();

        var rename = new MenuItem { Header = "重命名分类…" };
        rename.Click += (_, _) =>
        {
            var dlg = new InputDialog("重命名分类", "分类名称：", vm.Name) { Owner = this };
            if (dlg.ShowDialog() == true && !string.IsNullOrWhiteSpace(dlg.Answer))
            {
                vm.Model.Name = dlg.Answer.Trim();
                RebuildBindings();
                SaveAll();
            }
        };

        var remove = new MenuItem { Header = "删除分类" };
        remove.Click += (_, _) =>
        {
            int count = _data.Paths.Count(p => p.CategoryId == vm.Id);
            string extra = count > 0 ? $"\n\n该分类下还有 {count} 个条目，会一并移除。" : "";

            if (MessageBox.Show(this, $"删除分类「{vm.Name}」？{extra}",
                    "QuickDrawer", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            {
                return;
            }

            _data.Paths.RemoveAll(p => p.CategoryId == vm.Id);
            _data.Categories.Remove(vm.Model);
            RebuildBindings();
            SaveAll();
            DiagLog.Write("category-remove", $"removed {vm.Name} with {count} items");
        };

        menu.Items.Add(rename);
        menu.Items.Add(new Separator());
        menu.Items.Add(remove);

        menu.PlacementTarget = sender as UIElement;
        menu.IsOpen = true;
        e.Handled = true;
    }

    /// <summary>在资源管理器中定位到目标。</summary>
    private static void RevealInExplorer(string target)
    {
        try
        {
            bool isDir = Directory.Exists(target);
            if (!isDir && !File.Exists(target))
            {
                return;
            }

            if (isDir)
            {
                NativeMethods.ShellExecute(IntPtr.Zero, "open", target,
                    string.Empty, string.Empty, NativeMethods.SW_SHOWNORMAL);
            }
            else
            {
                // /select 会让资源管理器选中该文件并定位到所在目录
                NativeMethods.ShellExecute(IntPtr.Zero, "open",
                    "explorer.exe", $"/select,\"{target}\"", string.Empty,
                    NativeMethods.SW_SHOWNORMAL);
            }
        }
        catch (Exception ex)
        {
            DiagLog.Write("reveal", $"failed for {target}: {ex.Message}");
        }
    }

    /// <summary>重命名面板内的显示名（不改原始文件名）。</summary>
    private void RenameItem(ShortcutItem model, bool isApp)
    {
        var dlg = new InputDialog("重命名", "显示名称：", model.Name) { Owner = this };
        if (dlg.ShowDialog() == true && !string.IsNullOrWhiteSpace(dlg.Answer))
        {
            model.Name = dlg.Answer.Trim();
            RebuildBindings();
            SaveAll();
        }
    }

    private void AddNewCategory()
    {
        var dlg = new InputDialog("新建分类", "分类名称：", "新分类")
        {
            Owner = this
        };
        if (dlg.ShowDialog() == true && !string.IsNullOrWhiteSpace(dlg.Answer))
        {
            _data.Categories.Add(new PathCategory
            {
                Name = dlg.Answer.Trim(),
                Order = _data.Categories.Count
            });
            RebuildBindings();
            SaveAll();
        }
    }

    /* ==================== 第三区：便签 / 剪贴板 ==================== */

    private void TabNotes_Checked(object sender, RoutedEventArgs e)
    {
        // 注意：XAML 里 IsChecked="True" 会在解析阶段就触发本事件，
        // 那时 NotesPanel / ClipboardPanel 可能还没赋值（2026-10-18 崩溃教训）。
        // 必须判空，否则 WpfXamlLoader 抛 NullReferenceException。
        if (NotesPanel is null || ClipboardPanel is null || ClearButton is null)
        {
            return;
        }

        NotesPanel.Visibility = Visibility.Visible;
        ClipboardPanel.Visibility = Visibility.Collapsed;
        ClearButton.Visibility = Visibility.Visible;
        ClearButton.ToolTip = "清除全部便签";
        LeaveAssistantPage();
    }

    private void TabClipboard_Checked(object sender, RoutedEventArgs e)
    {
        if (NotesPanel is null || ClipboardPanel is null || ClearButton is null)
        {
            return;
        }

        NotesPanel.Visibility = Visibility.Collapsed;
        ClipboardPanel.Visibility = Visibility.Visible;
        ClearButton.Visibility = Visibility.Visible;
        ClearButton.ToolTip = "清除剪贴板历史";
        LeaveAssistantPage();

        // 切到剪贴板页 = 已读，未读角标清零
        _clipboardUnread = 0;
        UpdateBadge();
    }

    /* ==================== 智能助手页（2026-10-26 需求） ==================== */

    /// <summary>
    /// 切到助手页：懒加载 WebView2 → 导航到上次用的站点 → 面板宽度按"加宽"开关调整。
    ///
    /// 为什么在切页时 Activate()：窗口是 ShowActivated=false 滑出来的，
    /// 用户第一次点标签时窗口可能还没激活，WebView2 是子 HWND，
    /// 拿不到键盘焦点就会出现"看着能打字但一个字也进不去"。
    /// </summary>
    private async void TabAssistant_Checked(object sender, RoutedEventArgs e)
    {
        if (NotesPanel is null || ClipboardPanel is null || AssistantPanel is null || ClearButton is null)
        {
            return;   // XAML 解析阶段触发时控件还没就绪（同 TabNotes_Checked）
        }

        NotesPanel.Visibility = Visibility.Collapsed;
        ClipboardPanel.Visibility = Visibility.Collapsed;
        AssistantPanel.Visibility = Visibility.Visible;
        ClearButton.Visibility = Visibility.Collapsed;   // 助手页没有可清除的内容

        _assistantVisible = true;
        _assistantHold = true;

        if (_isOpen)
        {
            // 网页里打字时鼠标滑出面板不能把面板收走
            StartPinnedTracking();

            if (!IsActive)
            {
                try
                {
                    Activate();
                }
                catch
                {
                    // 激活失败不阻断导航，用户可以再点一下页面
                }
            }
        }

        ApplyPanelWidth();
        await EnsureAssistantPageAsync();

        DiagLog.Write("assistant", $"page shown (provider={_config.Assistant.ActiveProviderId})");
    }

    /// <summary>离开助手页：收起助手容器、面板宽度回落、自动收起重新武装。</summary>
    private void LeaveAssistantPage()
    {
        // WebView2 是子 HWND（airspace），只切别人的 Visibility 不够：
        // 它自己不被 Collapsed 就会一直盖在便签/剪贴板上面（2026-10-29 用户反馈）。
        if (AssistantPanel is not null && AssistantPanel.Visibility != Visibility.Collapsed)
        {
            AssistantPanel.Visibility = Visibility.Collapsed;
        }

        // 站点常驻：只隐藏，不销毁——回来时还是原来的页面（滚动位置、草稿都在）。
        _assistant?.Hide();

        if (!_assistantVisible)
        {
            return;
        }

        _assistantVisible = false;
        _assistantHold = false;
        ApplyPanelWidth();

        if (_isOpen)
        {
            _lastCursorInside = false;
            _cursorLeftAt = DateTime.Now;
            StartAutoHideWatch();
        }

        DiagLog.Write("assistant", "page hidden");
    }

    private async Task EnsureAssistantPageAsync()
    {
        if (!_config.Assistant.Enabled)
        {
            AssistantStatus.Text = "助手页已在配置中关闭（config: assistant.enabled）。";
            AssistantStatus.Visibility = Visibility.Visible;
            _assistant?.Hide();
            return;
        }

        _assistant ??= new AssistantService(
            AssistantHost,
            _config,
            msg => DiagLog.Write("assistant", msg),
            UpdateAssistantWidenVisual);

        // 2026-10-31：服务刚创建时还没收到宽度倍数（TabAssistant_Checked 里
        // 先 ApplyPanelWidth 再 EnsureAssistantPageAsync，创建时 _assistant 还是 null），
        // 这里补一次，否则首次就处于加宽状态时缩放仍是基础值。
        ApplyAssistantZoomScale(Width);

        if (!_assistant.IsReady)
        {
            AssistantStatus.Text = "正在加载助手页…";
            AssistantStatus.Visibility = Visibility.Visible;
        }

        AssistantProvider provider = AssistantProviders.ById(_config.Assistant.ActiveProviderId)
                                     ?? AssistantProviders.All[0];

        // 站点常驻（2026-10-29 需求）：已建过的实例直接显示，没建过的才创建并首次导航。
        // 因此来回切站点不再重新加载，草稿与滚动位置都保留在原实例里。
        bool ok = await _assistant.EnsureAsync(provider);
        if (!ok)
        {
            AssistantStatus.Text = "助手页不可用：\n" + (_assistant.LastError ?? "(未知原因)");
            AssistantStatus.Visibility = Visibility.Visible;
            _assistant.Hide();
            return;
        }

        AssistantStatus.Visibility = Visibility.Collapsed;

        UpdateAssistantChips(provider.Id);
        UpdateAssistantWidenVisual();
    }

    private async void AssistantChip_Checked(object sender, RoutedEventArgs e)
    {
        if (_syncingChips || sender is not RadioButton { Tag: string id })
        {
            return;
        }

        AssistantProvider? provider = AssistantProviders.ById(id);
        if (provider is null)
        {
            return;
        }

        _config.Assistant.ActiveProviderId = provider.Id;
        DiagLog.Write("assistant", $"provider selected {provider.Id}");

        // 记到磁盘：下次启动直接回到这个站点
        SaveAll();

        if (_assistantVisible)
        {
            await EnsureAssistantPageAsync();
        }
    }

    private void StartSelectionWatcher()
    {
        if (!_config.Assistant.SelectionPopup)
        {
            return;
        }

        try
        {
            _selection = new SelectionWatcher(_config, msg => DiagLog.Write("selection", msg));
            _selection.PromptChosen += (preset, text) => _ = HandlePromptChosenAsync(preset, text);
            _selection.CustomSendRequested += text => _ = HandleCustomSendAsync(text);
            // 参数名不能叫 _：lambda 里还要用 _ = ...（discard）丢弃 Task，
            // 同名会被解析成给参数赋值（CS0029：Task 转 string）。
            _selection.ShotSendRequested += (shot, _unused) => _ = HandleShotSendAsync(shot);
            _selection.Start();
        }
        catch (Exception ex)
        {
            // 钩子装不上不该拖垮整个程序（少数环境会拒绝全局钩子）
            DiagLog.Write("selection", "watcher failed: " + ex.Message);
            _selection = null;
        }
    }

    /// <summary>
    /// 用户点了悬浮条上的某个提示词：把这句指令 + 选中内容发到助手页。
    /// 面板收着的时候先展开并切到助手页（需求原文：收起状态默认发给 DeepSeek）。
    /// </summary>
    private async Task HandlePromptChosenAsync(PromptPreset preset, string selection)
    {
        await SendToAssistantAsync(preset.Instruction, selection, preset.Id);
    }

    /// <summary>
    /// 悬浮条最左侧「发送」：先弹自定义提示词编辑器，确定后才发（2026-10-31 需求）。
    ///
    /// 顺序讲究：编辑器必须在面板展开/切标签**之前**弹出——
    /// 否则面板先抢走前台，用户正要打字的模态框会被压在下面。
    /// 编辑器期间还要停掉自动收起轮询，不然鼠标停在悬浮条上（面板外）
    /// 会把 Owner 窗口收走，模态框就挂在一个隐藏的 Owner 上。
    /// </summary>
    private async Task HandleCustomSendAsync(string selection)
    {
        var dlg = new PromptEditorDialog(_config.Assistant.CustomPrompt, selection);

        if (_isOpen && IsVisible)
        {
            dlg.Owner = this;
        }
        else
        {
            // 面板收着时没有可用 Owner（Owner 必须可见），让它自己居中到屏幕
            dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }

        bool? ok;
        if (_isOpen)
        {
            StopAutoHideWatch();
        }

        try
        {
            ok = dlg.ShowDialog();
        }
        finally
        {
            if (_isOpen)
            {
                _lastCursorInside = false;
                _cursorLeftAt = DateTime.Now;
                StartAutoHideWatch();
            }
        }

        string prompt = dlg.Prompt.Trim();

        if (ok != true)
        {
            DiagLog.Write("selection", "custom prompt cancelled");
            return;
        }

        if (string.IsNullOrWhiteSpace(prompt))
        {
            DiagLog.Write("selection", "custom prompt empty, nothing sent");
            return;
        }

        // 回写草稿：下次点「发送」还是这句（用户不必每次重打）
        _config.Assistant.CustomPrompt = prompt;
        SaveAll();

        await SendToAssistantAsync(prompt, selection, "custom");
    }

    /// <summary>
    /// 把"一句指令 + 选中内容"送到助手页。预设按钮与「发送」共用这一条路径，
    /// 保证两种入口的展开/切站/日志行为完全一致。
    /// </summary>
    private async Task SendToAssistantAsync(string instruction, string selection, string tag)
    {
        bool wasOpen = _isOpen;

        // 收起状态下按需求强制走 DeepSeek
        if (!wasOpen)
        {
            _config.Assistant.ActiveProviderId = AssistantProviders.DeepSeek.Id;
            UpdateAssistantChips(AssistantProviders.DeepSeek.Id);
            ShowAnimated();
        }

        if (TabAssistant.IsChecked != true)
        {
            TabAssistant.IsChecked = true;
        }

        await EnsureAssistantPageAsync();

        if (_assistant is null)
        {
            DiagLog.Write("selection", "assistant not ready, prompt dropped");
            return;
        }

        string message = string.IsNullOrWhiteSpace(instruction)
            ? selection
            : instruction + "\n\n" + selection;

        bool ok = await _assistant.SendPromptAsync(message);
        DiagLog.Write("selection", ok
            ? $"prompt sent ({tag}, {selection.Length} chars selection)"
            : $"prompt failed ({tag}): {_assistant.LastError}");
    }

    private void UpdateAssistantChips(string providerId)
    {
        _syncingChips = true;
        try
        {
            ChipDeepSeek.IsChecked = string.Equals(providerId, AssistantProviders.DeepSeek.Id, StringComparison.Ordinal);
            ChipQwen.IsChecked = string.Equals(providerId, AssistantProviders.Qwen.Id, StringComparison.Ordinal);
            ChipKimi.IsChecked = string.Equals(providerId, AssistantProviders.Kimi.Id, StringComparison.Ordinal);
            ChipGlm.IsChecked = string.Equals(providerId, AssistantProviders.ChatGlm.Id, StringComparison.Ordinal);
        }
        finally
        {
            _syncingChips = false;
        }
    }

    private void AssistantBack_Click(object sender, RoutedEventArgs e) => _assistant?.GoBack();

    private void AssistantForward_Click(object sender, RoutedEventArgs e) => _assistant?.GoForward();

    private void AssistantReload_Click(object sender, RoutedEventArgs e) => _assistant?.Reload();

    private void AssistantBrowser_Click(object sender, RoutedEventArgs e) => _assistant?.OpenInBrowser();

    /// <summary>
    /// 工具栏「截图提问」（2026-11-01 五次需求）：先把自己的面板收起来，
    /// 再进入全屏框选，截完把图丢给悬浮条去配提示词。
    ///
    /// 为什么要先收面板：面板占着屏幕右侧一条，不收就会被自己截进去；
    /// 而且遮罩是全屏 Topmost，面板留在下面只会隔着黑幕露一角，很怪。
    /// 收起来之后**不自动再展开**——等用户点悬浮条上的预设/发送，走
    /// 既有的 SendToAssistant 链路，那里本来就会把面板展开。
    /// </summary>
    private async void AssistantShot_Click(object sender, RoutedEventArgs e)
    {
        await TakeScreenshotAsync("toolbar");
    }

    /// <summary>
    /// 截图提问的完整流程，工具栏按钮与截图热键共用（2026-11-01 七次：
    /// 热键是本条的唯一新入口，抽出来才不会再写一遍收起/取消/异常三条分支）。
    /// 参数 <paramref name="source"/> 只用于日志区分触发来源（toolbar / hotkey）。
    /// </summary>
    private async Task TakeScreenshotAsync(string source)
    {
        if (_selection is null)
        {
            DiagLog.Write("shot", $"{source}: selection watcher is not running, screenshot unavailable");
            return;
        }

        bool wasOpen = _isOpen;
        if (wasOpen)
        {
            HideAnimated();
            // 收起动画 140ms，等它走完再截，否则会截到半开的面板。
            await Task.Delay(200);
        }

        try
        {
            BitmapSource? shot = ScreenshotOverlay.CaptureInteractive();

            // 2026-11-05 用户反馈：截图按钮收面板后，被最小化的窗口会被弹出来。
            // 遮罩是一扇模态全屏窗，它关掉时系统同样要做一次前台重选，
            // 候选里若只剩最小化窗口就会被恢复。这里在遮罩关闭后立刻把前台
            // 交还打开面板之前的那个窗口，把重选结果压回去。
            RestoreForeground(_pasteTarget, "shot");

            if (shot is null)
            {
                DiagLog.Write("shot", $"{source}: cancelled");
                if (wasOpen)
                {
                    ShowAnimated();
                }

                return;
            }

            (int x, int y) = NativeMethods.GetCursorScreenPos();
            _selection.ShowForShot(shot, x, y);
            DiagLog.Write("shot",
                $"{source}: ready {shot.PixelWidth}x{shot.PixelHeight} px, popup shown at {x},{y}");
        }
        catch (Exception ex)
        {
            DiagLog.Write("shot", $"{source}: failed: {ex.Message}");
            if (wasOpen && !_isOpen)
            {
                ShowAnimated();
            }
        }
    }

    /// <summary>
    /// 截图模式下点了悬浮条的「发送」：先弹提示词编辑器（提示行显示截图尺寸），
    /// 确定后把"提示词 + 截图"一起发出去。
    ///
    /// 与 <see cref="HandleCustomSendAsync"/> 几乎一样，区别只有两处：
    /// 没有选中文字（传空），发送走带图通道 <see cref="AssistantService.SendPromptWithImageAsync"/>。
    /// </summary>
    private async Task HandleShotSendAsync(BitmapSource shot)
    {
        string hint = $"截图 {shot.PixelWidth} × {shot.PixelHeight} 像素";
        var dlg = new PromptEditorDialog(_config.Assistant.CustomPrompt, string.Empty, hint);

        if (_isOpen && IsVisible)
        {
            dlg.Owner = this;
        }
        else
        {
            dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }

        bool? ok;
        if (_isOpen)
        {
            StopAutoHideWatch();
        }

        try
        {
            ok = dlg.ShowDialog();
        }
        finally
        {
            if (_isOpen)
            {
                _lastCursorInside = false;
                _cursorLeftAt = DateTime.Now;
                StartAutoHideWatch();
            }
        }

        string prompt = dlg.Prompt.Trim();

        if (ok != true)
        {
            DiagLog.Write("shot", "prompt cancelled");
            return;
        }

        if (string.IsNullOrWhiteSpace(prompt))
        {
            // 截图提问空提示词没有意义：只有图没有"问什么"，模型不知道要看什么。
            DiagLog.Write("shot", "prompt empty, nothing sent");
            return;
        }

        _config.Assistant.CustomPrompt = prompt;
        SaveAll();

        await SendImageToAssistantAsync(prompt, shot, "shot");
    }

    /// <summary>
    /// 把"一句指令 + 一张截图"送到助手页。与 <see cref="SendToAssistantAsync"/>
    /// 保持同样的展开/切站/日志行为，只是末端换成了带图的发送方法。
    /// </summary>
    private async Task SendImageToAssistantAsync(string instruction, BitmapSource image, string tag)
    {
        bool wasOpen = _isOpen;

        if (!wasOpen)
        {
            _config.Assistant.ActiveProviderId = AssistantProviders.DeepSeek.Id;
            UpdateAssistantChips(AssistantProviders.DeepSeek.Id);
            ShowAnimated();
        }

        if (TabAssistant.IsChecked != true)
        {
            TabAssistant.IsChecked = true;
        }

        await EnsureAssistantPageAsync();

        if (_assistant is null)
        {
            DiagLog.Write("shot", "assistant not ready, screenshot dropped");
            return;
        }

        bool ok = await _assistant.SendPromptWithImageAsync(instruction, image);
        DiagLog.Write("shot", ok
            ? $"prompt with image sent ({tag}, {image.PixelWidth}x{image.PixelHeight} px)"
            : $"prompt with image failed ({tag}): {_assistant.LastError}");
    }

    /// <summary>加宽开关：只在助手页生效，切走自动回落（状态存 config）。</summary>
    private void AssistantWiden_Click(object sender, RoutedEventArgs e)
    {
        _config.Assistant.Widen = !_config.Assistant.Widen;
        UpdateAssistantWidenVisual();
        ApplyPanelWidth();
        SaveAll();
    }

    /// <summary>
    /// 应用面板宽度：助手页 + 加宽 → widenWidth，否则回落到 dock.width。
    /// 展开状态下同步把 Left 贴着工作区右边，避免宽度变了位置没跟着。
    ///
    /// 2026-10-31：宽度变化后必须同步"网页缩放倍数"，否则加宽只拉长页面、
    /// 字体一点没变（用户反馈"页面加宽了但字体还是原大小"）。
    /// 缩放倍数 = 当前宽度 / 常规宽度（dock.width），并在配置允许时才生效。
    /// </summary>
    private void ApplyPanelWidth()
    {
        Rect work = NativeMethods.GetWorkAreaForCursor();
        bool widen = _assistantVisible && _config.Assistant.Widen;
        double width = _config.Dock.Width;

        if (widen)
        {
            width = Math.Max(_config.Dock.MinWidth, Math.Min(_config.Assistant.WidenWidth, work.Width - 120));
        }

        ApplyAssistantZoomScale(width);

        if (Math.Abs(Width - width) < 0.5)
        {
            return;
        }

        Width = width;

        if (_isOpen)
        {
            BeginAnimation(Window.LeftProperty, null);
            Left = work.Right - width;
            RefreshPushOut();
        }

        DiagLog.Write("assistant", $"panel width -> {width:0} (widen={widen})");
    }

    /// <summary>
    /// 把"当前面板宽度 / 常规宽度"的倍数交给助手服务，
    /// 由它按比例放大 WebView2 的缩放，让字体随面板一起变大。
    /// </summary>
    private void ApplyAssistantZoomScale(double width)
    {
        double baseWidth = _config.Dock.Width > 0 ? _config.Dock.Width : 380;
        double scale = width / baseWidth;

        if (!_config.Assistant.ZoomScaleWithWidth)
        {
            scale = 1.0;
        }

        _assistant?.SetWidthScale(scale);
    }

    private void UpdateAssistantWidenVisual()
    {
        if (AssistantWidenButton is null)
        {
            return;
        }

        bool on = _config.Assistant.Widen && _assistantVisible;
        AssistantWidenButton.Opacity = on ? 1.0 : 0.6;
        AssistantWidenButton.Background = on
            ? new System.Windows.Media.SolidColorBrush(
                System.Windows.Media.Color.FromArgb(0x33, 0x89, 0xB4, 0xFA))
            : System.Windows.Media.Brushes.Transparent;
        AssistantWidenButton.ToolTip = on
            ? "已加宽（点击恢复原宽度，仅助手页生效）"
            : "加宽面板（仅助手页生效）";
    }

    /// <summary>
    /// 决策 #3：便签栏右侧的清除按钮。
    /// 便签是用户数据，误清代价高 —— 按配置决定是否弹确认。
    /// </summary>
    private void ClearButton_Click(object sender, RoutedEventArgs e)
    {
        bool onNotes = TabNotes.IsChecked == true;

        if (onNotes)
        {
            // 便签：保留已锁定（置顶锁定）的卡片（2026-10-25 需求 2）
            int lockedKeep = _notes.Cards.Count(c => c.Pinned);
            int noteRemovable = _notes.Cards.Count - lockedKeep;

            if (noteRemovable <= 0)
            {
                MessageBox.Show(this, lockedKeep > 0
                        ? $"剩余 {lockedKeep} 张卡片全部已锁定，先点锁解锁才能清除。"
                        : "没有可清除的卡片。",
                    "QuickDrawer", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            if (_config.Notes.ConfirmBeforeClear &&
                MessageBox.Show(this,
                        $"确定清除便签卡片（{noteRemovable} 张待删除，{lockedKeep} 张已锁定保留）？此操作不可撤销。",
                        "QuickDrawer", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            {
                return;
            }

            for (int i = _notes.Cards.Count - 1; i >= 0; i--)
            {
                if (_notes.Cards[i].Pinned)
                {
                    continue;   // 锁定卡不清除
                }

                _notes.Cards.RemoveAt(i);
            }

            SaveNotesToDisk();
            UpdateNotesEmptyState();
            DiagLog.Write("notes", $"cards cleared by user (kept {lockedKeep} locked)");
            return;
        }

        // 剪贴板：清除历史，但保留已锁定的条目（2026-10-25）
        int pinnedKeep = _clipItems.Count(c => c.Pinned);
        int removable = _clipItems.Count - pinnedKeep;

        if (removable <= 0)
        {
            MessageBox.Show(this, pinnedKeep > 0
                    ? $"剩余 {pinnedKeep} 条历史全部已锁定，先点锁定按钮解锁才能清除。"
                    : "没有可清除的历史记录。",
                "QuickDrawer", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        if (MessageBox.Show(this, $"确定清除剪贴板历史（{removable} 条待删除，{pinnedKeep} 条已锁定保留）？\n\n此操作不可撤销。",
                "QuickDrawer", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            return;
        }

        for (int i = _clipItems.Count - 1; i >= 0; i--)
        {
            if (_clipItems[i].Pinned)
            {
                continue;   // 锁定项不清除
            }

            ClipboardBlobStore.Delete(_clipItems[i].BlobPath);
            _clipItems.RemoveAt(i);
        }

        // 只保存剩余项（锁定项），不再整表清空
        SaveClipboardHistory();
        _clipboard?.Clear(keepPinned: true);
        _clipboardUnread = 0;
        UpdateBadge();
        UpdateClipboardEmptyState();
        DiagLog.Write("clipboard", "history cleared by user");
    }

    /* ---------- 便签卡片（M4） ---------- */

    /// <summary>新建一张卡片并聚焦其编辑区。</summary>
    private void AddNote_Click(object sender, RoutedEventArgs e)
    {
        NoteCardViewModel card = _notes.AddNew();
        UpdateNotesEmptyState();

        // 滚到顶部并聚焦新卡的正文编辑器（2026-10-26：正文默认是阅读态，先切到编辑态）。
        // 必须等布局这一轮跑完：ListBox 的容器是在渲染时才生成的，
        // 刚 AddNew 就 ContainerFromItem 会拿到 null，编辑态永远打不开。
        Dispatcher.BeginInvoke(
            new Action(() =>
            {
                if (NotesList.ItemContainerGenerator.ContainerFromItem(card) is FrameworkElement container)
                {
                    container.BringIntoView();
                    if (FindNoteBodyEditor(container) is { } tb)
                    {
                        SetNoteBodyEditing(tb, true);
                    }
                }
            }),
            System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// <summary>置顶/取消置顶。</summary>
    private void NotePin_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: NoteCardViewModel card })
        {
            _notes.TogglePin(card);
        }
    }

    /// <summary>色板点选：设置卡片颜色。</summary>
    private void NoteColor_Click(object sender, RoutedEventArgs e)
    {
        // 色板按钮的 Tag 是颜色名；它所在的卡片要从 DataContext 沿可视树找
        if (sender is not Button { Tag: string color })
        {
            return;
        }

        NoteCardViewModel? card = FindAncestorCard(sender as DependencyObject);
        if (card is not null)
        {
            _notes.SetColor(card, color);
        }
    }

    /// <summary>删除单张卡片（空卡直接删，有内容则确认）。</summary>
    private void NoteDelete_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: NoteCardViewModel card })
        {
            return;
        }

        // 锁定卡（置顶锁定，2026-10-25 需求 2）：先解锁才能删除
        if (card.Pinned)
        {
            MessageBox.Show(this, "这张卡片已锁定，不会被删除或清空。\n\n先点卡片上的锁图标解锁，再删除。",
                "QuickDrawer", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        if (!string.IsNullOrWhiteSpace(card.Text))
        {
            string preview = card.Text.Length > 20 ? card.Text.Substring(0, 20) + "…" : card.Text;
            if (MessageBox.Show(this, $"删除这张便签？\n\n「{preview}」",
                    "QuickDrawer", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            {
                return;
            }
        }

        _notes.Remove(card);
        UpdateNotesEmptyState();
    }

    /// <summary>文本失焦即保存（绑定已即时更新 VM，这里负责落盘）。</summary>
    private void NoteText_LostFocus(object sender, RoutedEventArgs e)
    {
        SaveNotesToDisk();
    }

    /* ==================== 便签正文：阅读态 / 编辑态切换（2026-10-26 需求 1） ====================
       WPF 的 TextBox 没有 LineHeight（加在 XAML 上会 MC3072 编译失败），
       所以正文用"TextBlock 阅读 + TextBox 编辑"两个元素叠在同一 Grid 里：
       阅读态由 TextBlock 用 LineHeight=20 拉开行距，点一下换成 TextBox 编辑，
       编辑态失焦即落盘并切回阅读态。二者共用同一个 Text 绑定，数据不会分叉。 */

    private void NoteBodyText_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not TextBlock tb || tb.Parent is not Panel panel)
        {
            return;
        }

        TextBox? editor = panel.Children.OfType<TextBox>().FirstOrDefault();
        if (editor is null)
        {
            return;
        }

        SetNoteBodyEditing(editor, true);

        // 鼠标按下后 WPF 会把键盘焦点交给 ListBoxItem（可聚焦的是它，不是 TextBlock），
        // 所以这里延后一拍再把焦点抢回正文编辑框，否则后续输入会丢。
        e.Handled = true;
        Dispatcher.BeginInvoke(
            new Action(() =>
            {
                editor.Focus();
                editor.CaretIndex = editor.Text.Length;
            }),
            System.Windows.Threading.DispatcherPriority.Input);
    }

    private void NoteBodyEditor_LostFocus(object sender, RoutedEventArgs e)
    {
        if (sender is TextBox editor)
        {
            SetNoteBodyEditing(editor, false);
        }

        SaveNotesToDisk();
    }

    /// <summary>切换某张便签正文的编辑态，并同步同一 Grid 里阅读态 TextBlock 的可见性。</summary>
    private static void SetNoteBodyEditing(TextBox editor, bool editing)
    {
        editor.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;

        if (editor.Parent is Panel panel)
        {
            foreach (UIElement child in panel.Children)
            {
                if (child is TextBlock { Tag: "NoteBodyDisplay" } display)
                {
                    display.Visibility = editing ? Visibility.Collapsed : Visibility.Visible;
                }
            }
        }

        if (editing)
        {
            editor.Focus();
            editor.CaretIndex = editor.Text.Length;
        }
    }

    /// <summary>在卡片容器里找正文编辑器（Tag="NoteBody"），避免误取到标题框。</summary>
    private static TextBox? FindNoteBodyEditor(DependencyObject parent)
    {
        int count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent);
        for (int i = 0; i < count; i++)
        {
            DependencyObject child = System.Windows.Media.VisualTreeHelper.GetChild(parent, i);
            if (child is TextBox { Tag: "NoteBody" } editor)
            {
                return editor;
            }

            TextBox? deeper = FindNoteBodyEditor(child);
            if (deeper is not null)
            {
                return deeper;
            }
        }

        return null;
    }

    /// <summary>沿可视树向上找到卡片 ViewModel（色板按钮的 DataContext 是颜色名，不是卡片）。</summary>
    private NoteCardViewModel? FindAncestorCard(DependencyObject? start)
    {
        while (start is not null)
        {
            if (start is FrameworkElement fe && fe.DataContext is NoteCardViewModel card)
            {
                return card;
            }

            start = System.Windows.Media.VisualTreeHelper.GetParent(start);
        }

        return null;
    }

    private static T? FindVisualChild<T>(DependencyObject parent) where T : DependencyObject
    {
        int count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent);
        for (int i = 0; i < count; i++)
        {
            DependencyObject child = System.Windows.Media.VisualTreeHelper.GetChild(parent, i);
            if (child is T typed)
            {
                return typed;
            }

            T? deeper = FindVisualChild<T>(child);
            if (deeper is not null)
            {
                return deeper;
            }
        }

        return null;
    }

    /// <summary>
    /// 沿可视树（必要时退回逻辑树）向上找第一个指定类型的祖先。
    /// 命中的元素可能就是起点本身。
    /// </summary>
    private static T? FindAncestor<T>(DependencyObject? node) where T : DependencyObject
    {
        while (node is not null)
        {
            if (node is T match)
            {
                return match;
            }

            node = node switch
            {
                System.Windows.Media.Media3D.Visual3D => System.Windows.Media.VisualTreeHelper.GetParent(node),
                System.Windows.Media.Visual => System.Windows.Media.VisualTreeHelper.GetParent(node),
                FrameworkContentElement fce => fce.Parent,
                _ => LogicalTreeHelper.GetParent(node)
            };
        }

        return null;
    }

    /* ---------- 2026-11-01（发布前审查 B3）：搜索 ---------- */

    /// <summary>
    /// 占位提示的显隐。搜索框本身不带 Text="搜索…"，
    /// 否则用户输入后会把占位文字当成搜索词的一部分（原 bug）。
    /// </summary>
    private void UpdateSearchPlaceholder()
    {
        if (SearchPlaceholder is null || SearchBox is null)
        {
            return;
        }

        SearchPlaceholder.Visibility = string.IsNullOrEmpty(SearchBox.Text)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        UpdateSearchPlaceholder();
        ApplySearchFilter(SearchBox?.Text);
    }

    private void SearchBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
        => UpdateSearchPlaceholder();

    private void SearchBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
        => UpdateSearchPlaceholder();

    /// <summary>
    /// 按搜索词过滤「目录路径项 + 当前标签页的便签/剪贴板」。
    /// 传空串（或全空白）即还原。
    /// </summary>
    private void ApplySearchFilter(string? raw)
    {
        string query = (raw ?? string.Empty).Trim();
        if (string.Equals(query, _searchQuery, StringComparison.Ordinal))
        {
            return;
        }

        _searchQuery = query;
        bool active = query.Length > 0;

        ApplyPathSearchFilter(active ? query : null);
        ApplyClipboardSearchFilter(active ? query : null);
        ApplyNotesSearchFilter(active ? query : null);

        DiagLog.Write("search", active ? $"filter {query.Length} chars" : "cleared");
    }

    /// <summary>路径项就地过滤；搜索中强制展开命中的分类。</summary>
    private void ApplyPathSearchFilter(string? query)
    {
        foreach (CategoryViewModel cat in _categories)
        {
            if (query is null)
            {
                // 还原：先把快照里的全量项放回去，再恢复用户原来的折叠状态。
                if (_allPathItems.TryGetValue(cat.Id, out List<PathItemViewModel>? snapshot))
                {
                    cat.Items.Clear();
                    foreach (PathItemViewModel item in snapshot)
                    {
                        cat.Items.Add(item);
                    }
                }

                cat.SetSearchExpand(false);
                continue;
            }

            if (!_allPathItems.TryGetValue(cat.Id, out List<PathItemViewModel>? all))
            {
                all = cat.Items.ToList();
                _allPathItems[cat.Id] = all;
            }

            List<PathItemViewModel> hits = all
                .Where(i => Contains(i.Name, query) || Contains(i.Target, query))
                .ToList();

            cat.Items.Clear();
            foreach (PathItemViewModel item in hits)
            {
                cat.Items.Add(item);
            }

            // 命中就展开（只改显示，不动 Model.Expanded）。
            cat.SetSearchExpand(hits.Count > 0);
        }

        if (query is null)
        {
            _allPathItems.Clear();
        }
    }

    private void ApplyClipboardSearchFilter(string? query)
    {
        if (query is null)
        {
            if (_clipFilterView is not null)
            {
                _clipFilterView = null;
                if (ClipboardList is not null)
                {
                    ClipboardList.ItemsSource = _clipItems;
                }
            }

            return;
        }

        _clipFilterView ??= new ObservableCollection<ClipEntry>();
        _clipFilterView.Clear();
        foreach (ClipEntry entry in _clipItems)
        {
            if (Contains(entry.Preview, query) || Contains(entry.SourceApp, query))
            {
                _clipFilterView.Add(entry);
            }
        }

        if (ClipboardList is not null)
        {
            ClipboardList.ItemsSource = _clipFilterView;
        }
    }

    private void ApplyNotesSearchFilter(string? query)
    {
        if (query is null)
        {
            if (_noteFilterView is not null)
            {
                _noteFilterView = null;
                if (NotesList is not null)
                {
                    NotesList.ItemsSource = _notes.Cards;
                }
            }

            UpdateNotesEmptyState();
            return;
        }

        _noteFilterView ??= new ObservableCollection<NoteCardViewModel>();
        _noteFilterView.Clear();
        foreach (NoteCardViewModel card in _notes.Cards)
        {
            // 注意用 Text 而不是 Preview：Preview 在非空卡片上返回空串，
            // 它是「空卡片…」占位用的，不是摘要。
            if (Contains(card.Text, query))
            {
                _noteFilterView.Add(card);
            }
        }

        if (NotesList is not null)
        {
            NotesList.ItemsSource = _noteFilterView;
        }

        UpdateNotesEmptyState();
    }

    /// <summary>
    /// 底层集合变化后重算过滤视图。只在搜索激活时生效；
    /// 未搜索时过滤视图为 null，什么也不做。
    /// </summary>
    private void RefreshFilterViewsIfSearching()
    {
        if (_searchQuery.Length == 0)
        {
            return;
        }

        ApplyClipboardSearchFilter(_searchQuery);
        ApplyNotesSearchFilter(_searchQuery);
    }

    /// <summary>大小写不敏感的子串匹配；null/空源一律不命中。</summary>
    private static bool Contains(string? source, string query)
        => !string.IsNullOrEmpty(source)
           && source!.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0;

    private void UpdateNotesEmptyState()
    {
        if (NotesEmpty is null)
        {
            return;
        }

        // 搜索中要看「命中数」而不是全量数：全量非空但一条都没命中时
        // 列表是空的，仍应给出占位提示，否则用户会以为界面坏了。
        int visible = _noteFilterView?.Count ?? _notes.Cards.Count;
        NotesEmpty.Visibility = visible == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>便签集合落盘（NotesViewModel 的保存回调）。</summary>
    private void SaveNotesToDisk()
    {
        if (!NoteStore.Save(_notes.ToModels()))
        {
            ReportSaveFailure("便签");
        }
    }

    /* ---------- 剪贴板：捕获 / 展示 / 交互 ---------- */

    /// <summary>新记录捕获（从后台线程触发，需切回 UI 线程）。</summary>
    private void Clipboard_EntryCaptured(ClipEntry entry)
    {
        Dispatcher.Invoke(() =>
        {
            _clipItems.Insert(0, entry);
            UpdateClipboardEmptyState();

            // 不在剪贴板页时累加未读角标（决策 #7）
            if (TabClipboard.IsChecked != true)
            {
                _clipboardUnread++;
                UpdateBadge();
            }

            SaveClipboardHistory();
        });
    }

    /// <summary>记录被容量淘汰时移除对应 UI 项。</summary>
    private void Clipboard_EntryEvicted(ClipEntry entry)
    {
        Dispatcher.Invoke(() =>
        {
            _clipItems.Remove(entry);
            ClipboardBlobStore.Delete(entry.BlobPath);
            UpdateClipboardEmptyState();
            SaveClipboardHistory();
        });
    }

    private void UpdateClipboardEmptyState()
    {
        if (ClipboardEmpty is null)
        {
            return;
        }

        ClipboardEmpty.Visibility = _clipItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /* ---------- 点击历史记录 → 自动粘贴（2026-10-25） ---------- */

    /// <summary>
    /// 单击历史记录：写回剪贴板并把内容粘贴到"抽屉外的那个前台窗口"。
    /// 用 PreviewMouseLeftButtonUp 而不是 SelectionChanged / MouseDoubleClick：
    /// 面板是 ShowActivated=false，键盘焦点不可靠，单击是最直接的意图表达。
    /// </summary>
    private void ClipboardList_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject origin)
        {
            return;
        }

        // 点在固定/锁定按钮上时只切锁定状态，不要粘贴
        if (FindAncestor<Button>(origin) is not null)
        {
            return;
        }

        if (FindAncestor<ListBoxItem>(origin)?.DataContext is not ClipEntry entry)
        {
            return;
        }

        PasteEntry(entry);
    }

    /// <summary>
    /// 粘贴一条历史记录到目标窗口：写回剪贴板 → 切前台 → 延迟后发 Ctrl+V。
    /// 延迟是必要的：SetForegroundWindow 只是"请求"，目标进程可能仍在激活过程中，
    /// 立刻发按键会打在自己身上。
    /// </summary>
    private void PasteEntry(ClipEntry entry)
    {
        // 防误触双击：350ms 内的第二次 Up 直接忽略
        if ((DateTime.UtcNow - _lastPasteAt).TotalMilliseconds < 350)
        {
            return;
        }

        _lastPasteAt = DateTime.UtcNow;

        IntPtr target = ResolvePasteTarget();
        bool written = ClipboardService.WriteBack(entry);

        if (!written)
        {
            MessageBox.Show(this, "无法写入剪贴板，可能被其他程序占用，请稍后重试。",
                "QuickDrawer", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        // 我们刚改写了剪贴板，别把它当成"用户新复制的内容"又捕获一条
        _clipboard?.SuppressRecapture(entry);

        if (target == IntPtr.Zero)
        {
            // 找不到可粘贴的目标：退化成"只复制"，旧行为仍可用
            DiagLog.Write("paste", $"copied only ({entry.Kind}): no target window");
            return;
        }

        // 收起面板，免得挡住目标窗口的输入框
        HideAnimated();

        NativeMethods.SetForegroundWindow(target);
        DiagLog.Write("paste", $"target=0x{target.ToInt64():X} kind={entry.Kind}");

        System.Windows.Threading.DispatcherTimer timer = new()
        {
            Interval = TimeSpan.FromMilliseconds(80)
        };

        timer.Tick += (_, _) =>
        {
            timer.Stop();

            IntPtr foreground = NativeMethods.GetForegroundWindow();
            if (foreground != target)
            {
                // 没切过去就补一次
                NativeMethods.SetForegroundWindow(target);
                foreground = NativeMethods.GetForegroundWindow();
            }

            if (foreground != target)
            {
                // 仍不是目标：宁可不粘贴，也不要把 Ctrl+V 打进自己面板
                DiagLog.Write("paste",
                    $"abort Ctrl+V: foreground=0x{foreground.ToInt64():X} expected=0x{target.ToInt64():X}");
                return;
            }

            uint sent = NativeMethods.SendCtrlV();
            DiagLog.Write("paste", $"sent Ctrl+V, events={sent} (4 = ok)");
        };

        timer.Start();
    }

    /// <summary>记录抽屉外的最后一个前台窗口，作为粘贴目标。</summary>
    private void TrackPasteTarget()
    {
        IntPtr foreground = NativeMethods.GetForegroundWindow();
        if (foreground == IntPtr.Zero || IsOwnWindow(foreground))
        {
            return;
        }

        _pasteTarget = foreground;
    }

    /// <summary>是否本进程自己的窗口（面板、托盘、消息窗都不算粘贴目标）。</summary>
    private static bool IsOwnWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return true;
        }

        NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
        return pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    }

    /// <summary>挑选粘贴目标；都失效时返回 0。</summary>
    private IntPtr ResolvePasteTarget()
    {
        TrackPasteTarget();

        if (_pasteTarget != IntPtr.Zero &&
            !IsOwnWindow(_pasteTarget) &&
            NativeMethods.IsWindow(_pasteTarget))
        {
            return _pasteTarget;
        }

        IntPtr foreground = NativeMethods.GetForegroundWindow();
        if (foreground != IntPtr.Zero && !IsOwnWindow(foreground))
        {
            _pasteTarget = foreground;
            return foreground;
        }

        return IntPtr.Zero;
    }

    /// <summary>固定/取消固定某条记录。</summary>
    private void PinClip_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id })
        {
            return;
        }

        ClipEntry? entry = _clipItems.FirstOrDefault(c => c.Id == id);
        if (entry is null)
        {
            return;
        }

        entry.Pinned = !entry.Pinned;

        // 固定项排前面
        int idx = _clipItems.IndexOf(entry);
        if (idx >= 0)
        {
            _clipItems.RemoveAt(idx);
        }

        if (entry.Pinned)
        {
            _clipItems.Insert(0, entry);
        }
        else
        {
            int afterPinned = _clipItems.Count(c => c.Pinned);
            _clipItems.Insert(Math.Min(afterPinned, _clipItems.Count), entry);
        }

        SaveClipboardHistory();
        // 隐私（B1）：只记类型与字节数。这里原来记完整 Preview（最长 200 字符，
        // 且不截断），是全项目泄露最严重的一处日志。
        DiagLog.Write("clipboard",
            $"{(entry.Pinned ? "pinned" : "unpinned")} {entry.Kind} {entry.SizeBytes}B");
    }

    /// <summary>
    /// 剪贴板保存的串行化闸门。
    /// S8：保存要逐条 DPAPI + 整表重写文件，500 条时在 UI 线程上会明显卡顿。
    /// 现在快照留在 UI 线程（微秒级），加密与写盘走后台。
    /// </summary>
    private readonly object _clipSaveGate = new();

    /// <summary>快照序号：后台任务发现自己是旧的就直接放弃，避免积压。</summary>
    private int _clipSaveGeneration;

    /// <summary>保存剪贴板历史（DPAPI 加密）。快照在 UI 线程拍，加密与写盘在后台。</summary>
    private void SaveClipboardHistory()
    {
        // 拍快照必须在 UI 线程：读的是可变的 ClipEntry。
        List<ClipboardStore.ClipSnapshot> snaps;
        try
        {
            snaps = ClipboardStore.SnapshotAll(_clipItems);
        }
        catch (Exception ex)
        {
            DiagLog.Write("clipboard", $"snapshot failed: {ex.Message}");
            return;
        }

        int generation = ++_clipSaveGeneration;

        _ = Task.Run(() =>
        {
            // 已经有更新的快照排在后面时，这次写盘没有意义（后写的一定更全）。
            if (generation != _clipSaveGeneration)
            {
                return;
            }

            bool ok;
            lock (_clipSaveGate)
            {
                if (generation != _clipSaveGeneration)
                {
                    return;
                }

                ok = ClipboardStore.SaveSnapshot(snaps);
            }

            if (!ok)
            {
                ReportSaveFailure("剪贴板历史");
            }
        });
    }

    /// <summary>
    /// 退出前同步落盘一次。
    /// 后台保存是"发了就走"的，进程退出时可能还没写完，所以关闭路径必须走这里。
    /// </summary>
    private void FlushClipboardHistory()
    {
        try
        {
            lock (_clipSaveGate)
            {
                if (!ClipboardStore.Save(_clipItems))
                {
                    DiagLog.Write("clipboard", "final flush failed");
                }
            }
        }
        catch (Exception ex)
        {
            DiagLog.Write("clipboard", $"final flush failed: {ex.Message}");
        }
    }

    /// <summary>
    /// 保存失败时明确告诉用户（S10）。
    /// 原来三个 Store 都是"catch 后写日志、返回 void"，UI 照样显示已保存，
    /// 用户以为数据存下来了，下次启动才发现没了。
    /// 用非模态提示窗：不打断操作，也不会像 MessageBox 那样挂住消息循环。
    /// </summary>
    private static void ReportSaveFailure(string what)
    {
        App.ShowNotice(
            $"{what}保存失败：无法写入配置目录。\n" +
            "可能是磁盘已满，或该目录没有写权限。\n" +
            "本次改动只存在内存中，退出后会丢失。",
            TimeSpan.FromSeconds(10));
    }

    private void UpdateBadge()
    {
        if (_clipboardUnread > 0)
        {
            ClipboardBadge.Text = _clipboardUnread.ToString();
            ClipboardBadge.Visibility = Visibility.Visible;
        }
        else
        {
            ClipboardBadge.Visibility = Visibility.Collapsed;
        }
    }

    /* ==================== 顶部菜单（决策 #4） ==================== */

    /// <summary>打开设置页（已打开则置前）。</summary>
    private void OpenSettings()
    {
        DiagLog.Write("settings", "OpenSettings called");

        if (_settingsWindow is not null)
        {
            DiagLog.Write("settings", "activating existing window");
            _settingsWindow.Activate();
            return;
        }

        DiagLog.Write("settings", "constructing SettingsWindow");
        _settingsWindow = new SettingsWindow(this, _config);
        DiagLog.Write("settings", "constructed OK");

        _settingsWindow.SettingsChanged += cfg =>
        {
            DiagLog.Write("settings", "SettingsChanged -> RefreshSize");
            _handle?.RefreshSize(cfg);
        };
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;

        DiagLog.Write("settings", "calling Show()");
        _settingsWindow.Show();
        DiagLog.Write("settings", "Show() returned, window visible");
    }

    private void MenuButton_Click(object sender, RoutedEventArgs e)
    {
        OpenAppMenu(sender as Button);
    }

    /// <summary>
    /// 应用菜单（M5 起面板与托盘共用）：
    /// 设置 / 开机自启（勾选态）/ 关于 / 退出。
    /// </summary>
    private void OpenAppMenu(UIElement? placementTarget, Point? screenPoint = null)
    {
        var menu = new ContextMenu();

        var settings = new MenuItem { Header = "设置…" };
        settings.Click += (_, _) => OpenSettings();

        // 2026-11-08 用户需求：全屏游戏/全屏视频时临时关掉拉手热区。
        // 为什么放在托盘而不是设置页：这是个"当场要关"的动作，进了全屏游戏就点不到设置；
        // 而且它同时是检测失效时的唯一逃生门（拉手已被藏，没法从拉手上唤起面板）。
        var hideFullscreen = new MenuItem
        {
            Header = "全屏时隐藏拉手",
            IsCheckable = true,
            IsChecked = _config.Dock.Handle.HideInFullscreen,
            IsEnabled = _handle is not null
        };
        hideFullscreen.Click += (_, _) =>
        {
            bool target = !_config.Dock.Handle.HideInFullscreen;
            _config.Dock.Handle.HideInFullscreen = target;
            ConfigStore.Save(_config);
            hideFullscreen.IsChecked = target;

            // 不等下一个 500ms tick：用户刚点完，拉手应该立刻回来/消失。
            // 注意关掉开关时必须把抑制标志清零，否则 _handleSuppressedByFullscreen
            // 还停在 true，UpdateHandleVisibility 一样不会显示。
            if (!target)
            {
                _handleSuppressedByFullscreen = false;
            }

            DiagLog.Write("handle", $"tray toggle: hideInFullscreen={target}");
            UpdateHandleVisibility();
        };

        var autoStart = new MenuItem
        {
            Header = "开机自启",
            IsCheckable = true,
            IsChecked = AutoStart.IsEnabled()
        };
        autoStart.Click += (_, _) =>
        {
            bool target = !AutoStart.IsEnabled();
            if (AutoStart.SetEnabled(target))
            {
                _config.StartWithWindows = target;
                ConfigStore.Save(_config);
                autoStart.IsChecked = target;
            }
        };

        var about = new MenuItem { Header = "关于" };
        about.Click += (_, _) => MessageBox.Show(this,
            "QuickDrawer\n\nWindows 桌面侧边栏快取抽屉工具。\nMIT License.",
            "关于 QuickDrawer", MessageBoxButton.OK, MessageBoxImage.Information);

        var exit = new MenuItem { Header = "退出" };
        exit.Click += (_, _) => Application.Current.Shutdown();

        menu.Items.Add(settings);
        menu.Items.Add(hideFullscreen);
        menu.Items.Add(autoStart);
        menu.Items.Add(about);
        menu.Items.Add(new Separator());
        menu.Items.Add(exit);

        // 托盘入口没有 placementTarget，用屏幕坐标弹出
        if (placementTarget is not null)
        {
            menu.PlacementTarget = placementTarget;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        }
        else if (screenPoint is { } p)
        {
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.AbsolutePoint;
            menu.HorizontalOffset = p.X;
            menu.VerticalOffset = p.Y;
        }

        menu.IsOpen = true;
    }

    /* ==================== 拖入支持（决策 #8） ==================== */

    private void Drawer_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(System.Windows.DataFormats.FileDrop)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
        e.Handled = true;
    }

    /// <summary>
    /// 拖入处理。应用与路径分流由 ShellLink 解析结果决定（问题 1 的修复点）。
    /// 路径类拖入时让用户选目标分类（问题 4）。
    /// </summary>
    private void Drawer_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(System.Windows.DataFormats.FileDrop) is not string[] files || files.Length == 0)
        {
            return;
        }

        var classified = files.Select(f => (Path: f, Item: ShortcutStore.Classify(f))).ToList();

        int appsAdded = 0;

        // ---- 应用类 ----
        foreach (var (_, item) in classified.Where(c => c.Item.Kind == "app"))
        {
            if (_data.Apps.Any(a => a.Target.Equals(item.Target, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            item.Order = _data.Apps.Count;
            _data.Apps.Add(item);
            appsAdded++;
            DiagLog.Write("drop", $"app -> {item.Name} ({item.Target})");
        }

        // ---- 路径类 ----
        var pathItems = classified.Where(c => c.Item.Kind != "app").ToList();
        if (pathItems.Count > 0)
        {
            var picker = new CategoryPickerDialog(_data.Categories,
                pathItems.Count == 1 ? $"把「{pathItems[0].Item.Name}」加到哪个分类？" : "把这些路径加到哪个分类？")
            {
                Owner = this
            };

            if (picker.ShowDialog() == true && picker.Selected is not null)
            {
                foreach (var (_, item) in pathItems)
                {
                    item.CategoryId = picker.Selected.Id;
                    item.Order = _data.Paths.Count(p => p.CategoryId == picker.Selected.Id);
                    _data.Paths.Add(item);
                    DiagLog.Write("drop", $"{item.Kind} {item.Name} -> category {picker.Selected.Name}");
                }
            }
        }

        RebuildBindings();
        SaveAll();

        if (appsAdded == 0 && pathItems.Count == 0)
        {
            return;
        }
    }

    /* ==================== 启动目标 ==================== */

    private static void LaunchTarget(ShortcutItem item)
    {
        try
        {
            if (!File.Exists(item.Target) && !Directory.Exists(item.Target))
            {
                MessageBox.Show($"目标不存在：\n{item.Target}", "QuickDrawer",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            // ShellExecute 让系统按文件类型决定行为：exe 启动、目录用资源管理器打开
            IntPtr r = NativeMethods.ShellExecute(IntPtr.Zero, "open", item.Target,
                item.Args ?? string.Empty, string.Empty, NativeMethods.SW_SHOWNORMAL);

            // ShellExecute 返回值 > 32 表示成功
            if ((long)r <= 32)
            {
                DiagLog.Write("launch", $"ShellExecute failed for {item.Target}, ret={r}");
                MessageBox.Show($"打开失败：\n{item.Target}", "QuickDrawer",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            item.UseCount++;
            item.LastUsedAt = DateTime.UtcNow.ToString("o");
            DiagLog.Write("launch", $"ok: {item.Name} ({item.Target})");
        }
        catch (Exception ex)
        {
            DiagLog.Write("launch", $"exception for {item.Target}: {ex.Message}");
            MessageBox.Show($"打开时出错：\n{ex.Message}", "QuickDrawer",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    /* ==================== 绑定与持久化 ==================== */

    private void RebuildBindings()
    {
        _apps.Clear();
        foreach (var app in _data.Apps.OrderBy(a => a.Order))
        {
            _apps.Add(new AppTileViewModel(app));
        }

        _categories.Clear();
        foreach (var cat in _data.Categories.OrderBy(c => c.Order))
        {
            var vm = new CategoryViewModel(cat);
            foreach (var p in _data.Paths.Where(p => p.CategoryId == cat.Id).OrderBy(p => p.Order))
            {
                vm.Items.Add(new PathItemViewModel(p));
            }

            _categories.Add(vm);
        }

        ApplyPathLayout();
    }

    /// <summary>
    /// 面板诞生时按当前配置定向（2026-10-23 根治"点击后变回横排"）。
    /// RebuildBindings 会销毁并重建面板，"切换时设置一次方向"会随重建丢失；
    /// 改为面板 Loaded 时自己读配置定向，重建多少次都正确。
    ///
    /// 分类级覆盖（同日需求）：分类内含盘符（ForceHorizontal）时
    /// **永远横向**，不受全局列表模式影响，且加宽间距。
    /// </summary>
    private void PathPanel_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.WrapPanel wp)
        {
            return;
        }

        bool categoryForced = wp.DataContext is CategoryViewModel cat && cat.ForceHorizontal;
        bool listMode = _config.Layout.Paths == "list" && !categoryForced;

        wp.Orientation = listMode ? Orientation.Vertical : Orientation.Horizontal;
    }

    /// <summary>
    /// 按配置应用路径区的"图标 / 列表"布局（2026-10-19 用户需求）。
    /// 直接替换已生成的视觉树内容，切换即时且不重复取图标。
    /// </summary>
    private void ApplyPathLayout()
    {
        if (!IsLoaded || PathLayoutToggle is null)
        {
            return;
        }

        bool listModeGlobal = _config.Layout.Paths == "list";
        PathLayoutToggle.Content = listModeGlobal ? "≡" : "▦";
        PathLayoutToggle.ToolTip = listModeGlobal ? "切换为图标显示" : "切换为列表显示";

        // 2026-10-23 修复"没有纵向列表"：
        // 容器是 WrapPanel。Horizontal（图标模式）= 横向填充、满行换行；
        // Vertical（列表模式）= 自上而下排列，面板高度不限时即单列纵向列表。
        // 通过可视树找到每个分类的实际面板实例切方向。
        // 分类级覆盖：含盘符的分类永远横向。
        foreach (CategoryViewModel cat in _categories)
        {
            if (FindCategoryHost(cat) is not ItemsControl host)
            {
                continue;
            }

            bool listMode = listModeGlobal && !cat.ForceHorizontal;

            if (DropPosition.GetItemsPanel(host) is System.Windows.Controls.WrapPanel wp)
            {
                wp.Orientation = listMode
                    ? Orientation.Vertical
                    : Orientation.Horizontal;
            }
        }

        foreach (CategoryViewModel cat in _categories)
        {
            foreach (PathItemViewModel item in cat.Items)
            {
                if (item.Button is not Button btn)
                {
                    continue;
                }

                bool drive = item.Model.Kind == "drive";
                bool listMode = listModeGlobal && !drive && !cat.ForceHorizontal;

                btn.Content = listMode ? BuildListRow(item) : BuildIconRow(item);

                // 2026-10-23 修复"没有纵向列表"：
                // 之前只换了 Button 内容，排列容器始终是横向 WrapPanel。
                // 列表模式：按钮占满整行（横向 Stretch）形成纵向列表；
                // 图标模式：恢复自适应宽度参与网格换行；盘符间距只加右侧（左侧为0才能与分类名首字对齐）。
                btn.HorizontalAlignment = listMode
                    ? HorizontalAlignment.Stretch
                    : HorizontalAlignment.Left;
                btn.Margin = listMode
                    ? new Thickness(0, 0, 0, 2)
                    : new Thickness(0, 0, drive ? 10 : 0, 0);
            }
        }
    }

    /// <summary>
    /// 路径项图标的方框边长（DIP）。2026-11-06 用户需求（m08752）：
    /// "调整路径下添加的快捷项的图标大小，图标与文字保持高度一致。我的电脑除外。"
    ///
    /// 为什么不是常量：图标要和它**自己那一行**的文字等高。列表模式字号 13、
    /// 图标模式字号 12，用同一个固定值必然有一边对不齐。用 字号+4 让两者
    /// 永远同步，日后改字号不用回来改这里。
    ///
    /// 为什么是 +4：实测（400x1032 截图像素量取）20px 方框下文件夹图标墨迹高 14px、
    /// 文件图标 15px，而 13px 中文字符墨迹高 12px —— 图标视觉上大一圈。
    /// 方框缩到 17px 后文件夹图标墨迹约 12px，与文字齐平。
    /// </summary>
    private static double PathIconBox(double fontSize) => fontSize + 4;

    /// <summary>盘符项（"我的电脑"分类）的图标方框：用户明确要求这一组保持原样 20px。</summary>
    private const double DriveIconBox = 20;

    private static UIElement BuildIconRow(PathItemViewModel item)
    {
        // 2026-11-06 m08752：图标与文字等高；"我的电脑"（盘符）保持 20px 不变。
        bool drive = item.Model.Kind == "drive";
        double box = drive ? DriveIconBox : PathIconBox(12);

        StackPanel panel = new() { Orientation = Orientation.Horizontal };
        panel.Children.Add(new System.Windows.Controls.Image
        {
            Width = box,
            Height = box,
            Stretch = System.Windows.Media.Stretch.Uniform,
            Source = item.Icon
        });
        TextBlock label = new()
        {
            Text = item.Name,
            FontSize = 12,
            Margin = new Thickness(4, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        // 2026-11-01：原本硬编码 Gainsboro（浅灰），浅色主题下与浅底几乎同色，
        // 对比度仅 1.27:1（WCAG AA 要求 4.5:1）。改走主题资源。
        label.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimary");
        panel.Children.Add(label);
        return panel;
    }

    private static UIElement BuildListRow(PathItemViewModel item)
    {
        // 列表模式：左图标 + 右(名称/完整路径)两行，便于辨认同名项
        Grid grid = new();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        // 2026-11-06 m08752：列表模式字号 13，图标方框随之取 17，与文字等高。
        // （列表模式对盘符项不生效，见 PathItem_Loaded 的 !drive 判断；
        //   这里仍按盘符分支写全，避免日后放开限制时对不齐。）
        double box = item.Model.Kind == "drive" ? DriveIconBox : PathIconBox(13);
        System.Windows.Controls.Image img = new()
        {
            Width = box,
            Height = box,
            Stretch = System.Windows.Media.Stretch.Uniform,
            Source = item.Icon,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0)
        };
        Grid.SetColumn(img, 0);
        grid.Children.Add(img);

        StackPanel text = new();

        // 2026-10-23 用户需求：列表模式去掉显式路径行，保留名称即可
        //（完整路径仍可通过悬停 ToolTip 查看）。
        TextBlock name = new()
        {
            Text = item.Name,
            FontSize = 13,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        name.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimary");
        text.Children.Add(name);

        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        return grid;
    }

    /// <summary>路径区布局切换按钮（2026-10-19）。</summary>
    private void PathLayoutToggle_Click(object sender, RoutedEventArgs e)
    {
        _config.Layout.Paths = _config.Layout.Paths == "list" ? "icon" : "list";
        ApplyPathLayout();
        SaveAll();
        DiagLog.Write("layout", $"paths layout -> {_config.Layout.Paths}");
    }

    /* ==================== 便签/剪贴板区高度拖动（2026-10-24） ==================== */

    // 分隔条分隔的是「目录路径区」与「便签/剪贴板区」：
    //   便签区 = Star（永远吃满剩余空间），目录区 = 固定像素高度（默认 Auto = 内容高度）。
    // 所以拖动只改目录区高度，便签区自动跟着反向变化，不会出现"拖不动"或"底下留白"。
    // 第一版曾试图直接改便签区高度，但它是唯一的 Star 行、可用空间等于它自身，
    // 夹范围后 max == 当前高度，往上拖必然无效（2026-10-24 探针实测 581.4 → 581.4）。

    /// <summary>目录区最小高度（DIP）：标题行 + 约两行分类。</summary>
    private const double PathAreaMinHeight = 90;

    /// <summary>便签/剪贴板区最小高度（DIP）：标签行 + 一张便签卡。</summary>
    private const double BottomAreaMinHeight = 120;

    private bool _splitterDragging;
    private double _splitterDragStartY;
    private double _splitterDragStartPathHeight;

    private void BottomSplitter_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        // 双击：恢复"目录区按内容高度自动"
        if (e.ClickCount == 2)
        {
            ResetSplitter();
            e.Handled = true;
            return;
        }

        _splitterDragging = true;
        _splitterDragStartY = e.GetPosition(this).Y;
        _splitterDragStartPathHeight = PathAreaRow.ActualHeight;
        BottomSplitter.CaptureMouse();
        DiagLog.Write("splitter", $"drag start path={_splitterDragStartPathHeight:F1}");
        e.Handled = true;
    }

    private void BottomSplitter_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_splitterDragging)
        {
            return;
        }

        // 往上拖（Y 变小）→ 目录区变矮 → 便签区变高；往下拖则相反
        double delta = e.GetPosition(this).Y - _splitterDragStartY;
        ApplyPathAreaHeight(_splitterDragStartPathHeight + delta);
    }

    private void BottomSplitter_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_splitterDragging)
        {
            return;
        }

        _splitterDragging = false;
        BottomSplitter.ReleaseMouseCapture();

        // 落盘：记住拖动后的分隔位置，下次启动恢复
        _config.Layout.PathAreaHeight = Math.Round(PathAreaRow.ActualHeight, 1);
        SaveAll();
        DiagLog.Write("splitter",
            $"drag end path={PathAreaRow.ActualHeight:F1} bottom={BottomAreaRow.ActualHeight:F1} " +
            $"saved={_config.Layout.PathAreaHeight:F1}");
        e.Handled = true;
    }

    /// <summary>
    /// 应用目录区高度：夹在 [目录区最小, 窗口高度 − 其它固定行 − 便签区最小] 之间。
    /// </summary>
    private void ApplyPathAreaHeight(double height)
    {
        double max = ComputePathAreaMaxHeight();
        double value = Math.Max(PathAreaMinHeight, Math.Min(height, max));
        if (max < PathAreaMinHeight)
        {
            value = Math.Max(0, max);
        }

        PathAreaRow.Height = new GridLength(value);
    }

    /// <summary>窗口尺寸变化（切显示器 / DPI 变化）后重新夹一次，避免越界。</summary>
    private void RootGrid_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_splitterDragging)
        {
            return;
        }

        if (PathAreaRow.Height.IsAbsolute)
        {
            ApplyPathAreaHeight(PathAreaRow.Height.Value);
        }
    }

    /* ==================== 底部仪表盘（2026-11-03 用户需求） ==================== */

    /// <summary>
    /// 启动仪表盘刷新。每秒一帧；面板收起时停掉（见 <see cref="StopDashboard"/>），
    /// 展开时再继续 —— 没人看着的时候不该一直烧 CPU 采样。
    /// </summary>
    private void StartDashboard()
    {
        _dashboard ??= new DashboardSampler();

        // 先同步采一帧：CPU/网速是差分指标，第一帧只建基线，
        // 但内存是绝对值，立刻就能显示，不至于刚打开面板时全是「--」。
        _dashboard.Sample();
        RenderDashboard();

        if (_dashboardTimer is null)
        {
            _dashboardTimer = new System.Windows.Threading.DispatcherTimer
            {
                Interval = TimeSpan.FromSeconds(1)
            };
            _dashboardTimer.Tick += (_, _) =>
            {
                _dashboard?.Sample();
                RenderDashboard();
            };
        }

        _dashboardTimer.Start();
        DiagLog.Write("dashboard", "started (1s interval)");
    }

    private void StopDashboard()
    {
        if (_dashboardTimer is not null)
        {
            _dashboardTimer.Stop();
            _dashboardTimer = null;
            DiagLog.Write("dashboard", "stopped");
        }
    }

    private void RenderDashboard()
    {
        if (_dashboard is null)
        {
            return;
        }

        DashCpuRun.Text = _dashboard.CpuPercent is double cpu
            ? " " + (int)Math.Round(cpu) + "%"
            : " --";

        DashMemRun.Text = _dashboard.MemoryTotalGb > 0
            ? $" {_dashboard.MemoryPercent}%"
            : " --";
        DashMem.ToolTip = _dashboard.MemoryTotalGb > 0
            ? $"已用 {_dashboard.MemoryUsedGb:F1} GB / 共 {_dashboard.MemoryTotalGb:F1} GB"
            : "内存状态不可用";

        DashNetRun.Text = " " + FormatRate(_dashboard.NetDownBytesPerSec)
                          + "↓ " + FormatRate(_dashboard.NetUpBytesPerSec) + "↑";
        DashNet.ToolTip = "下载 ↓ / 上传 ↑（当前所有已连接网卡之和）";
    }

    /// <summary>
    /// 把字节/秒格式化成 3 个字符内的短串 —— 仪表盘至少三格分掉面板宽（400px 时网速格约 160px），
    /// 写 "1234.5 KB/s" 一定被裁掉。单位用 K/M 而不是 KB/s，靠 ToolTip 补全语义。
    /// </summary>
    private static string FormatRate(double bytesPerSecond)
    {
        if (bytesPerSecond <= 0)
        {
            return "0";
        }

        double kb = bytesPerSecond / 1024.0;
        if (kb < 1)
        {
            return "0";
        }

        if (kb < 1000)
        {
            return kb < 10 ? kb.ToString("F1") + "K" : (int)Math.Round(kb) + "K";
        }

        double mb = kb / 1024.0;
        return mb < 10 ? mb.ToString("F1") + "M" : (int)Math.Round(mb) + "M";
    }

    /// <summary>
    /// 点 CPU 那格打开任务管理器（用户明确要求）。
    /// 用 Process.Start 而不是 ShellExecute：taskmgr.exe 是系统可执行文件，
    /// 不需要"按文件类型关联打开"，后者返回的 HINSTANCE 编码规则（≤32 = 错误）
    /// 在 net48 里要额外判 symbol，容易写成字符串比较（我第一次就写错了）。
    /// </summary>
    private void DashCpu_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("taskmgr.exe")
            {
                UseShellExecute = true
            });
            DiagLog.Write("dashboard", "taskmgr launched");
        }
        catch (Exception ex)
        {
            DiagLog.Write("dashboard", "failed to open taskmgr: " + ex.Message);
            App.ShowNotice("打不开任务管理器：" + ex.Message, TimeSpan.FromSeconds(8));
        }
    }

    /// <summary>
    /// 目录区可用上限 = 窗口高度 − 其它行（0/1 固定内容、3 分隔条）实际高度 − 便签区最小高度。
    /// </summary>
    private double ComputePathAreaMaxHeight()
    {
        if (RootGrid.ActualHeight <= 0)
        {
            return PathAreaMinHeight;
        }

        double used = 0;
        // 2026-11-03：加进 index 5（底部仪表盘）。漏掉它的话目录区上限会多算
        // 一行的高度，拖到极限时便签区会被仪表盘压掉一截。
        foreach (int index in new[] { 0, 1, 3, 5 })
        {
            used += RootGrid.RowDefinitions[index].ActualHeight;
        }

        return Math.Max(0, RootGrid.ActualHeight - used - BottomAreaMinHeight);
    }

    private void ResetSplitter()
    {
        PathAreaRow.Height = GridLength.Auto;
        _config.Layout.PathAreaHeight = 0;
        SaveAll();
        DiagLog.Write("splitter", "reset: path area back to auto (content height)");
    }

    /// <summary>启动时恢复上次拖动的分隔位置（0 = 目录区自动）。</summary>
    private void RestoreSplitter()
    {
        double saved = _config.Layout.PathAreaHeight;
        if (saved <= 0)
        {
            return;
        }

        // 等首次布局完成再夹范围：这时 RowDefinition.ActualHeight 才有值
        Dispatcher.BeginInvoke(new Action(() =>
        {
            ApplyPathAreaHeight(saved);
            DiagLog.Write("splitter", $"restored path={saved:F1} (max={ComputePathAreaMaxHeight():F1})");
        }), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    private void SaveAll()
    {
        if (!ShortcutStore.Save(_data))
        {
            ReportSaveFailure("快捷方式");
        }

        if (!ConfigStore.Save(_config))
        {
            ReportSaveFailure("设置");
        }

        // M4：便签卡片（绑定即时更新 VM，但落盘要在这里兜底——
        // 用户输入中途退出时 LostFocus 可能还没触发）
        if (_notes is not null && !NoteStore.Save(_notes.ToModels()))
        {
            ReportSaveFailure("便签");
        }

        // S8：剪贴板平时在后台异步保存，退出前必须同步写完，否则最后几条会丢。
        FlushClipboardHistory();
    }

    /* ==================== 辅助 ==================== */

    private static string FormatHotkey(uint mods, uint vk)
    {
        List<string> parts = new();
        if ((mods & NativeMethods.MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((mods & NativeMethods.MOD_ALT) != 0) parts.Add("Alt");
        if ((mods & NativeMethods.MOD_SHIFT) != 0) parts.Add("Shift");
        if ((mods & NativeMethods.MOD_WIN) != 0) parts.Add("Win");
        parts.Add("0x" + vk.ToString("X2"));
        return string.Join("+", parts);
    }

    private static bool TryParseVk(string name, out uint vk)
    {
        vk = 0;
        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        name = name.Trim();
        if (name.Length == 1)
        {
            char c = char.ToUpperInvariant(name[0]);
            if (c is >= 'A' and <= 'Z' or >= '0' and <= '9')
            {
                vk = c;
                return true;
            }
        }

        vk = name.ToUpperInvariant() switch
        {
            "F1" => 0x70,
            "F2" => 0x71,
            "F3" => 0x72,
            "F4" => 0x73,
            "SPACE" => 0x20,
            _ => 0u
        };
        return vk != 0;
    }


}
