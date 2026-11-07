// Prove: Directory.EnumerateFiles(AllDirectories) follows reparse points,
// while PowerShell's Get-ChildItem -Recurse does not (by default).
// This is the 2026-10-19 root cause of the 3GB / freeze issue.
//
// Pure ASCII.

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace ReparseProbe;

internal static class Program
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributes(string lpFileName);

    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;

    private static int Main()
    {
        string app = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string progData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);

        var roots = new[]
        {
            Path.Combine(app, @"Microsoft\Windows\Start Menu\Programs"),
            Path.Combine(progData, @"Microsoft\Windows\Start Menu\Programs"),
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory)
        };

        Console.WriteLine("=== 1. which roots are themselves reparse points? ===");
        foreach (string r in roots)
        {
            uint attr = GetFileAttributes(r);
            bool isReparse = (attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
            Console.WriteLine($"  {(isReparse ? "REPARSE" : "normal  ")}  {r}");
        }

        Console.WriteLine();
        Console.WriteLine("=== 2. bounded enumeration (our own recursion, skips reparse) ===");

        int lnkBounded = 0;
        int dirsBounded = 0;
        var sw = Stopwatch.StartNew();
        foreach (string r in roots)
        {
            if (Directory.Exists(r)) Walk(r, 0, 8, ref lnkBounded, ref dirsBounded);
        }
        sw.Stop();
        Console.WriteLine($"  bounded  : {lnkBounded} .lnk, {dirsBounded} dirs in {sw.Elapsed.TotalSeconds:F2}s");

        Console.WriteLine();
        Console.WriteLine("=== 3. EnumerateFiles with AllDirectories (what the app uses) ===");
        int lnkAll = 0;
        sw.Restart();
        foreach (string r in roots)
        {
            if (!Directory.Exists(r)) continue;
            try
            {
                foreach (string _ in Directory.EnumerateFiles(r, "*.lnk", SearchOption.AllDirectories))
                {
                    lnkAll++;
                    if (lnkAll % 200 == 0)
                    {
                        Console.WriteLine($"    ...{lnkAll} so far, {sw.Elapsed.TotalSeconds:F1}s");
                        Console.Out.Flush();
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"    error on {r}: {ex.Message}");
            }
        }
        sw.Stop();
        Console.WriteLine($"  AllDirectories: {lnkAll} .lnk in {sw.Elapsed.TotalSeconds:F2}s");

        Console.WriteLine();
        Console.WriteLine(lnkAll > lnkBounded * 2
            ? "VERDICT: AllDirectories follows reparse points -> INFINITE / runaway recursion."
            : "VERDICT: counts are comparable; reparse points are not the cause here.");

        return 0;
    }

    private static void Walk(string dir, int depth, int maxDepth, ref int lnk, ref int dirs)
    {
        if (depth > maxDepth) return;

        try
        {
            foreach (string f in Directory.EnumerateFiles(dir, "*.lnk"))
            {
                lnk++;
            }
        }
        catch
        {
            return;
        }

        string[] subdirs;
        try
        {
            subdirs = Directory.GetDirectories(dir);
        }
        catch
        {
            return;
        }

        foreach (string sub in subdirs)
        {
            uint attr = GetFileAttributes(sub);
            if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            {
                Console.WriteLine($"    SKIP reparse point: {sub}");
                continue;
            }

            dirs++;
            Walk(sub, depth + 1, maxDepth, ref lnk, ref dirs);
        }
    }
}
