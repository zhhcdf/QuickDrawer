# Verify that SelectionCapture.SnapshotClipboard + RestoreClipboard preserve a Word table.
#
# This is the regression test for the fix in probe/_fix7_snapshot_rich.py: before it, a
# selection capture while a Word table sat on the clipboard left only plain text behind,
# so pasting into Word/Excel produced a paragraph instead of a table.
#
# We call the REAL internal methods of the shipped assembly via reflection, on an STA
# thread (WPF Clipboard requires STA), so this exercises the production code path and not
# a re-implementation.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }
$asm = [Reflection.Assembly]::LoadFrom($exe)
$type = $asm.GetType('QuickDrawer.Selection.SelectionCapture')
if ($type -eq $null) { Write-Host 'FAIL: type not found'; exit 1 }

$flags = [Reflection.BindingFlags]'NonPublic,Static'
$snapM   = $type.GetMethod('SnapshotClipboard',   $flags)
$restoreM = $type.GetMethod('RestoreClipboard',   $flags)
$readRawM = $type.GetMethod('ReadRawFormat',      $flags)
if ($snapM -eq $null -or $restoreM -eq $null) { Write-Host 'FAIL: methods not found'; exit 1 }

# Register the clipboard formats so ReadRawFormat gets the right ids.
$regType = $asm.GetType('QuickDrawer.Native.NativeMethods')
$htmlId = [uint32]$regType::HtmlFormat
$rtfId  = [uint32]$regType::RtfFormat
Write-Host ("htmlId=$htmlId rtfId=$rtfId")

