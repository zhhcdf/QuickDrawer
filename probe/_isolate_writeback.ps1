# 隔离实验：在 PowerShell 宿主里逐调用复现 WriteBack(Html) 的两步写入，
# 每步之后都枚举剪贴板格式，定位 CF_UNICODETEXT 从哪一步开始消失。
#
# 背景：probe/clip-formats 与 probe/clip-e2e 走真控制台进程，均 PASS；
# 而本机 PowerShell 宿主里对着同一个 exe 调 WriteBack，剪贴板上只剩 HTML Format。
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CbDump
{
    [DllImport("user32.dll", SetLastError=true)] public static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern bool EmptyClipboard();
    [DllImport("user32.dll")] public static extern uint EnumClipboardFormats(uint f);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClipboardFormatNameW(uint f, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint f);
    [DllImport("user32.dll")] public static extern IntPtr GetClipboardOwner();
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern UIntPtr GlobalSize(IntPtr h);

    public static string Dump()
    {
        if (!OpenClipboard(IntPtr.Zero))
            return "  <OpenClipboard failed, err=" + Marshal.GetLastWin32Error() + ">";

        try
        {
            var sb = new StringBuilder();
            uint f = 0;
            while ((f = EnumClipboardFormats(f)) != 0)
            {
                IntPtr h = GetClipboardData(f);
                sb.Append("  fmt " + f);
                var nm = new StringBuilder(128);
                if (GetClipboardFormatNameW(f, nm, 128) > 0) sb.Append(" '" + nm + "'");
                if (h != IntPtr.Zero)
                {
                    sb.Append(" size=" + GlobalSize(h));
                    if (f == 13)
                    {
                        IntPtr p = GlobalLock(h);
                        if (p != IntPtr.Zero)
                        {
                            string t = Marshal.PtrToStringUni(p) ?? "";
                            sb.Append(" text='" + t.Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t") + "'");
                            GlobalUnlock(h);
                        }
                    }
                }
                sb.AppendLine();
            }
            return sb.Length == 0 ? "  <clipboard empty>" : sb.ToString();
        }
        finally { CloseClipboard(); }
    }
}
'@

$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
Write-Host ("exe   : {0}" -f $exe)
Write-Host ("host  : {0} / {1}" -f $PSVersionTable.PSVersion, [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)
Write-Host ("apart : {0}" -f [System.Threading.Thread]::CurrentThread.GetApartmentState())

$asm = [System.Reflection.Assembly]::LoadFrom($exe)
$svc = $asm.GetType('QuickDrawer.ClipboardService')
$entryType = $asm.GetType('QuickDrawer.ClipEntry')
$kindType = $asm.GetType('QuickDrawer.ClipKind')
$native = $asm.GetType('QuickDrawer.Native.NativeMethods')
$bf = [System.Reflection.BindingFlags]'Public,NonPublic,Static'

$open = $native.GetMethod('OpenClipboard', $bf)
$close = $native.GetMethod('CloseClipboard', $bf)
$empty = $native.GetMethod('EmptyClipboard', $bf)
$writeText = $svc.GetMethod('WriteTextPayload', $bf)
$writeHtml = $svc.GetMethod('WriteHtmlPayload', $bf)
$toPlain = $svc.GetMethod('HtmlToPlainText', $bf)

$html = '<table border=1><tr><td>A1</td><td>B1</td></tr></table>'
$fragment = '<!--StartFragment-->' + $html + '<!--EndFragment-->'
$plain = $toPlain.Invoke($null, @($html))
Write-Host ("HtmlToPlainText -> [{0}] len={1}" -f ($plain -replace "`t", '\t'), $plain.Length)

Write-Host ''
Write-Host '=== S1: Open -> Empty -> WriteTextPayload only ==='
$open.Invoke($null, @([IntPtr]::Zero)) | Out-Null
$empty.Invoke($null, @()) | Out-Null
Write-Host ("  WriteTextPayload -> {0}" -f $writeText.Invoke($null, @($plain)))
$close.Invoke($null, @()) | Out-Null
[CbDump]::Dump()

Write-Host ''
Write-Host '=== S2: Open -> Empty -> WriteHtmlPayload only ==='
$open.Invoke($null, @([IntPtr]::Zero)) | Out-Null
$empty.Invoke($null, @()) | Out-Null
Write-Host ("  WriteHtmlPayload -> {0}" -f $writeHtml.Invoke($null, @($fragment, $null)))
$close.Invoke($null, @()) | Out-Null
[CbDump]::Dump()

Write-Host ''
Write-Host '=== S3: Open -> Empty -> WriteTextPayload -> WriteHtmlPayload (WriteBack order) ==='
$open.Invoke($null, @([IntPtr]::Zero)) | Out-Null
$empty.Invoke($null, @()) | Out-Null
Write-Host ("  WriteTextPayload -> {0}" -f $writeText.Invoke($null, @($plain)))
Write-Host ("  WriteHtmlPayload -> {0}" -f $writeHtml.Invoke($null, @($fragment, $null)))
$close.Invoke($null, @()) | Out-Null
[CbDump]::Dump()

Write-Host ''
Write-Host '=== S4: Open -> Empty -> WriteHtmlPayload -> WriteTextPayload (reverse order) ==='
$open.Invoke($null, @([IntPtr]::Zero)) | Out-Null
$empty.Invoke($null, @()) | Out-Null
Write-Host ("  WriteHtmlPayload -> {0}" -f $writeHtml.Invoke($null, @($fragment, $null)))
Write-Host ("  WriteTextPayload -> {0}" -f $writeText.Invoke($null, @($plain)))
$close.Invoke($null, @()) | Out-Null
[CbDump]::Dump()

Write-Host ''
Write-Host '=== S5: real WriteBack(Html, PlainText=null) ==='
$entry = [System.Activator]::CreateInstance($entryType)
$entry.Kind = [System.Enum]::Parse($kindType, 'Html')
$entry.Text = $html
$entry.Preview = 'A1 B1'
if ($entryType.GetProperty('PlainText')) { $entry.PlainText = $null }
Write-Host ("  WriteBack -> {0}" -f $svc::WriteBack($entry))
Write-Host ("  entry.PlainText after call -> [{0}]" -f $entry.PlainText)
[CbDump]::Dump()
