using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using System.IO;

// 划词还原的"正常路径"验收目标：
// 必须是一个**独立桌面进程**（不能是 powershell / conhost / WindowsTerminal 之类，
// 否则 SelectionWatcher.IsForegroundTerminal() 会直接跳过，测不到还原逻辑）。
public class QdSelectTarget
{
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);

    const string Line = "QD normal restore check one two three four five six seven";
    static readonly string LogPath = Path.Combine(Path.GetTempPath(), "qd_select_target.log");

    static void Say(string s)
    {
        try { File.AppendAllText(LogPath, s + Environment.NewLine); } catch { }
    }

    [STAThread]
    static int Main()
    {
        var form = new Form();
        form.Text = "QD Select Target";
        form.Width = 720;
        form.Height = 240;
        form.StartPosition = FormStartPosition.Manual;
        form.Left = 260;
        form.Top = 260;
        form.TopMost = true;

        var box = new TextBox();
        box.Multiline = true;
        box.Font = new Font("Consolas", 16f);
        box.Left = 12;
        box.Top = 12;
        box.Width = 680;
        box.Height = 150;
        box.Text = Line + "\r\nsecond line";
        form.Controls.Add(box);

        form.Shown += (s, e) =>
        {
            form.Activate();
            SetForegroundWindow(form.Handle);
            Application.DoEvents();

            // 必须在 STA（UI 线程）上跑：ThreadPool 是 MTA，Clipboard.GetText 会恒返回空。
            var t = new System.Windows.Forms.Timer();
            t.Interval = 100;
            t.Tick += (s2, e2) => { t.Stop(); t.Dispose(); RunPumped(box, form); };
            t.Start();
        };

        Application.Run(form);
        return 0;
    }

    static void Pump(int ms)
    {
        var end = Environment.TickCount + ms;
        while (Environment.TickCount < end)
        {
            Application.DoEvents();
            Thread.Sleep(10);
        }
    }

    static void RunPumped(TextBox box, Form form)
    {
        try { Run(box, form); } catch (Exception ex) { Say("EX=" + ex.Message); }
    }

    static void Run(TextBox box, Form form)
    {
        try { File.Delete(LogPath); } catch { }
        Pump(600);

        // 先把剪贴板设成一个可辨认的基线值（用 copy:true 持久化，进程退出也不丢），
        // 这样拖拽之后只要剪贴板回到这个值，就证明还原真的执行了。
        string baseline = "QDPRE-baseline-" + DateTime.Now.ToString("HHmmss");
        for (int i = 0; i < 40; i++)
        {
            try { Clipboard.SetDataObject(baseline, true); break; }
            catch { Thread.Sleep(30); }
        }
        Pump(300);

        string before = SafeGetText();
        Say("BASELINE=[" + baseline + "]");
        Say("BEFORE=[" + before + "]");

        uint selfPid = 0;
        IntPtr fg = GetForegroundWindow();
        GetWindowThreadProcessId(fg, out selfPid);
        Say("foreground pid=" + selfPid + " self pid=" + (uint)System.Diagnostics.Process.GetCurrentProcess().Id);

        Point p1 = box.PointToScreen(new Point(8, 16));
        Point p2 = box.PointToScreen(new Point(560, 16));

        SetCursorPos(p1.X, p1.Y);
        Pump(80);
        mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
        for (int i = 1; i <= 16; i++)
        {
            SetCursorPos(p1.X + (p2.X - p1.X) * i / 16, p1.Y + (p2.Y - p1.Y) * i / 16);
            Pump(20);
        }
        mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
        Say("drag done at " + DateTime.Now.ToString("HH:mm:ss.fff"));

        Pump(6000);

        string after = SafeGetText();
        Say("AFTER=[" + after + "]");
        Say("RESTORED=" + (after == baseline ? "YES" : "NO"));
        Say("CAPTURED_LINE=" + (after.StartsWith("QD normal restore") ? "YES" : "NO"));

        try { form.Invoke(new Action(() => form.Close())); } catch { }
    }

    static string SafeGetText()
    {
        for (int i = 0; i < 40; i++)
        {
            try { return Clipboard.GetText(); }
            catch { Thread.Sleep(30); }
        }
        return "<ERR>";
    }
}
