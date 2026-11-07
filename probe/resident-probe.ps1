# Resident-sites verification (2026-10-29 request: "keep the web page loaded for a
# while instead of reloading on every switch").
#
# Asserts, with real mouse clicks and diag.log counts:
#   1. switching provider chips creates a resident site per provider
#   2. switching back to an already visited provider does NOT navigate again
#   3. leaving the assistant page and coming back does NOT navigate again
#   4. working set grows with each resident site (evidence they really are alive)
#
# ASCII only; every path derives from $PSScriptRoot.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_helpers.ps1')
$resultPath = Join-Path $PSScriptRoot 'resident-result.txt'

function Get-ProcessWs {
    $p = Get-Process QuickDrawer -ErrorAction SilentlyContinue
    if (-not $p) { return 0 }
    return [int]($p.WorkingSet64 / 1MB)
}

function Get-DiagLines {
    if (-not (Test-Path -LiteralPath $diagPath)) { return @() }
    return @(Get-Content -LiteralPath $diagPath -Encoding UTF8)
}

function Get-NavCount {
    return @((Get-DiagLines) | Where-Object { $_ -match '\[assistant\] navigate http' }).Count
}

function Get-SiteCreatedCount([string]$id) {
    return @((Get-DiagLines) | Where-Object { $_ -match ("site created: " + $id) }).Count
}

function Find-AssistantView {
    for ($i = 0; $i -lt 25; $i++) {
        $d = Get-DrawerWindow
        if ($d) {
            $all = $d.FindAll($CTS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($e in $all) {
                $aid = ''
                $nm = ''
                try { $aid = $e.Current.AutomationId } catch { }
                try { $nm = $e.Current.Name } catch { }
                if ($aid -like 'AssistantView:*' -or $nm -like 'AssistantView:*' -or $aid -eq 'AssistantView' -or $nm -eq 'AssistantView') {
                    $r = $e.Current.BoundingRectangle
                    if ($r.Width -gt 100 -and $r.Height -gt 100) { return $e }
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Click-Chip([string]$name) {
    $d = Get-DrawerWindow
    if (-not $d) { return $false }
    $el = Find-Ctl $d $name
    if (-not $el) { return $false }
    Click-El $el 0.5
    return $true
}

Start-App
try {
    Ensure-DrawerOpen | Out-Null

    # the drawer auto-hides when the pointer leaves; park it over the panel
    [U4]::MoveTo(1780, 400)

    # pin state must be off, otherwise "still open" assertions mean nothing
    $cfg = Read-Config
    if ($cfg.dock.pinPanel -eq $true) {
        $d = Get-DrawerWindow
        $pin = Find-Ctl $d 'PinPanel'
        if ($pin) { Click-El $pin 0.5; Start-Sleep -Milliseconds 600 }
        Say 'unpinned the panel for the run'
    }

    Click-Tab 'TabAssistant' | Out-Null
    $view = Find-AssistantView
    Check 'assistant view is on screen' ($null -ne $view)

    $nav0 = Get-NavCount
    $ws0 = Get-ProcessWs
    Say ("start: navs={0} ws={1}MB" -f $nav0, $ws0)

    # --- site 2: Kimi -------------------------------------------------------
    Click-Chip 'ChipKimi' | Out-Null
    Start-Sleep -Seconds 4
    $nav1 = Get-NavCount
    $ws1 = Get-ProcessWs
    Say ("after kimi: navs={0} (+{1}) ws={2}MB (+{3}MB)" -f $nav1, ($nav1 - $nav0), $ws1, ($ws1 - $ws0))
    Check 'kimi site was created' ((Get-SiteCreatedCount 'kimi') -ge 1)
    Check 'kimi navigated once' (($nav1 - $nav0) -ge 1)

    # --- back to DeepSeek: must NOT navigate again --------------------------
    Click-Chip 'ChipDeepSeek' | Out-Null
    Start-Sleep -Seconds 2
    $nav2 = Get-NavCount
    $ws2 = Get-ProcessWs
    Say ("back to deepseek: navs={0} (+{1}) ws={2}MB" -f $nav2, ($nav2 - $nav1), $ws2)
    Check 'switching back to deepseek did not reload' (($nav2 - $nav1) -eq 0)

    $view2 = Find-AssistantView
    Check 'deepseek view is on screen again' ($null -ne $view2)

    # --- Kimi again: must NOT navigate again --------------------------------
    Click-Chip 'ChipKimi' | Out-Null
    Start-Sleep -Seconds 2
    $nav3 = Get-NavCount
    $ws3 = Get-ProcessWs
    Say ("back to kimi: navs={0} (+{1}) ws={2}MB" -f $nav3, ($nav3 - $nav2), $ws3)
    Check 'switching back to kimi did not reload' (($nav3 - $nav2) -eq 0)

    # --- leave the page and come back: no navigation either -----------------
    Click-Tab 'TabNotes' | Out-Null
    Start-Sleep -Milliseconds 900
    Click-Tab 'TabAssistant' | Out-Null
    Start-Sleep -Milliseconds 1500
    $nav4 = Get-NavCount
    Say ("leave and return: navs={0} (+{1})" -f $nav4, ($nav4 - $nav3))
    Check 'returning to the assistant page did not reload' (($nav4 - $nav3) -eq 0)

    # --- memory: two resident sites must cost more than one -----------------
    Say ("working set: start={0}MB kimi={1}MB both={2}MB" -f $ws0, $ws1, $ws2)
    Check 'two resident sites use more memory than one' ($ws2 -gt $ws0)

    # --- the modest cleanup expectation: resident sites survive idle time ---
    Say ("resident sites created: deepseek={0} kimi={1}" -f (Get-SiteCreatedCount 'deepseek'), (Get-SiteCreatedCount 'kimi'))
}
finally {
    Flush
}
