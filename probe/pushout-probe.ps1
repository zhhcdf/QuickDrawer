param(
    [ValidateSet('notes', 'pushout')] [string]$Mode = 'notes',
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
$resultPath = Join-Path $PSScriptRoot ('pushout-result-' + $Mode + '.txt')

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
        if ($r.Width -ge 280 -and $r.Width -le 620 -and $r.Height -gt 400) { return $w }
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


# ---------------------------------------------------------------- U6: window geometry

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class U6 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    public static int[] Rect(IntPtr hWnd) {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) { return null; }
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }
}
"@

$SW_MAXIMIZE = 3
$SWP_NOZORDER = 0x0004
$SWP_NOACTIVATE = 0x0010

# ---------------------------------------------------------------- pixel helpers

function Get-InkRows([double]$x, [double]$y, [int]$w, [int]$h, [int]$threshold = 170) {
    if ($w -le 0 -or $h -le 0) { return @() }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen([int]$x, [int]$y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $rows = New-Object int[] $h
    for ($yy = 0; $yy -lt $h; $yy++) {
        $n = 0
        for ($xx = 0; $xx -lt $w; $xx++) {
            $c = $bmp.GetPixel($xx, $yy)
            if ((($c.R + $c.G + $c.B) / 3) -lt $threshold) { $n++ }
        }
        $rows[$yy] = $n
    }
    $g.Dispose(); $bmp.Dispose()
    return $rows
}

function Get-InkBands([double]$x, [double]$y, [int]$w, [int]$h, [int]$minInk = 2) {
    $rows = Get-InkRows $x $y $w $h
    $bands = New-Object System.Collections.Generic.List[object]
    $start = -1
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $has = $rows[$i] -ge $minInk
        if ($has -and $start -lt 0) { $start = $i }
        elseif (-not $has -and $start -ge 0) {
            $sum = 0
            for ($k = $start; $k -lt $i; $k++) { $sum += $rows[$k] }
            $bands.Add([pscustomobject]@{ Start = $start; End = $i - 1; Center = ($start + $i - 1) / 2.0; Ink = $sum })
            $start = -1
        }
    }
    if ($start -ge 0) {
        $sum = 0
        for ($k = $start; $k -lt $rows.Count; $k++) { $sum += $rows[$k] }
        $bands.Add([pscustomobject]@{ Start = $start; End = $rows.Count - 1; Center = ($start + $rows.Count - 1) / 2.0; Ink = $sum })
    }
    return $bands
}

function Get-InkCount([double]$x, [double]$y, [int]$w, [int]$h, [int]$threshold = 170) {
    $rows = Get-InkRows $x $y $w $h $threshold
    $sum = 0
    foreach ($r in $rows) { $sum += $r }
    return $sum
}

