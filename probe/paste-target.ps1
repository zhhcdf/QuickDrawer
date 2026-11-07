# Paste target window: a WinForms form with a multiline TextBox.
# It dumps its text to probe/target-text.txt every 200 ms so the probe can assert
# that Ctrl+V really landed in a foreign application's input box.
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$outFile = Join-Path $PSScriptRoot 'target-text.txt'
try { [System.IO.File]::WriteAllText($outFile, '') } catch { }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'QD Paste Target'
$form.Width = 520
$form.Height = 240
$form.StartPosition = 'Manual'
$form.Left = 140
$form.Top = 140
$form.MinimizeBox = $false

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.Dock = 'Fill'
$box.Font = New-Object System.Drawing.Font('Consolas', 12)
$box.ScrollBars = 'Vertical'
$form.Controls.Add($box)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    try { [System.IO.File]::WriteAllText($outFile, $box.Text) } catch { }
})
$timer.Start()

$form.Add_Shown({ $box.Focus() })
# Application::Run keeps the message loop alive; a bare Show() would let the host
# script finish and tear the window down before the probe could find it.
[System.Windows.Forms.Application]::Run($form)
