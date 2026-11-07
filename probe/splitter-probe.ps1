param(
    [string]$Exe = '',
    [string]$Mode = 'basic'
)

# Real-gesture verification for the notes/clipboard splitter (SendInput, not synthetic WPF events).
# Scenario: drag up 160px -> drag down 300px (hits bottom clamp) -> restart to prove persistence.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) {
    $Exe = Join-Path $root 'src\QuickDrawer\bin\x64\Release\net10.0-windows\win-x64\QuickDrawer.exe'
}
$diag = Join-Path $env:APPDATA 'QuickDrawer\logs\diag.log'
$cfg  = Join-Path $env:APPDATA 'QuickDrawer\config.json'
$out  = Join-Path $PSScriptRoot 'splitter-result.txt'

$report = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $report.Add($s) }

Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class U2 {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint dwFlags;
        public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT {
        public uint type; public INPUTUNION u;
    }

    const uint INPUT_MOUSE = 0;
    const uint MOUSEEVENTF_MOVE = 0x0001;
    const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;

    static INPUT MakeMouse(uint flags, int dx, int dy) {
        INPUT inp = new INPUT();
        inp.type = INPUT_MOUSE;
        inp.u.mi.dx = dx; inp.u.mi.dy = dy;
        inp.u.mi.dwFlags = flags;
        return inp;
    }

    public static void MoveTo(int x, int y) {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        int ax = (int)Math.Round(x * 65535.0 / (w - 1));
        int ay = (int)Math.Round(y * 65535.0 / (h - 1));
        INPUT[] a = new INPUT[] { MakeMouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, ax, ay) };
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void LeftDown() {
        INPUT[] a = new INPUT[] { MakeMouse(MOUSEEVENTF_LEFTDOWN, 0, 0) };
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void LeftUp() {
        INPUT[] a = new INPUT[] { MakeMouse(MOUSEEVENTF_LEFTUP, 0, 0) };
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static IntPtr FindMainWindow(uint targetPid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == targetPid && IsWindowVisible(h)) {
                StringBuilder c = new StringBuilder(512);
                GetClassNameW(h, c, 512);
                if (c.ToString().StartsWith("HwndWrapper[QuickDrawer")) {
                    RECT r; GetWindowRect(h, out r);
                    if ((r.Right - r.Left) > 200) { found = h; return false; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static int[] GetRect(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        return new int[] { r.Left, r.Top, r.Right, r.Bottom };
    }
}
"@

function Stop-App {
    Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
}

function Start-App {
    $p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
    Start-Sleep -Milliseconds 400
    [U2]::MoveTo(1780, 400)          # keep the drawer open (cursor inside panel)
    Start-Sleep -Milliseconds 1400
    return $p
}

function Read-Log {
    if (Test-Path -LiteralPath $diag) { return (Get-Content -LiteralPath $diag -Tail 60) }
    return @()
}

function Get-ConfigValue([string]$name) {
    $j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
    $p = $j.layout.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return '<absent>'
}

function Drag([int]$x, [int]$y, [int]$dyTotal, [int]$steps) {
    [U2]::MoveTo($x, $y)
    Start-Sleep -Milliseconds 150
    [U2]::LeftDown()
    Start-Sleep -Milliseconds 120
    for ($i = 1; $i -le $steps; $i++) {
        $dy = [int]($dyTotal * $i / $steps)
        [U2]::MoveTo($x, $y + $dy)
        Start-Sleep -Milliseconds 20
    }
    Start-Sleep -Milliseconds 120
    [U2]::LeftUp()
    Start-Sleep -Milliseconds 700
}

Stop-App
Say ("exe=" + $Exe)
Say ("config.pathAreaHeight before = " + (Get-ConfigValue 'pathAreaHeight'))

$proc = Start-App
$hwnd = [U2]::FindMainWindow([uint32]$proc.Id)
$rect = [U2]::GetRect($hwnd)
Say ("hwnd=0x" + $hwnd.ToInt64().ToString("X") + " pid=" + $proc.Id + " rect=" + ($rect -join ","))

$probe = (Read-Log | Select-String '\[splitter-probe\]' | Select-Object -Last 1)
Say ("probe(before): " + $probe)
$m = [regex]::Match($probe.ToString(), 'y=([0-9.]+) h=([0-9.]+)')
$splitY = [double]$m.Groups[1].Value
$splitH = [double]$m.Groups[2].Value
$x = [int]($rect[0] + ($rect[2] - $rect[0]) / 2)
$y = [int]($rect[1] + $splitY + $splitH / 2)
Say ("grab point = (" + $x + "," + $y + ")")

if ($Mode -eq 'clamp') {
    # clamps: drag UP far beyond min, then DOWN far beyond max
    $startPath = [double]([regex]::Match($probe.ToString(), 'path=([0-9.]+)').Groups[1].Value)

    Drag $x $y (-600) 24
    $endUp = (Read-Log | Select-String '\[splitter\] drag end' | Select-Object -Last 1).ToString()
    Say ("clamp-up: " + $endUp)
    $endPath = [double]([regex]::Match($endUp, 'path=([0-9.]+)').Groups[1].Value)

    # splitter moved up by exactly (startPath - endPath)
    $y2 = [int]($rect[1] + $splitY + ($startPath - $endPath) + $splitH / 2)
    Say ("clamp-down grab point y = " + $y2)
    Drag $x $y2 1200 30
    foreach ($l in (Read-Log | Select-String '\[splitter\] drag end' | Select-Object -Last 2)) { Say ("clamp-down: " + $l) }
    Say ("clamp-down config.pathAreaHeight = " + (Get-ConfigValue 'pathAreaHeight'))
} else {
    # 1) drag UP 160px: path area shrinks, notes/clipboard grows
    Drag $x $y (-160) 16
    foreach ($l in (Read-Log | Select-String '\[splitter\]')) { Say ("after-up log: " + $l) }
    Say ("after-up config.pathAreaHeight = " + (Get-ConfigValue 'pathAreaHeight'))

    # 2) drag DOWN 300px from the new splitter position: path grows, notes shrinks
    $newY = [int]($rect[1] + $splitY - 160 + $splitH / 2)
    Drag $x $newY 300 20
    foreach ($l in (Read-Log | Select-String '\[splitter\]')) { Say ("after-down log: " + $l) }
    Say ("after-down config.pathAreaHeight = " + (Get-ConfigValue 'pathAreaHeight'))
}

# 3) restart: height must be restored
Stop-App
$proc2 = Start-App
$restored = (Read-Log | Select-String 'restored path|splitter-probe')
foreach ($l in $restored) { Say ("restart: " + $l) }
Stop-App

$report | Set-Content -LiteralPath $out -Encoding UTF8
Write-Output ("written " + $out)
