using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using QuickDrawer.Native;

namespace QuickDrawer.Selection;

/// <summary>
/// 把"全局鼠标拖选 → 取选中文字 → 弹提示词按钮 → 交给助手发送"串起来（2026-10-30 需求）。
///
/// 时序上的讲究：
/// - 钩子回调在钩子线程上，不能直接碰 UI，统一 BeginInvoke 回 UI 线程；
/// - 取文字要在弹条**之前**，弹条一出现（哪怕不激活）也可能影响某些程序的选区；
/// - 任何一次左键按下，如果落点不在弹条上，就把弹条收起来（钩子兼任"点击别处关闭"）。
/// </summary>
internal sealed class SelectionWatcher : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    private readonly AppConfig _config;
    private readonly Action<string> _log;
    private SelectionPopup? _popup;
    private MouseHook? _hook;

    private bool HookInstalled => _hook?.Installed == true;
    private Dispatcher? _dispatcher;
    private DateTime _lastShown = DateTime.MinValue;
    private bool _disposed;

    /// <summary>用户点了某个提示词，参数是预设与当时的选中文字。</summary>
    public event Action<PromptPreset, string>? PromptChosen;

    /// <summary>
    /// 用户点了最左侧「发送」：参数是当时的选中文字。
    /// 上层负责弹编辑器、拼消息、发给助手（2026-10-31 需求）。
    /// </summary>
    public event Action<string>? CustomSendRequested;

    /// <summary>
    /// 截图提问模式下用户点了「发送」：参数是那张待发的截图。
    /// 与 <see cref="CustomSendRequested"/> 分开，是因为上层要走"先发图再打字"的
    /// 另一条链路（2026-11-01 五次需求）。
    /// </summary>
    public event Action<BitmapSource, string>? ShotSendRequested;

    public SelectionWatcher(AppConfig config, Action<string> log)
    {
        _config = config;
        _log = log;
    }

    public void Start()
    {
        if (!_config.Assistant.SelectionPopup)
        {
            _log("disabled by config");
            return;
        }

        _dispatcher = Dispatcher.CurrentDispatcher;
        _popup = new SelectionPopup();
        _popup.Chosen += OnPresetChosen;
        _popup.SendRequested += OnCustomSendRequested;
        // 2026-11-01 四次需求：弹条自动收起时留痕（探针靠这行断言 2 秒规则）。
        _popup.AutoHidden += reason => _log($"popup auto hidden ({reason})");

        _hook = new MouseHook(OnDragFinished, OnAnyLeftDown);
        _hook.Start();
        _log("watching mouse drags");
    }

    private void OnAnyLeftDown(int x, int y)
    {
        Dispatcher? dispatcher = _dispatcher;
        if (dispatcher is null || _popup is null)
        {
            return;
        }

        dispatcher.BeginInvoke(new Action(() =>
        {
            try
            {
                if (_popup.IsVisible && !_popup.Contains(x, y))
                {
                    _popup.HidePopup();
                }
            }
            catch
            {
                // 钩子链路里不抛异常
            }
        }));
    }

    private void OnDragFinished(int x, int y)
    {
        Dispatcher? dispatcher = _dispatcher;
        if (dispatcher is null)
        {
            return;
        }

        dispatcher.BeginInvoke(new Action(() => HandleDrag(x, y)));
    }

    // 2026-11-01 审查 S1：改成 async，避免同步捕获把 UI 线程卡住最长 1.6 秒。
    // async void 在这里是安全的：整个方法体都在 try/catch 里，
    // 且这是事件回调（没有调用方需要拿返回值）。
    private async void HandleDrag(int x, int y)
    {
        if (_disposed || _popup is null || !_config.Assistant.SelectionPopup)
        {
            return;
        }

        // 拖拽结束瞬间可能连发多次（多显示器/抖动），做个节流。
        // 120ms：只吞真正的重复触发，不吞"用户快速重选"（2026-10-30 反馈修）。
        if ((DateTime.UtcNow - _lastShown).TotalMilliseconds < 120)
        {
            return;
        }

        _log($"drag end at {x},{y} own={IsOwnWindowAt(x, y)} hook={HookInstalled}");

        if (IsOwnWindowAt(x, y))
        {
            return;
        }

        string? text;
        try
        {
            text = await SelectionCapture.CaptureAsync();
        }
        catch (Exception ex)
        {
            _log("capture failed: " + ex.Message);
            return;
        }

        // await 期间用户可能已经关掉了程序，或弹条被别处隐藏了
        if (_disposed)
        {
            return;
        }

        _log(text is null ? "capture -> null" : $"capture -> {text.Length} chars");

        if (string.IsNullOrWhiteSpace(text) || text!.Trim().Length < 2)
        {
            _popup.HidePopup();
            return;
        }

        string selection = text.Trim();
        if (selection.Length > 4000)
        {
            selection = selection.Substring(0, 4000);
        }

        _lastShown = DateTime.UtcNow;
        _currentSelection = selection;
        _log($"selection captured ({selection.Length} chars)");
        _popup.ShowFor(_config.Assistant.Prompts, x, y, selection);
    }

    private void OnPresetChosen(PromptPreset preset)
    {
        string selection = _currentSelection;
        _popup?.HidePopup();
        _currentSelection = "";
        if (string.IsNullOrWhiteSpace(selection))
        {
            return;
        }

        _log($"prompt chosen: {preset.Id} ({selection.Length} chars)");
        PromptChosen?.Invoke(preset, selection);
    }

    /// <summary>
    /// 用户点了「发送」：把选中文字交给上层弹编辑器。
    ///
    /// 注意这里**不预先清空 _currentSelection**——编辑器是模态对话框，
    /// 用户可能取消；取消时选中内容不该丢，弹条也不该关
    /// （弹条自己会因为点别处而由钩子收起，这里不抢那个决定）。
    /// </summary>
    private void OnCustomSendRequested()
    {
        // 2026-11-01 五次需求：截图模式下这个按钮的语义是"给这张图配提示词"，
        // 选区文字这时是空的（没人选中任何东西），必须按模式分流，
        // 否则会被下面"没有选中内容"的早退挡掉，截图提问直接失效。
        if (_popup is { IsShotMode: true, CurrentShot: { } shot })
        {
            BitmapSource frozen = shot;
            _popup.HidePopup();
            _log($"shot send requested ({frozen.PixelWidth}x{frozen.PixelHeight} px)");
            ShotSendRequested?.Invoke(frozen, string.Empty);
            return;
        }

        string selection = _currentSelection;
        if (string.IsNullOrWhiteSpace(selection))
        {
            _log("custom send requested but no selection");
            return;
        }

        _popup?.HidePopup();
        _log($"custom send requested ({selection.Length} chars)");
        CustomSendRequested?.Invoke(selection);
    }

    /// <summary>
    /// 截图完成后由上层调用：在指定屏幕坐标弹出"截图版"提示词条。
    /// 走的还是同一个 <see cref="_popup"/> 实例（Hide/Show 复用，不重建窗口），
    /// 所以 2 秒自动收起、点别处关闭这些规则自动继承。
    /// </summary>
    public void ShowForShot(BitmapSource shot, int screenX, int screenY)
    {
        if (_popup is null)
        {
            _log("shot requested but watcher is not running");
            return;
        }

        // 截图模式下没有选区文字，但仍要占住"当前有内容待发"这个语义位，
        // 这样点「发送」时 OnCustomSendRequested 能分清是哪种模式。
        _currentSelection = "";
        _lastShown = DateTime.UtcNow;
        _log($"shot ready ({shot.PixelWidth}x{shot.PixelHeight} px)");
        _popup.ShowForShot(_config.Assistant.Prompts, shot, screenX, screenY);
    }

    private string _currentSelection = "";

    /// <summary>落点是否属于本进程的窗口（面板自己、弹条自己）。</summary>
    private static bool IsOwnWindowAt(int x, int y)
    {
        try
        {
            IntPtr hwnd = WindowFromPoint(new POINT { X = x, Y = y });
            if (hwnd == IntPtr.Zero)
            {
                return false;
            }

            GetWindowThreadProcessId(hwnd, out uint pid);
            return (int)pid == System.Diagnostics.Process.GetCurrentProcess().Id;
        }
        catch
        {
            return false;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _hook?.Dispose();
        _hook = null;
        try
        {
            _popup?.Close();
        }
        catch
        {
            // 关闭失败无碍
        }

        _popup = null;
    }
}
