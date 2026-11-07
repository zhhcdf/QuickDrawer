# Diagnose the Win+Alt+N hotkey registration failure reported by the user.
# Pure ASCII (see docs appendix D item 2). Paths passed as params.

param(
    [string]$ReportDir = 'C:\Windows\Temp\qd-hotkey-diag'
)

$ErrorActionPreference = 'Continue'

$src = @'
using System;
using System.Runtime.InteropServices;

public delegate IntPtr WndProcD(IntPtr h, uint m, IntPtr w, IntPtr l);

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct WNDCLASSD {
    public uint style;
    [MarshalAs(UnmanagedType.FunctionPtr)] public WndProcD lpfnWndProc;
    public int cbClsExtra, cbWndExtra;
    public IntPtr hInstance, hIcon, hCursor, hbrBackground;
    [MarshalAs(UnmanagedType.LPTStr)] public string lpszMenuName;
    [MarshalAs(UnmanagedType.LPTStr)] public string lpszClassName;
}

public class HD {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern ushort RegisterClass(ref WNDCLASSD wc);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateWindowEx(uint ex, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fs, uint vk);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@

Add-Type -TypeDefinition $src

$MOD_ALT = 0x0001
$MOD_CTRL = 0x0002
$MOD_SHIFT = 0x0004
$MOD_WIN = 0x0008
$MOD_NOREPEAT = 0x4000
$VK_N = 0x4E

$wc = New-Object WNDCLASSD
$wc.lpszClassName = 'QdHotkeyDiag'
$wc.lpfnWndProc = { param($h,$m,$w,$l) return [HD]::DefWindowProc($h,$m,$w,$l) }
[void][HD]::RegisterClass([ref]$wc)

function Try-Reg($label, $mods, $vk) {
    $hwnd = [HD]::CreateWindowEx([uint32]0, 'QdHotkeyDiag', 'diag', [uint32]2147483648, 0,0,1,1,
        [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    $ok = [HD]::RegisterHotKey($hwnd, 9001, $mods, $vk)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $verdict = if ($ok) { 'FREE  (registered OK)' } else { "OCCUPIED (Win32 error $err)" }
    Write-Output ("  {0,-38} {1}" -f $label, $verdict)
    if ($ok) { [void][HD]::UnregisterHotKey($hwnd, 9001) }
    [void][HD]::DestroyWindow($hwnd)
    return $ok
}

Write-Output "=== 1. Is Win+Alt+N registrable right now? ==="
$plain = Try-Reg 'Win+Alt+N  (no NOREPEAT)'  ($MOD_WIN -bor $MOD_ALT) $VK_N
$norep = Try-Reg 'Win+Alt+N + MOD_NOREPEAT' ($MOD_WIN -bor $MOD_ALT -bor $MOD_NOREPEAT) $VK_N

Write-Output ""
Write-Output "=== 2. Alternative hotkeys (fallback candidates) ==="
Try-Reg 'Win+Shift+V' ($MOD_WIN -bor $MOD_SHIFT) 0x56 | Out-Null
Try-Reg 'Win+Alt+Q'   ($MOD_WIN -bor $MOD_ALT)   0x51 | Out-Null
Try-Reg 'Ctrl+Alt+N'  ($MOD_CTRL -bor $MOD_ALT)  0x4E | Out-Null
Try-Reg 'Win+Alt+M'   ($MOD_WIN -bor $MOD_ALT)   0x4D | Out-Null

Write-Output ""
Write-Output "=== 3. Stale QuickDrawer processes? ==="
$procs = Get-Process -Name 'QuickDrawer' -ErrorAction SilentlyContinue
if ($procs) {
    $procs | ForEach-Object { Write-Output ("  PID {0}  started {1}" -f $_.Id, $_.StartTime) }
} else {
    Write-Output "  none running"
}

Write-Output ""
Write-Output "=== 4. Conclusion inputs ==="
Write-Output ("  Win+Alt+N plain    : {0}" -f $(if($plain){'FREE'}else{'OCCUPIED'}))
Write-Output ("  Win+Alt+N NOREPEAT : {0}" -f $(if($norep){'FREE'}else{'OCCUPIED'}))
