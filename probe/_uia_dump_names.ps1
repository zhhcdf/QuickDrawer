Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$out = Join-Path $env:TEMP 'qd_all_names.txt'
$procId = [int](Get-Process QuickDrawer).Id
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if ($null -eq $win) { "window NOT FOUND" | Out-File $out -Encoding utf8; Get-Content $out -Encoding utf8; exit 1 }

$all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)

$lines = New-Object System.Collections.Generic.List[string]
foreach ($e in $all) {
    $n = $e.Current.Name
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    $r = $e.Current.BoundingRectangle
    $lines.Add(("{0}|{1}|{2},{3}|{4}x{5}" -f $e.Current.ControlType.ProgrammaticName, $n,
        [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height))
}
[System.IO.File]::WriteAllLines($out, $lines, (New-Object System.Text.UTF8Encoding($false)))
"wrote $($lines.Count) lines to $out"
