$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class SS {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static IntPtr Find(uint procId, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == procId) { StringBuilder t = new StringBuilder(256); GetWindowTextW(h, t, 256);
                if (t.ToString() == title) { found = h; return false; } }
            return true; }, IntPtr.Zero);
        return found;
    }
}
"@
function Pump([int]$ms) {
    $end = [Environment]::TickCount + $ms
    while ([Environment]::TickCount -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }
}
$outDir = Join-Path $env:TEMP 'qd_docs'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$proc = Get-Process -Name QuickDrawer -ErrorAction Stop | Select-Object -First 1
$pid32 = [uint32]$proc.Id

[void][SS]::SetCursorPos(1915, 500)
Pump 1600
$h = [SS]::Find($pid32, 'QuickDrawer')
if ($h -eq [IntPtr]::Zero) { Write-Output 'FAIL=no-window'; exit 1 }
$r = New-Object SS+RECT
[void][SS]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
Write-Output ("drawer rect = {0},{1} {2}x{3}" -f $r.Left, $r.Top, $w, $ht)

$AE = [Windows.Automation.AutomationElement]
$root = $AE::FromHandle($h)

# 三个底部标签是 RadioButton，按 ControlType 取全部，用序号选（避免中文/emoji 字面量）
$tabCond = New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::RadioButton)
$tabs = $root.FindAll([Windows.Automation.TreeScope]::Descendants, $tabCond)
Write-Output ("tabs found = {0}" -f $tabs.Count)
for ($i = 0; $i -lt $tabs.Count; $i++) {
    Write-Output ("  tab[{0}] name='{1}' rect={2}" -f $i, $tabs[$i].Current.Name, $tabs[$i].Current.BoundingRectangle)
}

function SelectTabIdx([int]$i) {
    if ($i -ge $tabs.Count) { Write-Output "tab[$i] : NOT FOUND"; return $false }
    try {
        $p = $tabs[$i].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
        $p.Select()
        return $true
    } catch {
        Write-Output ("tab[{0}] select failed: {1}" -f $i, $_.Exception.Message)
        return $false
    }
}

function Shot([string]$name) {
    [void][SS]::SetCursorPos($r.Left + 200, $r.Top + 400)
    Pump 350
    $bmp = New-Object System.Drawing.Bitmap($w, $ht)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
    $p = Join-Path $outDir ("{0}.png" -f $name)
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Output ("shot {0} = {1}" -f $name, $p)
}

if (SelectTabIdx 0) { Pump 800 }
Shot 'notes'

if (SelectTabIdx 1) { Pump 800 }
Shot 'clipboard'

if (SelectTabIdx 2) { Pump 6000 }
Shot 'assistant'

[void](SelectTabIdx 0)
Pump 500
Write-Output 'DONE'
