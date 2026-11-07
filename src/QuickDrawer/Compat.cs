// net48 兼容垫片。仅评估用。
using System;
using System.IO;
using System.Diagnostics;

namespace System.Runtime.CompilerServices
{
    internal static class IsExternalInit { }
}

internal static class Compat
{
    public static int Clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
    public static long TickCount64 => (long)Environment.TickCount;
    public static string? ProcessPath
    {
        get
        {
            try { return Process.GetCurrentProcess().MainModule?.FileName; }
            catch { return null; }
        }
    }
    public static void MoveOverwrite(string src, string dst)
    {
        if (File.Exists(dst)) File.Delete(dst);
        File.Move(src, dst);
    }
}
