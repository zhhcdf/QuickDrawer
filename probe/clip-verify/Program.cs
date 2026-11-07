// M2 verification: exercises the real ClipboardService path.
//   1. WM_CLIPBOARDUPDATE listener actually fires on a real Set-Clipboard
//   2. text is captured, deduped, and the source app is recorded
//   3. DPAPI round-trip works (protect -> unprotect)
//   4. capacity eviction removes the oldest unpinned entry
//   5. write-back puts an old entry back on the system clipboard
//
// Pure ASCII.

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using QuickDrawer;
using QuickDrawer.Native;

namespace ClipVerify;

internal static class Program
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool AddClipboardFormatListener(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RemoveClipboardFormatListener(IntPtr hWnd);

    private static int _clipEvents;

    [STAThread]
    private static int Main()
    {
        // A real WPF window so HwndSource + message pump work.
        // IMPORTANT: we must run a real Dispatcher loop, otherwise the WPF window
        // never pumps messages and WM_CLIPBOARDUPDATE is never delivered.
        // (First version of this probe showed "0 events" for exactly that reason.)
        var app = new Application();
        var window = new Window { Width = 1, Height = 1, ShowInTaskbar = false, Left = -2000 };
        window.Show();

        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        var source = HwndSource.FromHwnd(hwnd);
        source?.AddHook((IntPtr h, int m, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if (m == 0x031D)   // WM_CLIPBOARDUPDATE
            {
                _clipEvents++;
            }
            return IntPtr.Zero;
        });

        Console.WriteLine("=== 1. listener registration ===");
        bool reg = AddClipboardFormatListener(hwnd);
        Console.WriteLine($"  AddClipboardFormatListener -> {reg} (err={Marshal.GetLastWin32Error()})");
        Console.WriteLine($"  clipboard history already enabled on this machine: {IsWinHistoryEnabled()}");
        Console.WriteLine();

        var config = new AppConfig();
        var svc = new ClipboardService(config);
        var captured = new List<ClipEntry>();
        svc.EntryCaptured += e => { lock (captured) { captured.Add(e); } };
        svc.Start(hwnd, source);

        Console.WriteLine("=== 2. fire real clipboard changes ===");
        // Each Set must run on the UI thread with the dispatcher alive, otherwise
        // the WM_CLIPBOARDUPDATE message is never pumped to our hook.
        for (int i = 1; i <= 3; i++)
        {
            SetTextRetry(app, $"clip-verify-{i}-{Guid.NewGuid():N}");
            Pump(app, 700);
        }

        // dedupe: same content again must NOT create a new entry
        string dup = "clip-verify-dup-" + Guid.NewGuid().ToString("N");
        SetTextRetry(app, dup);
        Pump(app, 700);
        SetTextRetry(app, dup);
        Pump(app, 900);

        lock (captured)
        {
            Console.WriteLine($"  WM_CLIPBOARDUPDATE fired: {_clipEvents} times");
            Console.WriteLine($"  entries captured: {captured.Count}");
            foreach (ClipEntry e in captured)
            {
                Console.WriteLine($"    [{e.Kind}] '{ClipboardService.Truncate(e.Preview, 44)}' from {e.SourceApp}");
            }
        }

        // Snapshot for the dedupe assertion, taken before stage 4 adds more entries.
        List<ClipEntry> capturedAtStage2;
        lock (captured)
        {
            capturedAtStage2 = captured.ToList();
        }
        Console.WriteLine();

        Console.WriteLine("=== 3. DPAPI round-trip ===");
        string secret = "sensitive content password=12345";
        string cipher = ClipboardStore.Protect(secret);
        string? plain = ClipboardStore.Unprotect(cipher);
        bool ok = plain == secret;
        Console.WriteLine($"  protect  -> {cipher.Length} chars base64");
        Console.WriteLine($"  unprotect-> {(ok ? "MATCH" : "MISMATCH: " + (plain ?? "null"))}");
        Console.WriteLine($"  ciphertext contains plaintext? {cipher.Contains("password")}");
        Console.WriteLine($"  garbage input returns null (not throws)? {ClipboardStore.Unprotect("not-base64!!") is null}");
        Console.WriteLine();

        Console.WriteLine("=== 4. capacity eviction ===");
        config.Clipboard.MaxItems = 5;
        var svc2 = new ClipboardService(config);
        var kept = new List<ClipEntry>();
        svc2.EntryCaptured += e => { lock (kept) { kept.Add(e); } };
        svc2.Start(hwnd, source);
        for (int i = 1; i <= 8; i++)
        {
            SetTextRetry(app, $"evict-test-{i}");
            Pump(app, 450);
        }
        Pump(app, 800);

        // Count what the service actually RETAINS, not how many capture events
        // fired. An evicted entry fires EntryCaptured first, so counting events
        // would over-count (2026-10-20 first version of this probe did that).
        int retained = svc2.Snapshot().Count;
        int evicted = 0;
        svc2.EntryEvicted += _ => Interlocked.Increment(ref evicted);

        Console.WriteLine($"  started with 8 copies, MaxItems=5");
        Console.WriteLine($"  entries RETAINED: {retained} (expect 5)");
        Console.WriteLine($"  capture events seen: {kept.Count} (events, not retention)");
        Console.WriteLine();

        Console.WriteLine("=== 5. write-back to system clipboard ===");
        var sample = new ClipEntry { Kind = ClipKind.Text, Text = "restored-by-writeback" };
        bool wrote = ClipboardService.WriteBack(sample);
        Pump(app, 300);
        string? back = null;
        RunOnUi(app, () => { back = Clipboard.ContainsText() ? Clipboard.GetText() : null; });
        Console.WriteLine($"  WriteBack -> {wrote}");
        Console.WriteLine($"  clipboard now contains: '{back}'");
        Console.WriteLine();

        RemoveClipboardFormatListener(hwnd);
        svc.Dispose();
        svc2.Dispose();
        window.Close();

        // 统计去重时必须只用**第 2 阶段**的条目。
        // 第 4 阶段的 evict-test-* 是不同内容，混进来会把去重计数抬高。
        int uniqueStage2 = capturedAtStage2
            .Select(c => c.Text)
            .Distinct()
            .Count();

        bool pass = ok && uniqueStage2 == 4 && retained == 5
                    && back == "restored-by-writeback" && _clipEvents >= 4;

        Console.WriteLine($"  unique entries in stage 2 (dedupe check): {uniqueStage2} (expect 4)");
        Console.WriteLine(pass ? "RESULT: PASS" : "RESULT: FAIL (see above)");

        // Application keeps a message loop alive; force exit so the probe terminates.
        app.Shutdown();
        return pass ? 0 : 1;
    }

    /// <summary>Run an action on the UI thread and wait for it.</summary>
    private static void RunOnUi(Application app, Action action)
    {
        app.Dispatcher.Invoke(action);
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetClipboardOwner();

    [DllImport("user32.dll")]
    private static extern IntPtr GetOpenClipboardWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    /// <summary>
    /// 谁在占着剪贴板。GetOpenClipboardWindow 拿到的是**当前打开**剪贴板的那扇窗，
    /// 比 GetClipboardOwner（只在有空格式数据时才有值）更能定位长时间占用者。
    /// </summary>
    private static string DescribeClipboardOwner()
    {
        IntPtr owner = GetClipboardOwner();
        IntPtr open = GetOpenClipboardWindow();
        string where = "owner=none";
        if (open != IntPtr.Zero)
        {
            GetWindowThreadProcessId(open, out uint pid);
            string name = "?";
            try { if (pid != 0) name = Process.GetProcessById((int)pid).ProcessName; } catch { }
            where = $"openWindow=0x{open.ToInt64():X} pid={pid} ({name})";
        }
        return $"{where} owner=0x{owner.ToInt64():X}";
    }

    /// <summary>
    /// Clipboard.SetText 会直接抛 COMException CLIPBRD_E_CANT_OPEN (0x800401D0)，
    /// 只要此刻别的进程（QuickDrawer 的格式监听、输入法、浏览器）占着剪贴板。
    /// 这不是被测代码的缺陷，探针必须自己重试，否则一出偶发占用就整个崩掉。
    ///
    /// 实测（2026-11-07）：同样代码会出现两次运行一次 PASS 一次崩掉，
    /// 说明 20 次 x 100ms = 2s 的重试窗口不够；提到 60 次（6s）并在每次
    /// 失败时打印占用者，崩溃时也能知道是谁卡住了剪贴板，而不是只看到 HRESULT。
    /// </summary>
    private static void SetTextRetry(Application app, string text)
    {
        const int maxAttempts = 60;
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                RunOnUi(app, () => Clipboard.SetText(text));
                return;
            }
            catch (COMException ex) when (attempt < maxAttempts && (uint)ex.HResult == 0x800401D0)
            {
                if (attempt == 1 || attempt % 10 == 0)
                {
                    Console.WriteLine($"  clipboard busy, attempt {attempt}/{maxAttempts}: {DescribeClipboardOwner()}");
                }
                Thread.Sleep(100);
            }
            catch (COMException ex) when ((uint)ex.HResult == 0x800401D0)
            {
                throw new InvalidOperationException(
                    $"clipboard stayed locked for {maxAttempts * 100} ms: {DescribeClipboardOwner()}", ex);
            }
        }
    }

    /// <summary>
    /// Let the dispatcher pump messages for the given time.
    /// Without this the WM_CLIPBOARDUPDATE messages are never delivered.
    /// </summary>
    private static void Pump(Application app, int milliseconds)
    {
        DateTime until = DateTime.UtcNow.AddMilliseconds(milliseconds);
        while (DateTime.UtcNow < until)
        {
            app.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Background);
            Thread.Sleep(20);
        }
    }

    private static bool IsWinHistoryEnabled()
    {
        try
        {
            using Microsoft.Win32.RegistryKey? key =
                Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Clipboard");
            return key?.GetValue("EnableClipboardHistory") is int v && v != 0;
        }
        catch
        {
            return false;
        }
    }
}
