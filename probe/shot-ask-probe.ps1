# End-to-end verification for the 2026-11-01 (5th) "screenshot question" feature.
#   click the toolbar screenshot button -> the panel collapses -> a full screen
#   overlay appears -> drag a rectangle -> the overlay closes and the selection
#   popup shows a thumbnail -> click send -> prompt editor -> OK -> the image
#   and the prompt reach the assistant page.
# ASCII only; paths derive from $PSScriptRoot.

. (Join-Path $PSScriptRoot '_helpers.ps1')

$token = 'QD-SHOT-' + (Get-Date -Format 'HHmmss')
$promptText = 'QDSHOTPROMPT ' + $token

$liveClip = $null
try { $liveClip = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }

$script:fail = 0

function Get-DiagLines {
    if (-not (Test-Path -LiteralPath $diagPath)) { return @() }
    return @(Get-Content -LiteralPath $diagPath -ErrorAction SilentlyContinue)
}

# Do not use _helpers' Get-DrawerWindow: it hard-filters width 380..430 and the
# panel width is user configurable (appendix D #141 / #156).
function Get-DrawerAny {
    $p = (Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($null -eq $p) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    $kids = $AE::RootElement.FindAll($CTS::Children, $cond)
    foreach ($w in $kids) {
        $r = $w.Current.BoundingRectangle
        if ($r.Height -gt 400 -and $r.Width -gt 280 -and $r.Width -lt 700) { return $w }
    }
    return $null
}

function Wait-Title([string]$title, [int]$timeoutMs = 5000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $h = [U4]::FindByTitle($title)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 100
    }
    return [IntPtr]::Zero
}

