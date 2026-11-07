param(
    [ValidateSet('pinpanel', 'cards')] [string]$Mode = 'pinpanel',
    [string]$Exe = ''
)

# End-to-end verification for the 2026-10-25 requests:
#   pinpanel: the top-bar pin button keeps the drawer open when the cursor leaves.
#   cards:    the note card title box, the pin button turned into a lock, and the
#             guarantee that a locked card survives both single delete and clear-all.
# config.json / notes.json are backed up before the run and restored afterwards.
# ASCII only; all paths derive from $PSScriptRoot.

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
$resultPath = Join-Path $PSScriptRoot ('panel-lock-result-' + $Mode + '.txt')

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

# ---------------------------------------------------------------- pin panel

function Run-PinPanel {
    Stop-App
    Backup-State

    $app = Start-App
    Say ("app pid={0}" -f $app.Id)

    if (-not (Ensure-DrawerOpen)) { Say 'FAIL: drawer did not open'; return $false }
    [U4]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 600

    $win = Get-DrawerWindow
    $btn = Find-Ctl $win 'PinPanel'
    if ($null -eq $btn) { Say 'FAIL: PinPanel button not found'; return $false }
    $nameBefore = $btn.Current.Name
    $pxBefore = Get-RegionStats $btn.Current.BoundingRectangle
    $cfgBefore = Read-Config
    $pinBefore = if ($cfgBefore -and $cfgBefore.dock) { [bool]$cfgBefore.dock.pinPanel } else { $false }
    Say ("pin button name=[{0}] rect={1}x{2}" -f $nameBefore, [int]$btn.Current.BoundingRectangle.Width, [int]$btn.Current.BoundingRectangle.Height)
    Say ("pixels before=({0},{1},{2})" -f $pxBefore.R, $pxBefore.G, $pxBefore.B)
    Say ("config dock.pinPanel before={0}" -f $pinBefore)

    Click-El $btn 0.5
    Say 'clicked pin panel button'
    Start-Sleep -Milliseconds 1200

    $win = Get-DrawerWindow
    $btn2 = Find-Ctl $win 'PinPanel'
    $pxAfter = Get-RegionStats $btn2.Current.BoundingRectangle
    $pxDelta = 0.0
    if ($null -ne $pxAfter) {
        $pxDelta = [math]::Abs($pxAfter.R - $pxBefore.R) + [math]::Abs($pxAfter.G - $pxBefore.G) + [math]::Abs($pxAfter.B - $pxBefore.B)
    }
    Say ("pixels after=({0},{1},{2}) meanDelta={3}" -f $pxAfter.R, $pxAfter.G, $pxAfter.B, [math]::Round($pxDelta, 1))

    $cfgPinned = Read-Config
    $pinAfter = if ($cfgPinned -and $cfgPinned.dock) { [bool]$cfgPinned.dock.pinPanel } else { $false }
    Say ("config dock.pinPanel after pin={0}" -f $pinAfter)

    # cursor far outside the drawer; without the pin this collapses after ~500ms
    [U4]::MoveTo(120, 900)
    Start-Sleep -Milliseconds 3200
    $rectPinned = Get-DrawerRect
    $openWhilePinned = ($null -ne $rectPinned) -and ($rectPinned[0] -lt 1900)
    Say ("rect after 3.2s outside while pinned={0} stillOpen={1}" -f `
        $(if ($rectPinned) { ($rectPinned -join ',') } else { 'none' }), $openWhilePinned)

    $tail = Read-DiagTail 20
    $joined = ($tail -join "`n")
    $loggedPinned = $joined -match 'pinned: auto-hide disabled'

    # unpin and confirm the auto-hide really comes back
    [U4]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 400
    $win = Get-DrawerWindow
    $btn3 = Find-Ctl $win 'PinPanel'
    if ($null -eq $btn3) { Say 'FAIL: PinPanel button lost after pinning'; return $false }
    Click-El $btn3 0.5
    Say 'clicked pin panel button again (unpin)'
    Start-Sleep -Milliseconds 900

    $cfgUnpinned = Read-Config
    $pinOff = if ($cfgUnpinned -and $cfgUnpinned.dock) { [bool]$cfgUnpinned.dock.pinPanel } else { $true }
    Say ("config dock.pinPanel after unpin={0}" -f $pinOff)

    [U4]::MoveTo(120, 900)
    Start-Sleep -Milliseconds 3200
    $rectUnpinned = Get-DrawerRect
    $collapsed = ($null -eq $rectUnpinned) -or ($rectUnpinned[0] -ge 1900)
    Say ("rect after 3.2s outside when unpinned={0} collapsed={1}" -f `
        $(if ($rectUnpinned) { ($rectUnpinned -join ',') } else { 'none' }), $collapsed)

    $tail2 = Read-DiagTail 20
    $joined2 = ($tail2 -join "`n")
    $loggedUnpinned = $joined2 -match 'unpinned: auto-hide re-armed'
    foreach ($l in $tail2) { Say ("diag| " + $l) }

    $styleOk = ($null -ne $pxAfter) -and ($pxDelta -ge 3.0)
    Say ("style changed (pixel mean delta >= 3): {0}" -f $styleOk)
    Say ("config persisted pinPanel=true: {0}" -f $pinAfter)
    Say ("stayed open while pinned: {0}" -f $openWhilePinned)
    Say ("diag logged pin: {0}" -f $loggedPinned)
    Say ("config pinPanel back to false: {0}" -f (-not $pinOff))
    Say ("auto-hide resumed after unpin: {0}" -f $collapsed)
    Say ("diag logged unpin: {0}" -f $loggedUnpinned)

    $ok = $styleOk -and $pinAfter -and $openWhilePinned -and $loggedPinned -and (-not $pinOff) -and $collapsed
    Say ($(if ($ok) { 'RESULT: PASS (pinpanel)' } else { 'RESULT: FAIL (pinpanel)' }))
    return $ok
}

# ---------------------------------------------------------------- note cards

function Run-Cards {
    $lockGlyph = ([string][char]0xD83D + [char]0xDD12)
    $pinGlyph = ([string][char]0xD83D + [char]0xDCCC)
    $token = 'qd-title-' + (Get-Date -Format 'HHmmss')

    Stop-App
    Backup-State

    $app = Start-App
    Say ("app pid={0}" -f $app.Id)

    if (-not (Ensure-DrawerOpen)) { Say 'FAIL: drawer did not open'; return $false }
    [U4]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 500
    if (-not (Click-Tab 'TabNotes')) { Say 'FAIL: could not switch to the notes tab'; return $false }

    $notesBefore = Read-Notes
    $countBefore = if ($notesBefore) { $notesBefore.notes.Count } else { 0 }
    Say ("notes on disk before={0}" -f $countBefore)

    $win = Get-DrawerWindow
    $add = Find-Ctl $win 'AddNoteButton'
    if ($null -eq $add) { Say 'FAIL: AddNoteButton not found'; return $false }
    Click-El $add 0.5
    Say 'clicked add note'
    Start-Sleep -Milliseconds 1000

    $win = Get-DrawerWindow
    $list = Find-ById $win 'NotesList'
    if ($null -eq $list) { Say 'FAIL: NotesList not found'; return $false }
    $items = Find-All-Of $list $CTL::ListItem
    Say ("card items={0}" -f $items.Count)
    if ($items.Count -lt 1) { Say 'FAIL: no card rendered'; return $false }
    $card = $items[0]

    $titleBox = Find-Ctl $card 'CardTitle'
    if ($null -eq $titleBox) { Say 'FAIL: CardTitle box not found'; return $false }
    $tr = $titleBox.Current.BoundingRectangle
    Say ("title box rect={0},{1} {2}x{3}" -f [int]$tr.X, [int]$tr.Y, [int]$tr.Width, [int]$tr.Height)

    Click-El $titleBox 0.5
    Start-Sleep -Milliseconds 900
    [U4]::TypeAscii($token)
    Say ("typed title {0}" -f $token)
    Start-Sleep -Milliseconds 500

    # blur the box so NoteText_LostFocus persists the card
    if (-not (Click-Tab 'TabNotes')) { Say 'warn: could not click the tab to blur' }
    Start-Sleep -Milliseconds 700

    $notes = Read-Notes
    $titles = @()
    if ($notes) { $titles = @($notes.notes | ForEach-Object { $_.Title }) }
    Say ("titles on disk right after typing=[{0}]" -f ($titles -join '|'))

    $win = Get-DrawerWindow
    $list = Find-ById $win 'NotesList'
    $items = Find-All-Of $list $CTL::ListItem
    $card = $items[0]
    $pinBtn = Find-Ctl $card 'PinCard'
    if ($null -eq $pinBtn) { Say 'FAIL: PinCard button not found'; return $false }
    $nameBefore = $pinBtn.Current.Name
    $glyphBefore = Get-CardGlyph $card
    $pxBefore = Get-RegionStats $pinBtn.Current.BoundingRectangle
    Say ("card pin name before=[{0}] isPushpin={1}" -f $nameBefore, $nameBefore.StartsWith($pinGlyph))

    Click-El $pinBtn 0.5
    Say 'clicked card lock button'
    Start-Sleep -Milliseconds 1200

    $win = Get-DrawerWindow
    $list2 = Find-ById $win 'NotesList'
    $items2 = Find-All-Of $list2 $CTL::ListItem
    $card2 = $items2[0]
    $pinBtn2 = Find-Ctl $card2 'PinCard'
    $nameAfter = $pinBtn2.Current.Name
    $glyphAfter = Get-CardGlyph $card2
    $pxAfter = Get-RegionStats $pinBtn2.Current.BoundingRectangle
    $pxDelta = 0.0
    if ($null -ne $pxAfter) {
        $pxDelta = [math]::Abs($pxAfter.R - $pxBefore.R) + [math]::Abs($pxAfter.G - $pxBefore.G) + [math]::Abs($pxAfter.B - $pxBefore.B)
    }
    Say ("card pin name after=[{0}] isLock={1} meanDelta={2}" -f $nameAfter, $nameAfter.StartsWith($lockGlyph), [math]::Round($pxDelta, 1))

    $notesLocked = Read-Notes
    $pinnedCount = if ($notesLocked) { @($notesLocked.notes | Where-Object { $_.Pinned }).Count } else { 0 }
    $lockedTitle = ''
    if ($notesLocked) {
        $lp = $notesLocked.notes | Where-Object { $_.Pinned } | Select-Object -First 1
        if ($lp) { $lockedTitle = $lp.Title }
    }
    Say ("after lock: pinned={0} lockedTitle=[{1}]" -f $pinnedCount, $lockedTitle)
    $actualTitle = $lockedTitle
    $titleOk = ($actualTitle -match '^qd-title-\d{4,6}$')
    Say ("title persisted: {0}" -f $titleOk)

    # single delete must refuse
    $delBtn = Find-Ctl $card2 'DeleteCard'
    if ($null -eq $delBtn) { Say 'FAIL: DeleteCard button not found'; return $false }
    Click-El $delBtn 0.5
    Say 'clicked delete on the locked card'
    Start-Sleep -Milliseconds 1200

    $dlg = [U4]::FindDialog($app.Id)
    $dialogShown = ($dlg -ne [IntPtr]::Zero)
    Say ("refusal dialog hwnd=0x{0:X} class={1}" -f [int64]$dlg, $(if ($dialogShown) { [U4]::ClassOf($dlg) } else { '' }))
    if ($dialogShown) { [void][U4]::SetForegroundWindow($dlg); Start-Sleep -Milliseconds 400 }
    Press-Enter

    $notesAfterDel = Read-Notes
    $countAfterDel = if ($notesAfterDel) { $notesAfterDel.notes.Count } else { 0 }
    $stillThere = ($notesAfterDel -ne $null) -and (@($notesAfterDel.notes | Where-Object { $_.Title -eq $actualTitle }).Count -eq 1)
    Say ("after delete attempt: notes={0} lockedCardStillThere={1}" -f $countAfterDel, $stillThere)

    # clear-all must keep the locked card
    $win = Get-DrawerWindow
    $clear = Find-ById $win 'ClearButton'
    if ($null -eq $clear) { Say 'FAIL: ClearButton not found'; return $false }
    Click-El $clear 0.5
    Say 'clicked ClearButton'
    Start-Sleep -Milliseconds 1200

    $dlg2 = [U4]::FindDialog($app.Id)
    Say ("clear confirm dialog hwnd=0x{0:X}" -f [int64]$dlg2)
    if ($dlg2 -ne [IntPtr]::Zero) { [void][U4]::SetForegroundWindow($dlg2); Start-Sleep -Milliseconds 400 }
    Press-Enter

    $notesAfterClear = Read-Notes
    $countAfterClear = if ($notesAfterClear) { $notesAfterClear.notes.Count } else { 0 }
    $pinnedAfterClear = if ($notesAfterClear) { @($notesAfterClear.notes | Where-Object { $_.Pinned }).Count } else { 0 }
    $titleSurvived = ($notesAfterClear -ne $null) -and (@($notesAfterClear.notes | Where-Object { $_.Title -eq $actualTitle }).Count -eq 1)
    Say ("after clear: notes={0} pinned={1} lockedTitleSurvived={2}" -f $countAfterClear, $pinnedAfterClear, $titleSurvived)

    $win = Get-DrawerWindow
    $list3 = Find-ById $win 'NotesList'
    $items3 = Find-All-Of $list3 $CTL::ListItem
    Say ("card items after clear={0}" -f $items3.Count)

    $tail = Read-DiagTail 25
    foreach ($l in $tail) { Say ("diag| " + $l) }
    $joined = ($tail -join "`n")
    $loggedKept = $joined -match 'cards cleared by user \(kept 1 locked\)'

    $glyphOk = ($glyphBefore -eq 'pin') -and ($glyphAfter -eq 'lock')
    Say ("glyph before=[{0}] after=[{1}]" -f $glyphBefore, $glyphAfter)
    $styleOk = ($null -ne $pxAfter) -and ($pxDelta -ge 3.0)
    $pinnedOk = ($pinnedCount -ge 1) -and ($lockedTitle -eq $actualTitle)
    $deleteOk = $dialogShown -and $stillThere -and ($countAfterDel -eq $countBefore + 1)
    $clearOk = ($countAfterClear -eq 1) -and ($pinnedAfterClear -eq 1) -and $titleSurvived

    Say ("title persisted: {0}" -f $titleOk)
    Say ("glyph flipped: {0}" -f $glyphOk)
    Say ("style changed (pixel mean delta >= 3): {0}" -f $styleOk)
    Say ("lock persisted with title: {0}" -f $pinnedOk)
    Say ("locked card refused delete: {0}" -f $deleteOk)
    Say ("clear kept the locked card: {0}" -f $clearOk)
    Say ("diag logged kept-locked: {0}" -f $loggedKept)

    $ok = $titleOk -and $glyphOk -and $styleOk -and $pinnedOk -and $deleteOk -and $clearOk
    Say ($(if ($ok) { 'RESULT: PASS (cards)' } else { 'RESULT: FAIL (cards)' }))
    return $ok
}

# ---------------------------------------------------------------- main

Say ("mode={0} exe={1}" -f $Mode, $Exe)
Say ("time={0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
try {
    if ($Mode -eq 'pinpanel') { [void](Run-PinPanel) } else { [void](Run-Cards) }
}
catch {
    Say ("EXCEPTION: " + $_.Exception.Message)
    Say ($_.ScriptStackTrace)
}
finally {
    try { Restore-State } catch { Say ("restore failed: " + $_.Exception.Message) }
    try { $app = Start-App; Say ("restarted app pid={0}" -f $app.Id) } catch { Say ("restart failed: " + $_.Exception.Message) }
    Flush
    Say ("written: " + $resultPath)
}
