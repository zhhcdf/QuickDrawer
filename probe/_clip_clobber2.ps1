$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class D3 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    public const uint DOWN = 0x0002, UP = 0x0004;
    public static void Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(120);
        mouse_event(DOWN, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(60);
        mouse_event(UP, 0, 0, 0, IntPtr.Zero);
    }
    public static void Drag(int x1, int y1, int x2, int y2) {
        SetCursorPos(x1, y1); System.Threading.Thread.Sleep(100);
        mouse_event(DOWN, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(80);
        int steps = 16;
        for (int i = 1; i <= steps; i++) {
            SetCursorPos(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps);
            System.Threading.Thread.Sleep(18);
        }
        System.Threading.Thread.Sleep(80);
        mouse_event(UP, 0, 0, 0, IntPtr.Zero);
    }
}
"@

function Try-SetText([string]$t, [int]$tries) {
    for ($i = 0; $i -lt $tries; $i++) {
        try { [System.Windows.Forms.Clipboard]::SetText($t); return $true } catch { Start-Sleep -Milliseconds 60 }
    }
    return $false
}

[D3]::Click(760, 620)
Start-Sleep -Milliseconds 600
Write-Output "BEFORE=[$([System.Windows.Forms.Clipboard]::GetText())]"

[D3]::Drag(700, 560, 1000, 560)
Write-Output "drag done at $(Get-Date -Format 'HH:mm:ss.fff')"

# 持续尝试写入 marker，直到成功（模拟用户在捕获期间按 Ctrl+C）
Start-Sleep -Milliseconds 300
$stamp = Get-Date -Format 'HHmmssfff'
$marker = "QDMARK-$stamp"
$ok = $false
for ($k = 0; $k -lt 40; $k++) {
    if (Try-SetText $marker 1) { $ok = $true; Write-Output "SET marker at $(Get-Date -Format 'HH:mm:ss.fff') (try $k)"; break }
    Start-Sleep -Milliseconds 50
}
if (-not $ok) { Write-Output "SET_FAILED" }

Start-Sleep -Milliseconds 4000
$after = [System.Windows.Forms.Clipboard]::GetText()
Write-Output "AFTER=[$after]"
if ($after -eq $marker) { Write-Output "RESULT=SURVIVED" } else { Write-Output "RESULT=CLOBBERED" }
Write-Output "marker=$marker"
