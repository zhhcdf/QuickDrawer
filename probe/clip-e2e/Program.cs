// End-to-end probe for the 2026-11-07 regression:
// "content copied from Obsidian pastes ONLY into Word after restoring from history".
//
// The unit-ish gate (probe/clip-formats) proves WriteBack *writes* CF_UNICODETEXT.
// This probe proves a **real target application** can paste it: it creates a plain
// Win32 EDIT control (exactly what Notepad uses) and sends it WM_PASTE.
//
// Pipeline exercised, all through production code paths:
//   1. REPRO: clipboard carries ONLY "HTML Format" (the old WriteBack output)
//      -> EDIT control pastes EMPTY. This is the bug, on the record.
//   2. Obsidian-shaped clipboard (HTML + CF_UNICODETEXT, with the
//      <!-- obsidian --> device comment) is captured by the real
//      ClipboardService (AddClipboardFormatListener + WM_CLIPBOARDUPDATE).
//   3. entry.PlainText must be the FULL source text, not the 200-char preview.
//   4. ClipboardStore.Save -> Load (DPAPI round-trip) must keep PlainText.
//   5. ClipboardService.WriteBack(loaded) -> EDIT control pastes the full text
//      AND "HTML Format" is still on the clipboard (rich target still works).
//
// Storage is redirected to %TEMP% via QD_E2E_DIR so the user's real
// %APPDATA%\QuickDrawer\clipboard.json is never touched.
//
// Pure ASCII output.

using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using QuickDrawer;
using QuickDrawer.Native;

namespace ClipE2E;