function Say-EditStates($root, [string]$stage) {
    $edits = Find-All-Of $root $CTL::Edit
    $acc = @()
    foreach ($e in $edits) {
        $val = 'n/a'
        try {
            $vp = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $val = [string]$vp.Current.Value
        } catch { $val = 'n/a' }
        $acc += ("{0}='{1}'" -f $e.Current.AutomationId, ($val -replace "`r?`n", '
'))
    }
    Say ("edits {0}: {1}" -f $stage, ($acc -join ' ; '))
}

function Find-BodyText($card) {
    $texts = Find-All-Of $card $CTL::Text
    foreach ($t in $texts) {
        $name = [string]$t.Current.Name
        if ($name -like '*qdbold*') {
            $r = $t.Current.BoundingRectangle
            if ($r.Height -gt 24) { return $t }
        }
    }
    return $null
}

# ---------------------------------------------------------------- notes layout

function Run-Notes {
    Stop-App
    Backup-State
    $app = Start-App
    Say ("app pid={0}" -f $app.Id)
    if (-not (Ensure-DrawerOpen)) { Say 'FAIL: drawer did not open'; return }
    if (-not (Click-Tab 'TabNotes')) { Say 'FAIL: notes tab not found'; return }

    $win = Get-DrawerWindow
    if ($null -eq $win) { Say 'FAIL: drawer window not found'; return }
    $notesBefore = (Read-Notes).notes.Count
    Say ("notes on disk before={0}" -f $notesBefore)

    $add = Find-Ctl $win 'AddNoteButton'
    if ($null -eq $add) { Say 'FAIL: AddNoteButton not found'; return }
    Click-El $add
    Start-Sleep -Milliseconds 1000

    $list = Find-ById $win 'NotesList'
    if ($null -eq $list) { Say 'FAIL: NotesList not found'; return }
    $items = Find-All-Of $list $CTL::ListItem
    Say ("card items={0}" -f $items.Count)
    if ($items.Count -lt 1) { Say 'FAIL: no note card'; return }
    $card = $items[0]
    $cr = $card.Current.BoundingRectangle
    Say ("card rect={0},{1} {2}x{3}" -f [int]$cr.X, [int]$cr.Y, [int]$cr.Width, [int]$cr.Height)

    # a freshly added card already sits in body-edit mode (AddNote_Click focuses the editor),
    # so type the two body lines first and the title afterwards.
    Say-EditStates $card 'after add'
    Start-Sleep -Milliseconds 500
    # Enter injection through SendInput is unreliable (see docs), so build the
    # two-line body by pasting a prepared two-line clipboard payload instead.
    Set-Clipboard -Value ("qdbold`r`nqdbold")
    Start-Sleep -Milliseconds 250
    [U4]::KeyDown(0x11)
    [U4]::KeyTap(0x56)
    [U4]::KeyUp(0x11)
    Start-Sleep -Milliseconds 800
    Say-EditStates $card 'after body typing'

    $title = Find-Ctl $card 'CardTitle'
    if ($null -eq $title) { Say 'FAIL: CardTitle not found'; return }
    $tr = $title.Current.BoundingRectangle
    Say ("title box rect={0},{1} {2}x{3}" -f [int]$tr.X, [int]$tr.Y, [int]$tr.Width, [int]$tr.Height)
    Click-El $title
    Start-Sleep -Milliseconds 900
    [U4]::TypeAscii('qdbold')
    Start-Sleep -Milliseconds 500
    Say-EditStates $card 'after title typing'

    # blur (click the notes tab) so LostFocus writes notes.json
    $tab = Find-ById $win 'TabNotes'
    if ($null -ne $tab) { Click-El $tab; Start-Sleep -Milliseconds 1400 }

    $saved = Read-Notes
    $note = $saved.notes | Where-Object { $_.Title -eq 'qdbold' } | Select-Object -First 1
    if ($null -eq $note) {
        Say 'FAIL: title not persisted to notes.json'
        Say ("titles on disk=[{0}]" -f (($saved.notes | ForEach-Object { $_.Title }) -join '|'))
        return
    }
    $textFlat = ([string]$note.Text) -replace "`r", ''
    Say ("saved note: Title='{0}' Text='{1}'" -f $note.Title, ($textFlat -replace "`n", '\n'))
    $twoLines = ($textFlat -match "`n")
    Say ("assert body has two lines (pasted): {0}" -f $twoLines)

    # title weight from UIA TextPattern
    $fw = 'n/a'
    try {
        $pattern = $title.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        $fw = $pattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::FontWeightAttribute)
    } catch {
        $fw = 'err: ' + $_.Exception.Message
    }
    Say ("title font weight={0}" -f $fw)
    $isBold = ($fw -is [int] -and $fw -ge 700)
    Say ("assert title bold: {0}" -f $isBold)

    # line spacing from pixel ink bands inside the read-mode body TextBlock
    $body = Find-BodyText $card
    if ($null -eq $body) {
        $texts = Find-All-Of $card $CTL::Text
        foreach ($t in $texts) {
            Say ("  text el: name='{0}' rect={1},{2} {3}x{4}" -f ([string]$t.Current.Name -replace "`r?`n", '\n'), [int]$t.Current.BoundingRectangle.X, [int]$t.Current.BoundingRectangle.Y, [int]$t.Current.BoundingRectangle.Width, [int]$t.Current.BoundingRectangle.Height)
        }
        Say 'FAIL: body TextBlock not found'
        return
    }

    $br = $body.Current.BoundingRectangle
    Say ("body text rect={0},{1} {2}x{3}" -f [int]$br.X, [int]$br.Y, [int]$br.Width, [int]$br.Height)
    $bands = Get-InkBands $br.X $br.Y ([int]$br.Width) ([int]$br.Height)
    Say ("body ink bands={0}" -f $bands.Count)
    foreach ($b in $bands) { Say ("  band start={0} end={1} center={2:N1} ink={3}" -f $b.Start, $b.End, $b.Center, $b.Ink) }

    if ($bands.Count -ge 2) {
        $gap = $bands[1].Center - $bands[0].Center
        Say ("baseline gap={0:N1}px (LineHeight=20 -> expect ~20; old default ~16)" -f $gap)
        $spacingOk = ($gap -ge 17.5 -and $gap -le 22.5)
        Say ("assert line spacing ~20: {0}" -f $spacingOk)
    } else {
        Say 'FAIL: fewer than two ink bands'
    }

    # click-to-edit: clicking the read-mode body must switch it back into a TextBox
    $bcr = $body.Current.BoundingRectangle
    Click-Point ([int]($bcr.X + 30)) ([int]($bcr.Y + 10))
    Start-Sleep -Milliseconds 700
    [U4]::TypeAscii('x')
    Start-Sleep -Milliseconds 400
    $tab2 = Find-ById $win 'TabNotes'
    if ($null -ne $tab2) { Click-El $tab2; Start-Sleep -Milliseconds 1400 }
    $saved2 = Read-Notes
    $note2 = $saved2.notes | Where-Object { $_.Title -eq 'qdbold' } | Select-Object -First 1
    $text2 = ([string]$note2.Text) -replace "`r", ''
    Say ("after click-to-edit Text='{0}'" -f ($text2 -replace "`n", '
'))
    $clickEdit = ($text2 -match 'qdboldx$')
    Say ("body tail='{0}'" -f ($text2.Substring([Math]::Max(0, $text2.Length - 12))))
    Say ("assert click body switches to edit: {0}" -f $clickEdit)

    Say 'RESULT: notes layout checked'
}

# ---------------------------------------------------------------- push out

function Run-PushOut {
    Stop-App
    Backup-State
    $app = Start-App
    Say ("app pid={0}" -f $app.Id)
    if (-not (Ensure-DrawerOpen)) { Say 'FAIL: drawer did not open'; return }

    $win = Get-DrawerWindow
    $drawer = Get-DrawerRect
    if ($null -eq $win -or $null -eq $drawer) { Say 'FAIL: drawer not found'; return }
    $panelLeft = [int]$drawer[0]
    Say ("panel rect={0}" -f ($drawer -join ','))
    Say ("panel left={0} (expected work area right minus panel width)" -f $panelLeft)

    # make sure the panel is pinned
    $cfg = Read-Config
    $pinned = $false
    if ($null -ne $cfg -and $null -ne $cfg.dock) { $pinned = [bool]$cfg.dock.pinPanel }
    Say ("pinPanel on disk before={0}" -f $pinned)
    if (-not $pinned) {
        $pin = Find-Ctl $win 'PinPanel'
        if ($null -eq $pin) { Say 'FAIL: PinPanel button not found'; return }
        Click-El $pin
        Start-Sleep -Milliseconds 900
        $cfg = Read-Config
        $pinned = [bool]$cfg.dock.pinPanel
        Say ("pinPanel after click={0}" -f $pinned)
    }

    # fresh test window: our own WinForms form (Win11 notepad is packaged -> MainWindowHandle stays 0)
    $pwshExe = (Get-Process -Id $PID).Path
    $targetScript = Join-Path $PSScriptRoot 'paste-target.ps1'
    $script:targetProc = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $targetScript) -PassThru
    $h = [IntPtr]::Zero
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $h = [U4]::FindByTitle('QD Paste Target')
        if ($h -ne [IntPtr]::Zero) { break }
    }
    Say ("test window hwnd=0x{0:X}" -f $h.ToInt64())
    if ($h -eq [IntPtr]::Zero) { Say 'FAIL: test window not found'; return }

    # 1) normal window overlapping the panel -> pushed left, right edge at the panel inner edge
    $startX = $panelLeft - 200
    [void][U6]::SetWindowPos($h, [IntPtr]::Zero, $startX, 300, 600, 400, ($SWP_NOZORDER -bor $SWP_NOACTIVATE))
    Start-Sleep -Milliseconds 2200
    $r1 = [U6]::Rect($h)
    Say ("normal window: placed {0},300 600x400 -> now {1},{2} {3}x{4}" -f $startX, $r1[0], $r1[1], $r1[2], $r1[3])
    $normalPushed = (($r1[0] + $r1[2]) -le ($panelLeft + 2)) -and ($r1[0] -lt $startX)
    Say ("assert normal window pushed out: {0}" -f $normalPushed)

    # 2) maximize -> becomes a normal window filling the free area left of the panel
    [void][U6]::ShowWindow($h, $SW_MAXIMIZE)
    Start-Sleep -Milliseconds 2400
    $r2 = [U6]::Rect($h)
    Say ("maximized window -> now {0},{1} {2}x{3}" -f $r2[0], $r2[1], $r2[2], $r2[3])
    $maxPushed = ([math]::Abs($r2[0]) -le 2) -and ([math]::Abs(($r2[0] + $r2[2]) - $panelLeft) -le 2) -and ($r2[3] -ge 900)
    Say ("assert maximized window fits left of panel: {0}" -f $maxPushed)

    # 3) unpin -> target restored to where it was before we touched it
    $pin = Find-Ctl $win 'PinPanel'
    Click-El $pin
    Start-Sleep -Milliseconds 2400
    $cfg = Read-Config
    Say ("pinPanel after unpin={0}" -f [bool]$cfg.dock.pinPanel)
    $r3 = [U6]::Rect($h)
    Say ("after unpin target={0},{1} {2}x{3}" -f $r3[0], $r3[1], $r3[2], $r3[3])
    $restored = (($r3[0] + $r3[2]) -gt ($panelLeft + 100))
    Say ("assert target restored: {0}" -f $restored)

    $tail = Read-DiagTail 80
    $started  = [bool]($tail | Where-Object { $_ -match '\[pushout\] started \(panel pinned\)' })
    $movedWin = [bool]($tail | Where-Object { $_ -match '\[pushout\] window 0x' })
    $movedMax = [bool]($tail | Where-Object { $_ -match '\[pushout\] maximized 0x' })
    $stopped  = [bool]($tail | Where-Object { $_ -match '\[pushout\] stopped, restored' })
    Say ("diag: started={0} window={1} maximized={2} stopped={3}" -f $started, $movedWin, $movedMax, $stopped)
    Say '--- diag tail (pushout) ---'
    foreach ($line in $tail) { if ($line -match '\[pushout\]') { Say ("  " + $line) } }

    Say 'RESULT: pushout checked'
}

# ---------------------------------------------------------------- run

try {
    if ($Mode -eq 'notes') { [void](Run-Notes) } else { [void](Run-PushOut) }
} catch {
    Say ('ERROR: ' + $_.Exception.Message)
    Say ($_.ScriptStackTrace)
} finally {
    if ($script:targetProc) { Stop-Process -Id $script:targetProc.Id -Force -ErrorAction SilentlyContinue }
    Flush
    Restore-State
    Start-App | Out-Null
    Say 'cleanup: test window closed, state restored, app restarted'
    Flush
}
