# Probe (2026-10-31, sixth round): the splitter band above the notes/clipboard/
# assistant area must be always visible (not only on hover) and must no longer
# draw the 44x3 center grip line.
#
# Method (pixel based, no "before" build needed):
#   1. Locate the tab row (TabNotes) via UIA to anchor the band's y range: the
#      splitter sits directly above it.
#   2. Scan only the ~40px window above the tab row. The band is the contiguous
#      run of rows whose colour is darker than the plain panel background.
#      (Scanning the whole window does not work: notes cards are darker than the
#      background too, so a full-window scan reports a bogus 700px "band".)
#   3. Assertions:
#      a) a run exists, ~10px tall        -> band is always visible
#      b) inside it, left == centre colour (delta <= 2)
#                                        -> the 44x3 grip line is gone
#      c) the tint is subtle (total delta 20..120 vs background)
#                                        -> it reads as a hint, not a divider
#
# ASCII only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_helpers.ps1')

function Shot([string]$path, [int[]]$r) {
    $w = $r[2] - $r[0]; $h = $r[3] - $r[1]
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r[0], $r[1], 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    return $bmp
}

function RowMean($bmp, [int]$y, [int]$x0, [int]$w) {
    $sumR = 0; $sumG = 0; $sumB = 0
    for ($x = $x0; $x -lt ($x0 + $w); $x++) {
        $c = $bmp.GetPixel($x, $y)
        $sumR += $c.R; $sumG += $c.G; $sumB += $c.B
    }
    return @([int]($sumR / $w), [int]($sumG / $w), [int]($sumB / $w))
}

