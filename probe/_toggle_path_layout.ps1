$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$out = Join-Path $env:TEMP 'qd_iconmode.txt'
$procId = [int](Get-Process QuickDrawer).Id
$AE = [System.Windows.Automation.AutomationElement]
$root = $AE::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $procId)
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if ($null -eq $win) { "window NOT FOUND" | Out-File $out; Get-Content $out; exit 1 }

$btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'PathLayout')
$btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
if ($null -eq $btn) { "PathLayout NOT FOUND" | Out-File $out; Get-Content $out; exit 1 }
$pat = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$pat.Invoke()
Start-Sleep -Milliseconds 900
"invoked" | Out-File -Encoding utf8 $out
Get-Content $out
