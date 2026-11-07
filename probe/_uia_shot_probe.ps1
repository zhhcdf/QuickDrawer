param()

# 直接按 Name 找 AssistantShot，打印它的 ControlType / 矩形 / 支持的模式，
# 弄清为什么它不支持 InvokePattern。
# 2026-11-05。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$out = Join-Path $env:TEMP 'qd_uia_shot.txt'
"=== AssistantShot element ===" | Out-File -FilePath $out -Encoding utf8
function W([string]$msg) { $msg | Out-File -FilePath $out -Append -Encoding utf8 }

$root = [System.Windows.Automation.AutomationElement]::RootElement
foreach ($probe in @('AssistantShot', 'AssistantWiden', 'AssistantReload', 'TabAssistant', 'PinPanel')) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $probe)
    $el = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if ($null -eq $el) { W ("$probe : NOT FOUND"); continue }
    $r = $el.Current.BoundingRectangle
    $pats = ''
    try { foreach ($p in $el.GetSupportedPatterns()) { $pats += $p.ProgrammaticName.Replace('PatternIdentifiers.Pattern','') + ',' } } catch { $pats = 'err' }
    W ("$probe : type=" + $el.Current.ControlType.ProgrammaticName + " aid=[" + $el.Current.AutomationId + "] offscreen=" + $el.Current.IsOffscreen + " enabled=" + $el.Current.IsEnabled + " rect=" + [int]$r.X + "," + [int]$r.Y + " " + [int]$r.Width + "x" + [int]$r.Height + " patterns=" + $pats)
}
W "done"
Get-Content -Path $out -Encoding utf8
