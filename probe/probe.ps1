# Feasibility probe: call Win32 APIs directly to verify high-risk mechanisms on Win11 22H2.
# ASCII-only source so Windows PowerShell 5.1 (ANSI default) cannot mangle it.
$ErrorActionPreference = 'Stop'

$src = @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }

public delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct WNDCLASS {
    public uint style;
    [MarshalAs(UnmanagedType.FunctionPtr)] public WndProc lpfnWndProc;
    public int cbClsExtra, cbWndExtra;
    public IntPtr hInstance, hIcon, hCursor, hbrBackground;
    [MarshalAs(UnmanagedType.LPTStr)] public string lpszMenuName;
    [MarshalAs(UnmanagedType.LPTStr)] public string lpszClassName;
}

[StructLayout(LayoutKind.Sequential)]
public struct APPBARDATA {
    public uint cbSize;
    public IntPtr hWnd;
    public uint uCallbackMessage;
    public uint uEdge;
    public RECT rc;
    public int lParam;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct MSG {
    public IntPtr hWnd; public uint message; public IntPtr wParam, lParam; public uint time; public int ptX, ptY;
}

public class W {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern ushort RegisterClass(ref WNDCLASS wc);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateWindowEx(uint ex, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool UpdateWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetMessage(out MSG m, IntPtr h, uint fmin, uint fmax);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll")] public static extern void PostQuitMessage(int code);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern bool PeekMessage(out MSG m, IntPtr h, uint fmin, uint fmax, uint rm);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool AddClipboardFormatListener(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RemoveClipboardFormatListener(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fs, uint vk);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint u);
}
'@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms

$script:ClipEvents = 0
$script:HotEvents  = 0

$proc = {
    param($hWnd, $msg, $wParam, $lParam)
    switch ($msg) {
        0x031D { $script:ClipEvents++; return [IntPtr]::Zero }
        0x0312 { $script:HotEvents++;  return [IntPtr]::Zero }
        default { return [W]::DefWindowProc($hWnd, $msg, $wParam, $lParam) }
    }
}

$wc = New-Object WNDCLASS
$wc.lpszClassName = 'DshFeasProbe'
$wc.lpfnWndProc = $proc

$atom = [W]::RegisterClass([ref]$wc)
if ($atom -eq 0) { Write-Output "FAIL RegisterClass err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 1 }

$hwnd = [W]::CreateWindowEx([uint32]0, 'DshFeasProbe', 'probe', [uint32]2147483648, 0,0, 1,1,
    [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
if ($hwnd -eq [IntPtr]::Zero) { Write-Output "FAIL CreateWindowEx err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 1 }

$log = New-Object System.Collections.Generic.List[string]
function Rec($name, $ok, $extra) {
    $log.Add(("  {0,-44} {1}  {2}" -f $name, $(if($ok){'PASS'}else{'FAIL'}), $extra))
}

# --- 1. clipboard format listener ---
$seq0 = [W]::GetClipboardSequenceNumber()
$ok = [W]::AddClipboardFormatListener($hwnd)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
Rec 'AddClipboardFormatListener' $ok "err=$err seq0=$seq0"

# --- 2. global hotkeys ---
$ok1 = [W]::RegisterHotKey($hwnd, 1, (0x0008 -bor 0x0001), 0x4E)
$e1 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
$ok2 = [W]::RegisterHotKey($hwnd, 2, (0x0002 -bor 0x0001), 0x70)
$e2 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
Rec 'RegisterHotKey Win+Alt+N' $ok1 "err=$e1"
Rec 'RegisterHotKey Ctrl+Win+F1' $ok2 "err=$e2"

# --- 3. appbar registration + reserved work area ---
$abd = New-Object APPBARDATA
$abd.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($abd)
$abd.hWnd = $hwnd
$abd.uCallbackMessage = 0x0400 + 1

$workBefore = New-Object RECT
[void][W]::SystemParametersInfo(0x0030, 0, [ref]$workBefore, 0)
$res = [W]::SHAppBarMessage(0x00000000, [ref]$abd)
$e3 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
Rec 'SHAppBarMessage ABM_NEW' ($res -ne [IntPtr]::Zero) "ret=$res err=$e3"

$abd.uEdge = 0
$abd.rc.Left = 0; $abd.rc.Top = 0; $abd.rc.Right = 300; $abd.rc.Bottom = 1080
[void][W]::SHAppBarMessage(0x00000002, [ref]$abd)
$abd.rc.Right = 300
[void][W]::SHAppBarMessage(0x00000003, [ref]$abd)
$workAfter = New-Object RECT
[void][W]::SystemParametersInfo(0x0030, 0, [ref]$workAfter, 0)
$reserved = $workAfter.Left - $workBefore.Left
Rec 'AppBar LEFT reserves work area (300px)' ($reserved -gt 0) "workArea.Left $($workBefore.Left) -> $($workAfter.Left), reserved=$reserved px"

# --- 4. topmost + exstyle ---
$okTop = [W]::SetWindowPos($hwnd, [IntPtr](-1), 0,0,0,0, 0x0013)
Rec 'SetWindowPos HWND_TOPMOST' $okTop "err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
$ex = [W]::GetWindowLong($hwnd, -20)
Rec 'GetWindowLong GWL_EXSTYLE' ($ex -ne 0) "exstyle=0x$('{0:X8}' -f $ex) NOACTIVATE=$(($ex -band 0x08000000) -ne 0) TOOLWINDOW=$(($ex -band 0x00000080) -ne 0)"

# --- 5. fire clipboard writes, confirm the listener actually fires ---
$script:ClipEvents = 0
Set-Clipboard -Value 'probe-text'
Start-Sleep -Milliseconds 200
Set-Clipboard -Value 'probe-text-2'
Start-Sleep -Milliseconds 300

$deadline = (Get-Date).AddSeconds(12)
$fired = $false
$m = New-Object MSG
while ((Get-Date) -lt $deadline) {
    while ([W]::PeekMessage([ref]$m, [IntPtr]::Zero, 0, 0, 1)) {
        [void][W]::TranslateMessage([ref]$m)
        [void][W]::DispatchMessage([ref]$m)
    }
    if ($script:ClipEvents -gt 0) { $fired = $true; break }
    Start-Sleep -Milliseconds 100
}
Rec 'WM_CLIPBOARDUPDATE delivered' $fired "events=$($script:ClipEvents)"

# --- cleanup ---
[void][W]::UnregisterHotKey($hwnd, 1)
[void][W]::UnregisterHotKey($hwnd, 2)
[void][W]::RemoveClipboardFormatListener($hwnd)
[void][W]::SHAppBarMessage(0x00000001, [ref]$abd)
[void][W]::DestroyWindow($hwnd)

Write-Output ''
Write-Output '======== PROBE RESULT ========'
$log | ForEach-Object { Write-Output $_ }
Write-Output '============================='
Write-Output ("CLIP_EVENTS={0} HOT_EVENTS={1}" -f $script:ClipEvents, $script:HotEvents)
