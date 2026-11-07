# End-to-end verification for the 2026-10-31 "send with custom prompt" button.
# Flow: select text -> popup shows a leftmost send button -> click it ->
# PromptEditorDialog appears -> replace the prompt -> click OK ->
# the prompt reaches the assistant page.
# ASCII only; paths derive from $PSScriptRoot.

. (Join-Path $PSScriptRoot '_helpers.ps1')

$token = 'QD-CUS-' + (Get-Date -Format 'HHmmss')
$sourceScript = Join-Path $PSScriptRoot 'sel-source.ps1'

$liveClip = $null
try { $liveClip = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }

$script:fail = 0
$script:sourceProc = $null

function Get-DiagLines {
    if (-not (Test-Path -LiteralPath $diagPath)) { return @() }
    return @(Get-Content -LiteralPath $diagPath -ErrorAction SilentlyContinue)
}

function Get-DrawerWin {
    $p = (Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($null -eq $p) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    $kids = $AE::RootElement.FindAll($CTS::Children, $cond)
    foreach ($w in $kids) {
        $r = $w.Current.BoundingRectangle
        if ($r.Width -ge 280 -and $r.Width -le 620 -and $r.Height -gt 400) { return $w }
    }
    return $null
}

function Get-SourceEdit([IntPtr]$hwnd) {
    $win = $AE::FromHandle($hwnd)
    if ($null -eq $win) { return $null }
    $hit = Find-All-Of $win $CTL::Edit | Select-Object -First 1
    if ($null -ne $hit) { return $hit }
    $all = $win.FindAll($CTS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        if ($el.Current.ClassName -like '*EDIT*') { return $el }
    }
    return $null
}

function Invoke-DragSelect([int]$ax1, [int]$ay1, [int]$ax2) {
    [U4]::MoveTo($ax1, $ay1)
    Start-Sleep -Milliseconds 150
    [U4]::LeftDown()
    Start-Sleep -Milliseconds 90
    for ($i = 1; $i -le 12; $i++) {
        $x = [int]($ax1 + (($ax2 - $ax1) * $i / 12))
        [U4]::MoveTo($x, $ay1)
        Start-Sleep -Milliseconds 25
    }
    [U4]::LeftUp()
}

function Wait-Window([string]$title, [int]$timeoutMs = 4000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $h = [U4]::FindByTitle($title)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 100
    }
    return [IntPtr]::Zero
}

function Stop-Source {
    if ($script:sourceProc) {
        Stop-Process -Id $script:sourceProc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        $script:sourceProc = $null
    }
}

