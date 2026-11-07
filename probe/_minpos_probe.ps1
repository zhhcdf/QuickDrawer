param()

# 目的：验证"对已最小化的窗口调用 SetWindowPos 是否会改写它的还原矩形（rcNormalPosition），
# 以及是否会把它从最小化状态弹出来"。这决定 WindowPushOut.End() 里对 IsIconic 窗口
# 是"直接跳过"还是"静默改回原位置"。2026-11-05。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('MinPosProbe' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MinPosProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT
    {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }

    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);

    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;

    public static string Describe(IntPtr h)
    {
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        GetWindowPlacement(h, ref p);
        return String.Format("showCmd={0} iconic={1} normal={2},{3} {4}x{5}",
            p.showCmd, IsIconic(h),
            p.rcNormalPosition.Left, p.rcNormalPosition.Top,
            p.rcNormalPosition.Right - p.rcNormalPosition.Left,
            p.rcNormalPosition.Bottom - p.rcNormalPosition.Top);
    }
}
"@
}

$out = Join-Path $env:TEMP 'qd_minpos_probe.txt'
"=== minpos probe ===" | Out-File -FilePath $out -Encoding utf8

$form = New-Object System.Windows.Forms.Form
$form.Text = 'QdMinPosProbe'
$form.Left = 400
$form.Top = 300
$form.Width = 600
$form.Height = 400
$form.ShowInTaskbar = $true
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 400
[System.Windows.Forms.Application]::DoEvents()

$h = $form.Handle
"before minimize : $(MinPosProbe)::Describe($h)" | Out-Null
$before = [MinPosProbe]::Describe($h)
"before minimize : $before" | Out-File -FilePath $out -Append -Encoding utf8

$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 500
[System.Windows.Forms.Application]::DoEvents()

$min = [MinPosProbe]::Describe($h)
"after minimize  : $min" | Out-File -FilePath $out -Append -Encoding utf8

# 试着在"仍最小化"的前提下把还原矩形改到 (100,100,500x500)
$ok = [MinPosProbe]::SetWindowPos($h, [IntPtr]::Zero, 100, 100, 500, 500,
    ([MinPosProbe]::SWP_NOZORDER -bor [MinPosProbe]::SWP_NOACTIVATE))
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 300

$after = [MinPosProbe]::Describe($h)
"after setpos    : $after" | Out-File -FilePath $out -Append -Encoding utf8
"setpos returned : $ok" | Out-File -FilePath $out -Append -Encoding utf8

$fg = [MinPosProbe]::IsWindowVisible($h)
"visible         : $fg" | Out-File -FilePath $out -Append -Encoding utf8

"VERDICT=" + $(if ($after -match 'iconic=True') { 'STILL-MINIMIZED' } else { 'GOT-RESTORED' }) |
    Out-File -FilePath $out -Append -Encoding utf8
"normalRectChanged=" + $(if ($after -match 'normal=100,100 500x500') { 'YES' } else { 'NO' }) |
    Out-File -FilePath $out -Append -Encoding utf8

$form.Close()
$form.Dispose()
"done" | Out-File -FilePath $out -Append -Encoding utf8
Get-Content -Path $out -Encoding utf8
