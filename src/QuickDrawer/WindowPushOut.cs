using System.Runtime.InteropServices;
using System.Windows.Threading;
using QuickDrawer.Native;

namespace QuickDrawer;

/// <summary>
/// 面板固定（📌）时，把被面板压住的窗口"弹出"遮挡区（2026-10-26 需求 2）。
///
/// 规则（用户原话："最大化窗口以面板内侧为左边框缩放；其他缩放窗口弹出遮挡区"）：
///   - 最大化窗口 → 先 SW_RESTORE，再以面板内侧（面板左边界）为左边框铺满剩余工作区；
///   - 普通可缩放窗口 → 左移，右边界贴住面板内侧；宽度超出可用区时压窄到可用宽度。
///   - 取消固定 / 面板收起 → **不做任何还原**，被弹出的窗口保持在弹出后的位置
///     （2026-11-06 用户需求 m08344："不要让被弹开的窗口再回到原来位置，保持当前布局"）。
///     早先版本会按存档的 WINDOWPLACEMENT 原样还原，用户明确要求去掉这套还原逻辑。
///     随之而来的两个后果是有意为之，不是缺陷：
///       · 原来最大化的窗口被弹出后会保持"已还原 + 缩在面板左侧"的状态，不会自己变回最大化；
///       · 程序退出时同样不还原，桌面就停在当前的样子。
///     代价是：本类不再需要保存窗口的原始摆放，`_saved` 已整个删除。
///
/// 安全边界（避免和用户抢窗口，也不误伤全屏应用）：
///   - 只处理与面板同一显示器的顶层窗口：可见、非最小化、无所有者、非子窗口、
///     非工具窗口、未被 DWM 隐身（虚拟桌面/其他会话）；
///   - 整屏全屏窗口（放视频/玩游戏）不动；
///   - 每个窗口在本轮固定期间只动一次；用户再次最大化它时允许再动一次；
///   - 用户自己把窗口拖回遮挡区不会被反复推走（已记录的不再处理）；
///   - 所有动作写 diag.log（分类 pushout），便于事后核对。
/// </summary>
internal sealed class WindowPushOut
{
    /// <summary>轮询间隔：够快追上"用户刚最大化"，又不会和用户拖动打架。</summary>
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(700);

    /// <summary>普通窗口被压窄后允许的最小宽度，太窄就没法用了，宁可不动。</summary>
    private const int MinUsableWidth = 240;

    /// <summary>面板左边界离工作区左边不足这个宽度时，说明面板几乎盖满屏幕，不做任何处理。</summary>
    private const int MinFreeWidth = 120;

    private readonly DispatcherTimer _timer;
    private readonly HashSet<IntPtr> _handled = new();
    private readonly HashSet<string> _skippedClasses = new(StringComparer.Ordinal)
    {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd",
        "Windows.UI.Core.CoreWindow", "ApplicationFrameWindow"
    };

    private IntPtr _panel = IntPtr.Zero;
    private bool _active;

    public WindowPushOut()
    {
        _timer = new DispatcherTimer { Interval = PollInterval };
        _timer.Tick += (_, _) => Tick();
    }

    /// <summary>是否正在看守（面板固定且展开中）。</summary>
    public bool Active => _active;

    /// <summary>开始看守：立刻处理一次，然后每 700ms 复查有没有新窗口压到面板上。</summary>
    public void Begin(IntPtr panelHwnd)
    {
        if (panelHwnd == IntPtr.Zero)
        {
            return;
        }

        _panel = panelHwnd;
        if (!_active)
        {
            _active = true;
            DiagLog.Write("pushout", "started (panel pinned)");
        }

        Tick();
        if (!_timer.IsEnabled)
        {
            _timer.Start();
        }
    }

    /// <summary>
    /// 停止看守。**不还原**被弹出的窗口：用户要求取消固定/收起面板后保持当前布局
    /// （2026-11-06 m08344）。这里只做状态清理。
    /// </summary>
    public void End()
    {
        if (!_active)
        {
            return;
        }

        _active = false;
        _timer.Stop();

        DiagLog.Write("pushout",
            $"stopped, {_handled.Count} window(s) left where they were pushed (no restore)");

        _handled.Clear();
        _panel = IntPtr.Zero;
    }

    private void Tick()
    {
        if (!_active || _panel == IntPtr.Zero)
        {
            return;
        }

        if (!NativeMethods.IsWindow(_panel) || !NativeMethods.GetWindowRect(_panel, out NativeMethods.RECT pr))
        {
            return;
        }

        IntPtr hmon = NativeMethods.GetMonitorForWindow(_panel);
        if (!NativeMethods.TryGetMonitorWorkArea(hmon, out System.Windows.Rect work))
        {
            return;
        }

        // 面板可能正在滑出：把右边界夹进工作区，左边界按宽度反推，
        // 这样动画途中算出的就是"展开完成后"的位置。
        double width = pr.Right - pr.Left;
        double panelRight = Math.Min(pr.Right, work.Right);
        double panelLeft = panelRight - width;
        if (panelLeft - work.Left < MinFreeWidth)
        {
            return;
        }

        List<IntPtr> targets = new();
        NativeMethods.EnumWindows((hwnd, _) =>
        {
            if (IsCandidate(hwnd, hmon, work, panelLeft))
            {
                targets.Add(hwnd);
            }

            return true;
        }, IntPtr.Zero);

        foreach (IntPtr hwnd in targets)
        {
            bool maximized = NativeMethods.IsZoomed(hwnd);
            if (_handled.Contains(hwnd) && !maximized)
            {
                // 已经处理过，用户又自己拖回来了：不再抢。
                continue;
            }

            Apply(hwnd, work, panelLeft, maximized);
        }
    }

