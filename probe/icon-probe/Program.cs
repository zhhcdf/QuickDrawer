// Icon probe (2026-10-23): what icon does each code path actually return?
//
// User reports: "folder items show DRIVE icons, not folder icons".
// We dump every icon variant SHGetFileInfo can produce for a real folder
// path, compare with the current GetShellFolderIcon() output, and save all
// as PNG files so the difference is visible.
//
// Pure ASCII.

using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace IconProbe;

internal static class Program
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEINFO
    {
        public IntPtr hIcon;
        public IntPtr iIcon;
        public uint dwAttributes;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szDisplayName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string szTypeName;
    }

    private const uint SHGFI_ICON = 0x100;
    private const uint SHGFI_USEFILEATTRIBUTES = 0x10;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x80;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes,
        ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    [STAThread]
    private static int Main()
    {
        // 探针需要一个真实存在的目录来取图标；用当前用户的桌面，避免写死个人路径。
        string folder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Work");
        Console.WriteLine($"target folder: {folder}  exists={Directory.Exists(folder)}");
        Console.WriteLine();

        // A: path query, no USEFILEATTRIBUTES (what the app's normal branch does)
        Dump("A: path query (no flags extra)", folder, 0, SHGFI_ICON);

        // B: path query + USEFILEATTRIBUTES + FILE_ATTRIBUTE_DIRECTORY
        Dump("B: path + USEFILEATTRIBUTES + DIRECTORY", folder, FILE_ATTRIBUTE_DIRECTORY,
            SHGFI_ICON | SHGFI_USEFILEATTRIBUTES);

        // C: empty string + USEFILEATTRIBUTES + DIRECTORY (GetShellFolderIcon today)
        Dump("C: empty + USEFILEATTRIBUTES + DIRECTORY (current impl)", string.Empty,
            FILE_ATTRIBUTE_DIRECTORY, SHGFI_ICON | SHGFI_USEFILEATTRIBUTES);

        // D: path query + USEFILEATTRIBUTES (no attribute) - the failing old combo
        Dump("D: path + USEFILEATTRIBUTES only", folder, 0, SHGFI_ICON | SHGFI_USEFILEATTRIBUTES);

        Console.WriteLine();
        Console.WriteLine("PNG files written to C:\\Windows\\Temp\\icon-probe-out for visual comparison");
        return 0;
    }

    private static void Dump(string label, string path, uint attrs, uint flags)
    {
        SHFILEINFO info = new();
        IntPtr result = SHGetFileInfo(path, attrs, ref info,
            (uint)Marshal.SizeOf<SHFILEINFO>(), flags);

        if (result == IntPtr.Zero || info.hIcon == IntPtr.Zero)
        {
            Console.WriteLine($"{label,-52} -> FAILED");
            return;
        }

        try
        {
            BitmapSource bmp = Imaging.CreateBitmapSourceFromHIcon(
                info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(32, 32));
            bmp.Freeze();

            string file = $"C:\\Windows\\Temp\\icon-probe-out\\{label.Substring(0, 1)}.png";
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            using (FileStream fs = File.Create(file))
            {
                PngBitmapEncoder enc = new();
                enc.Frames.Add(BitmapFrame.Create(bmp));
                enc.Save(fs);
            }
        }
        finally
        {
            DestroyIcon(info.hIcon);
        }

        Console.WriteLine($"{label,-52} -> OK, typename=\"{info.szTypeName}\"");
    }
}