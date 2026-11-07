# Probe (2026-10-31): verify the bottom area (notes / clipboard / assistant)
# lost its translucent "glass" backdrop, gained 16px of content width, and that
# the clipboard list now uses a 6px scrollbar instead of the 17px system one.
#
# Method:
#   - The whole drawer is one Border painted with PanelBackground. Before the
#     change the bottom area added a second layer (SectionBackground, ~10% white
#     in dark mode) plus 8px padding. So an 8px-tall strip just above the bottom
#     edge of that area was the glass colour, while the 6px strip at the window's
#     left margin was plain PanelBackground. Comparing those two strips proves
#     the extra layer is gone without needing a "before" build.
#   - Content width is read from UIA bounding rectangles (NotesList, the
#     assistant WebView2 host) and compared against the window width.
#   - The scrollbar width comes from UIA too (ScrollBar element), which is the
#     real layout width, not a pixel guess.
#
# ASCII only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_helpers.ps1')
$resultPath = Join-Path $PSScriptRoot 'panel-flat-result.txt'

# System.Drawing + UIAutomationClient/Types are already loaded by _helpers.ps1

function Shot([string]$path, [int[]]$r) {
    $w = $r[2] - $r[0]; $h = $r[3] - $r[1]
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r[0], $r[1], 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Region([int]$x, [int]$y, [int]$w, [int]$h) {
    return (Get-RegionStats ([pscustomobject]@{ X = $x; Y = $y; Width = $w; Height = $h }))
}

try {
    Say '=== panel-flat probe ==='
    # Backup BEFORE starting the app. Backup-State retries the clipboard copy
    # (the app rewrites clipboard.json mid-flight) and throws rather than
    # silently continuing without it.
    Stop-App
    Backup-State
    Start-App | Out-Null
    Start-Sleep -Milliseconds 1200

    if (-not (Ensure-DrawerOpen)) { throw 'drawer did not open' }
    $r = Get-DrawerRect
    Say ("window rect = " + ($r -join ','))
    $winW = $r[2] - $r[0]
    $winH = $r[3] - $r[1]
    Say ("window size = {0}x{1}" -f $winW, $winH)

    $win = Get-DrawerWindow
    if ($null -eq $win) { throw 'UIA window not found' }

    # ---------------- 1. background: bottom area == panel background
    # The window is translucent (PanelBackground is 96% opaque), so absolute
    # colours drift with whatever desktop sits behind each x. Compare two strips
    # at the SAME x, 10px apart vertically instead: y = bottom-4 used to be the
    # 8px padding ring (plain panel in both builds), y = bottom-14 used to be
    # inside the glass border. Desktop bleed-through varies smoothly over 10px,
    # so an unchanged build gives ~0 and the old glass layer gave ~20 (8% black
    # in light theme / 10% white in dark).
    $x0 = $r[0] + 60
    $plain = Region $x0 ($r[3] - 10) 60 6
    $inner = Region $x0 ($r[3] - 20) 60 6
    Say ("plain strip R={0} G={1} B={2}" -f $plain.R, $plain.G, $plain.B)
    Say ("inner strip R={0} G={1} B={2}" -f $inner.R, $inner.G, $inner.B)
    $dr = [math]::Abs($plain.R - $inner.R)
    $dg = [math]::Abs($plain.G - $inner.G)
    $db = [math]::Abs($plain.B - $inner.B)
    Say ("delta R={0} G={1} B={2}" -f $dr, $dg, $db)
    Check 'bottom-area background matches panel background (no glass layer)' (($dr -le 5) -and ($dg -le 5) -and ($db -le 5))

    # ---------------- 2. notes list got the 16px back
    $notesList = Find-ById $win 'NotesList'
    Check 'NotesList found' ($null -ne $notesList)
    if ($null -ne $notesList) {
        $nr = $notesList.Current.BoundingRectangle
        Say ("NotesList rect = {0},{1} {2}x{3}" -f [int]$nr.X, [int]$nr.Y, [int]$nr.Width, [int]$nr.Height)
        Say ("NotesList width vs window {0} vs {1}" -f [int]$nr.Width, $winW)
        Check 'NotesList spans full panel width (16px margins only)' ([int]$nr.Width -ge ($winW - 18))
    }
    Shot (Join-Path $PSScriptRoot 'panel-flat-notes.png') $r

    # ---------------- 3. clipboard: thin scrollbar
    if (-not (Click-Tab 'TabClipboard')) { throw 'clipboard tab click failed' }
    Start-Sleep -Milliseconds 600

    # WPF's templated ScrollBar is NOT exposed as a ControlType.ScrollBar element
    # in the UIA tree (verified: Find-All-Of returns 0 even with the default
    # template), so its width cannot be read directly. Measure it geometrically
    # instead: the list item's right edge stops where the scrollbar column
    # begins, so (listRect.Right - itemRect.Right) IS the scrollbar column.
    # A system 17px scrollbar leaves >= 18px there (17 + 1px item inset).
    $clipList = Find-ById $win 'ClipboardList'
    Check 'ClipboardList found' ($null -ne $clipList)
    if ($null -ne $clipList) {
        $lr = $clipList.Current.BoundingRectangle
        $items = $clipList.FindAll($CTS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::ListItem)))
        Say ("clipboard list rect = {0},{1} {2}x{3}" -f [int]$lr.X, [int]$lr.Y, [int]$lr.Width, [int]$lr.Height)
        Say ("clipboard list items = " + $items.Count)
        Check 'clipboard history intact (>= 10 items)' ($items.Count -ge 10)

        if ($items.Count -ge 1) {
            $ir = $items.Item(0).Current.BoundingRectangle
            $gap = [int]($lr.X + $lr.Width) - [int]($ir.X + $ir.Width)
            Say ("item right edge = {0}, list right edge = {1}, scrollbar column = {2}px (system default is 17+1)" -f `
                [int]($ir.X + $ir.Width), [int]($lr.X + $lr.Width), $gap)
            Check 'clipboard scrollbar column <= 9px' ($gap -le 9)
        }

        # and it still scrolls
        try {
            $sp = $clipList.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
            $before = $sp.Current.VerticalScrollPercent
            # Scroll(horizontalAmount, verticalAmount) -- order matters.
            $sp.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, [System.Windows.Automation.ScrollAmount]::LargeIncrement)
            Start-Sleep -Milliseconds 500
            $after = $sp.Current.VerticalScrollPercent
            Say ("scroll percent {0} -> {1}" -f [math]::Round($before, 1), [math]::Round($after, 1))
            Check 'clipboard list still scrolls with the custom scrollbar' ($after -gt $before)
            $sp.SetScrollPercent(-1, 0)
            Start-Sleep -Milliseconds 300
        } catch {
            Say ('scroll pattern failed: ' + $_.Exception.Message)
            Check 'clipboard list still scrolls with the custom scrollbar' $false
        }
    }
    Shot (Join-Path $PSScriptRoot 'panel-flat-clipboard.png') $r

    # ---------------- 4. assistant page width + zoom still wired
    if (-not (Click-Tab 'TabAssistant')) { throw 'assistant tab click failed' }
    Start-Sleep -Milliseconds 2500
    $view = $null
    $views = Find-All-Of $win $CTL::Pane
    foreach ($v in $views) {
        $id = $v.Current.AutomationId
        if ($id -and $id.StartsWith('AssistantView:')) { $view = $v }
    }
    Check 'assistant WebView2 host found' ($null -ne $view)
    if ($null -ne $view) {
        $vr = $view.Current.BoundingRectangle
        Say ("assistant view rect = {0},{1} {2}x{3}" -f [int]$vr.X, [int]$vr.Y, [int]$vr.Width, [int]$vr.Height)
        Check 'assistant page spans full panel width' ([int]$vr.Width -ge ($winW - 18))
    }
    Shot (Join-Path $PSScriptRoot 'panel-flat-assistant.png') $r

    Say ("RESULT: " + $(if ($script:fail -eq 0) { 'PASS' } else { "FAIL ($script:fail)" }))
} catch {
    Say ('ERROR: ' + $_.Exception.Message)
    Say ('RESULT: FAIL (exception)')
} finally {
    Flush
    Restore-State
    Stop-App
}
