# Verify the SHIPPED WriteBack implementation for Html/Rtf.
#
# Loads the real QuickDrawer.exe assembly and calls ClipboardService.WriteBack,
# then parses the resulting "HTML Format" payload back out and checks that the
# StartFragment/EndFragment offsets actually point at the fragment. Getting those
# offsets wrong makes Word silently paste plain text, which is exactly the bug
# being fixed -- so they must be validated, not assumed.
#
# 2026-11-07 regression: WriteBack used to publish ONLY the rich format, so
# Notepad / browser inputs / chat boxes pasted nothing while Word was fine.
# The script therefore also asserts that CF_UNICODETEXT is present and carries
# the full text -- checking only the CF_HTML offsets is what let the bug ship.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }
$asm = [System.Reflection.Assembly]::LoadFrom($exe)
$svc = $asm.GetType('QuickDrawer.ClipboardService')
$entryType = $asm.GetType('QuickDrawer.ClipEntry')
$kindType = $asm.GetType('QuickDrawer.ClipKind')

Write-Host ("assembly loaded: {0}" -f $asm.FullName)
Write-Host ("ClipboardService: {0}" -f $svc.FullName)

# ---- build a ClipEntry with Kind=Html -------------------------------------
$entry = [System.Activator]::CreateInstance($entryType)
$entry.Kind = [System.Enum]::Parse($kindType, 'Html')
$entry.Text = '<table border=1><tr><td>A1</td><td>B1</td></tr><tr><td>A2</td><td>B2</td></tr></table>'
$entry.Preview = 'A1 B1 A2 B2'
# PlainText 留空：这是历史条目（本次修复之前存盘的那些）的真实形态，
# 写回时必须从 HTML 现场反推出纯文本，否则老历史仍然粘不出来。
# 旧版本的程序集没有这个属性（正是待验证的 bug），所以按存在性赋值，
# 让本脚本也能对着旧 exe 跑出 FAIL，而不是在这里抛异常。
if ($entryType.GetProperty('PlainText')) {
    $entry.PlainText = $null
}

$ok = $svc::WriteBack($entry)
Write-Host ("WriteBack(Html) returned: {0}" -f $ok)

if (-not $ok) {
    Write-Host 'RESULT: FAIL (WriteBack returned false)' -ForegroundColor Red
    exit 1
}

# ---- read it back and validate the offsets --------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClipHtml {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern uint RegisterClipboardFormatW(string f);
    [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint f);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern UIntPtr GlobalSize(IntPtr h);

    public static string Read() {
        uint id = RegisterClipboardFormatW("HTML Format");
        if (id == 0) return null;
        if (!OpenClipboard(IntPtr.Zero)) return null;
        try {
            IntPtr h = GetClipboardData(id);
            if (h == IntPtr.Zero) return null;
            IntPtr p = GlobalLock(h);
            if (p == IntPtr.Zero) return null;
            try {
                int size = (int)GlobalSize(h);
                byte[] buf = new byte[size];
                Marshal.Copy(p, buf, 0, size);
                int n = Array.IndexOf(buf, (byte)0);
                if (n < 0) n = size;
                return System.Text.Encoding.UTF8.GetString(buf, 0, n);
            } finally { GlobalUnlock(h); }
        } finally { CloseClipboard(); }
    }

    // CF_UNICODETEXT (13). This is what every non-rich target reads, so its
    // presence is the actual user-facing fix -- offsets mean nothing if only
    // Word can see the payload.
    public static string ReadPlainText() {
        if (!OpenClipboard(IntPtr.Zero)) return null;
        try {
            IntPtr h = GetClipboardData(13);
            if (h == IntPtr.Zero) return null;
            IntPtr p = GlobalLock(h);
            if (p == IntPtr.Zero) return null;
            try { return Marshal.PtrToStringUni(p); }
            finally { GlobalUnlock(h); }
        } finally { CloseClipboard(); }
    }
}
'@