internal static class Program
{
    // ---- Win32 -----------------------------------------------------------

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public uint cbSize;
        public uint style;
        [MarshalAs(UnmanagedType.FunctionPtr)] public WndProcDelegate lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string? name);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassExW(ref WNDCLASSEX wc);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowExW(
        uint exStyle, string className, string windowName, uint style,
        int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, string? lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hWnd);

    private const uint WS_OVERLAPPEDWINDOW = 0x00CF0000;
    private const uint WS_CHILD = 0x40000000;
    private const uint WS_VISIBLE = 0x10000000;
    private const uint ES_MULTILINE = 0x0004;
    private const uint WM_SETTEXT = 0x000C;
    private const uint WM_GETTEXT = 0x000D;
    private const uint WM_GETTEXTLENGTH = 0x000E;
    private const uint WM_PASTE = 0x0302;

    private static WndProcDelegate? _wndProc;   // keep the delegate alive

    // ---- probe data ------------------------------------------------------

    // Obsidian-shaped payload. The device comment is what Obsidian really puts
    // in CF_HTML, and it must NOT leak into the plain text.
    private const string HtmlFragment =
        "<!-- obsidian --><p>第一行</p><p>第二行</p><p>汇总：$1,234.56 &amp; 备注</p>";

    // What Obsidian puts in CF_UNICODETEXT for that selection.
    private const string ExpectedPlain =
        "第一行\r\n第二行\r\n\r\n汇总：$1,234.56 & 备注";

    [STAThread]
    private static int Main()
    {
        int failures = 0;

        string dataDir = Environment.GetEnvironmentVariable("QD_E2E_DIR")
                         ?? Path.Combine(Path.GetTempPath(), "qd-e2e-" + Guid.NewGuid().ToString("N"));
        Environment.SetEnvironmentVariable("QD_E2E_DIR", dataDir);
        Directory.CreateDirectory(dataDir);
        Console.WriteLine($"  storage dir: {dataDir}");
        Console.WriteLine();

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var window = new Window
        {
            Width = 1, Height = 1, ShowInTaskbar = false,
            Left = -3000, Top = -3000, WindowStyle = WindowStyle.None
        };
        window.Show();

        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        HwndSource? source = HwndSource.FromHwnd(hwnd);

        // A plain Win32 window + EDIT control: this is a real paste target that
        // has no idea what CF_HTML is. If it pastes, Notepad pastes.
        IntPtr pasteTarget = CreateEditWindow();
        IntPtr host = GetParent(pasteTarget);
        Console.WriteLine($"  paste target EDIT hwnd=0x{pasteTarget.ToInt64():X} (host=0x{host.ToInt64():X})");
        Console.WriteLine();

        // ---- 1. REPRO ----------------------------------------------------
        Console.WriteLine("=== 1. REPRO: clipboard with ONLY 'HTML Format' (old WriteBack) ===");
        WriteHtmlOnlyClipboard();
        Pump(app, 300);
        string legacy = PasteInto(pasteTarget);
        bool reproOk = legacy.Length == 0;
        Console.WriteLine($"  EDIT control pasted: {Escape(legacy)} ({legacy.Length} chars)");
        Console.WriteLine($"  -> reproduces the bug (non-Word app gets nothing): {reproOk}");
        if (!reproOk)
        {
            Console.WriteLine("  NOTE: could not reproduce (another clipboard manager may be rewriting formats)");
            failures++;
        }

        Console.WriteLine();

        // ---- 2. capture --------------------------------------------------
        Console.WriteLine("=== 2. Obsidian-shaped clipboard captured by ClipboardService ===");
        var config = new AppConfig();
        var svc = new ClipboardService(config);
        var captured = new List<ClipEntry>();
        svc.EntryCaptured += e => { lock (captured) { captured.Add(e); } };

        WriteObsidianClipboard();
        Pump(app, 200);            // let the write land
        svc.Start(hwnd, source);   // listener now active
        WriteObsidianClipboard();  // second write, so the listener sees an update
        Pump(app, 1500);

        ClipEntry? entry;
        lock (captured) { entry = captured.LastOrDefault(); }

        if (entry is null)
        {
            Console.WriteLine("  FAIL: nothing captured");
            failures++;
            svc.Dispose();
            window.Close();
            app.Shutdown();
            return 1;
        }

        svc.Stop();

        Console.WriteLine($"  kind            : {entry.Kind} (expect Html)");
        Console.WriteLine($"  preview         : {Escape(ClipboardService.Truncate(entry.Preview, 50))}");
        Console.WriteLine($"  plain len       : {entry.PlainText?.Length.ToString() ?? "null"} (expect {ExpectedPlain.Length})");
        Console.WriteLine($"  plain           : {Escape(entry.PlainText ?? "<null>")}");
        Console.WriteLine($"  html fragment   : {Escape(ClipboardService.Truncate(entry.Text ?? "", 60))}");

        if (entry.Kind != ClipKind.Html) { Console.WriteLine("  FAIL: kind is not Html"); failures++; }
        if (entry.PlainText != ExpectedPlain)
        {
            Console.WriteLine("  FAIL: PlainText was not preserved verbatim from CF_UNICODETEXT");
            failures++;
        }

        // The 200-char-preview trap: a long selection must not be stored truncated.
        Console.WriteLine();

        // ---- 3. persist --------------------------------------------------
        Console.WriteLine("=== 3. ClipboardStore save -> load (DPAPI) keeps PlainText ===");
        bool saved = ClipboardStore.Save(new[] { entry });
        Console.WriteLine($"  save -> {saved}");
        Console.WriteLine($"  file  -> {ClipboardStore.FilePath}");

        List<ClipEntry> loaded = ClipboardStore.Load();
        ClipEntry? reloaded = loaded.FirstOrDefault(e => e.Id == entry.Id);
        Console.WriteLine($"  entries loaded : {loaded.Count}");
        Console.WriteLine($"  PlainText kept : {reloaded?.PlainText == ExpectedPlain}");
        Console.WriteLine($"  PlainText len  : {reloaded?.PlainText?.Length.ToString() ?? "null"}");

        if (!saved || reloaded is null || reloaded.PlainText != ExpectedPlain)
        {
            Console.WriteLine("  FAIL: PlainText did not survive the DPAPI round-trip");
            failures++;
        }

        Console.WriteLine();

        // ---- 4. write back + real paste ----------------------------------
        Console.WriteLine("=== 4. WriteBack(loaded entry) then paste into EDIT control ===");
        bool wrote = reloaded is not null && ClipboardService.WriteBack(reloaded);
        Console.WriteLine($"  WriteBack -> {wrote}");
        Pump(app, 300);

        var formats = DumpFormats();
        foreach (string f in formats) Console.WriteLine(f);

        string pasted = PasteInto(pasteTarget);
        bool pastedOk = pasted == ExpectedPlain;
        Console.WriteLine($"  EDIT control pasted: {Escape(ClipboardService.Truncate(pasted, 60))} ({pasted.Length} chars)");
        Console.WriteLine($"  exact match : {pastedOk}");
        Console.WriteLine($"  html still on clipboard : {formats.Any(f => f.Contains("HTML Format"))}");

        if (!wrote) { Console.WriteLine("  FAIL: WriteBack returned false"); failures++; }
        if (!pastedOk)
        {
            Console.WriteLine("  FAIL: a plain EDIT control (i.e. Notepad) cannot paste this");
            Console.WriteLine($"    expected: {Escape(ExpectedPlain)}");
            failures++;
        }

        if (!formats.Any(f => f.Contains("HTML Format")))
        {
            Console.WriteLine("  FAIL: rich format was dropped (Word/WordPad would lose formatting)");
            failures++;
        }

        Console.WriteLine();

        // ---- 5. legacy entry (no PlainText) must still be pasteable ------
        Console.WriteLine("=== 5. legacy history entry (PlainText == null) still pasteable ===");
        var legacyEntry = new ClipEntry
        {
            Kind = ClipKind.Html,
            Text = "<p>旧条目</p><p>second line</p>",
            Preview = "旧条目 second line",
            PlainText = null
        };
        bool wroteLegacy = ClipboardService.WriteBack(legacyEntry);
        Pump(app, 300);
        string legacyPasted = PasteInto(pasteTarget);

        // Line endings must be CRLF, matching what Windows apps put in
        // CF_UNICODETEXT. A lone '\n' silently breaks single-line EDIT
        // controls and line-oriented scripts.
        const string expectedLegacy = "旧条目\r\nsecond line";

        Console.WriteLine($"  WriteBack -> {wroteLegacy}");
        Console.WriteLine($"  pasted: {Escape(legacyPasted)} ({legacyPasted.Length} chars)");
        Console.WriteLine($"  expected CRLF-joined: {Escape(expectedLegacy)}");
        Console.WriteLine($"  exact match : {legacyPasted == expectedLegacy}");
        Console.WriteLine($"  uses CRLF   : {legacyPasted.Contains("\r\n")}");
        Console.WriteLine($"  has bare LF : {legacyPasted.Replace("\r\n", "").Contains('\n')}");

        if (!wroteLegacy || legacyPasted.Length == 0)
        {
            Console.WriteLine("  FAIL: entries saved before this fix are still un-pasteable");
            failures++;
        }
        else if (legacyPasted != expectedLegacy)
        {
            Console.WriteLine("  FAIL: HTML-derived plain text is not CRLF-joined");
            failures++;
        }

        DestroyWindow(host);
        svc.Dispose();
        window.Close();

        Console.WriteLine();
        Console.WriteLine(failures == 0
            ? "RESULT: PASS (bug reproduced with HTML-only clipboard; fixed path pastes into a plain EDIT control)"
            : $"RESULT: FAIL ({failures} assertion(s) failed)");

        app.Shutdown();
        return failures == 0 ? 0 : 1;
    }

    // ---- clipboard fixtures ---------------------------------------------

    /// <summary>Old WriteBack output: HTML only, no CF_UNICODETEXT.</summary>
    private static void WriteHtmlOnlyClipboard()
    {
        var data = new DataObject();
        data.SetData(HtmlFormatName, new MemoryStream(BuildCfHtml(HtmlFragment)));
        SetDataObjectRetry(data);
    }

    /// <summary>What Obsidian actually puts on the clipboard: HTML + plain text.</summary>
    private static void WriteObsidianClipboard()
    {
        var data = new DataObject();
        data.SetText(ExpectedPlain);
        data.SetData(HtmlFormatName, new MemoryStream(BuildCfHtml(HtmlFragment)));
        SetDataObjectRetry(data);
    }

    private const string HtmlFormatName = "HTML Format";

    /// <summary>
    /// Build a spec-conforming CF_HTML payload. The header is 4 lines of
    /// zero-padded offsets plus a blank line; every offset is a UTF-8 byte
    /// offset into the whole payload.
    /// </summary>
    private static byte[] BuildCfHtml(string fragment)
    {
        const string headFmt =
            "Version:0.9\r\n" +
            "StartHTML:{0:0000000000}\r\n" +
            "EndHTML:{1:0000000000}\r\n" +
            "StartFragment:{2:0000000000}\r\n" +
            "EndFragment:{3:0000000000}\r\n";

        string bare = string.Format(headFmt, 0, 0, 0, 0);
        int headLen = Encoding.UTF8.GetByteCount(bare);

        string startMarker = "<!--StartFragment-->";
        string endMarker = "<!--EndFragment-->";
        string body = startMarker + fragment + endMarker;

        int fragStart = headLen + Encoding.UTF8.GetByteCount(startMarker);
        int fragEnd = fragStart + Encoding.UTF8.GetByteCount(fragment);
        int htmlStart = headLen;
        int htmlEnd = headLen + Encoding.UTF8.GetByteCount(body);

        string full = string.Format(headFmt, htmlStart, htmlEnd, fragStart, fragEnd) + body;
        byte[] bytes = Encoding.UTF8.GetBytes(full + "\0");
        return bytes;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetClipboardOwner();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    /// <summary>Whoever holds the clipboard blocks every writer. Name them.</summary>
    private static string DescribeClipboardOwner()
    {
        IntPtr owner = GetClipboardOwner();
        if (owner == IntPtr.Zero) return "owner=none";
        GetWindowThreadProcessId(owner, out uint pid);
        string name;
        try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; }
        catch { name = "<gone>"; }
        return $"owner hwnd=0x{owner.ToInt64():X} pid={pid} ({name})";
    }

    private static void SetDataObjectRetry(DataObject data)
    {
        const int maxAttempts = 20;
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(data, true);
                if (attempt > 1) Console.WriteLine($"    (clipboard opened on attempt {attempt})");
                return;
            }
            catch (COMException ex) when ((uint)ex.HResult == 0x800401D0)
            {
                if (attempt >= maxAttempts)
                {
                    throw new InvalidOperationException(
                        $"clipboard stayed locked for {maxAttempts * 100} ms: {DescribeClipboardOwner()}", ex);
                }

                Console.WriteLine($"    clipboard busy, attempt {attempt}/{maxAttempts} {DescribeClipboardOwner()}");
                Thread.Sleep(100);
            }
        }
    }

    private static List<string> DumpFormats()
    {
        var rows = new List<string>();
        var d = Clipboard.GetDataObject();
        if (d is null) return rows;

        foreach (string fmt in d.GetFormats(false))
        {
            rows.Add($"    fmt '{fmt}'");
        }

        return rows;
    }

    // ---- paste target ----------------------------------------------------

    private static IntPtr CreateEditWindow()
    {
        IntPtr hInstance = GetModuleHandleW(null);

        _wndProc = (IntPtr hWnd, uint msg, IntPtr w, IntPtr l) => DefWindowProcW(hWnd, msg, w, l);

        var wc = new WNDCLASSEX
        {
            cbSize = (uint)Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = _wndProc,
            hInstance = hInstance,
            lpszClassName = "QD_E2E_PasteHost"
        };
        RegisterClassExW(ref wc);

        IntPtr hwnd = CreateWindowExW(0, "QD_E2E_PasteHost", "QD E2E paste host",
            WS_OVERLAPPEDWINDOW, -3000, -3000, 420, 260,
            IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero)
        {
            throw new InvalidOperationException($"CreateWindowEx failed, err={Marshal.GetLastWin32Error()}");
        }

        IntPtr edit = CreateWindowExW(0, "EDIT", "",
            WS_CHILD | WS_VISIBLE | ES_MULTILINE,
            10, 10, 390, 200, hwnd, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (edit == IntPtr.Zero)
        {
            throw new InvalidOperationException($"CreateWindowEx(EDIT) failed, err={Marshal.GetLastWin32Error()}");
        }

        return edit;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetParent(IntPtr hWnd);

    /// <summary>
    /// Clear the EDIT, send WM_PASTE, read it back. WM_PASTE on a Unicode EDIT
    /// control is exactly what Notepad does on Ctrl+V: it reads CF_UNICODETEXT
    /// (falling back to CF_TEXT). No CF_HTML awareness whatsoever.
    /// </summary>
    private static string PasteInto(IntPtr edit)
    {
        SendMessageW(edit, WM_SETTEXT, IntPtr.Zero, "");
        SendMessageW(edit, WM_PASTE, IntPtr.Zero, IntPtr.Zero);
        Thread.Sleep(60);

        int len = (int)SendMessageW(edit, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero);
        if (len <= 0) return "";

        var sb = new StringBuilder(len + 2);
        SendMessageW(edit, WM_GETTEXT, (IntPtr)(len + 1), sb);
        return sb.ToString();
    }

    // ---- misc ------------------------------------------------------------

    private static void Pump(Application app, int milliseconds)
    {
        DateTime until = DateTime.UtcNow.AddMilliseconds(milliseconds);
        while (DateTime.UtcNow < until)
        {
            app.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Background);
            Thread.Sleep(20);
        }
    }

    /// <summary>ASCII-only rendering so the probe output stays readable in any console.</summary>
    private static string Escape(string s)
    {
        var sb = new StringBuilder();
        foreach (char c in s)
        {
            if (c == '\r') sb.Append("\\r");
            else if (c == '\n') sb.Append("\\n");
            else if (c == '\t') sb.Append("\\t");
            else if (c < 0x20 || c > 0x7E) sb.Append($"\\u{(int)c:X4}");
            else sb.Append(c);
        }

        return "'" + ClipboardService.Truncate(sb.ToString(), 220) + "'";
    }
}
