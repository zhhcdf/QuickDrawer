// Clipboard format-set probe: what does ClipboardService.WriteBack actually put
// on the clipboard for Html and Rtf entries?
//
// Motivation (2026-11-07): user reported that content copied from Obsidian
// pastes ONLY into Word after restoring from QuickDrawer history. Live dump of
// the clipboard showed a single format 49409 ("HTML Format") and no
// CF_UNICODETEXT, which matches "everything except Word ignores it".
//
// Contract asserted here (this is the regression gate for that bug):
//   every WriteBack, whatever the Kind, must leave CF_UNICODETEXT on the
//   clipboard carrying the *full* text -- not the 200-char preview.
//   Rich kinds must ALSO carry their rich format.
// Pure ASCII output.

using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using QuickDrawer;
using QuickDrawer.Native;

namespace ClipFormats;

internal static class Program
{
    private const uint CF_UNICODETEXT = 13;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    // Returns the next format after `format`, or 0 at the end / on error.
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint EnumClipboardFormats(uint format);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint format);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern int GetClipboardFormatNameW(uint format, StringBuilder lpszFormatName, int cchMaxCount);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr GlobalSize(IntPtr hMem);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool GetClipboardOwner(out IntPtr owner);

    [DllImport("kernel32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [STAThread]
    private static int Main()
    {
        // WriteBack manipulates the real system clipboard, so a WPF Application
        // must exist (Clipboard / OLE state). Keep it headless.
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };

        int failures = 0;

        Console.WriteLine("=== A. WriteBack(Html) -- legacy entry, PlainText == null ===");
        // Old clipboard.json entries have no PlainText field. WriteBack must
        // still synthesise one from the HTML, otherwise every restored item from
        // before this fix stays un-pastable in non-Word apps.
        var html = new ClipEntry
        {
            Kind = ClipKind.Html,
            Text = "<p class=\"note\">\u300c\u53d1\u9001\u300d\u6309\u94ae obsidian-sample</p>",
            Preview = "\u300c\u53d1\u9001\u300d\u6309\u94ae obsidian-sample",
        };
        Report("A", ClipboardService.WriteBack(html), expectPlain: true,
            "\u300c\u53d1\u9001\u300d\u6309\u94ae obsidian-sample", expectRich: true, ref failures);

        Console.WriteLine();
        Console.WriteLine("=== B. WriteBack(Html) + HtmlStyle + PlainText ===");
        var htmlStyled = new ClipEntry
        {
            Kind = ClipKind.Html,
            Text = "<p>first</p><p>second</p>",
            Preview = "first second",
            HtmlStyle = "<style>p{font-size:14pt}</style>",
            // Source app handed us its own plain text; use it verbatim
            // (it knows about its own line breaks better than our HTML walk).
            PlainText = "first\r\nsecond",
        };
        Report("B", ClipboardService.WriteBack(htmlStyled), expectPlain: true,
            "first\r\nsecond", expectRich: true, ref failures);

        Console.WriteLine();
        Console.WriteLine("=== C. WriteBack(Rtf) ===");
        var rtf = new ClipEntry
        {
            Kind = ClipKind.Rtf,
            Text = @"{\rtf1\ansi\deff0{\fonttbl{\f0 SimSun;}}\f0\fs24 rtf-sample \u20013?}",
            Preview = "rtf-sample",
        };
        Report("C", ClipboardService.WriteBack(rtf), expectPlain: true,
            "rtf-sample \u4e2d", expectRich: true, ref failures);

        Console.WriteLine();
        Console.WriteLine("=== D. control: WriteBack(Text) ===");
        var text = new ClipEntry { Kind = ClipKind.Text, Text = "text-control-sample" };
        Report("D", ClipboardService.WriteBack(text), expectPlain: true,
            "text-control-sample", expectRich: false, ref failures);

        Console.WriteLine();
        Console.WriteLine("=== E. long Html (> 200 chars) must NOT degrade to Preview ===");
        // The old fallback path wrote entry.Preview, i.e. a 200-char ellipsis
        // string. Restoring a long note and pasting it into a chat box silently
        // truncated it. Assert the full length survives.
        string longBody = new string('x', 900);
        var htmlLong = new ClipEntry
        {
            Kind = ClipKind.Html,
            Text = $"<p>{longBody}</p>",
            Preview = longBody.Substring(0, 200) + "\u2026",
        };
        Report("E", ClipboardService.WriteBack(htmlLong), expectPlain: true,
            longBody, expectRich: true, ref failures);

        app.Shutdown();

        Console.WriteLine();
        Console.WriteLine(failures == 0
            ? "RESULT: PASS (every case exposes full CF_UNICODETEXT; rich kinds keep their rich format)"
            : $"RESULT: FAIL ({failures} assertion(s) failed)");
        return failures == 0 ? 0 : 1;
    }

    private static void Report(string label, bool wrote, bool expectPlain, string expectedPlain,
        bool expectRich, ref int failures)
    {
        Console.WriteLine($"  WriteBack -> {wrote}");
        if (!wrote)
        {
            Console.WriteLine("  FAIL: WriteBack reported failure");
            failures++;
            return;
        }

        var rows = new List<string>();
        string? plain = null;
        bool hasRich = false;

        if (!TryOpenClipboard())
        {
            Console.WriteLine($"  FAIL: OpenClipboard denied, err={Marshal.GetLastWin32Error()}");
            failures++;
            return;
        }

        try
        {
            uint fmt = 0;
            while (true)
            {
                fmt = EnumClipboardFormats(fmt);
                if (fmt == 0) break;
                string name = FormatName(fmt);
                IntPtr h = GetClipboardData(fmt);
                long size = h == IntPtr.Zero ? -1 : (long)GlobalSize(h);
                rows.Add($"    fmt {fmt,-6} {name,-20} size={size}");

                if (fmt == CF_UNICODETEXT && h != IntPtr.Zero)
                {
                    IntPtr p = GlobalLock(h);
                    if (p != IntPtr.Zero)
                    {
                        plain = Marshal.PtrToStringUni(p);
                        GlobalUnlock(h);
                    }
                }

                if (name is "HTML Format" or "Rich Text Format") hasRich = true;
            }
        }
        finally
        {
            CloseClipboard();
        }

        foreach (string r in rows) Console.WriteLine(r);

        bool pass = true;

        if (plain is null)
        {
            Console.WriteLine("  FAIL: no CF_UNICODETEXT -- NOTEPAD/BROWSER/CHAT/TERMINAL CANNOT PASTE");
            pass = false;
        }
        else
        {
            string got = plain.TrimEnd('\0');
            bool match = got == expectedPlain;
            Console.WriteLine($"  plain ({got.Length} ch) = '{ClipboardService.Truncate(got, 60)}'");
            Console.WriteLine($"  plain text exact match      : {match}");
            Console.WriteLine($"  plain not truncated to prev : {got.Length >= expectedPlain.Length}");
            if (!match)
            {
                Console.WriteLine($"    expected ({expectedPlain.Length} ch) = '{ClipboardService.Truncate(expectedPlain, 60)}'");
                pass = false;
            }
        }

        if (expectRich)
        {
            Console.WriteLine($"  rich format still present    : {hasRich}");
            if (!hasRich) pass = false;
        }

        if (!pass)
        {
            failures++;
            Console.WriteLine($"  -> case {label}: FAIL");
        }
    }

    /// <summary>
    /// OpenClipboard fails with ERROR_ACCESS_DENIED (5) while another process
    /// still owns the clipboard -- typically the writer we just called, whose
    /// CloseClipboard has not fully taken effect yet. Retry briefly.
    /// </summary>
    private static bool TryOpenClipboard()
    {
        for (int i = 0; i < 20; i++)
        {
            if (OpenClipboard(IntPtr.Zero)) return true;
            Thread.Sleep(25);
        }

        return false;
    }

    private static string FormatName(uint fmt)
    {
        if (fmt == CF_UNICODETEXT) return "(CF_UNICODETEXT)";
        if (fmt == 8) return "(CF_DIB)";
        var sb = new StringBuilder(256);
        int n = GetClipboardFormatNameW(fmt, sb, sb.Capacity);
        return n > 0 ? sb.ToString(0, n) : $"<standard {fmt}>";
    }
}
