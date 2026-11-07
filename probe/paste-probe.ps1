param(
    [ValidateSet('paste', 'pin')] [string]$Mode = 'paste',
    [string]$Exe = ''
)

# End-to-end verification of the clipboard "click to paste" + "pin = lock" feature.
#   paste: seed the clipboard with a token, focus a foreign WinForms TextBox, open the
#          drawer, click the first clipboard entry, then assert the token landed in that
#          TextBox and diag.log shows "sent Ctrl+V, events=4".
#   pin:   click the first entry's pin button, assert the glyph flips from pushpin to
#          lock and clipboard.json carries Pinned=true, then ClearButton + Enter and
#          assert only locked entries survive.
# The clipboard history on disk is backed up before the run and restored afterwards.
# ASCII only; all paths derive from $PSScriptRoot.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) { $Exe = Join-Path $root 'publish\QuickDrawer.exe' }
$baseDir = Join-Path $env:APPDATA 'QuickDrawer'
$diagPath = Join-Path $baseDir 'logs\diag.log'
$clipPath = Join-Path $baseDir 'clipboard.json'
$blobDir = Join-Path $baseDir 'blobs'
$backupDir = Join-Path $PSScriptRoot 'clipboard-backup'
$targetTxt = Join-Path $PSScriptRoot 'target-text.txt'
$targetScript = Join-Path $PSScriptRoot 'paste-target.ps1'
$resultPath = Join-Path $PSScriptRoot ('paste-result-' + $Mode + '.txt')

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }
function Flush { $lines | Set-Content -LiteralPath $resultPath -Encoding UTF8 }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
$AE = [System.Windows.Automation.AutomationElement]
$CTS = [System.Windows.Automation.TreeScope]
$CTL = [System.Windows.Automation.ControlType]

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class U3 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
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
    public static void CtrlKey(uint vk) { KeyDown(0x11); KeyTap(vk); KeyUp(0x11); }
    public static void HotkeyWinAltN() { KeyDown(0x12); KeyDown(0x5B); KeyTap(0x4E); KeyUp(0x5B); KeyUp(0x12); }

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

    // FindWindow keeps the class parameter; PowerShell turns $null into "" which would
    // match only class-less windows, so expose a title-only wrapper.
    public static IntPtr FindByTitle(string title) { return FindWindowW(null, title); }
}
"@

[void][U3]::SetProcessDPIAware()

# ---------------------------------------------------------------- helpers

function Get-App {
    return (Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Start-App {
    $p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
    Start-Sleep -Milliseconds 500
    [U3]::MoveTo(1780, 400)
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
    $h = [U3]::FindMainWindow($p.Id)
    if ($h -eq 0) { return $null }
    return [U3]::GetRect($h)
}

function Ensure-DrawerOpen {
    for ($i = 0; $i -lt 6; $i++) {
        $r = Get-DrawerRect
        if ($r -and $r[0] -lt 1900) { return $true }
        Say ("ensure: attempt {0} rect={1}" -f $i, $(if ($r) { ($r -join ',') } else { 'none' }))
        [U3]::HotkeyWinAltN()
        for ($j = 0; $j -lt 8; $j++) {
            Start-Sleep -Milliseconds 200
            $r = Get-DrawerRect
            if ($r -and $r[0] -lt 1900) { return $true }
        }
    }
    return $false
}

function Click-Point([int]$x, [int]$y) {
    [U3]::MoveTo($x, $y)
    Start-Sleep -Milliseconds 90
    [U3]::LeftDown()
    Start-Sleep -Milliseconds 60
    [U3]::LeftUp()
    Start-Sleep -Milliseconds 80
}

function Click-El($el, [double]$fx = 0.5) {
    $r = $el.Current.BoundingRectangle
    Click-Point ([int]($r.X + $r.Width * $fx)) ([int]($r.Y + $r.Height * 0.5))
}

# Mean colour of a screen rectangle: proves a control's look really changed
# (glyph swap alone could be font fallback, so measure the pixels too).
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
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    return $rootEl.FindFirst($CTS::Descendants, $c)
}

function Find-All-Of($rootEl, $controlType) {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $controlType)
    return $rootEl.FindAll($CTS::Descendants, $c)
}

function Open-ClipboardTab {
    $win = Get-DrawerWindow
    if ($null -eq $win) { return $false }
    $tab = Find-ById $win 'TabClipboard'
    if ($null -eq $tab) { return $false }
    Click-El $tab 0.5
    Start-Sleep -Milliseconds 900
    return $true
}