$payload = [ClipHtml]::Read()
if (-not $payload) {
    Write-Host 'RESULT: FAIL (could not read HTML Format back)' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '--- raw payload (first 400 chars) ---'
Write-Host $payload.Substring(0, [Math]::Min(400, $payload.Length))
Write-Host '--- end ---'
Write-Host ''

function Get-Offset([string]$s, [string]$name) {
    $m = [regex]::Match($s, "$name`:(\d+)")
    if (-not $m.Success) { return -1 }
    return [int]$m.Groups[1].Value
}

$startHtml = Get-Offset $payload 'StartHTML'
$endHtml   = Get-Offset $payload 'EndHTML'
$startFrag = Get-Offset $payload 'StartFragment'
$endFrag   = Get-Offset $payload 'EndFragment'

Write-Host ("StartHTML={0} EndHTML={1} StartFragment={2} EndFragment={3}" -f `
    $startHtml, $endHtml, $startFrag, $endFrag)
Write-Host ("payload UTF-8 byte length = {0}" -f ([System.Text.Encoding]::UTF8.GetByteCount($payload)))

$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$checks = @()

# 1. StartHTML must land on the body (right after the blank line).
$headEnd = $bytes.Length
$idx = 0
for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
    if ($bytes[$i] -eq 13 -and $bytes[$i+1] -eq 10) {
        if ($i + 3 -lt $bytes.Length -and $bytes[$i+2] -eq 13 -and $bytes[$i+3] -eq 10) {
            $headEnd = $i + 4
            break
        }
    }
}
$checks += ,@('StartHTML == header end', ($startHtml -eq $headEnd), "start=$startHtml headEnd=$headEnd")

# 2. StartFragment must point at the character right after <!--StartFragment-->.
$marker = '<!--StartFragment-->'
$markerBytePos = -1
$accum = 0
$s = $payload
$pos = $s.IndexOf($marker)
if ($pos -ge 0) {
    $markerBytePos = [System.Text.Encoding]::UTF8.GetByteCount($s.Substring(0, $pos)) + $marker.Length
}
$checks += ,@('StartFragment == after <!--StartFragment-->', ($startFrag -eq $markerBytePos), "startFrag=$startFrag expected=$markerBytePos")

# 3. The bytes between StartFragment and EndFragment must be the original table.
if ($startFrag -ge 0 -and $endFrag -gt $startFrag -and $endFrag -le $bytes.Length) {
    $fragBytes = $bytes[$startFrag..($endFrag-1)]
    $frag = [System.Text.Encoding]::UTF8.GetString($fragBytes)
    $checks += ,@('fragment content round-trips', ($frag -eq $entry.Text), "frag=$($frag.Substring(0,[Math]::Min(60,$frag.Length)))")
} else {
    $checks += ,@('fragment offsets in range', $false, "start=$startFrag end=$endFrag len=$($bytes.Length)")
}

# 4. EndHTML must equal the total byte length.
$checks += ,@('EndHTML == payload length', ($endHtml -eq $bytes.Length), "endHtml=$endHtml len=$($bytes.Length)")

# 5. The 2026-11-07 regression: CF_UNICODETEXT must accompany the rich format.
#    Without it Notepad / browser inputs / chat boxes paste NOTHING (Word is the
#    only common app that reads CF_HTML). Offsets above can all be perfect while
#    this is missing -- that combination is exactly what shipped.
$plainRaw = [ClipHtml]::ReadPlainText()
$hasPlain = -not [string]::IsNullOrEmpty($plainRaw)
$checks += ,@('CF_UNICODETEXT present', $hasPlain, $(if ($hasPlain) { "$($plainRaw.Length) chars" } else { 'MISSING - only Word could paste this' }))

if ($hasPlain) {
    # 6. It must be the FULL text, not the 200-char list preview.
    $entryPreview = $entry.Preview
    $isPreviewOnly = ($plainRaw.Trim() -eq $entryPreview.Trim())
    $checks += ,@('plain text is not the preview', (-not $isPreviewOnly), "plain='$($plainRaw -replace "`r",'\r' -replace "`n",'\n' -replace "`t",'\t' -replace "`0",'' )'")

    # 7. It must be plain text, not the HTML fragment passed through.
    $noTags = ($plainRaw -notmatch '<[a-zA-Z/!]')
    $checks += ,@('plain text has no markup', $noTags, "contains '<' tags: $(-not $noTags)")

    # 8. Derived from HTML: table cells -> TAB, rows -> CRLF, no trailing newline.
    $expectedPlain = "A1`tB1`r`nA2`tB2"
    $checks += ,@('derived text is TAB/CRLF joined', ($plainRaw -eq $expectedPlain), "expected='$($expectedPlain -replace "`t",'\t' -replace "`r",'\r' -replace "`n",'\n' )'")
}

Write-Host ''
$allOk = $true
foreach ($c in $checks) {
    $mark = if ($c[1]) { 'PASS' } else { 'FAIL' }
    if (-not $c[1]) { $allOk = $false }
    Write-Host ("{0,-45} {1}   {2}" -f $c[0], $mark, $c[2])
}
Write-Host ''
Write-Host ("RESULT: {0}" -f $(if ($allOk) { 'PASS' } else { 'FAIL' }))
if (-not $allOk) { exit 1 }
