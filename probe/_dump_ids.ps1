$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class QC {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@
$proc = Get-Process -Name QuickDrawer | Select-Object -First 1
[void][QC]::SetCursorPos(1915, 500)
Start-Sleep -Milliseconds 1200
[void][QC]::SetCursorPos(1700, 500)
Start-Sleep -Milliseconds 800

$AE = [Windows.Automation.AutomationElement]
$cond = New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)
$win = $AE::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $cond)
$all = $win.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
Write-Output "elements: $($all.Count)"
foreach ($e in $all) {
    $n = $e.Current.Name
    $aid = $e.Current.AutomationId
    if ([string]::IsNullOrWhiteSpace($n) -and [string]::IsNullOrWhiteSpace($aid)) { continue }
    $r = $e.Current.BoundingRectangle
    Write-Output ("{0}|id='{1}'|name='{2}'|{3},{4} {5}x{6}|off={7}" -f $e.Current.ControlType.ProgrammaticName, $aid, $n, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height, $e.Current.IsOffscreen)
}