    /// <summary>判断某个顶层窗口是不是"被面板压住、需要弹出"的候选。</summary>
    private bool IsCandidate(IntPtr hwnd, IntPtr hmon, System.Windows.Rect work, double panelLeft)
    {
        if (hwnd == _panel || !NativeMethods.IsWindowVisible(hwnd) || NativeMethods.IsIconic(hwnd))
        {
            return false;
        }

        if (NativeMethods.GetWindow(hwnd, NativeMethods.GW_OWNER) != IntPtr.Zero)
        {
            return false;
        }

        int exStyle = NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_EXSTYLE);
        if ((exStyle & (int)NativeMethods.WS_EX_TOOLWINDOW) != 0)
        {
            return false;
        }

        int style = NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_STYLE);
        if ((style & (int)NativeMethods.WS_CHILD) != 0)
        {
            return false;
        }

        NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
        if (pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id)
        {
            return false;
        }

        if (NativeMethods.GetMonitorForWindow(hwnd) != hmon)
        {
            return false;
        }

        if (_skippedClasses.Contains(NativeMethods.ClassNameOf(hwnd)))
        {
            return false;
        }

        if (IsCloaked(hwnd))
        {
            return false;
        }

        if (!NativeMethods.GetWindowRect(hwnd, out NativeMethods.RECT r))
        {
            return false;
        }

        // 整屏全屏窗口（非最大化状态）多半在放视频/玩游戏，不动它。
        bool fillsMonitor = Math.Abs(r.Left - work.Left) <= 2 && Math.Abs(r.Top - work.Top) <= 2
                            && Math.Abs(r.Right - work.Right) <= 2 && Math.Abs(r.Bottom - work.Bottom) <= 2;
        if (fillsMonitor && !NativeMethods.IsZoomed(hwnd))
        {
            return false;
        }

        // 与面板横向重叠（面板纵向占满工作区）。
        return r.Right > panelLeft + 1;
    }

    /// <summary>把单个窗口挪出遮挡区，并存档原始摆放以便还原。</summary>
    private void Apply(IntPtr hwnd, System.Windows.Rect work, double panelLeft, bool maximized)
    {
        if (!NativeMethods.GetWindowRect(hwnd, out NativeMethods.RECT r))
        {
            return;
        }

        // 2026-11-06 m08344：不再保存原始摆放 —— 取消固定/收起面板后不还原，
        // 窗口就停在弹出后的位置。原来这里的 GetWindowPlacement 存档已整个删除。

        int targetLeft;
        int targetTop;
        int targetWidth;
        int targetHeight;

        if (maximized)
        {
            // 最大化窗口：先还原成普通窗口，再铺满"面板左侧的可见区"，
            // 也就是把类最大化窗口的右边界收在面板内侧，不再被面板压住。
            NativeMethods.ShowWindow(hwnd, NativeMethods.SW_RESTORE);
            targetLeft = (int)Math.Round(work.Left);
            targetTop = (int)Math.Round(work.Top);
            targetWidth = (int)Math.Round(panelLeft - work.Left);
            targetHeight = (int)Math.Round(work.Bottom - work.Top);
        }
        else
        {
            int currentWidth = r.Right - r.Left;
            int available = (int)Math.Round(panelLeft - work.Left);
            int width = Math.Min(currentWidth, available);
            if (width < MinUsableWidth || r.Bottom - r.Top < MinUsableWidth)
            {
                DiagLog.Write("pushout",
                    $"skip 0x{hwnd.ToInt64():X} ({NativeMethods.ClassNameOf(hwnd)}): too small to move " +
                    $"(w={currentWidth}, free={available})");
                _handled.Add(hwnd);
                return;
            }

            targetLeft = (int)Math.Round(panelLeft) - width;
            targetTop = r.Top;
            targetWidth = width;
            targetHeight = r.Bottom - r.Top;
        }

        bool ok = NativeMethods.SetWindowPos(hwnd, IntPtr.Zero,
            targetLeft, targetTop, targetWidth, targetHeight,
            NativeMethods.SWP_NOZORDER | NativeMethods.SWP_NOACTIVATE);

        string kind = maximized ? "maximized" : "window";
        if (ok)
        {
            _handled.Add(hwnd);
            DiagLog.Write("pushout",
                $"{kind} 0x{hwnd.ToInt64():X} ({NativeMethods.ClassNameOf(hwnd)}) " +
                $"{r.Left},{r.Top} {r.Right - r.Left}x{r.Bottom - r.Top} -> " +
                $"{targetLeft},{targetTop} {targetWidth}x{targetHeight}");
        }
        else
        {
            DiagLog.Write("pushout",
                $"SetWindowPos failed for 0x{hwnd.ToInt64():X} ({NativeMethods.ClassNameOf(hwnd)}), " +
                $"err={Marshal.GetLastWin32Error()}");
            _handled.Add(hwnd);
        }
    }

    /// <summary>DWM 隐身 = 窗口在别的虚拟桌面/会话里，不该动。</summary>
    private static bool IsCloaked(IntPtr hwnd)
    {
        try
        {
            return NativeMethods.DwmGetWindowAttribute(hwnd, NativeMethods.DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0
                   && cloaked != 0;
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
}