try {
    Backup-State
    Stop-App
    Start-App | Out-Null
    if (-not (Ensure-DrawerOpen)) { throw 'drawer did not open' }
    $dr = Get-DrawerRectNow
    Say ("drawer rect={0}" -f $(if ($dr) { ($dr -join ',') } else { 'none' }))

    $script:sourceProc = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sourceScript, '-Text', $token) -PassThru

    $dhwnd = [IntPtr]::Zero
    for ($w = 0; $w -lt 30; $w++) {
        Start-Sleep -Milliseconds 200
        $dhwnd = [U4]::FindByTitle('QD Sel Source')
        if ($dhwnd -ne [IntPtr]::Zero) { break }
        if ($script:sourceProc.HasExited) { break }
    }
    Check 'source window found' ($dhwnd -ne [IntPtr]::Zero)
    if ($dhwnd -eq [IntPtr]::Zero) { throw 'source window not found' }
    [void][U4]::SetForegroundWindow($dhwnd)
    Start-Sleep -Milliseconds 600

    $edit = Get-SourceEdit $dhwnd
    if ($null -eq $edit) { throw 'source edit not found' }
    $er = $edit.Current.BoundingRectangle
    Say ("edit rect={0},{1} {2}x{3}" -f [int]$er.X, [int]$er.Y, [int]$er.Width, [int]$er.Height)

    $diagBefore = (Get-DiagLines).Count

    Invoke-DragSelect ([int]($er.X + 6)) ([int]($er.Y + 12)) ([int]($er.X + 190))

    $popup = Wait-Window 'QuickDrawer Selection' 4000
    Check 'popup appeared' ($popup -ne [IntPtr]::Zero)
    if ($popup -eq [IntPtr]::Zero) { throw 'popup did not appear' }

    $pel = $AE::FromHandle($popup)
    $buttons = @()
    for ($retry = 0; $retry -lt 5 -and @($buttons).Count -eq 0; $retry++) {
        Start-Sleep -Milliseconds 300
        $popup = [U4]::FindByTitle('QuickDrawer Selection')
        if ($popup -eq [IntPtr]::Zero) { break }
        $pel = $AE::FromHandle($popup)
        $buttons = @(Find-All-Of $pel $CTL::Button)
    }

    $sendBtn = @($buttons | Where-Object { $_.Current.Name -eq 'SendCustomPrompt' })
    $presets = @($buttons | Where-Object { $_.Current.Name -ne 'SendCustomPrompt' })
    Say ("popup buttons total={0} send={1} presets={2}" -f @($buttons).Count, $sendBtn.Count, $presets.Count)
    Check 'send button present' ($sendBtn.Count -eq 1)
    Check 'preset chips still present' ($presets.Count -ge 2)
    if ($sendBtn.Count -ne 1) { throw 'send button missing' }

    $sb = $sendBtn[0].Current.BoundingRectangle
    if ($presets.Count -gt 0) {
        $fc = $presets[0].Current.BoundingRectangle
        Say ("send button x={0} first preset x={1}" -f [int]$sb.X, [int]$fc.X)
        Check 'send button sits left of every preset' ($sb.X -lt $fc.X)
    }

    Say ("clicking send button at {0},{1}" -f [int]($sb.X + $sb.Width / 2), [int]($sb.Y + $sb.Height / 2))
    Click-El $sendBtn[0] 0.5
    Start-Sleep -Milliseconds 900

    $dlgHwnd = [IntPtr]::Zero
    # The dialog belongs to the QuickDrawer process, NOT to this PowerShell
    # process. Enumerate the app's top-level windows and pick the one that is
    # neither the drawer panel nor the handle strip.
    $appProc = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $appProc) {
        $deadline = (Get-Date).AddMilliseconds(5000)
        while ((Get-Date) -lt $deadline -and $dlgHwnd -eq [IntPtr]::Zero) {
            $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $appProc.Id)
            $tops = $AE::RootElement.FindAll($CTS::Children, $cond)
            foreach ($w in $tops) {
                $n = $w.Current.Name
                if ($n -eq 'QuickDrawer' -or $n -eq 'QuickDrawer Handle') { continue }
                if ($n -like 'QuickDrawer*') {
                    $dlgHwnd = [IntPtr]$w.Current.NativeWindowHandle
                    Say ("dialog window name='{0}' class='{1}'" -f $n, $w.Current.ClassName)
                    break
                }
            }
            if ($dlgHwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
        }
    }

    Check 'prompt editor dialog opened' ($dlgHwnd -ne [IntPtr]::Zero)

    if ($dlgHwnd -ne [IntPtr]::Zero) {
        $dlg = $AE::FromHandle($dlgHwnd)
        $box = Find-ById $dlg 'CustomPromptBox'
        if ($null -eq $box) { $box = Find-By-Name $dlg 'CustomPromptBox' }
        Check 'prompt text box found' ($null -ne $box)

        $initial = ''
        if ($null -ne $box) {
            try { $initial = $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { }
        }
        Say ("initial prompt text length={0}" -f $initial.Length)
        Check 'prompt box prefilled from config' ($initial.Length -gt 0)

        $ok = Find-ById $dlg 'PromptOk'
        if ($null -eq $ok) { $ok = Find-By-Name $dlg 'PromptOk' }
        Check 'ok button found' ($null -ne $ok)

        if ($null -ne $box -and $null -ne $ok) {
            # Replace the whole draft. ValuePattern is reliable here; SendKeys
            # silently dropped characters in an earlier run (22 chars typed,
            # 18 landed), which made the "did the edit stick" assertion mushy.
            $typed = 'QDPROMPT ' + $token
            try {
                $vp = $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                $vp.SetValue($typed)
            } catch {
                Say ("ValuePattern failed: {0}" -f $_.Exception.Message)
            }
            Start-Sleep -Milliseconds 400

            $after = ''
            try { $after = $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { }
            Say ("edited prompt text length={0} exact={1}" -f $after.Length, ($after -eq $typed))
            Check 'prompt box holds exactly the typed text' ($after -eq $typed)

            Click-El $ok 0.5
            Start-Sleep -Milliseconds 3000
        }
    }

    $diag2 = @(Get-DiagLines | Select-Object -Skip $diagBefore)

    $req = $diag2 | Select-String -Pattern 'custom send requested' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($req) { $req.Line.Trim() } else { '(no custom send line)' }))
    Check 'custom send requested logged' ($null -ne $req)

    $sent = $diag2 | Select-String -Pattern 'prompt sent' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($sent) { $sent.Line.Trim() } else { '(no prompt sent line)' }))
    Check 'custom prompt sent' ($null -ne $sent -and $sent.Line -notmatch 'failed')
    Check 'sent line tagged custom' ($null -ne $sent -and $sent.Line.Contains('custom'))

    # the draft must be written back so the next send starts from it
    $cfg = Read-Config
    $draft = ''
    try { $draft = [string]$cfg.assistant.customPrompt } catch { }
    Say ("config assistant.customPrompt length={0}" -f $draft.Length)
    Check 'edited prompt written back to config' ($draft.Contains('QDPROMPT'))

    # The composer got the exact text: assert on the char count the assistant
    # service logged (prompt + blank line + selection), which is deterministic.
    $toPage = $diag2 | Select-String -Pattern 'prompt sent to ' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($toPage) { $toPage.Line.Trim() } else { '(no assistant send line)' }))
    # Parse without regex. Single-quoted PowerShell strings keep backslashes
    # literal, so an earlier '\(...\)' pattern demanded two real backslashes
    # and matched nothing (expected stayed 0).
    $expected = 0
    if ($null -ne $sent) {
        $mark = ' chars selection)'
        $idx = $sent.Line.IndexOf($mark)
        if ($idx -gt 0) {
            $j = $idx - 1
            while ($j -ge 0 -and [char]::IsDigit($sent.Line[$j])) { $j-- }
            $expected = $typed.Length + 2 + [int]$sent.Line.Substring($j + 1, $idx - $j - 1)
        }
    }
    Say ("expected composer chars={0}" -f $expected)
    Check 'assistant composer received prompt + selection' ($null -ne $toPage -and $expected -gt 0 -and $toPage.Line.Contains('(' + $expected + ' chars)'))

    # WebView2 exposes little to UIA, so the token scan is a soft signal: retry
    # a while and treat the composer char count above as the hard assertion.
    $drawer = $null
    $visible = $false
    for ($w = 0; $w -lt 10 -and -not $visible; $w++) {
        Start-Sleep -Milliseconds 800
        $drawer = Get-DrawerWin
        if ($null -eq $drawer) { continue }
        $texts = Find-All-Of $drawer $CTL::Text
        foreach ($t in $texts) {
            $n = $t.Current.Name
            if ($n -and $n.Contains($token)) { $visible = $true; break }
        }
    }
    Say ("token '{0}' visible in drawer UIA tree: {1}" -f $token, $visible)
}
finally {
    Stop-Source
    if ($liveClip) { try { Set-Clipboard -Value $liveClip } catch { } }
    Restore-State
    Start-App | Out-Null
    Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
    Flush
}
