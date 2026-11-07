// clicktype: send a REAL OS mouse click and REAL keystrokes at a screen point.
// Used to test whether the drawer's notes box can actually be typed into.
//
// Usage: clicktype.exe <x> <y> <text>
//
// Console subsystem + launched with -NoNewWindow, so it never creates a window
// and never changes which window is foreground. The click itself is what may
// activate the target window -- which is exactly what we are testing.
//
// Pure ASCII.

using System.Runtime.InteropServices;

internal static class Program
{
    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    private static int Main(string[] args)
    {
        if (args.Length < 3)
        {
            Console.WriteLine("usage: clicktype <x> <y> <text>");
            return 2;
        }

        int x = int.Parse(args[0]);
        int y = int.Parse(args[1]);
        string text = args[2];

        Console.WriteLine($"  foreground before click: 0x{GetForegroundWindow().ToInt64():X}");

        SetCursorPos(x, y);
        Thread.Sleep(150);

        // real left click
        INPUT[] click =
        {
            new() { type = INPUT_MOUSE, U = new InputUnion { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_LEFTDOWN } } },
            new() { type = INPUT_MOUSE, U = new InputUnion { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_LEFTUP } } }
        };
        uint sent = SendInput((uint)click.Length, click, Marshal.SizeOf<INPUT>());
        Console.WriteLine($"  click SendInput returned {sent} (2 = both delivered)");
        Thread.Sleep(350);

        Console.WriteLine($"  foreground after click:  0x{GetForegroundWindow().ToInt64():X}");

        // real keystrokes
        var keys = new List<INPUT>();
        foreach (char c in text)
        {
            keys.Add(new INPUT
            {
                type = INPUT_KEYBOARD,
                U = new InputUnion { ki = new KEYBDINPUT { wVk = 0, wScan = c, dwFlags = KEYEVENTF_UNICODE } }
            });
            keys.Add(new INPUT
            {
                type = INPUT_KEYBOARD,
                U = new InputUnion { ki = new KEYBDINPUT { wVk = 0, wScan = c, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } }
            });
        }

        uint typed = SendInput((uint)keys.Count, keys.ToArray(), Marshal.SizeOf<INPUT>());
        Console.WriteLine($"  typed SendInput returned {typed} ({keys.Count} = all)");
        Thread.Sleep(300);

        return 0;
    }
}