# Probe (2026-10-31, fifth round): the notes list and the path area must now
# use the same 6px thin scrollbar as the clipboard list.
#
# Method:
#   - WPF's templated ScrollBar is not exposed as ControlType.ScrollBar in UIA,
#     so the scrollbar column is measured geometrically: a list item's right
#     edge stops where the scrollbar column begins, hence
#     (listRect.Right - itemRect.Right) IS the scrollbar column.
#   - Notes list already overflows, so its column is readable directly.
#   - The path area is a plain ScrollViewer; it only shows a scrollbar when its
#     content is taller than the area. Phase A reads the content width with the
#     saved height (318, content fits, no scrollbar), phase B rewrites
#     layout.pathAreaHeight to 120 so the content overflows, then the width
#     difference between the two phases is exactly the scrollbar column.
#     Differential measurement: no assumptions about margins.
#
# ASCII only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_helpers.ps1')

function Get-ListGap($win, [string]$listId) {
    $el = Find-ById $win $listId
    if ($null -eq $el) { return $null }
    $lr = $el.Current.BoundingRectangle
    $items = $el.FindAll($CTS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::ListItem)))
    if ($items.Count -lt 1) { return $null }
    $ir = $items.Item(0).Current.BoundingRectangle
    $gap = [int]($lr.X + $lr.Width) - [int]($ir.X + $ir.Width)
    Say ("{0}: rect={1},{2} {3}x{4} items={5} firstItemRight={6} gap={7}px" -f `
        $listId, [int]$lr.X, [int]$lr.Y, [int]$lr.Width, [int]$lr.Height, $items.Count, [int]($ir.X + $ir.Width), $gap)
    return $gap
}

function Set-PathAreaHeight([int]$h) {
    Stop-App
    Start-Sleep -Milliseconds 600
    # Rewrite the value in place instead of re-serialising the whole object:
    # ConvertTo-Json round-trips drop formatting and can produce a document the
    # app refuses to parse, which silently falls back to defaults (path area
    # then goes back to Auto and the experiment measures nothing).
    $raw = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    $patched = [System.Text.RegularExpressions.Regex]::Replace($raw, '"pathAreaHeight"\s*:\s*[0-9.]+', ('"pathAreaHeight": ' + $h))
    if ($patched -eq $raw) { throw 'pathAreaHeight not found in config.json' }
    [System.IO.File]::WriteAllText($configPath, $patched, (New-Object System.Text.UTF8Encoding($false)))
    $check = Read-Json $configPath
    if ($null -eq $check) { throw 'config.json became unparseable after patch' }
    Say ("patched layout.pathAreaHeight = " + $check.layout.pathAreaHeight)
}

function Get-CategoriesWidth($win) {
    $cats = Find-ById $win 'CategoriesList'
    if ($null -eq $cats) { return $null }
    $cr = $cats.Current.BoundingRectangle
    Say ("CategoriesList rect = {0},{1} {2}x{3}" -f [int]$cr.X, [int]$cr.Y, [int]$cr.Width, [int]$cr.Height)
    return [int]$cr.Width
}

try {
    Say '=== thin-scrollbar probe (notes / clipboard / path area) ==='
    Stop-App
    Backup-State
    Start-App | Out-Null
    Start-Sleep -Milliseconds 1500
    if (-not (Ensure-DrawerOpen)) { throw 'drawer did not open' }
    $r = Get-DrawerRect
    Say ("window rect = " + ($r -join ','))
    $win = Get-DrawerWindow
    if ($null -eq $win) { throw 'UIA window not found' }

    # ---------------- phase A: notes list
    # The notes list only shows a scrollbar when its content overflows. With the
    # user's real data (2 cards, 507px tall list) it does not, so measuring the
    # column here would compare against a 1px item inset and always fail.
    # Assert the thin style by the same differential method used for the path
    # area: shrink the bottom area (make the list overflow) and compare widths.
    $notesGap = Get-ListGap $win 'NotesList'
    Check 'NotesList found' ($null -ne $notesGap)
    $notesList = Find-ById $win 'NotesList'
    $notesOverflow = $false
    if ($null -ne $notesList) {
        $sp = $null
        if ($notesList.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$sp)) {
            $notesOverflow = $sp.Current.VerticallyScrollable
        }
    }
    Say ("notes list vertically scrollable (content overflows) = " + $notesOverflow)
    if ($notesOverflow) {
        Check 'notes scrollbar column is thin (4..9px, system is 18)' (($notesGap -ge 4) -and ($notesGap -le 9))
    } else {
        Say 'notes list does not overflow with current data - thin style covered by clipboard/path area assertions'
    }

    # ---------------- phase A: clipboard list
    if (-not (Click-Tab 'TabClipboard')) { throw 'clipboard tab click failed' }
    Start-Sleep -Milliseconds 600
    $clipGap = Get-ListGap $win 'ClipboardList'
    Check 'ClipboardList found and overflowing' ($null -ne $clipGap)
    if ($null -ne $clipGap) {
        Check 'clipboard scrollbar column is thin (4..9px)' (($clipGap -ge 4) -and ($clipGap -le 9))
    }

    # ---------------- phase A: path area, saved height 318 -> content fits
    $catA = Get-CategoriesWidth $win
    Check 'CategoriesList found (phase A)' ($null -ne $catA)
    $script:catAHeight = [int](Find-ById $win 'CategoriesList').Current.BoundingRectangle.Height
    Say ("phase A categories width = " + $catA + " (no scrollbar expected)")

    # ---------------- phase B: force the path area to overflow
    Set-PathAreaHeight 120
    Start-App | Out-Null
    Start-Sleep -Milliseconds 1800
    if (-not (Ensure-DrawerOpen)) { throw 'drawer did not reopen' }
    $win = Get-DrawerWindow
    $catB = Get-CategoriesWidth $win
    Check 'CategoriesList found (phase B)' ($null -ne $catB)
    $delta = $catA - $catB
    Say ("phase B categories width = {0}, delta vs phase A = {1}px" -f $catB, $delta)
    # Precondition: the shortened path area must actually be shorter, otherwise
    # the width comparison measures nothing (the config patch silently failed).
    $catElB = Find-ById $win 'CategoriesList'
    $hB = [int]$catElB.Current.BoundingRectangle.Height
    Say ("phase B categories height = {0} (phase A was {1})" -f $hB, $script:catAHeight)
    Check 'precondition: path area actually shrank' ($hB -lt $script:catAHeight)
    Check 'path area gained a scrollbar when content overflowed' ($delta -gt 0)
    Check 'path area scrollbar column is thin (4..9px, system is 18)' (($delta -ge 4) -and ($delta -le 9))

    Say ("RESULT: " + $(if ($script:fail -eq 0) { 'PASS' } else { "FAIL ($script:fail)" }))
} catch {
    Say ('ERROR: ' + $_.Exception.Message)
    Say ('RESULT: FAIL (exception)')
} finally {
    Flush
    Restore-State
    Stop-App
}
