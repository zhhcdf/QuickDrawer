param(
    [string]$Default = '',
    [string]$Dragged = ''
)

# Pixel-level verification (no eyeballing): the two shots must differ only below the
# splitter, and the 44x3 drag grip must have moved up by ~120 px.

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($Default)) { $Default = Join-Path $PSScriptRoot 'splitter-default.png' }
if ([string]::IsNullOrEmpty($Dragged)) { $Dragged = Join-Path $PSScriptRoot 'splitter-dragged.png' }

Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class SplitterPixels
{
    static byte[] Bytes(Bitmap b, out int stride)
    {
        Rectangle r = new Rectangle(0, 0, b.Width, b.Height);
        BitmapData d = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        stride = d.Stride;
        byte[] buf = new byte[stride * b.Height];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        b.UnlockBits(d);
        return buf;
    }

    static double Luma(byte[] buf, int stride, int x, int y)
    {
        int i = y * stride + x * 4;
        return 0.299 * buf[i + 2] + 0.587 * buf[i + 1] + 0.114 * buf[i];
    }

    public static string Run(string p1, string p2)
    {
        using (Bitmap b1 = new Bitmap(p1))
        using (Bitmap b2 = new Bitmap(p2))
        {
            if (b1.Width != b2.Width || b1.Height != b2.Height)
                return "SIZE MISMATCH";
            int w = b1.Width, h = b1.Height, cx = w / 2;
            int s1, s2;
            byte[] a1 = Bytes(b1, out s1);
            byte[] a2 = Bytes(b2, out s2);

            int[] rowDiff = new int[h];
            long total = 0;
            for (int y = 0; y < h; y++)
            {
                int c = 0;
                // ignore the right 26px strip: the categories area may grow a scrollbar
                for (int x = 0; x < w - 26; x += 2)
                {
                    int i1 = y * s1 + x * 4, i2 = y * s2 + x * 4;
                    int d = Math.Abs(a1[i1] - a2[i2]) + Math.Abs(a1[i1 + 1] - a2[i2 + 1]) + Math.Abs(a1[i1 + 2] - a2[i2 + 2]);
                    if (d > 12) c++;
                }
                rowDiff[y] = c; total += c;
            }

            long above280 = 0;
            for (int y = 0; y < 280 && y < h; y++) above280 += rowDiff[y];

            long moved = 0;    // where the splitter used to be (435..455)
            for (int y = 430; y < 460 && y < h; y++) moved += rowDiff[y];
            long landed = 0;   // where the splitter is now (310..335)
            for (int y = 305; y < 340 && y < h; y++) landed += rowDiff[y];

            int first = -1;
            for (int y = 0; y < h; y++) if (rowDiff[y] > 0) { first = y; break; }

            bool ok = above280 == 0 && moved > 200 && landed > 200;
            return string.Format(
                "image={0}x{1}\ntotalDiff={2}\nfirstDiffRow={3}\ndiffAbove280={4}\n" +
                "diffAtOldSplitter(430-460)={5}\ndiffAtNewSplitter(305-340)={6}\n" +
                "VERDICT={7}",
                w, h, total, first, above280, moved, landed, ok ? "PASS" : "FAIL");
        }
    }
}
"@

[SplitterPixels]::Run($Default, $Dragged)