function Wait-TitleGone([string]$title, [int]$timeoutMs = 5000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $h = [U4]::FindByTitle($title)
        if ($h -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Drag-Rect([int]$ax1, [int]$ay1, [int]$ax2, [int]$ay2) {
    [U4]::MoveTo($ax1, $ay1)
    Start-Sleep -Milliseconds 200
    [U4]::LeftDown()
    Start-Sleep -Milliseconds 120
    for ($i = 1; $i -le 12; $i++) {
        $x = [int]($ax1 + (($ax2 - $ax1) * $i / 12))
        $y = [int]($ay1 + (($ay2 - $ay1) * $i / 12))
        [U4]::MoveTo($x, $y)
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 120
    [U4]::LeftUp()
}

function Get-PopupButtons($hwnd) {
    $pel = $AE::FromHandle($hwnd)
    if ($null -eq $pel) { return @() }
    return @(Find-All-Of $pel $CTL::Button)
}

try {
    Backup-State
    Stop-App
    Start-App | Out-Null
    if (-not (Ensure-DrawerOpen)) { throw 'drawer did not open' }

    $tabOk = Click-Tab 'TabAssistant'
    Start-Sleep -Milliseconds 1200
    Say ("assistant tab clicked={0}" -f $tabOk)

    $drawer = Get-DrawerAny
    if ($null -eq $drawer) { throw 'drawer window not found in UIA' }
    $shotBtn = Find-ById $drawer 'AssistantShot'
    if ($null -eq $shotBtn) { $shotBtn = Find-By-Name $drawer 'AssistantShot' }
    Check 'toolbar exposes the screenshot button' ($null -ne $shotBtn)
    if ($null -eq $shotBtn) { throw 'screenshot button not found' }
    Say ("screenshot button rect={0}" -f ($shotBtn.Current.BoundingRectangle).ToString())

    $diagBefore = (Get-DiagLines).Count
    $drBefore = Get-DrawerRectNow
    Say ("drawer rect before shot={0}" -f $(if ($drBefore) { ($drBefore -join ',') } else { 'none' }))

    Click-El $shotBtn 0.5

    $overlay = Wait-Title 'QuickDrawer Screenshot' 6000
    Check 'screenshot overlay appeared' ($overlay -ne [IntPtr]::Zero)
    if ($overlay -eq [IntPtr]::Zero) { throw 'overlay did not appear' }
    Say ("overlay rect={0}" -f ([U4]::GetRect($overlay) -join ','))
    Start-Sleep -Milliseconds 400

    # The panel must be out of the way before the frame is frozen.
    # Do NOT measure the drawer rect here: after Hide() the UIA window is gone and
    # [U4]::FindMainWindow falls back to the full-screen overlay (0,0,1920,1080).
    # Assert on the product's own log ordering instead.
    $diagMid = @(Get-DiagLines | Select-Object -Skip $diagBefore)
    $collapsed = $diagMid | Select-String -Pattern 'drawer collapsed' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($collapsed) { $collapsed.Line.Trim() } else { '(no collapse line)' }))
    Check 'panel collapsed before the frame was frozen' ($null -ne $collapsed)

    $freezeFail = $diagMid | Select-String -Pattern 'screen freeze failed' -SimpleMatch | Select-Object -Last 1
    Check 'frame freeze did not fail' ($null -eq $freezeFail)

    # drag a rectangle over the middle of the desktop, well away from the panel
    $x1 = 320; $y1 = 300; $x2 = 720; $y2 = 500
    Say ("dragging {0},{1} -> {2},{3}" -f $x1, $y1, $x2, $y2)
    Drag-Rect $x1 $y1 $x2 $y2

    $gone = Wait-TitleGone 'QuickDrawer Screenshot' 4000
    Check 'overlay closed after the drag' $gone

    $popup = Wait-Title 'QuickDrawer Selection' 4000
    Check 'selection popup shown in screenshot mode' ($popup -ne [IntPtr]::Zero)
    if ($popup -eq [IntPtr]::Zero) { throw 'popup did not appear' }

    # 2s auto hide is armed: dock the pointer on the popup immediately
    $pr = [U4]::GetRect($popup)
    $px = [int](($pr[0] + $pr[2]) / 2)
    $py = [int](($pr[1] + $pr[3]) / 2)
    [U4]::MoveTo($px, $py)
    Say ("popup rect={0} docking pointer at {1},{2}" -f ($pr -join ','), $px, $py)
    Start-Sleep -Milliseconds 300

    $pel = $AE::FromHandle($popup)
    $thumb = $null
    for ($w = 0; $w -lt 8 -and $null -eq $thumb; $w++) {
        $thumb = Find-By-Name $pel 'ShotThumbnail'
        if ($null -eq $thumb) { Start-Sleep -Milliseconds 250 }
    }
    Check 'popup carries the screenshot thumbnail' ($null -ne $thumb)
    if ($null -ne $thumb) {
        $tr = $thumb.Current.BoundingRectangle
        Say ("thumbnail rect={0},{1} {2}x{3}" -f [int]$tr.X, [int]$tr.Y, [int]$tr.Width, [int]$tr.Height)
        Check 'thumbnail has a real size' ($tr.Width -ge 30 -and $tr.Height -ge 20)
    }

    $buttons = Get-PopupButtons $popup
    $sendBtn = @($buttons | Where-Object { $_.Current.Name -eq 'SendCustomPrompt' })
    $presets = @($buttons | Where-Object { $_.Current.Name -ne 'SendCustomPrompt' })
    Say ("popup buttons total={0} send={1} presets={2}" -f @($buttons).Count, $sendBtn.Count, $presets.Count)
    Check 'send button still present in screenshot mode' ($sendBtn.Count -eq 1)
    Check 'preset chips still offered in screenshot mode' ($presets.Count -ge 2)

    $diag1 = @(Get-DiagLines | Select-Object -Skip $diagBefore)
    $ready = $diag1 | Select-String -Pattern 'ready ' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($ready) { $ready.Line.Trim() } else { '(no ready line)' }))
    Check 'diag records the frozen screenshot size' ($null -ne $ready)

    $shotReady = $diag1 | Select-String -Pattern 'shot ready (' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($shotReady) { $shotReady.Line.Trim() } else { '(no shot ready line)' }))
    Check 'selection watcher logged the shot mode popup' ($null -ne $shotReady)

    # the drag that framed the screenshot must not be mistaken for a text selection
    $captured = $diag1 | Select-String -Pattern 'selection captured' -SimpleMatch | Select-Object -Last 1
    Check 'framing drag did not capture text' ($null -eq $captured)

    if ($sendBtn.Count -ne 1) { throw 'send button missing' }
    Click-El $sendBtn[0] 0.5
    Start-Sleep -Milliseconds 1000

    # the prompt editor owns the QuickDrawer process, and its title is Chinese:
    # pick it by process id + name prefix instead of by title.
    $dlgHwnd = [IntPtr]::Zero
    $appProc = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $appProc) {
        $deadline = (Get-Date).AddMilliseconds(6000)
        while ((Get-Date) -lt $deadline -and $dlgHwnd -eq [IntPtr]::Zero) {
            $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $appProc.Id)
            $tops = $AE::RootElement.FindAll($CTS::Children, $cond)
            foreach ($w in $tops) {
                $n = $w.Current.Name
                if ($n -eq 'QuickDrawer' -or $n -eq 'QuickDrawer Handle') { continue }
                if ($n -eq 'QuickDrawer Selection') { continue }
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

        # The hint reads "shot 400 x 200 pixels" in Chinese with a FULL-WIDTH
        # multiplication sign (U+00D7), not the ASCII letter x. Match on that
        # code point instead of spelling it out (probe files must stay ASCII).
        $times = [string][char]0x00D7
        $hint = ''
        $texts = @(Find-All-Of $dlg $CTL::Text)
        foreach ($t in $texts) {
            $n = $t.Current.Name
            if ($n -and $n.Contains($times)) { $hint = $n; break }
        }
        Say ("dialog hint line='{0}'" -f $hint)
        Check 'dialog hint describes the screenshot size' ($hint.Length -gt 0)

        $ok = Find-ById $dlg 'PromptOk'
        if ($null -eq $ok) { $ok = Find-By-Name $dlg 'PromptOk' }
        Check 'ok button found' ($null -ne $ok)

        if ($null -ne $box -and $null -ne $ok) {
            try {
                $vp = $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                $vp.SetValue($promptText)
            } catch {
                Say ("ValuePattern failed: {0}" -f $_.Exception.Message)
            }
            Start-Sleep -Milliseconds 400
            $after = ''
            try { $after = $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { }
            Say ("edited prompt text length={0} exact={1}" -f $after.Length, ($after -eq $promptText))
            Check 'prompt box holds exactly the typed text' ($after -eq $promptText)

            Click-El $ok 0.5
            Start-Sleep -Milliseconds 1500
        }
    }

    # the send chain is asynchronous (paste -> verify -> insert text -> enter)
    $diag2 = @()
    for ($w = 0; $w -lt 20; $w++) {
        Start-Sleep -Milliseconds 700
        $diag2 = @(Get-DiagLines | Select-Object -Skip $diagBefore)
        $hit = $diag2 | Select-String -Pattern 'prompt with image' -SimpleMatch | Select-Object -Last 1
        if ($null -ne $hit) { break }
    }

    $req = $diag2 | Select-String -Pattern 'shot send requested' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($req) { $req.Line.Trim() } else { '(no shot send line)' }))
    Check 'shot send requested logged' ($null -ne $req)

    $placed = $diag2 | Select-String -Pattern 'shot placed on clipboard' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($placed) { $placed.Line.Trim() } else { '(no clipboard line)' }))
    Check 'screenshot put on the clipboard' ($null -ne $placed)

    $focus = $diag2 | Select-String -Pattern 'composer focus' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($focus) { $focus.Line.Trim() } else { '(no focus line)' }))
    Check 'composer focus found' ($null -ne $focus -and $focus.Line -notmatch '"none"')

    $imgCount = -1
    $countLine = $diag2 | Select-String -Pattern 'composer images after paste -> ' -SimpleMatch | Select-Object -Last 1
    if ($null -ne $countLine) {
        $mark = 'composer images after paste -> '
        $idx = $countLine.Line.IndexOf($mark)
        if ($idx -ge 0) {
            $tail = $countLine.Line.Substring($idx + $mark.Length).Trim()
            $num = ''
            foreach ($ch in $tail.ToCharArray()) {
                if ([char]::IsDigit($ch)) { $num += $ch } else { break }
            }
            if ($num.Length -gt 0) { $imgCount = [int]$num }
        }
    }
    Say ("composer images after paste={0}" -f $imgCount)
    Check 'the page accepted the pasted image' ($imgCount -ge 1)

    $sent = $diag2 | Select-String -Pattern 'prompt with image sent' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($sent) { $sent.Line.Trim() } else { '(no image send line)' }))
    Check 'prompt with image sent' ($null -ne $sent)

    $failed = $diag2 | Select-String -Pattern 'prompt with image failed' -SimpleMatch | Select-Object -Last 1
    if ($null -ne $failed) { Say ("diag: {0}" -f $failed.Line.Trim()) }
    Check 'no image send failure' ($null -eq $failed)

    $cfg = Read-Config
    $draft = ''
    try { $draft = [string]$cfg.assistant.customPrompt } catch { }
    Say ("config assistant.customPrompt length={0}" -f $draft.Length)
    Check 'edited prompt written back to config' ($draft.Contains('QDSHOTPROMPT'))

    # The draft must also reach the page as text next to the image. The char count
    # lives on the assistant line ("... sent to deepseek (27 chars, 400x200 px)"),
    # NOT on the "[shot] prompt with image sent (...)" line.
    $sentTo = $diag2 | Select-String -Pattern 'prompt with image sent to ' -SimpleMatch | Select-Object -Last 1
    if ($null -ne $sentTo) { Say ("diag: {0}" -f $sentTo.Line.Trim()) }
    if ($null -ne $sentTo) {
        Check 'send line carries the prompt length' ($sentTo.Line.Contains('(' + $promptText.Length + ' chars'))
    }
}
finally {
    if ($liveClip) { try { Set-Clipboard -Value $liveClip } catch { } }
    Restore-State
    Start-App | Out-Null
    Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
    Flush
}
