using System.Runtime.InteropServices;

namespace QuickDrawer.Selection;

/// <summary>
/// 全局低级鼠标钩子（WH_MOUSE_LL）。
///
/// 为什么必须用钩子而不是轮询：用户是在**别的程序**里拖选文字，
/// 我们既没有那个窗口的句柄，也没有办法订阅它的选择事件；
/// 低级钩子是唯一能在不注入 DLL 的前提下全局感知"鼠标拖拽结束"的办法。
///
/// 注意：低级钩子的回调必须在装钩子的**那个线程**的消息泵里跑，
/// 所以这里起一条专用线程挂着 GetMessage 循环，回调里只做极轻的事
/// （算距离、投递事件），任何耗时操作都交回 UI 线程。
/// </summary>
internal sealed class MouseHook : IDisposable
{
    private const int WH_MOUSE_LL = 14;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern bool PostThreadMessage(uint idThread, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern uint GetDoubleClickTime();

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    private const int SM_CXDOUBLECLK = 36;

    /// <summary>系统双击判定区域边长（像素）。取失败时按 4 兜底。</summary>
    private static int DoubleClickArea
    {
        get
        {
            try
            {
                return GetSystemMetrics(SM_CXDOUBLECLK);
            }
            catch
            {
                return 4;
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    private const uint WM_QUIT = 0x0012;

    private readonly HookProc _proc;
    private readonly Action<int, int> _onDragSelect;
    private readonly Action<int, int>? _onAnyLeftDown;
    private Thread? _thread;
    private uint _threadId;
    private IntPtr _hook;
    private POINT _down;
    private bool _downSeen;
    private volatile bool _disposed;

    // 2026-10-30 用户反馈"悬浮按钮不是每次选中都能弹出"：
    // 双击/三击选词的位移是 0，原先被拖拽阈值当单击静默丢弃，永远不触发。
    // 这里按系统的双击时间/双击区域判定"连击"，第 2、3 次抬起也当作一次选择。
    private long _lastUpTick = long.MinValue;
    private POINT _lastUp;
    private int _clickCount;

    /// <summary>拖拽位移超过这个像素才算"选择"，避免把单击当选择。</summary>
    public int DragThreshold { get; init; } = 4;

    /// <summary>钩子是否真的装上了（诊断用：装不上时 SetWindowsHookEx 返回 0）。</summary>
    public bool Installed => _hook != IntPtr.Zero;

    /// <param name="onDragSelect">拖拽结束回调（在钩子线程上调用，参数是松开时的屏幕坐标）。</param>
    /// <param name="onAnyLeftDown">任意左键按下回调（用来关掉悬浮按钮）。</param>
    public MouseHook(Action<int, int> onDragSelect, Action<int, int>? onAnyLeftDown = null)
    {
        _onDragSelect = onDragSelect;
        _onAnyLeftDown = onAnyLeftDown;
        _proc = Handle;
    }

    public void Start()
    {
        if (_thread is not null)
        {
            return;
        }

        _thread = new Thread(Loop)
        {
            IsBackground = true,
            Name = "QuickDrawer.MouseHook"
        };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
    }

    private void Loop()
    {
        _threadId = GetCurrentThreadId();
        IntPtr module = GetModuleHandle(null);
        _hook = SetWindowsHookEx(WH_MOUSE_LL, _proc, module, 0);
        if (_hook == IntPtr.Zero)
        {
            return;
        }

        while (!_disposed && GetMessage(out MSG msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }

        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
    }

    private IntPtr Handle(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && !_disposed)
        {
            try
            {
                MSLLHOOKSTRUCT data = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
                int msg = (int)wParam;
                if (msg == WM_LBUTTONDOWN)
                {
                    _down = data.pt;
                    _downSeen = true;
                    if (_onAnyLeftDown is not null)
                    {
                        int dx0 = data.pt.X;
                        int dy0 = data.pt.Y;
                        _onAnyLeftDown(dx0, dy0);
                    }
                }
                else if (msg == WM_LBUTTONUP && _downSeen)
                {
                    _downSeen = false;
                    int x = data.pt.X;
                    int y = data.pt.Y;
                    int dx = x - _down.X;
                    int dy = y - _down.Y;
                    long now = Compat.TickCount64;

                    if ((dx * dx + dy * dy) >= DragThreshold * DragThreshold)
                    {
                        // 真拖拽：一次拖选只有一次抬起
                        _clickCount = 0;
                        _onDragSelect(x, y);
                    }
                    else
                    {
                        // 位移太小：可能是双击/三击选词。
                        // 判定标准与系统一致：与上一次抬起的间隔 <= 双击时间、
                        // 且两次落点都在系统的双击区域内。
                        int ddx = x - _lastUp.X;
                        int ddy = y - _lastUp.Y;
                        int area = DoubleClickArea;
                        bool rapid = now - _lastUpTick <= GetDoubleClickTime()
                                     && (ddx * ddx + ddy * ddy) <= area * area;
                        _clickCount = rapid ? _clickCount + 1 : 1;
                        if (_clickCount is 2 or 3)
                        {
                            // 双击 = 选词；三击 = 选段落。都值得弹提示词条。
                            // 捕捉失败（Ctrl+C 没拿到文字）时上层会静默收起，不会打扰单击。
                            _onDragSelect(x, y);
                        }
                        else if (_clickCount > 3)
                        {
                            _clickCount = 0;
                        }
                    }

                    _lastUpTick = now;
                    _lastUp = data.pt;
                }
            }
            catch
            {
                // 钩子回调里绝不能让异常冒出去
            }
        }

        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_threadId != 0)
        {
            PostThreadMessage(_threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        }

        _thread?.Join(500);
        _thread = null;
    }
}