try {
    Say '=== splitter-visible probe ==='
    Stop-App
    Backup-State
    Start-App | Out-Null
    Start-Sleep -Milliseconds 1500
    if (-not (Ensure-DrawerOpen)) { throw 'drawer did not open' }
    # park the cursor away from the splitter so IsMouseOver is false
    [U4]::MoveTo(1800, 950)
    Start-Sleep -Milliseconds 500

    $r = Get-DrawerRect
    Say ("window rect = " + ($r -join ','))
    $winW = $r[2] - $r[0]
    $winH = $r[3] - $r[1]

    $win = Get-DrawerWindow
    if ($null -eq $win) { throw 'UIA window not found' }
    $tab = Find-ById $win 'TabNotes'
    Check 'TabNotes found (anchor for the band)' ($null -ne $tab)
    if ($null -eq $tab) { throw 'cannot anchor the band without TabNotes' }
    $tabTop = [int]$tab.Current.BoundingRectangle.Y
    Say ('TabNotes top = ' + $tabTop)

    $png = Join-Path $PSScriptRoot 'splitter-visible.png'
    $bmp = Shot $png $r
    Say ('shot = ' + $png)

    # plain panel background: just below the band, i.e. 3px above the tab row
    $bgRef = RowMean $bmp ($tabTop - 3) 20 40
    Say ("panel background ref R={0} G={1} B={2}" -f $bgRef[0], $bgRef[1], $bgRef[2])

    $xLeft = 20
    $xMid = [int]($winW / 2) - 15

    # Scan only the 40px window above the tab row. The band must be the run
    # that ENDS at the tab row: scanning for "any darker row" also catches the
    # last path-area row (a folder icon can sit there), which inflated the band
    # to 37px on 2026-10-31. Walk upward from the tab row instead.
    $rows = @()
    for ($y = $tabTop - 40; $y -lt $tabTop; $y++) {
        $l = RowMean $bmp $y $xLeft 30
        $m = RowMean $bmp $y $xMid 30
        $darker = (($bgRef[0] - $l[0]) -ge 2) -or (($bgRef[1] - $l[1]) -ge 2) -or (($bgRef[2] - $l[2]) -ge 2)
        $rows += , @($y, $l[0], $l[1], $l[2], $m[0], $m[1], $m[2], $darker)
    }

    # contiguous run adjacent to the tab row (allow a 1px antialias gap)
    $bandRows = @()
    for ($i = $rows.Count - 1; $i -ge 0; $i--) {
        if (-not $rows[$i][7]) {
            if ($bandRows.Count -eq 0) { continue }   # skip antialias gap just above the tab row
            break
        }
        $bandRows = , $rows[$i] + $bandRows
    }
    Say ('band rows = ' + $bandRows.Count)
    foreach ($row in $rows) {
        Say ("  y={0,4} left=({1},{2},{3}) mid=({4},{5},{6}) band={7}" -f `
            $row[0], $row[1], $row[2], $row[3], $row[4], $row[5], $row[6], $row[7])
    }

    Check 'splitter band is always visible (tinted run above the tab row)' ($bandRows.Count -ge 6)

    if ($bandRows.Count -ge 6) {
        $top = $bandRows[0][0]
        $bot = $bandRows[$bandRows.Count - 1][0]
        $height = $bot - $top + 1
        Say ("band = y {0}..{1}, height {2}px (expected ~10)" -f $top, $bot, $height)
        Check 'splitter band height matches the 10px row' (($height -ge 8) -and ($height -le 13))

        $midY = [int](($top + $bot) / 2)
        $l = RowMean $bmp $midY $xLeft 30
        $m = RowMean $bmp $midY $xMid 30
        $dl = [math]::Abs($l[0] - $m[0]); $dg = [math]::Abs($l[1] - $m[1]); $db = [math]::Abs($l[2] - $m[2])
        Say ("band mid y={0} left R={1} G={2} B={3} / centre R={4} G={5} B={6} / delta {7},{8},{9}" -f `
            $midY, $l[0], $l[1], $l[2], $m[0], $m[1], $m[2], $dl, $dg, $db)

        # 2026-10-31: the panel background is only 96% opaque, so two columns at
        # different x pick up different desktop content behind the window -- the
        # raw left-vs-centre delta is never 0 even on a perfectly flat band.
        # Self-calibrate: measure the same pair of columns OUTSIDE the band and
        # subtract. What remains is the grip's own contribution.
        $refY = $top - 6
        if ($refY -lt 0) { $refY = $bot + 6 }
        $rl = RowMean $bmp $refY $xLeft 30
        $rm = RowMean $bmp $refY $xMid 30
        $bl = [math]::Abs($rl[0] - $rm[0]); $bg = [math]::Abs($rl[1] - $rm[1]); $bb = [math]::Abs($rl[2] - $rm[2])
        Say ("same pair outside the band at y={0}: delta {1},{2},{3}" -f $refY, $bl, $bg, $bb)

        $gl = $dl - $bl; $gg = $dg - $bg; $gb = $db - $bb
        Say ("grip contribution (band delta - reference delta) = {0},{1},{2}" -f $gl, $gg, $gb)
        Check 'the 44x3 centre grip line is gone (band is uniform across x)' (($gl -le 2) -and ($gg -le 2) -and ($gb -le 2))

        $bandDelta = [math]::Abs($bgRef[0] - $l[0]) + [math]::Abs($bgRef[1] - $l[1]) + [math]::Abs($bgRef[2] - $l[2])
        Say ('band vs panel background total delta = ' + $bandDelta + ' (expected 20..120)')
        Check 'band is a subtle tint, not a heavy divider' (($bandDelta -ge 20) -and ($bandDelta -le 120))

        # ---- the band must still work as a drag target now that it is visible
        $cfgBefore = Read-Json $configPath
        $hBefore = 0
        if ($cfgBefore -and $cfgBefore.layout) { $hBefore = [double]$cfgBefore.layout.pathAreaHeight }
        Say ('pathAreaHeight before drag = ' + $hBefore)

        $dragX = $r[0] + [int]($winW / 2)
        $dragY = $r[1] + $midY
        [U4]::MoveTo($dragX, $dragY)
        Start-Sleep -Milliseconds 200
        [U4]::LeftDown()
        Start-Sleep -Milliseconds 150
        for ($i = 1; $i -le 12; $i++) {
            [U4]::MoveTo($dragX, $dragY - [int](60 * $i / 12))
            Start-Sleep -Milliseconds 25
        }
        Start-Sleep -Milliseconds 150
        [U4]::LeftUp()
        Start-Sleep -Milliseconds 800

        $cfgAfter = Read-Json $configPath
        $hAfter = 0
        if ($cfgAfter -and $cfgAfter.layout) { $hAfter = [double]$cfgAfter.layout.pathAreaHeight }
        Say ("pathAreaHeight after drag = {0} (delta {1})" -f $hAfter, ($hAfter - $hBefore))
        Check 'the visible band still drags (pathAreaHeight changed)' ([math]::Abs($hAfter - $hBefore) -ge 20)
    }

    $bmp.Dispose()
    Say ("RESULT: " + $(if ($script:fail -eq 0) { 'PASS' } else { "FAIL ($script:fail)" }))
} catch {
    Say ('ERROR: ' + $_.Exception.Message)
    Say ('RESULT: FAIL (exception)')
} finally {
    Flush
    Restore-State
    Stop-App
}
