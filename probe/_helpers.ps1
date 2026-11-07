param(
    [string]$Exe = ''
)

# End-to-end verification for the 2026-10-26 assistant page:
#   open the assistant tab, confirm WebView2 navigates, the panel keeps itself
#   open, the widen toggle resizes only on that page, and leaving re-arms
#   auto-hide. config.json / notes.json / clipboard.json are backed up and
#   restored around the run. ASCII only; paths derive from $PSScriptRoot.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) { $Exe = Join-Path $root 'publish\QuickDrawer.exe' }
$baseDir = Join-Path $env:APPDATA 'QuickDrawer'
$diagPath = Join-Path $baseDir 'logs\diag.log'
$configPath = Join-Path $baseDir 'config.json'
$notesPath = Join-Path $baseDir 'notes.json'
$clipPath  = Join-Path $baseDir 'clipboard.json'
$blobDir   = Join-Path $baseDir 'blobs'
$backupDir = Join-Path $PSScriptRoot 'state-backup'
$resultPath = Join-Path $PSScriptRoot 'assistant-result.txt'

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }
function Flush { $lines | Set-Content -LiteralPath $resultPath -Encoding UTF8 }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Drawing | Out-Null
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
$AE = [System.Windows.Automation.AutomationElement]
$CTS = [System.Windows.Automation.TreeScope]
$CTL = [System.Windows.Automation.ControlType]

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class U4 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    delegate bool EnumProc(IntPtr h, IntPtr l);
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint dwFlags;
        public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags;
        public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT {
        public uint type; public INPUTUNION u;
    }

    const uint INPUT_MOUSE = 0;
    const uint INPUT_KEYBOARD = 1;
    const uint MOUSEEVENTF_MOVE = 0x0001;
    const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    const uint MOUSEEVENTF_LEFTUP = 0x0004;
    const uint KEYEVENTF_KEYUP = 0x0002;

    static INPUT MakeMouse(uint flags, int dx, int dy) {
        INPUT i = new INPUT(); i.type = INPUT_MOUSE;
        i.u.mi.dx = dx; i.u.mi.dy = dy; i.u.mi.dwFlags = flags;
        return i;
    }
    static INPUT MakeKey(uint vk, bool up) {
        INPUT i = new INPUT(); i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = (ushort)vk; i.u.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        return i;
    }
    static void Send(INPUT one) { SendInput(1, new INPUT[] { one }, Marshal.SizeOf(typeof(INPUT))); }

    public static void MoveTo(int x, int y) {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        int ax = (int)Math.Round(x * 65535.0 / (w - 1));
        int ay = (int)Math.Round(y * 65535.0 / (h - 1));
        Send(MakeMouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, ax, ay));
    }
    public static void LeftDown() { Send(MakeMouse(MOUSEEVENTF_LEFTDOWN, 0, 0)); }
    public static void LeftUp() { Send(MakeMouse(MOUSEEVENTF_LEFTUP, 0, 0)); }
    public static void KeyDown(uint vk) { Send(MakeKey(vk, false)); }
    public static void KeyUp(uint vk) { Send(MakeKey(vk, true)); }
    public static void KeyTap(uint vk) { Send(MakeKey(vk, false)); Send(MakeKey(vk, true)); }
    public static void HotkeyWinAltN() { KeyDown(0x12); KeyDown(0x5B); KeyTap(0x4E); KeyUp(0x5B); KeyUp(0x12); }

    // lowercase ascii only: no shift juggling, so the text matches what we assert
    public static void TypeAscii(string s) {
        foreach (char c in s) {
            uint vk;
            if (c >= 'a' && c <= 'z') vk = (uint)('A' + (c - 'a'));
            else if (c >= '0' && c <= '9') vk = (uint)(0x30 + (c - '0'));
            else if (c == '-') vk = 0xBD;
            else if (c == ' ') vk = 0x20;
            else continue;
            KeyTap(vk);
            System.Threading.Thread.Sleep(12);
        }
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

    public static IntPtr FindDialog(uint targetPid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == targetPid && IsWindowVisible(h)) {
                StringBuilder c = new StringBuilder(512);
                GetClassNameW(h, c, 512);
                if (c.ToString() == "#32770") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static int[] GetRect(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        return new int[] { r.Left, r.Top, r.Right, r.Bottom };
    }

    public static string ClassOf(IntPtr h) {
        StringBuilder c = new StringBuilder(512);
        GetClassNameW(h, c, 512);
        return c.ToString();
    }

    public static IntPtr FindByTitle(string title) { return FindWindowW(null, title); }
}
"@

[void][U4]::SetProcessDPIAware()

# ---------------------------------------------------------------- helpers

function Get-App {
    return (Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Start-App {
    $p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
    Start-Sleep -Milliseconds 500
    [U4]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 1600
    return $p
}

function Stop-App {
    Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

function Get-DrawerRect {
    $p = Get-App
    if ($null -eq $p) { return $null }
    $h = [U4]::FindMainWindow($p.Id)
    if ($h -eq 0) { return $null }
    return [U4]::GetRect($h)
}

function Ensure-DrawerOpen {
    for ($i = 0; $i -lt 6; $i++) {
        $r = Get-DrawerRect
        if ($r -and $r[0] -lt 1900) { return $true }
        Say ("ensure: attempt {0} rect={1}" -f $i, $(if ($r) { ($r -join ',') } else { 'none' }))
        [U4]::HotkeyWinAltN()
        for ($j = 0; $j -lt 8; $j++) {
            Start-Sleep -Milliseconds 200
            $r = Get-DrawerRect
            if ($r -and $r[0] -lt 1900) { return $true }
        }
    }
    return $false
}

function Click-Point([int]$x, [int]$y) {
    [U4]::MoveTo($x, $y)
    Start-Sleep -Milliseconds 90
    [U4]::LeftDown()
    Start-Sleep -Milliseconds 60
    [U4]::LeftUp()
    Start-Sleep -Milliseconds 80
}

function Click-El($el, [double]$fx = 0.5) {
    $r = $el.Current.BoundingRectangle
    Click-Point ([int]($r.X + $r.Width * $fx)) ([int]($r.Y + $r.Height * 0.5))
}

function Get-InkStats($rect) {
    $x = [int]$rect.X; $y = [int]$rect.Y
    $w = [int]$rect.Width; $h = [int]$rect.Height
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $ink = 0; $dark = 0; $minL = 255
    for ($yy = 0; $yy -lt $h; $yy++) {
        for ($xx = 0; $xx -lt $w; $xx++) {
            $c = $bmp.GetPixel($xx, $yy)
            $l = [int](0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
            if ($l -lt $minL) { $minL = $l }
            if ($l -lt 200) { $ink++ }
            if ($l -lt 90) { $dark++ }
        }
    }
    $g.Dispose(); $bmp.Dispose()
    $n = [double]($w * $h)
    return [pscustomobject]@{ Ink = [math]::Round(100.0 * $ink / $n, 2); Dark = [math]::Round(100.0 * $dark / $n, 2); MinLuma = $minL; W = $w; H = $h }
}

function Get-RegionStats($rect) {
    $x = [int]$rect.X; $y = [int]$rect.Y
    $w = [int]$rect.Width; $h = [int]$rect.Height
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $sr = 0; $sg = 0; $sb = 0
    for ($yy = 0; $yy -lt $h; $yy++) {
        for ($xx = 0; $xx -lt $w; $xx++) {
            $c = $bmp.GetPixel($xx, $yy)
            $sr += $c.R; $sg += $c.G; $sb += $c.B
        }
    }
    $g.Dispose(); $bmp.Dispose()
    $n = [double]($w * $h)
    return [pscustomobject]@{
        R = [math]::Round($sr / $n, 1)
        G = [math]::Round($sg / $n, 1)
        B = [math]::Round($sb / $n, 1)
        W = $w; H = $h
    }
}

function Get-DrawerWindow {
    $p = Get-App
    if ($null -eq $p) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    $kids = $AE::RootElement.FindAll($CTS::Children, $cond)
    foreach ($w in $kids) {
        $r = $w.Current.BoundingRectangle
        if ($r.Width -ge 380 -and $r.Width -le 430 -and $r.Height -gt 500) { return $w }
    }
    return $null
}

function Find-ById($rootEl, [string]$id) {
    if ($null -eq $rootEl) { return $null }
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    return $rootEl.FindFirst($CTS::Descendants, $c)
}

function Find-All-Of($rootEl, $controlType) {
    if ($null -eq $rootEl) { return @() }
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $controlType)
    return $rootEl.FindAll($CTS::Descendants, $c)
}

function Find-By-Name($rootEl, [string]$name) {
    if ($null -eq $rootEl) { return $null }
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
    return $rootEl.FindFirst($CTS::Descendants, $c)
}

function Find-Ctl($rootEl, [string]$key) {
    $byId = Find-ById $rootEl $key
    if ($null -ne $byId) { return $byId }
    return (Find-By-Name $rootEl $key)
}

function Get-CardGlyph($card) {
    $pin = Find-Ctl $card 'PinCard'
    if ($null -eq $pin) { return '' }
    $lockG = ([string][char]0xD83D + [char]0xDD12)
    $pinG  = ([string][char]0xD83D + [char]0xDCCC)
    $texts = Find-All-Of $pin $CTL::Text
    foreach ($t in $texts) {
        $n = $t.Current.Name
        if ($n -eq $lockG) { return 'lock' }
        if ($n -eq $pinG) { return 'pin' }
    }
    return ''
}

function Click-Tab([string]$id) {
    $win = Get-DrawerWindow
    $tab = Find-ById $win $id
    if ($null -eq $tab) { return $false }
    Click-El $tab 0.5
    Start-Sleep -Milliseconds 900
    return $true
}

function Read-Json([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Read-Config { return (Read-Json $configPath) }
function Read-Notes { return (Read-Json $notesPath) }

function Read-DiagTail([int]$n = 30) {
    if (-not (Test-Path -LiteralPath $diagPath)) { return @() }
    return (Get-Content -LiteralPath $diagPath -Tail $n)
}

function Backup-State {
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
    New-Item -ItemType Directory -Path $backupDir | Out-Null
    if (Test-Path -LiteralPath $configPath) { Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDir 'config.json') -Force }
    if (Test-Path -LiteralPath $notesPath) { Copy-Item -LiteralPath $notesPath -Destination (Join-Path $backupDir 'notes.json') -Force }
    # Clipboard history is real user data and must be backed up, or the clear
    # test destroys it permanently. The running app rewrites clipboard.json
    # (delete + recreate), so a Copy-Item can hit that window, fail silently and
    # leave a 0-byte file. Retry and verify the length, then refuse to run.
    if (Test-Path -LiteralPath $clipPath) {
        $clipDest = Join-Path $backupDir 'clipboard.json'
        for ($i = 0; $i -lt 5; $i++) {
            try {
                Copy-Item -LiteralPath $clipPath -Destination $clipDest -Force -ErrorAction Stop
                if ((Get-Item -LiteralPath $clipDest).Length -gt 0) { break }
            } catch { }
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $clipDest) -or (Get-Item -LiteralPath $clipDest).Length -eq 0) {
            throw 'clipboard.json backup failed (file busy) - refusing to run and risk losing user data'
        }
    }
    if (Test-Path -LiteralPath $blobDir) { Copy-Item -LiteralPath $blobDir -Destination (Join-Path $backupDir 'blobs') -Recurse -Force }
    Say ("backup: config={0} notes={1} clipboard={2} blobs={3}" -f `
        (Test-Path -LiteralPath (Join-Path $backupDir 'config.json')), `
        (Test-Path -LiteralPath (Join-Path $backupDir 'notes.json')), `
        (Test-Path -LiteralPath (Join-Path $backupDir 'clipboard.json')), `
        (Test-Path -LiteralPath (Join-Path $backupDir 'blobs')))
}

function Restore-State {
    Stop-App
    $b1 = Join-Path $backupDir 'config.json'
    if (Test-Path -LiteralPath $b1) { Copy-Item -LiteralPath $b1 -Destination $configPath -Force }
    $b2 = Join-Path $backupDir 'notes.json'
    if (Test-Path -LiteralPath $b2) { Copy-Item -LiteralPath $b2 -Destination $notesPath -Force }
    $b3 = Join-Path $backupDir 'clipboard.json'
    if (Test-Path -LiteralPath $b3) { Copy-Item -LiteralPath $b3 -Destination $clipPath -Force }
    $b4 = Join-Path $backupDir 'blobs'
    if (Test-Path -LiteralPath $blobDir) { Remove-Item -LiteralPath $blobDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $b4) { Copy-Item -LiteralPath $b4 -Destination $blobDir -Recurse -Force }
    Say 'restored config.json + notes.json + clipboard.json + blobs'
}

function Press-Enter {
    [U4]::KeyTap(0x0D)
    Start-Sleep -Milliseconds 800
}

# ---------------- assistant page (2026-10-26 request) ----------------

function Find-Name2($rootEl, [string]$name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
    return $rootEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Wait-Diag([string]$pattern, [int]$timeoutMs = 20000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $hit = Select-String -LiteralPath $diagPath -Pattern $pattern -SimpleMatch -ErrorAction SilentlyContinue |
               Select-Object -Last 1
        if ($hit) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-DrawerRectNow {
    $app = Get-App
    if (-not $app) { return $null }
    $hwnd = [U4]::FindMainWindow($app.Id)
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    return [U4]::GetRect($hwnd)
}

function Get-FocusedInfo {
    try {
        $f = [System.Windows.Automation.AutomationElement]::FocusedElement
        if (-not $f) { return 'none' }
        $procId = $f.Current.ProcessId
        $ct = $f.Current.ControlType.ProgrammaticName
        $nm = $f.Current.Name
        if ($nm -and $nm.Length -gt 40) { $nm = $nm.Substring(0, 40) }
        return ("pid={0} type={1} name={2}" -f $procId, $ct, $nm)
    } catch {
        return ('error: ' + $_.Exception.Message)
    }
}

$script:fail = 0
function Check([string]$label, [bool]$ok) {
    Say ("assert {0}: {1}" -f $label, $ok)
    if (-not $ok) { $script:fail++ }
}

