Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$out = Join-Path $env:TEMP 'qd_note_header_uia.txt'
"=== note card header UIA (2026-11-06 narrow) ===" | Out-File -FilePath $out -Encoding utf8
function W([string]$m) { $m | Out-File -FilePath $out -Append -Encoding utf8 }

$root = [System.Windows.Automation.AutomationElement]::RootElement
foreach ($name in @('CardTitle', 'CardColor', 'PinCard', 'DeleteCard')) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    W "$name : count=$($found.Count)"
    $i = 0
    foreach ($e in $found) {
        if ($i -ge 2) { break }
        $r = $e.Current.BoundingRectangle
        W ("  [{0}] type={1} rect={2},{3} {4}x{5} enabled={6}" -f $i,
            $e.Current.ControlType.ProgrammaticName,
            [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height,
            $e.Current.IsEnabled)
        $i++
    }
}
Get-Content -Path $out -Encoding utf8