function Read-ClipJson {
    if (-not (Test-Path -LiteralPath $clipPath)) { return $null }
    try { return (Get-Content -LiteralPath $clipPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Read-DiagTail([int]$n = 40) {
    if (-not (Test-Path -LiteralPath $diagPath)) { return @() }
    return (Get-Content -LiteralPath $diagPath -Tail $n)
}

function Stop-Target {
    Get-Process -Name powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -eq 'QD Paste Target' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}

function Start-Target {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $targetScript) | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        $h = [U3]::FindByTitle("QD Paste Target")
        if ($h -ne 0) { return $h }
    }
    return [IntPtr]::Zero
}

function Backup-State {
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
    New-Item -ItemType Directory -Path $backupDir | Out-Null
    if (Test-Path -LiteralPath $clipPath) { Copy-Item -LiteralPath $clipPath -Destination (Join-Path $backupDir 'clipboard.json') -Force }
    if (Test-Path -LiteralPath $blobDir) {
        New-Item -ItemType Directory -Path (Join-Path $backupDir 'blobs') | Out-Null
        Copy-Item -LiteralPath (Join-Path $blobDir '*') -Destination (Join-Path $backupDir 'blobs') -Force -ErrorAction SilentlyContinue
    }
    Say ("backup: clipboard.json present={0}" -f (Test-Path -LiteralPath (Join-Path $backupDir 'clipboard.json')))
}

function Restore-State {
    Stop-App
    $bak = Join-Path $backupDir 'clipboard.json'
    if (Test-Path -LiteralPath $bak) { Copy-Item -LiteralPath $bak -Destination $clipPath -Force }
    $bakBlobs = Join-Path $backupDir 'blobs'
    if (Test-Path -LiteralPath $blobDir) {
        Get-ChildItem -LiteralPath $blobDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not (Test-Path -LiteralPath (Join-Path $bakBlobs $_.Name))) { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    if (Test-Path -LiteralPath $bakBlobs) {
        if (-not (Test-Path -LiteralPath $blobDir)) { New-Item -ItemType Directory -Path $blobDir | Out-Null }
        Copy-Item -LiteralPath (Join-Path $bakBlobs '*') -Destination $blobDir -Force -ErrorAction SilentlyContinue
    }
    Say 'restored clipboard.json + blobs'
}

# ---------------------------------------------------------------- paste mode

function Run-Paste {
    Stop-Target
    Stop-App
    Backup-State

    $targetHwnd = Start-Target
    if ($targetHwnd -eq [IntPtr]::Zero) { Say 'FAIL: paste target window did not appear'; return $false }
    Say ("target hwnd=0x{0:X}" -f [int64]$targetHwnd)

    $app = Start-App
    Say ("app pid={0}" -f $app.Id)

    [void][U3]::SetForegroundWindow($targetHwnd)
    Start-Sleep -Milliseconds 500
    $tr = [U3]::GetRect($targetHwnd)
    Click-Point ([int](($tr[0] + $tr[2]) / 2)) ([int](($tr[1] + $tr[3]) / 2))
    Start-Sleep -Milliseconds 300
    [U3]::CtrlKey(0x41)
    [U3]::KeyTap(0x2E)
    Start-Sleep -Milliseconds 300

    $token = 'QD-PASTE-' + (Get-Date -Format 'HHmmss')
    Set-Clipboard -Value $token
    Say ("clipboard seeded with {0}" -f $token)
    Start-Sleep -Milliseconds 1600

    if (-not (Ensure-DrawerOpen)) { Say 'FAIL: drawer did not open'; return $false }
    [U3]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 400
    if (-not (Open-ClipboardTab)) { Say 'FAIL: could not switch to the clipboard tab'; return $false }

    $win = Get-DrawerWindow
    $list = Find-ById $win 'ClipboardList'
    if ($null -eq $list) { Say 'FAIL: ClipboardList not found'; return $false }
    $items = Find-All-Of $list $CTL::ListItem
    Say ("clipboard items={0}" -f $items.Count)
    if ($items.Count -lt 1) { Say 'FAIL: clipboard list is empty'; return $false }

    $first = $items[0]
    Say ("first item name={0}" -f $first.Current.Name)
    $r1 = $first.Current.BoundingRectangle
    Say ("first item rect={0},{1} {2}x{3}" -f [int]$r1.X, [int]$r1.Y, [int]$r1.Width, [int]$r1.Height)

    Click-El $first 0.12
    Say 'clicked first clipboard entry'
    Start-Sleep -Milliseconds 2400

    $pasted = ''
    if (Test-Path -LiteralPath $targetTxt) { $pasted = Get-Content -LiteralPath $targetTxt -Raw -Encoding UTF8 }
    Say ("target text=[{0}]" -f ($pasted -replace "`r?`n", ' / '))

    $tail = Read-DiagTail 40
    foreach ($l in $tail) { Say ("diag| " + $l) }

    $hit = ($null -ne $pasted) -and ($pasted.Contains($token))
    $joined = ($tail -join "`n")
    $sent = $joined -match 'sent Ctrl\+V, events=4'
    $aborted = $joined -match 'abort Ctrl\+V'
    Say ("pasted contains token: {0}" -f $hit)
    Say ("diag sent Ctrl+V events=4: {0}" -f $sent)
    Say ("diag abort present: {0}" -f $aborted)

    $ok = $hit -and $sent
    Say ($(if ($ok) { 'RESULT: PASS (paste)' } else { 'RESULT: FAIL (paste)' }))
    return $ok
}

# ---------------------------------------------------------------- pin mode

function Run-Pin {
    $lockGlyph = ([string][char]0xD83D + [char]0xDD12)
    $pinGlyph = ([string][char]0xD83D + [char]0xDCCC)

    Stop-Target
    Stop-App
    Backup-State

    $app = Start-App
    Say ("app pid={0}" -f $app.Id)

    if (-not (Ensure-DrawerOpen)) { Say 'FAIL: drawer did not open'; return $false }
    [U3]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 400
    if (-not (Open-ClipboardTab)) { Say 'FAIL: could not switch to the clipboard tab'; return $false }

    $win = Get-DrawerWindow
    $list = Find-ById $win 'ClipboardList'
    if ($null -eq $list) { Say 'FAIL: ClipboardList not found'; return $false }
    $items = Find-All-Of $list $CTL::ListItem
    Say ("clipboard items={0}" -f $items.Count)
    if ($items.Count -lt 1) { Say 'FAIL: clipboard list is empty'; return $false }

    $first = $items[0]
    Say ("first item name={0}" -f $first.Current.Name)

    $jsonBefore = Read-ClipJson
    $countBefore = 0
    $pinnedBefore = 0
    if ($jsonBefore) {
        $countBefore = $jsonBefore.Entries.Count
        $pinnedBefore = @($jsonBefore.Entries | Where-Object { $_.Pinned }).Count
    }
    Say ("before: entries={0} pinned={1}" -f $countBefore, $pinnedBefore)

    $btns = Find-All-Of $first $CTL::Button
    Say ("buttons in first item={0}" -f $btns.Count)
    if ($btns.Count -lt 1) { Say 'FAIL: pin button not found'; return $false }
    $pinBtn = $btns[0]
    $nameBefore = $pinBtn.Current.Name
    Say ("pin button name before=[{0}] isPushpin={1}" -f $nameBefore, $nameBefore.StartsWith($pinGlyph))

    $pxBefore = Get-RegionStats $pinBtn.Current.BoundingRectangle
    if ($null -eq $pxBefore) { Say 'FAIL: pin button rect is empty'; return $false }
    Say ("pin pixels before=({0},{1},{2}) rect={3}x{4}" -f $pxBefore.R, $pxBefore.G, $pxBefore.B, $pxBefore.W, $pxBefore.H)

    Click-El $pinBtn 0.5
    Say 'clicked pin button'
    Start-Sleep -Milliseconds 1200

    $win = Get-DrawerWindow
    $list2 = Find-ById $win 'ClipboardList'
    $items2 = Find-All-Of $list2 $CTL::ListItem
    Say ("items after pin={0}" -f $items2.Count)
    $first2 = $items2[0]
    $btns2 = Find-All-Of $first2 $CTL::Button
    $nameAfter = $btns2[0].Current.Name
    Say ("pin button name after=[{0}] isLock={1}" -f $nameAfter, $nameAfter.StartsWith($lockGlyph))

    $pxAfter = Get-RegionStats $btns2[0].Current.BoundingRectangle
    $pxDelta = 0.0
    if ($null -ne $pxAfter) {
        $pxDelta = [math]::Abs($pxAfter.R - $pxBefore.R) + [math]::Abs($pxAfter.G - $pxBefore.G) + [math]::Abs($pxAfter.B - $pxBefore.B)
        Say ("pin pixels after=({0},{1},{2}) rect={3}x{4} meanDelta={5}" -f $pxAfter.R, $pxAfter.G, $pxAfter.B, $pxAfter.W, $pxAfter.H, [math]::Round($pxDelta, 1))
    }
    else {
        Say 'pin pixels after=<empty rect>'
    }
    $styleOk = ($null -ne $pxAfter) -and ($pxDelta -ge 3.0)

    $jsonAfter = Read-ClipJson
    $countAfter = 0
    $pinnedAfter = 0
    $pinnedPreview = ''
    if ($jsonAfter) {
        $countAfter = $jsonAfter.Entries.Count
        $pinnedAfter = @($jsonAfter.Entries | Where-Object { $_.Pinned }).Count
        $pp = $jsonAfter.Entries | Where-Object { $_.Pinned } | Select-Object -First 1
        if ($pp) { $pinnedPreview = $pp.Preview }
    }
    Say ("after pin: entries={0} pinned={1} pinnedPreview=[{2}]" -f $countAfter, $pinnedAfter, $pinnedPreview)

    $win = Get-DrawerWindow
    $clear = Find-ById $win 'ClearButton'
    if ($null -eq $clear) { Say 'FAIL: ClearButton not found'; return $false }
    Click-El $clear 0.5
    Say 'clicked ClearButton'
    Start-Sleep -Milliseconds 1200

    $dlg = [U3]::FindDialog($app.Id)
    Say ("confirm dialog hwnd=0x{0:X} class={1}" -f [int64]$dlg, $(if ($dlg -ne [IntPtr]::Zero) { [U3]::ClassOf($dlg) } else { '' }))
    if ($dlg -ne [IntPtr]::Zero) {
        [void][U3]::SetForegroundWindow($dlg)
        Start-Sleep -Milliseconds 400
    }
    [U3]::KeyTap(0x0D)
    Start-Sleep -Milliseconds 1600

    $jsonCleared = Read-ClipJson
    $countCleared = 0
    $pinnedCleared = 0
    $keptPreview = ''
    if ($jsonCleared) {
        $countCleared = $jsonCleared.Entries.Count
        $pinnedCleared = @($jsonCleared.Entries | Where-Object { $_.Pinned }).Count
        $kp = $jsonCleared.Entries | Where-Object { $_.Pinned } | Select-Object -First 1
        if ($kp) { $keptPreview = $kp.Preview }
    }
    Say ("after clear: entries={0} pinned={1} pinnedPreview=[{2}]" -f $countCleared, $pinnedCleared, $keptPreview)

    $win = Get-DrawerWindow
    $list3 = Find-ById $win 'ClipboardList'
    $items3 = Find-All-Of $list3 $CTL::ListItem
    Say ("list items after clear={0}" -f $items3.Count)

    $tail = Read-DiagTail 25
    foreach ($l in $tail) { Say ("diag| " + $l) }

    $glyphOk = $nameBefore.StartsWith($pinGlyph) -and $nameAfter.StartsWith($lockGlyph)
    $pinOk = ($pinnedAfter -ge $pinnedBefore + 1) -and ($pinnedPreview.Length -gt 0)
    $clearOk = ($countCleared -eq $pinnedCleared) -and ($pinnedCleared -ge 1) -and ($items3.Count -eq $pinnedCleared)
    Say ("glyph flipped: {0}" -f $glyphOk)
    Say ("style changed (pixel mean delta >= 3): {0}" -f $styleOk)
    Say ("pinned persisted: {0}" -f $pinOk)
    Say ("clear kept only pinned: {0}" -f $clearOk)

    $ok = $glyphOk -and $styleOk -and $pinOk -and $clearOk
    Say ($(if ($ok) { 'RESULT: PASS (pin)' } else { 'RESULT: FAIL (pin)' }))
    return $ok
}

# ---------------------------------------------------------------- main

Say ("mode={0} exe={1}" -f $Mode, $Exe)
Say ("time={0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
try {
    if ($Mode -eq 'paste') { [void](Run-Paste) } else { [void](Run-Pin) }
}
catch {
    Say ("EXCEPTION: " + $_.Exception.Message)
    Say ($_.ScriptStackTrace)
}
finally {
    Stop-Target
    try { Restore-State } catch { Say ("restore failed: " + $_.Exception.Message) }
    try { $app = Start-App; Say ("restarted app pid={0}" -f $app.Id) } catch { Say ("restart failed: " + $_.Exception.Message) }
    Flush
    Say ("written: " + $resultPath)
}
