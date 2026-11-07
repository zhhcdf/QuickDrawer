# Dump the raw bytes of a real .lnk so we can verify offsets against MS-SHLLINK.
# Pure ASCII (see docs appendix D item 2).

param([string]$LnkPath)

if (-not (Test-Path -LiteralPath $LnkPath)) {
    Write-Output "file not found: $LnkPath"
    exit 1
}

$b = [IO.File]::ReadAllBytes($LnkPath)
Write-Output "file  : $LnkPath"
Write-Output "size  : $($b.Length) bytes"
Write-Output ""

# HeaderSize at 0x00, LinkCLSID at 0x04, LinkFlags at 0x14
$hdr = [BitConverter]::ToUInt32($b, 0x00)
$clsid = [BitConverter]::ToUInt32($b, 0x04)
$flags = [BitConverter]::ToUInt32($b, 0x14)
Write-Output ("HeaderSize (0x00) = 0x{0:X8}   expect 0x0000004C" -f $hdr)
Write-Output ("LinkCLSID (0x04) = 0x{0:X8}   expect 0x00021401" -f $clsid)
Write-Output ("LinkFlags (0x14) = 0x{0:X8}" -f $flags)
Write-Output ""

$hasIdList   = ($flags -band 0x01) -ne 0
$hasName    = ($flags -band 0x04) -ne 0
$hasRelPath = ($flags -band 0x08) -ne 0
$hasAbsPath = ($flags -band 0x10) -ne 0
Write-Output "FL_HAS_IDLIST          = $hasIdList"
Write-Output "FL_HAS_NAME            = $hasName"
Write-Output "FL_HAS_RELATIVE_PATH   = $hasRelPath"
Write-Output "FL_HAS_ABSOLUTE_PATH   = $hasAbsPath"
Write-Output ""

$pos = 0x4C
Write-Output "walk from 0x4C:"
Write-Output ""

if ($hasIdList) {
    $idListSize = [BitConverter]::ToUInt16($b, $pos)
    Write-Output ("  IDListSize at 0x{0:X} = {1}" -f $pos, $idListSize)
    $pos += 2 + $idListSize
    Write-Output ("  next pos = 0x{0:X}" -f $pos)
}

if ($hasName) {
    $nameChars = [BitConverter]::ToUInt16($b, $pos)
    $name = [Text.Encoding]::Unicode.GetString($b, $pos + 2, $nameChars * 2)
    Write-Output ("  NAME at 0x{0:X}: {1} chars = '{2}'" -f $pos, $nameChars, $name)
    $pos += 2 + $nameChars * 2
    Write-Output ("  next pos = 0x{0:X}" -f $pos)
}

if ($hasRelPath) {
    $relChars = [BitConverter]::ToUInt16($b, $pos)
    Write-Output ("  RELATIVE_PATH Count at 0x{0:X} = {1}" -f $pos, $relChars)
    if ($relChars -gt 0) {
        $rel = [Text.Encoding]::Unicode.GetString($b, $pos + 2, $relChars * 2)
        Write-Output ("  RELATIVE_PATH = '{0}'" -f $rel)
        Write-Output ("  resolved = '{0}'" -f [IO.Path]::GetFullPath((Join-Path (Split-Path $LnkPath -Parent) $rel)))
    }
    $pos += 2 + $relChars * 2
    Write-Output ("  next pos = 0x{0:X}" -f $pos)
}

if ($hasAbsPath) {
    $absChars = [BitConverter]::ToUInt16($b, $pos)
    Write-Output ("  ABSOLUTE_PATH Count at 0x{0:X} = {1}" -f $pos, $absChars)
    if ($absChars -gt 0) {
        $abs = [Text.Encoding]::Unicode.GetString($b, $pos + 2, $absChars * 2)
        Write-Output ("  ABSOLUTE_PATH = '{0}'" -f $abs)
        Write-Output ("  exists = {0}" -f (Test-Path -LiteralPath $abs))
    }
    $pos += 2 + $absChars * 2
}