$script = {
    param($snapM, $restoreM, $type, $htmlId)

    # Read a custom clipboard format as RAW BYTES through Win32. Going through
    # Clipboard.GetData('HTML Format') is wrong here: WPF decodes the MemoryStream we put
    # back into a String, so we cannot inspect the byte offsets that Word actually needs.
    if (-not ('RawClip' -as [type])) {
        Add-Type -Namespace '' -Name 'RawClip' -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern bool OpenClipboard(IntPtr h);
[DllImport("user32.dll", SetLastError=true)] public static extern bool CloseClipboard();
[DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetClipboardData(uint f);
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GlobalLock(IntPtr h);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GlobalUnlock(IntPtr h);
[DllImport("kernel32.dll", SetLastError=true)] public static extern UIntPtr GlobalSize(IntPtr h);
'@
    }

    function Read-Raw([uint32]$fmt) {
        if (-not [RawClip]::OpenClipboard([IntPtr]::Zero)) { return $null }
        try {
            $h = [RawClip]::GetClipboardData($fmt)
            if ($h -eq [IntPtr]::Zero) { return $null }
            # GlobalSize returns UIntPtr; PowerShell cannot cast UIntPtr straight to int.
            $size = [int]([RawClip]::GlobalSize($h).ToUInt64())
            if ($size -le 0) { return $null }
            $p = [RawClip]::GlobalLock($h)
            if ($p -eq [IntPtr]::Zero) { return $null }
            try {
                $buf = New-Object byte[] $size
                [Runtime.InteropServices.Marshal]::Copy($p, $buf, 0, $size)
                return $buf
            } finally { [void][RawClip]::GlobalUnlock($h) }
        } finally { [void][RawClip]::CloseClipboard() }
    }

    $word = $null
    $doc  = $null
    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false
        $word.DisplayAlerts = 0
        $doc = $word.Documents.Add()
        $tbl = $doc.Tables.Add($doc.Content, 2, 2)
        $tbl.Cell(1,1).Range.Text = 'A1'
        $tbl.Cell(1,2).Range.Text = 'B1'
        $tbl.Cell(2,1).Range.Text = 'A2'
        $tbl.Cell(2,2).Range.Text = 'B2'
        $tbl.Range.Copy()
        Start-Sleep -Milliseconds 1500

        $before = [System.Windows.Forms.Clipboard]::GetDataObject().GetFormats()
        Write-Host ('before formats: ' + ($before -join ','))

        # --- production snapshot + restore ---
        $snap = $snapM.Invoke($null, @())
        if ($snap -eq $null) { Write-Host 'FAIL: snapshot returned null'; return }
        $snapType = $snap.GetType()
        $htmlProp = $snapType.GetProperty('Html')
        $rtfProp  = $snapType.GetProperty('Rtf')
        $html = $htmlProp.GetValue($snap)
        $rtf  = $rtfProp.GetValue($snap)
        Write-Host ('snapshot html bytes = ' + $(if ($html -eq $null) { 'null' } else { $html.Length }))
        Write-Host ('snapshot rtf  bytes = ' + $(if ($rtf  -eq $null) { 'null' } else { $rtf.Length }))

        # previousText arg is the 2nd parameter; pass the current clipboard text
        $prev = [System.Windows.Clipboard]::GetText()
        $restoreM.Invoke($null, @($snap, $prev)) | Out-Null
        Start-Sleep -Milliseconds 500

        $after = [System.Windows.Clipboard]::GetDataObject().GetFormats()
        Write-Host ('after  formats: ' + ($after -join ','))

        $ok = $true
        if (-not ($after -contains 'HTML Format'))      { Write-Host 'FAIL: HTML Format lost'; $ok = $false }
        if (-not ($after -contains 'Rich Text Format')) { Write-Host 'FAIL: Rich Text Format lost'; $ok = $false }

        # The HTML must still contain the table markup, with valid byte offsets.
        $bytes = Read-Raw $htmlId
        if ($bytes -eq $null) {
            Write-Host 'FAIL: HTML Format not readable as raw bytes'
            $ok = $false
        }
        else {
            $s = [Text.Encoding]::UTF8.GetString($bytes)
            $hasTable = $s.IndexOf('<table', [StringComparison]::OrdinalIgnoreCase) -ge 0
            Write-Host ('html bytes = ' + $bytes.Length + ' hasTable=' + $hasTable)
            if (-not $hasTable) { Write-Host 'FAIL: table markup lost'; $ok = $false }

            # Validate the header offsets against the actual payload length.
            $m = [regex]::Match($s, 'StartHTML:(\d+)\r\nEndHTML:(\d+)\r\nStartFragment:(\d+)\r\nEndFragment:(\d+)')
            if (-not $m.Success) { Write-Host 'FAIL: header offsets unparsable'; $ok = $false }
            else {
                $sh = [int]$m.Groups[1].Value; $eh = [int]$m.Groups[2].Value
                $sf = [int]$m.Groups[3].Value; $ef = [int]$m.Groups[4].Value
                Write-Host ("offsets StartHTML=$sh EndHTML=$eh StartFragment=$sf EndFragment=$ef len=$($bytes.Length)")
                if ($eh -gt $bytes.Length) { Write-Host 'FAIL: EndHTML beyond payload'; $ok = $false }
                if ($sf -lt $sh -or $ef -gt $eh) { Write-Host 'FAIL: fragment offsets inconsistent'; $ok = $false }
                if ($sf -ge $ef) { Write-Host 'FAIL: empty fragment'; $ok = $false }
            }
        }

        if ($ok) { Write-Host 'PASS: selection capture snapshot/restore preserves the Word table' }
    }
    finally {
        if ($doc  -ne $null) { try { $doc.Close(0) } catch {} }
        if ($word -ne $null) { try { $word.Quit(0) } catch {} }
    }
}

# Run the whole thing on an STA thread.
Add-Type -AssemblyName System.Windows.Forms
$ps = [PowerShell]::Create()
$null = $ps.AddScript($script.ToString())
$null = $ps.AddArgument($snapM)
$null = $ps.AddArgument($restoreM)
$null = $ps.AddArgument($type)
$null = $ps.AddArgument($htmlId)
$handle = $ps.Runspace = [RunspaceFactory]::CreateRunspace()
$ps.Runspace.ApartmentState = 'STA'
$ps.Runspace.Open()
$async = $ps.BeginInvoke()
$ps.EndInvoke($async)
$ps.Streams.Information | ForEach-Object { Write-Host $_.MessageData }
$ps.Streams.Error | ForEach-Object { Write-Host ('ERROR: ' + $_) }
$ps.Dispose()
