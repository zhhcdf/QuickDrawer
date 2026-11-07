param()

# 目的：已最小化的窗口，能否用 SetWindowPlacement(showCmd = SW_SHOWMINIMIZED)
# 把还原矩形（rcNormalPosition）改回原值，同时保持"仍最小化、不抢前台"。
# 这决定 WindowPushOut.End() 遇到 IsIconic 窗口时是"纯跳过"还是"静默改回原位置"。
# 2026-11-05。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('MinPosProbe2' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class MinPosProbe2
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
    [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

    public const int SW_SHOWMINIMIZED = 2;

    public static WINDOWPLACEMENT Get(IntPtr h)
    {
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        GetWindowPlacement(h, ref p);
        return p;
    }

    public static string Describe(IntPtr h)
    {
        WINDOWPLACEMENT p = Get(h);
        return String.Format("showCmd={0} iconic={1} normal={2},{3} {4}x{5}",
            p.showCmd, IsIconic(h),
            p.rcNormalPosition.Left, p.rcNormalPosition.Top,
            p.rcNormalPosition.Right - p.rcNormalPosition.Left,
            p.rcNormalPosition.Bottom - p.rcNormalPosition.Top);
    }

    // 把还原矩形改成 x,y,w,h，但强制 showCmd = 最小化
    public static bool SetNormalWhileMinimized(IntPtr h, int x, int y, int w, int hh)
    {
        WINDOWPLACEMENT p = Get(h);
        p.showCmd = SW_SHOWMINIMIZED;
        p.rcNormalPosition.Left = x;
        p.rcNormalPosition.Top = y;
        p.rcNormalPosition.Right = x + w;
        p.rcNormalPosition.Bottom = y + hh;
        return SetWindowPlacement(h, ref p);
    }
}
"@
}

$out = Join-Path $env:TEMP 'qd_minpos_probe2.txt'
"=== minpos probe 2 ===" | Out-File -FilePath $out -Encoding utf8

$form = New-Object System.Windows.Forms.Form
$form.Text = 'QdMinPosProbe2'
$form.Left = 400
$form.Top = 300
$form.Width = 600
$form.Height = 400
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 400
[System.Windows.Forms.Application]::DoEvents()

$h = $form.Handle
$before = [MinPosProbe2]::Get($h)
"before          : $([MinPosProbe2]::Describe($h))" | Out-File -FilePath $out -Append -Encoding utf8
$orig = "normal=$($before.rcNormalPosition.Left),$($before.rcNormalPosition.Top) " +
        "$($before.rcNormalPosition.Right - $before.rcNormalPosition.Left)x" +
        "$($before.rcNormalPosition.Bottom - $before.rcNormalPosition.Top)"
"original        : $orig" | Out-File -FilePath $out -Append -Encoding utf8

$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 500
"after minimize  : $([MinPosProbe2]::Describe($h))" | Out-File -FilePath $out -Append -Encoding utf8
$fgBefore = [MinPosProbe2]::GetForegroundWindow()
"fg before set   : 0x$($fgBefore.ToInt64().ToString('X')) (self=0x$((Get-Process -Id $PID).MainWindowHandle.ToInt64().ToString('X')))" |
    Out-File -FilePath $out -Append -Encoding utf8

# 模拟"被挪走过又被最小化"：先把还原矩形改到 100,100 500x500
$ok1 = [MinPosProbe2]::SetNormalWhileMinimized($h, 100, 100, 500, 500)
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 300
"after move      : $([MinPosProbe2]::Describe($h))  ret=$ok1" | Out-File -FilePath $out -Append -Encoding utf8

# 再改回原始还原矩形，仍保持最小化
$ok2 = [MinPosProbe2]::SetNormalWhileMinimized($h,
    $before.rcNormalPosition.Left, $before.rcNormalPosition.Top,
    $before.rcNormalPosition.Right - $before.rcNormalPosition.Left,
    $before.rcNormalPosition.Bottom - $before.rcNormalPosition.Top)
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 300
"after restore   : $([MinPosProbe2]::Describe($h))  ret=$ok2" | Out-File -FilePath $out -Append -Encoding utf8

$fgAfter = [MinPosProbe2]::GetForegroundWindow()
"fg after set    : 0x$($fgAfter.ToInt64().ToString('X'))" | Out-File -FilePath $out -Append -Encoding utf8

$iconic = [MinPosProbe2]::IsIconic($h)
"VERDICT=" + $(if ($iconic) { 'STILL-MINIMIZED' } else { 'GOT-RESTORED' }) |
    Out-File -FilePath $out -Append -Encoding utf8
$now = [MinPosProbe2]::Describe($h)
"normalRestored=" + $(if ($now -eq "showCmd=2 iconic=True $orig") { 'YES' } else { 'NO' }) |
    Out-File -FilePath $out -Append -Encoding utf8

$form.Close()
$form.Dispose()
"done" | Out-File -FilePath $out -Append -Encoding utf8
Get-Content -Path $out -Encoding utf8
