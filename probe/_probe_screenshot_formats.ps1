# What formats does a REAL screenshot actually put on the clipboard?
#
# This matters because TryReadClipboard sets hasImage for CF_BITMAP, CF_DIB and
# CF_DIBV5, but ReadImage() only reads CF_DIB then CF_DIBV5. If a screenshot tool
# provides ONLY CF_BITMAP, we detect an image and then fail to read it -> silent
# null -> the user sees nothing captured. That is a real possible cause of
# "截图后剪贴板里看不到截图内容", so it must be measured, not assumed.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ClipFmt {
    [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern bool EmptyClipboard();
    [DllImport("user32.dll")] public static extern uint EnumClipboardFormats(uint f);
    [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint f);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClipboardFormatNameW(uint f, StringBuilder s, int n);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern UIntPtr GlobalSize(IntPtr h);
    [DllImport("user32.dll")] public static extern uint RegisterClipboardFormatW(string f);

    public static string Name(uint f) {
        if (f < 0xC000) {
            switch (f) {
                case 2: return "CF_BITMAP";
                case 8: return "CF_DIB";
                case 13: return "CF_UNICODETEXT";
                case 15: return "CF_HDROP";
                case 17: return "CF_DIBV5";
                default: return "CF_" + f;
            }
        }
        var sb = new StringBuilder(256);
        int n = GetClipboardFormatNameW(f, sb, 256);
        return n > 0 ? sb.ToString(0, n) : ("reg:" + f);
    }

    public static void Dump(string tag) {
        if (!OpenClipboard(IntPtr.Zero)) { Console.WriteLine("  [" + tag + "] OpenClipboard FAILED"); return; }
        try {
            Console.WriteLine("  [" + tag + "]");
            uint f = 0;
            while ((f = EnumClipboardFormats(f)) != 0) {
                IntPtr h = GetClipboardData(f);
                long size = h == IntPtr.Zero ? -1 : (long)GlobalSize(h).ToUInt64();
                Console.WriteLine("    {0,-24} id={1,-6} size={2}", Name(f), f, size);
            }
        } finally { CloseClipboard(); }
    }
}
'@

Write-Host "HTML Format id = $([ClipFmt]::RegisterClipboardFormatW('HTML Format'))"
Write-Host "RTF  Format id = $([ClipFmt]::RegisterClipboardFormatW('Rich Text Format'))"
Write-Host ''

# ---------------------------------------------------- 1. real PrintScreen key
Write-Host '[1] Pressing PrintScreen (real screenshot path)...'
[ClipFmt]::OpenClipboard([IntPtr]::Zero) | Out-Null
[ClipFmt]::EmptyClipboard() | Out-Null
[ClipFmt]::CloseClipboard() | Out-Null
Start-Sleep -Milliseconds 200
[System.Windows.Forms.SendKeys]::SendWait('{PRTSC}')
Start-Sleep -Seconds 1
[ClipFmt]::Dump('after PrintScreen')

# --------------------------------------------- 2. .NET Bitmap-only clipboard
Write-Host ''
Write-Host '[2] System.Drawing.Bitmap via Clipboard.SetImage...'
$bmp = New-Object System.Drawing.Bitmap 200, 120
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(255, 40, 140, 200))
$g.Dispose()
[System.Windows.Forms.Clipboard]::SetImage($bmp)
Start-Sleep -Milliseconds 600
[ClipFmt]::Dump('after SetImage')
$bmp.Dispose()
