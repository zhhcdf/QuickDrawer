# Put ONLY CF_BITMAP on the clipboard (no CF_DIB / CF_DIBV5).
#
# This is the pathological case the fallback exists for: a tool that publishes a
# raw GDI bitmap handle. Before the fix QuickDrawer detected hasImage=true, then
# ReadImage() found neither CF_DIB nor CF_DIBV5 and returned null, so the entry
# vanished without a log line. After the fix it must be captured.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class BitmapOnly {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool OpenClipboard(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError=true)] public static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetClipboardData(uint f, IntPtr h);
    [DllImport("user32.dll")] public static extern uint EnumClipboardFormats(uint f);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr o);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateSolidBrush(uint c);
    [DllImport("gdi32.dll")] public static extern bool PatBlt(IntPtr hdc, int x, int y, int w, int h, uint rop);

    public static string Set(int w, int h, uint color) {
        IntPtr hdc = GetDC(IntPtr.Zero);
        if (hdc == IntPtr.Zero) return "GetDC failed";
        IntPtr mem = CreateCompatibleDC(hdc);
        if (mem == IntPtr.Zero) { ReleaseDC(IntPtr.Zero, hdc); return "CreateCompatibleDC failed"; }

        // CreateCompatibleBitmap gives us a real GDI bitmap we can publish as CF_BITMAP.
        IntPtr hbm = CreateCompatibleBitmap(hdc, w, h);
        if (hbm == IntPtr.Zero) { DeleteDC(mem); ReleaseDC(IntPtr.Zero, hdc); return "CreateCompatibleBitmap failed"; }

        IntPtr old = SelectObject(mem, hbm);
        IntPtr brush = CreateSolidBrush(color);
        IntPtr oldBrush = SelectObject(mem, brush);
        PatBlt(mem, 0, 0, w, h, 0x00F00021); // PATCOPY
        SelectObject(mem, oldBrush);
        DeleteObject(brush);
        SelectObject(mem, old);

        if (!OpenClipboard(IntPtr.Zero)) { DeleteObject(hbm); DeleteDC(mem); ReleaseDC(IntPtr.Zero, hdc); return "OpenClipboard failed"; }
        EmptyClipboard();
        // Publish ONLY CF_BITMAP. No CF_DIB, no CF_DIBV5.
        IntPtr r = SetClipboardData(2, hbm);
        CloseClipboard();

        DeleteDC(mem);
        ReleaseDC(IntPtr.Zero, hdc);
        if (r == IntPtr.Zero) { DeleteObject(hbm); return "SetClipboardData failed"; }
        return "ok";
    }

    public static string Formats() {
        if (!OpenClipboard(IntPtr.Zero)) return "open failed";
        var sb = new System.Text.StringBuilder();
        uint f = 0;
        while ((f = EnumClipboardFormats(f)) != 0) sb.Append(f).Append(' ');
        CloseClipboard();
        return sb.ToString().Trim();
    }
}
'@

$w = 260
$h = 150
$color = [uint32]0x00C88C28   # 0x00BBGGRR -> orange-ish
$r = [BitmapOnly]::Set($w, $h, $color)
Write-Host ("Set CF_BITMAP only: {0}" -f $r)
Start-Sleep -Milliseconds 300
Write-Host ("formats now: {0}" -f [BitmapOnly]::Formats())
Write-Host ''
Write-Host 'expected formats: 2 (CF_BITMAP) and possibly 17/8 if the OS synthesizes them.'
Write-Host 'If only "2" appears, this is a true CF_BITMAP-only clipboard.'
