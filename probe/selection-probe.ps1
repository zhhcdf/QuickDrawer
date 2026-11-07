param([ValidateSet('drag', 'doubleclick', 'sameclip', 'repeat')][string]$Mode = 'drag')

# End-to-end verification for the 2026-10-30 selection popup feature.
#   drag        - drag-select across a line of text (original flow)
#   doubleclick - double-click word select: displacement 0, the old low level
#                 hook dropped these entirely, so this is the main regression
#   sameclip    - the selected text equals the current clipboard text: the old
#                 guard treated "copied == previous" as a failed copy
#   repeat      - select twice in a row: the old 200ms throttle dropped the 2nd
# Every mode clicks the first preset chip and expects the prompt to reach the
# DeepSeek assistant page. ASCII only; paths derive from $PSScriptRoot.

. (Join-Path $PSScriptRoot '_helpers.ps1')

if ($Mode -eq 'drag') {
    $resultPath = Join-Path $PSScriptRoot 'selection-result.txt'
} else {
    $resultPath = Join-Path $PSScriptRoot ('selection-result-' + $Mode + '.txt')
}

$token = 'QD-SEL-' + (Get-Date -Format 'HHmmss')
$sourceScript = Join-Path $PSScriptRoot 'sel-source.ps1'

if ($Mode -eq 'doubleclick') {
    $srcText = 'sample quickdrawer doubleclick words'
    $searchToken = 'sample'
} else {
    $srcText = $token
    $searchToken = $token
}

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
    # 2026-10-31: the WinForms TextBox surfaces as ControlType.Pane whose class
    # name is WindowsForms10.EDIT..., so the Edit control-type query finds
    # nothing. Fall back to matching the class name and use that element.
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

