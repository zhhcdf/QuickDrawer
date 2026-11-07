param([string]$Text = "QD-SEL-SOURCE first line of sample text")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "QD Sel Source"
$form.Width = 620
$form.Height = 260
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Left = 200
$form.Top = 220

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.AcceptsReturn = $true
$box.Width = 580
$box.Height = 180
$box.Left = 12
$box.Top = 12
$box.Font = New-Object System.Drawing.Font("Consolas", 12)
$box.Text = $Text
$form.Controls.Add($box)

$form.Add_Shown({ $box.Focus() })

[System.Windows.Forms.Application]::Run($form)
