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
    # 2026-10-31: the drawer hides by moving itself off-screen (Left = work.Right + 4),
    # NOT by destroying the window. GetWindowRect then still returns a rect, but
    # r[0] is past the screen edge, so the old "r[0] -lt 1900" test said "not open"
    # while the panel was actually open -- and the hotkey then HID it again.
    # Fix: after toggling, accept either state; the UIA lookups below work on the
    # visible window either way, and the pixel assertions run after we re-open it.
    for ($i = 0; $i -lt 6; $i++) {
        $r = Get-DrawerRect
        if ($r -and $r[0] -lt 1900) { return $true }
        Say ("ensure: attempt {0} rect={1}" -f $i, $(if ($r) { ($r -join ',') } else { 'none' }))
        [U4]::HotkeyWinAltN()
        Start-Sleep -Milliseconds 600
        $r2 = Get-DrawerRect
        if ($r2) {
            Say ("ensure: after toggle rect={0}" -f ($r2 -join ','))
            if ($r2[0] -lt 1900) { return $true }
            # toggled to the off-screen state: toggle once more to bring it back
            [U4]::HotkeyWinAltN()
            Start-Sleep -Milliseconds 600
            $r3 = Get-DrawerRect
            if ($r3) {
                Say ("ensure: after second toggle rect={0}" -f ($r3 -join ','))
                if ($r3[0] -lt 1900) { return $true }
            }
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

function Get-RegionBitmap($rect) {
    $x = [int]$rect.X; $y = [int]$rect.Y
    $w = [int]$rect.Width; $h = [int]$rect.Height
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    return $bmp
}

# Percentage of pixels that changed by more than $thresh in any channel.
# A mean-colour delta is too weak for a near-white page on a near-white panel
# (Qwen measured 2.9 against a >3 threshold), so compare pixel by pixel and
# require that a real fraction of the region actually changed.
function Get-DiffRatio($bmpA, $bmpB, [int]$thresh = 12) {
    if (-not $bmpA -or -not $bmpB) { return -1 }
    $w = [math]::Min($bmpA.Width, $bmpB.Width)
    $h = [math]::Min($bmpA.Height, $bmpB.Height)
    if ($w -le 0 -or $h -le 0) { return -1 }
    $diff = 0; $n = 0
    for ($yy = 0; $yy -lt $h; $yy += 2) {
        for ($xx = 0; $xx -lt $w; $xx += 2) {
            $a = $bmpA.GetPixel($xx, $yy); $b = $bmpB.GetPixel($xx, $yy)
            $n++
            if ([math]::Abs($a.R - $b.R) -gt $thresh -or
                [math]::Abs($a.G - $b.G) -gt $thresh -or
                [math]::Abs($a.B - $b.B) -gt $thresh) { $diff++ }
        }
    }
    if ($n -eq 0) { return -1 }
    return [math]::Round(100.0 * $diff / $n, 2)
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

# 2026-10-31: since the per-site resident WebView2 change (2026-10-29) the
# automation id is "AssistantView:<providerId>" (see AssistantService.cs), not
# the flat "AssistantView" this probe still asked for. Match by prefix.
function Find-CtlByIdPrefix($rootEl, [string]$prefix) {
    if ($null -eq $rootEl) { return $null }
    $all = $rootEl.FindAll($CTS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        try {
            $id = $el.Current.AutomationId
            if ($id -and $id.StartsWith($prefix)) { return $el }
        } catch { }
    }
    return $null
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
    # 剪贴板历史属于用户真实数据，必须一起备份，否则清除测试会永久丢失
    if (Test-Path -LiteralPath $clipPath) { Copy-Item -LiteralPath $clipPath -Destination (Join-Path $backupDir 'clipboard.json') -Force }
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

function Get-DiagLineCount {
    if (-not (Test-Path -LiteralPath $diagPath)) { return 0 }
    return @(Get-Content -LiteralPath $diagPath -ErrorAction SilentlyContinue).Count
}

# sinceLine: only match lines appended after this line number. The diag log keeps
# history across runs, so a plain whole-file match can pass on an old line.
function Wait-Diag([string]$pattern, [int]$timeoutMs = 20000, [int]$sinceLine = 0) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $hit = Select-String -LiteralPath $diagPath -Pattern $pattern -SimpleMatch -ErrorAction SilentlyContinue |
               Where-Object { $_.LineNumber -gt $sinceLine } |
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

# Clicking the chip of the already-active provider is a no-op: no "provider
# selected" / "navigate" lines are written, so the assertions below would fail
# for a reason that has nothing to do with the product. Switch to another site
# first whenever the provider under test is already the active one.
function Ensure-ProviderSwitchable($drawerEl, [string]$providerId) {
    $cfgNow = Read-Config
    $active = if ($cfgNow.assistant) { $cfgNow.assistant.activeProviderId } else { '' }
    Say ("active provider before {0} step = {1}" -f $providerId, $active)
    if ($active -ne $providerId) { return $true }
    $alt = if ($providerId -eq 'deepseek') { 'ChipKimi' } else { 'ChipDeepSeek' }
    $altEl = Find-Ctl $drawerEl $alt
    if (-not $altEl) { Say ("no {0} to switch away with" -f $alt); return $false }
    $markAlt = Get-DiagLineCount
    Click-El $altEl
    Start-Sleep -Milliseconds 1500
    [U4]::MoveTo(1780, 400)
    $ok = Wait-Diag 'provider selected' 8000 $markAlt
    Say ("switched away from {0} = {1}" -f $providerId, $ok)
    return $ok
}

try {
    Say '=== assistant probe ==='
    Backup-State

    $app = Get-App
    if (-not $app) {
        Start-App
        Start-Sleep -Milliseconds 1800
        $app = Get-App
    }
    if (-not $app) { Say 'FAIL: app did not start'; Flush; exit 1 }

    Ensure-DrawerOpen
    $drawer = Get-DrawerWindow
    if (-not $drawer) { Say 'FAIL: drawer window not found'; Flush; exit 1 }

    $cfgObj = Read-Config
    $dockWidth = $cfgObj.dock.width
    Say ("dock width = {0}" -f $dockWidth)

    if ($cfgObj.dock.pinPanel -eq $true) {
        Say 'panel is pinned in config -> unpin it first so the auto-hide check is meaningful'
        $pinBtn = Find-Ctl $drawer 'PinPanel'
        if ($pinBtn) { Click-El $pinBtn; Start-Sleep -Milliseconds 800 }
    }

    $rect0 = Get-DrawerRectNow
    $stBefore = $null
    $bmpBefore = $null
    $capX = 0; $capY = 0
    if ($rect0) {
        # Capture the whole content column below the tab strip. The web view only
        # exists after the switch, so the "before" shot must already cover the
        # area it will occupy; the comparison below crops to the view rectangle.
        $capX = [int]$rect0[0] + 6
        $capY = [int]$rect0[1] + 120
        $regBefore = [pscustomobject]@{ X = $capX; Y = $capY; Width = [int]($rect0[2] - $rect0[0]) - 12; Height = [int]($rect0[3] - $rect0[1]) - 130 }
        try { $stBefore = Get-RegionStats $regBefore } catch { }
        try { $bmpBefore = Get-RegionBitmap $regBefore } catch { }
        if ($stBefore) { Say ("content pixels before assistant = R={0} G={1} B={2}" -f $stBefore.R, $stBefore.G, $stBefore.B) }
    }

    $tab = Find-Ctl $drawer 'TabAssistant'
    if (-not $tab) { Say 'FAIL: assistant tab not found'; Flush; exit 1 }
    Say ("assistant tab rect = {0}" -f $tab.Current.BoundingRectangle)
    Click-El $tab
    [U4]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 900

    Check 'page shown log' (Wait-Diag 'page shown (provider=' 20000)
    Check 'navigated to deepseek' (Wait-Diag 'navigate https://chat.deepseek.com/' 40000)

    Start-Sleep -Milliseconds 3000

    $view = Find-CtlByIdPrefix $drawer 'AssistantView'
    $vr = $null
    if ($view) {
        $vr = $view.Current.BoundingRectangle
        Say ("assistant view rect = {0}" -f $vr)
        Check 'assistant view visible' (($vr.Width -gt 100) -and ($vr.Height -gt 100))
    } else {
        Say 'assistant view element not found'
        Check 'assistant view visible' $false
    }

    if ($vr) {
        Say ("view rect x={0} y={1} w={2} h={3}" -f [int]$vr.X, [int]$vr.Y, [int]$vr.Width, [int]$vr.Height)
        $inkStats = $null
        try { $inkStats = Get-InkStats $vr } catch { Say ('ink stats failed: ' + $_.Exception.Message) }
        if ($inkStats) {
            Say ("view ink = {0}% dark = {1}% minLuma = {2}" -f $inkStats.Ink, $inkStats.Dark, $inkStats.MinLuma)
            Check 'web page has text/pixels (ink > 0.5%)' ($inkStats.Ink -gt 0.5)
        }
        $stats = $null
        try { $stats = Get-RegionStats $vr } catch { Say ('pixel stats failed: ' + $_.Exception.Message) }
        if ($stats) {
            Say ("view pixels R={0} G={1} B={2} W={3} H={4}" -f $stats.R, $stats.G, $stats.B, $stats.W, $stats.H)
            $spread = [math]::Abs([double]$stats.R - [double]$stats.B)
            Say ("color spread = {0}" -f $spread)
            # spread is a bad metric for a mostly-white login page; ink ratio covers this
            if ($bmpBefore) {
                # Crop the "before" shot to exactly the rectangle the web view now
                # occupies, so the two bitmaps cover the same screen area.
                $bmpNow = $null
                $bmpCrop = $null
                try { $bmpNow = Get-RegionBitmap $vr } catch { }
                $nowW = if ($bmpNow) { $bmpNow.Width } else { 0 }
                $nowH = if ($bmpNow) { $bmpNow.Height } else { 0 }
                $cropW = [int]$vr.Width
                $cropH = [int]$vr.Height
                $ox = [int]$vr.X - $capX
                $oy = [int]$vr.Y - $capY
                # The "before" shot stops 10px short of the drawer bottom, and
                # the web view grew one pixel past it, so an exact-fit test
                # failed on a 1px sliver. Clamp to the bitmap instead of
                # discarding a perfectly usable comparison.
                if ($bmpNow -and $ox -ge 0 -and $oy -ge 0 -and
                    $ox -lt $bmpBefore.Width -and $oy -lt $bmpBefore.Height) {
                    if (($ox + $cropW) -gt $bmpBefore.Width) { $cropW = $bmpBefore.Width - $ox }
                    if (($oy + $cropH) -gt $bmpBefore.Height) { $cropH = $bmpBefore.Height - $oy }
                    if ($cropW -gt $nowW) { $cropW = $nowW }
                    if ($cropH -gt $nowH) { $cropH = $nowH }
                }
                if ($bmpNow -and $ox -ge 0 -and $oy -ge 0 -and
                    $cropW -gt 0 -and $cropH -gt 0 -and
                    ($ox + $cropW) -le $bmpBefore.Width -and ($oy + $cropH) -le $bmpBefore.Height) {
                    $cropRect = New-Object System.Drawing.Rectangle($ox, $oy, $cropW, $cropH)
                    $bmpCrop = $bmpBefore.Clone($cropRect, $bmpBefore.PixelFormat)
                }
                if ($bmpNow -and $bmpCrop) {
                    $ratio = Get-DiffRatio $bmpCrop $bmpNow
                    Say ("changed-pixel ratio inside view rect = {0}% (crop {1}x{2} at +{3}+{4})" -f $ratio, $cropW, $cropH, $ox, $oy)
                    Check 'web view painted over the panel content (changed > 8%)' ($ratio -gt 8)
                } else {
                    Say ("view rect outside captured region (view={0},{1},{2},{3} cap={4},{5})" -f $vr.X, $vr.Y, $vr.Width, $vr.Height, $capX, $capY)
                    Check 'web view painted over the panel content (changed > 8%)' $false
                }
                if ($bmpCrop) { $bmpCrop.Dispose() }
                if ($bmpNow) { $bmpNow.Dispose() }
                $bmpBefore.Dispose()
                $bmpBefore = $null
            } elseif ($stBefore) {
                $paintDelta = ([math]::Abs([double]$stats.R - [double]$stBefore.R) + [math]::Abs([double]$stats.G - [double]$stBefore.G) + [math]::Abs([double]$stats.B - [double]$stBefore.B)) / 3.0
                Say ("paint delta vs notes page = {0}" -f [math]::Round($paintDelta, 1))
                Check 'web view painted over the panel content' ($paintDelta -gt 3)
            }
        } else {
            Say 'pixel stats unavailable'
            Check 'page paints content' $false
        }
    }

    $rect = Get-DrawerRectNow
    Say ("drawer rect after open = {0}" -f ($rect -join ','))
    Check 'width still dock width' ([math]::Abs(($rect[2] - $rect[0]) - $dockWidth) -le 2)

    $vx = [int]($vr.X + $vr.Width / 2)
    $vy = [int]($vr.Y + $vr.Height / 2)
    Say ("clicking page surface at {0},{1}" -f $vx, $vy)
    Click-Point $vx $vy
    Start-Sleep -Milliseconds 1200
    $focused = Get-FocusedInfo
    Say ("focused after click in page = {0}" -f $focused)
    $focusedPid = 0
    try { $focusedPid = [System.Windows.Automation.AutomationElement]::FocusedElement.Current.ProcessId } catch { }
    Say ("focused pid = {0} app pid = {1}" -f $focusedPid, $app.Id)
    $focusInPage = ($focusedPid -ne $app.Id) -or ($focused -match 'ControlType\.(Document|Edit|Pane|Group)')
    Check 'keyboard focus is inside the page' $focusInPage

    [U4]::MoveTo(120, 900)
    Start-Sleep -Milliseconds 3200
    $rect = Get-DrawerRectNow
    Say ("drawer rect after cursor outside = {0}" -f ($rect -join ','))
    Check 'still open on assistant page' ($rect[0] -lt 1900)

    [U4]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 400
    $widenBtn = Find-Ctl $drawer 'AssistantWiden'
    if (-not $widenBtn) { Say 'FAIL: widen button not found'; Flush; exit 1 }
    Click-El $widenBtn
    Start-Sleep -Milliseconds 1400
    $rect2 = Get-DrawerRectNow
    $wideW = $rect2[2] - $rect2[0]
    Say ("drawer rect after widen = {0}" -f ($rect2 -join ','))
    Check 'panel widened (> dock + 100)' ($wideW -gt ($dockWidth + 100))
    Check 'widen logged' (Wait-Diag 'panel width -> ' 4000)

    # 2026-10-31: widening must also scale the web zoom, otherwise the page
    # only gets longer while the font stays the same size (user feedback).
    # The app logs "zoom <id> = <effective> (base <b> x scale <s>)".
    $zoomLines = @(Select-String -LiteralPath $diagPath -Pattern 'zoom ' -SimpleMatch -ErrorAction SilentlyContinue)
    $lastZoom = if ($zoomLines.Count -gt 0) { $zoomLines[-1].Line } else { '' }
    Say ("last zoom log line = {0}" -f $lastZoom)
    $zoomScaled = $lastZoom -match '\(base\s+([0-9.]+)\s+x\s+scale\s+([0-9.]+)\)'
    if ($zoomScaled) {
        $baseZ = [double]$Matches[1]
        $scaleZ = [double]$Matches[2]
        Say ("zoom base = {0} scale = {1}" -f $baseZ, $scaleZ)
        Check 'zoom scale factor > 1 when widened' ($scaleZ -gt 1.01)
    } else {
        Say 'no zoom scale info in diag log'
        Check 'zoom scale factor > 1 when widened' $false
    }

    $cfg2 = Read-Config
    if ($cfg2.assistant) {
        Say ("config assistant after widen = {0}" -f ($cfg2.assistant | ConvertTo-Json -Compress))
        Check 'widen persisted in config' ($cfg2.assistant.widen -eq $true)
    } else {
        Say 'config has no assistant section after the widen click'
        Check 'widen persisted in config' $false
    }

    Click-El $widenBtn
    Start-Sleep -Milliseconds 1400
    $rect2b = Get-DrawerRectNow
    Say ("drawer rect after un-widen = {0}" -f ($rect2b -join ','))
    Check 'width back to dock width' ([math]::Abs(($rect2b[2] - $rect2b[0]) - $dockWidth) -le 4)

    # Un-widen must bring the zoom back to the per-site base value.
    $zoomLines2 = @(Select-String -LiteralPath $diagPath -Pattern 'zoom ' -SimpleMatch -ErrorAction SilentlyContinue)
    $lastZoom2 = if ($zoomLines2.Count -gt 0) { $zoomLines2[-1].Line } else { '' }
    Say ("last zoom log line after un-widen = {0}" -f $lastZoom2)
    $zoomBack = $lastZoom2 -match '\(base\s+([0-9.]+)\s+x\s+scale\s+([0-9.]+)\)'
    if ($zoomBack) {
        $scaleZ2 = [double]$Matches[2]
        Say ("zoom scale after un-widen = {0}" -f $scaleZ2)
        Check 'zoom scale back to ~1 after un-widen' ([math]::Abs($scaleZ2 - 1.0) -le 0.01)
    } else {
        Say 'no zoom scale info after un-widen'
        Check 'zoom scale back to ~1 after un-widen' $false
    }

    # 2026-10-31: Qwen chip must sit directly to the right of DeepSeek.
    $qwenChip = Find-Ctl $drawer 'ChipQwen'
    if ($qwenChip) {
        $dsChip = Find-Ctl $drawer 'ChipDeepSeek'
        $kmChip = Find-Ctl $drawer 'ChipKimi'
        if ($dsChip -and $kmChip) {
            $xds = [int]$dsChip.Current.BoundingRectangle.X
            $xq = [int]$qwenChip.Current.BoundingRectangle.X
            $xk = [int]$kmChip.Current.BoundingRectangle.X
            Say ("chip x: deepseek={0} qwen={1} kimi={2}" -f $xds, $xq, $xk)
            Check 'qwen chip is between deepseek and kimi' (($xq -gt $xds) -and ($xq -lt $xk))
        }
        Say ("qwen pre-switch = {0}" -f (Ensure-ProviderSwitchable $drawer 'qwen'))
        $qwenChip = Find-Ctl $drawer 'ChipQwen'
        $markQ = Get-DiagLineCount
        Click-El $qwenChip
        Start-Sleep -Milliseconds 1500
        [U4]::MoveTo(1780, 400)
        Check 'qwen selected log' (Wait-Diag 'provider selected qwen' 8000 $markQ)
        $cfgQ = Read-Config
        if ($cfgQ.assistant) {
            Check 'qwen persisted in config' ($cfgQ.assistant.activeProviderId -eq 'qwen')
        } else {
            Check 'qwen persisted in config' $false
        }
        # A warm (resident) site switch re-uses the existing WebView2 and does not
        # navigate again, so "providers qwen -> url" / "navigate ..." lines only
        # appear on a cold first load. Assert what is deterministic on every
        # switch: the qwen view exists and is actually on screen.
        $qView = Find-CtlByIdPrefix $drawer 'AssistantView:qwen'
        if ($qView) {
            Say ("qwen view rect = {0} offscreen = {1}" -f $qView.Current.BoundingRectangle, $qView.Current.IsOffscreen)
            Check 'qwen view visible' (-not $qView.Current.IsOffscreen)
        } else {
            Say 'qwen view element not found'
            Check 'qwen view visible' $false
        }

        # qwen base zoom is 1.00, i.e. the WebView2 default, so ApplyZoom writes no
        # line until the value actually changes. Widening forces it to change and
        # proves both the base value and the width coupling.
        $qWiden = Find-Ctl $drawer 'AssistantWiden'
        if ($qWiden) {
            $markW = Get-DiagLineCount
            Click-El $qWiden
            Start-Sleep -Milliseconds 1500
            [U4]::MoveTo(1780, 400)
            Check 'qwen zoom scales with width' (Wait-Diag 'zoom qwen = ' 6000 $markW)
            $markU = Get-DiagLineCount
            Click-El $qWiden
            Start-Sleep -Milliseconds 1500
            [U4]::MoveTo(1780, 400)
            Check 'qwen zoom back to base 1.00' (Wait-Diag 'zoom qwen = 1.00 (base 1.00 x scale 1.00)' 6000 $markU)
        } else {
            Say 'qwen widen button not found'
            Check 'qwen zoom scales with width' $false
        }
    } else {
        Say 'FAIL: qwen chip not found'
        $script:fail++
    }

    $kimiChip = Find-Ctl $drawer 'ChipKimi'
    if ($kimiChip) {
        Say ("kimi pre-switch = {0}" -f (Ensure-ProviderSwitchable $drawer 'kimi'))
        $kimiChip = Find-Ctl $drawer 'ChipKimi'
        # A resident site keeps its WebView2, so a switch back does not navigate
        # again and writes no cold-load lines.
        $kimiWarm = [bool](Find-CtlByIdPrefix $drawer 'AssistantView:kimi')
        $markK = Get-DiagLineCount
        Click-El $kimiChip
        Start-Sleep -Milliseconds 1500
        [U4]::MoveTo(1780, 400)
        Check 'kimi selected log' (Wait-Diag 'provider selected kimi' 8000 $markK)
        if ($kimiWarm) {
            Say 'kimi site already resident (cold-load lines not expected)'
            $kv = Find-CtlByIdPrefix $drawer 'AssistantView:kimi'
            Check 'kimi view visible' ([bool]($kv -and (-not $kv.Current.IsOffscreen)))
        } else {
            Check 'kimi zoom log (0.90)' (Wait-Diag 'www.kimi.com/ (zoom 0.90)' 20000 $markK)
            Check 'kimi navigated' (Wait-Diag 'navigate https://www.kimi.com/' 40000 $markK)
        }

        $cfg3 = Read-Config
        if ($cfg3.assistant) {
            Check 'provider persisted in config' ($cfg3.assistant.activeProviderId -eq 'kimi')
        } else {
            Check 'provider persisted in config' $false
        }
        $kimiView = Find-CtlByIdPrefix $drawer 'AssistantView'
        if ($kimiView) { Say ("kimi view rect = {0}" -f $kimiView.Current.BoundingRectangle) }
    } else {
        Say 'FAIL: kimi chip not found'
        $script:fail++
    }

    $notesTab = Find-Ctl $drawer 'TabNotes'
    if (-not $notesTab) { Say 'FAIL: notes tab not found'; Flush; exit 1 }
    Click-El $notesTab
    Start-Sleep -Milliseconds 1000
    Check 'page hidden log' (Wait-Diag 'page hidden' 4000)

    # 2026-10-29 user feedback: after leaving the assistant page the web view
    # stayed on top of the notes/clipboard pages (WebView2 is a child HWND).
    if ($vr) {
        $statsAfter = $null
        try { $statsAfter = Get-RegionStats $vr } catch { Say ('pixel stats after switch failed: ' + $_.Exception.Message) }
        if ($stats -and $statsAfter) {
            $delta = ([math]::Abs([double]$stats.R - [double]$statsAfter.R) + [math]::Abs([double]$stats.G - [double]$statsAfter.G) + [math]::Abs([double]$stats.B - [double]$statsAfter.B)) / 3.0
            Say ("region pixels after switch R={0} G={1} B={2} meanDelta={3}" -f $statsAfter.R, $statsAfter.G, $statsAfter.B, [math]::Round($delta, 1))
            Check 'assistant page no longer covers content (delta > 5)' ($delta -gt 5)
        } else {
            Check 'assistant page no longer covers content (delta > 5)' $false
        }
    }

    $avAfter = Find-CtlByIdPrefix $drawer 'AssistantView'
    if ($avAfter) {
        $off = $avAfter.Current.IsOffscreen
        Say ("assistant view offscreen after switch = {0}" -f $off)
        Check 'assistant view collapsed after switch' $off
    } else {
        Say 'assistant view element not found after switch (treated as collapsed)'
        Check 'assistant view collapsed after switch' $true
    }

    $cbTab = Find-Ctl $drawer 'TabClipboard'
    if ($cbTab) {
        Click-El $cbTab
        Start-Sleep -Milliseconds 900
        $cbList = Find-Ctl $drawer 'ClipboardList'
        if ($cbList) {
            $cr = $cbList.Current.BoundingRectangle
            Say ("clipboard list rect after switch = {0}" -f $cr)
            Check 'clipboard page visible after switch' (($cr.Width -gt 50) -and (-not $cbList.Current.IsOffscreen))
        } else {
            Say 'clipboard list not found after switch'
            Check 'clipboard page visible after switch' $false
        }
        $backTab = Find-Ctl $drawer 'TabNotes'
        if ($backTab) { Click-El $backTab; Start-Sleep -Milliseconds 600 }
    }

    [U4]::MoveTo(120, 900)
    Start-Sleep -Milliseconds 3600
    $rect4 = Get-DrawerRectNow
    if ($null -eq $rect4) {
        Say 'drawer window is hidden (collapsed) - auto-hide ran'
        Check 'auto-hide re-armed after leaving' $true
    } else {
        Say ("drawer rect after leaving notes page = {0}" -f ($rect4 -join ','))
        Check 'auto-hide re-armed after leaving' ($rect4[0] -ge 1900)
    }

    $verdict = if ($script:fail -eq 0) { 'PASS' } else { ('FAIL (' + $script:fail + ')') }
    Say ("RESULT: " + $verdict)
}
catch {
    Say ("EXCEPTION: " + $_.Exception.Message)
    Say 'RESULT: FAIL (exception)'
}
finally {
    Flush
    try { Stop-App } catch { }
    try { Start-Sleep -Milliseconds 500; Restore-State } catch { }
    try { Start-App } catch { }
}