function Wait-Popup([int]$timeoutMs = 4000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $h = [U4]::FindByTitle('QuickDrawer Selection')
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

    # Start-Process -ArgumentList joins the array with plain spaces and does
    # NOT quote anything, so a multi-word source text arrived as separate
    # positional args: $Text ended up as just the first word ("sample"), and
    # the doubleclick mode then selected 3 characters instead of a word.
    # NOTE: this comment must stay ABOVE the call - a backtick continuation
    # followed by a comment line ends the statement, which made
    # "-ArgumentList" run as its own command (CommandNotFoundException).
    $script:sourceProc = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sourceScript, '-Text', ('"' + $srcText + '"')) -PassThru

    $dhwnd = [IntPtr]::Zero
    for ($w = 0; $w -lt 30; $w++) {
        Start-Sleep -Milliseconds 200
        $dhwnd = [U4]::FindByTitle('QD Sel Source')
        if ($dhwnd -ne [IntPtr]::Zero) { break }
        if ($script:sourceProc.HasExited) { break }
    }
    Say ("source pid={0} exited={1}" -f $script:sourceProc.Id, $script:sourceProc.HasExited)
    Say ("source hwnd=0x{0:X}" -f $dhwnd.ToInt64())
    Check 'source window found' ($dhwnd -ne [IntPtr]::Zero)
    if ($dhwnd -eq [IntPtr]::Zero) { throw 'source window not found' }
    [void][U4]::SetForegroundWindow($dhwnd)
    Start-Sleep -Milliseconds 600

    $edit = Get-SourceEdit $dhwnd
    if ($null -eq $edit) { throw 'source edit not found' }
    $er = $edit.Current.BoundingRectangle
    Say ("edit rect={0},{1} {2}x{3}" -f [int]$er.X, [int]$er.Y, [int]$er.Width, [int]$er.Height)

    $x1 = [int]($er.X + 6)
    $y1 = [int]($er.Y + 12)
    $x2 = [int]($er.X + 190)

    $diagBefore = (Get-DiagLines).Count

    if ($Mode -eq 'doubleclick') {
        $dx1 = [int]($er.X + 26)
        [U4]::MoveTo($dx1, $y1)
        Start-Sleep -Milliseconds 150
        for ($c = 1; $c -le 2; $c++) {
            [U4]::LeftDown()
            Start-Sleep -Milliseconds 60
            [U4]::LeftUp()
            Start-Sleep -Milliseconds 140
        }
        Say ("double-clicked at {0},{1}" -f $dx1, $y1)
    } elseif ($Mode -eq 'sameclip') {
        Set-Clipboard -Value $srcText
        Start-Sleep -Milliseconds 500
        Invoke-DragSelect $x1 $y1 $x2
        Say ("dragged {0},{1} -> {2} with identical clipboard text" -f $x1, $y1, $x2)
    } elseif ($Mode -eq 'repeat') {
        Invoke-DragSelect $x1 $y1 $x2
        Say ("dragged {0},{1} -> {2}" -f $x1, $y1, $x2)
        $p1 = Wait-Popup 3000
        Say ("first popup={0}" -f ($p1 -ne [IntPtr]::Zero))
        $c1 = @(Get-DiagLines | Select-String -Pattern 'selection captured' -SimpleMatch).Count
        # second drag starts at the same x: selecting the same text twice is the
        # case that used to fail. Starting further right would select only the
        # tail of the token and the "token visible" check below would misfire.
        Invoke-DragSelect $x1 $y1 $x2
        # the clipboard round trip needs its own second: wait for a new line
        # instead of a fixed sleep, otherwise the count races the log write
        $c2 = $c1
        for ($w = 0; $w -lt 30; $w++) {
            Start-Sleep -Milliseconds 200
            $c2 = @(Get-DiagLines | Select-String -Pattern 'selection captured' -SimpleMatch).Count
            if ($c2 -gt $c1) { break }
        }
        Say ("captured lines: after first={0} after second={1}" -f $c1, $c2)
        Check 'second select also captured' ($c2 -ge ($c1 + 1))
    } else {
        Invoke-DragSelect $x1 $y1 $x2
        Say ("dragged {0},{1} -> {2}" -f $x1, $y1, $x2)
    }

    $popup = Wait-Popup 4000
    Say ("popup hwnd=0x{0:X}" -f $popup.ToInt64())
    Check 'popup appeared' ($popup -ne [IntPtr]::Zero)

    $newDiag = @(Get-DiagLines | Select-Object -Skip $diagBefore)
    $capturedLine = $newDiag | Select-String -Pattern 'selection captured' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($capturedLine) { $capturedLine.Line.Trim() } else { '(no capture line)' }))
    Check 'diag logged selection captured' ($null -ne $capturedLine)

    $chars = 0
    if ($capturedLine -and $capturedLine.Line -match '\((\d+) chars\)') { $chars = [int]$matches[1] }
    Say ("captured chars={0}" -f $chars)
    Check 'captured more than 3 chars' ($chars -gt 3)

    if ($popup -ne [IntPtr]::Zero) {
        $pel = $AE::FromHandle($popup)
        $chips = Find-All-Of $pel $CTL::Button
        # a popup that was hidden between two selections keeps its hwnd but
        # loses its UIA children; wait for the fresh show before measuring
        for ($retry = 0; $retry -lt 5 -and @($chips).Count -eq 0; $retry++) {
            Start-Sleep -Milliseconds 300
            $popup = [U4]::FindByTitle('QuickDrawer Selection')
            if ($popup -eq [IntPtr]::Zero) { break }
            $pel = $AE::FromHandle($popup)
            $chips = Find-All-Of $pel $CTL::Button
        }
        $r = $pel.Current.BoundingRectangle
        Say ("popup rect={0},{1} {2}x{3}" -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
        Check 'popup has width' ($r.Width -gt 60 -and $r.Height -gt 10)
        $allButtons = @($chips)
        # 2026-10-31: the popup now carries a fixed "send" button at the far left
        # (UIA Name = SendCustomPrompt) followed by a 1px separator, so the
        # preset chips are no longer the first buttons. Split them apart by name.
        $sendBtn = @($allButtons | Where-Object { $_.Current.Name -eq 'SendCustomPrompt' })
        $chips = @($allButtons | Where-Object { $_.Current.Name -ne 'SendCustomPrompt' })
        Say ("popup buttons total={0} send={1} presets={2}" -f $allButtons.Count, $sendBtn.Count, $chips.Count)
        Check 'send button present' ($sendBtn.Count -eq 1)
        Check 'preset chips present' (@($chips).Count -ge 2)
        if ($sendBtn.Count -eq 1 -and @($chips).Count -gt 0) {
            $sb = $sendBtn[0].Current.BoundingRectangle
            $fc = $chips[0].Current.BoundingRectangle
            Say ("send button x={0} first preset x={1}" -f [int]$sb.X, [int]$fc.X)
            Check 'send button sits left of every preset' ($sb.X -lt $fc.X)
        }
        if (@($chips).Count -gt 0) {
            $chip = @($chips)[0]
            $cr = $chip.Current.BoundingRectangle
            Say ("clicking chip at {0},{1} ({2}x{3})" -f [int]($cr.X + $cr.Width / 2), [int]($cr.Y + $cr.Height / 2), [int]$cr.Width, [int]$cr.Height)
            Click-El $chip 0.5
            Start-Sleep -Milliseconds 2500
        }
    }

    $diag2 = @(Get-DiagLines | Select-Object -Skip $diagBefore)
    $chosen = $diag2 | Select-String -Pattern 'prompt chosen' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($chosen) { $chosen.Line.Trim() } else { '(no prompt chosen line)' }))
    Check 'prompt chosen' ($null -ne $chosen)

    $focus = $diag2 | Select-String -Pattern 'composer focus' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($focus) { $focus.Line.Trim() } else { '(no focus line)' }))
    Check 'composer focus' ($null -ne $focus -and $focus.Line -notmatch '"none"')

    $sent = $diag2 | Select-String -Pattern 'prompt sent' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($sent) { $sent.Line.Trim() } else { '(no prompt sent line)' }))
    Check 'prompt sent' ($null -ne $sent -and $sent.Line -notmatch 'failed')

    # Hard evidence that the whole message reached the page: the assistant
    # service logs the exact character count it typed (prompt + blank line +
    # selection). Compute the same number from config so this is deterministic
    # instead of depending on WebView2's UIA tree, which is thin and slow.
    $expected = 0
    if ($null -ne $chosen) {
        foreach ($p in (Read-Config).assistant.prompts) {
            if ($p.id -eq 'translate') { $expected = $p.instruction.Length + 2 + $chars; break }
        }
    }
    Say ("expected composer chars={0}" -f $expected)
    $toPage = $diag2 | Select-String -Pattern 'prompt sent to ' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($toPage) { $toPage.Line.Trim() } else { '(no assistant send line)' }))
    Check 'assistant composer received prompt + selection' ($null -ne $toPage -and $expected -gt 0 -and $toPage.Line.Contains('(' + $expected + ' chars)'))

    # Soft signal only: WebView2 exposes little to UIA and wakes up late, so the
    # DOM token scan retries for ~12s and is reported but not asserted.
    $visible = $false
    for ($w = 0; $w -lt 15 -and -not $visible; $w++) {
        if ($w -gt 0) { Start-Sleep -Milliseconds 800 }
        $drawer = Get-DrawerWin
        if ($null -eq $drawer) { continue }
        $texts = Find-All-Of $drawer $CTL::Text
        foreach ($t in $texts) {
            $n = $t.Current.Name
            if ($n -and $n.Contains($searchToken)) { $visible = $true; break }
        }
    }
    Say ("token '{0}' visible in drawer UIA tree: {1}" -f $searchToken, $visible)
}
finally {
    Stop-Source
    if ($liveClip) { try { Set-Clipboard -Value $liveClip } catch { } }
    Restore-State
    Start-App | Out-Null
    Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
    Flush
}
