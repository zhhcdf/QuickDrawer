// net48 兼容用：SHBrowseForFolder 封装，替代 .NET 8+ 的 Microsoft.Win32.OpenFolderDialog。
// 只在本实验分支存在；主工程（net10.0-windows）用官方 OpenFolderDialog。
using System;
using System.Runtime.InteropServices;

namespace QuickDrawer
{
    internal static class FolderPicker
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct BROWSEINFO
        {
            public IntPtr hwndOwner;
            public IntPtr pidlRoot;
            public IntPtr pszDisplayName;
            public string lpszTitle;
            public uint ulFlags;
            public IntPtr lpfn;
            public IntPtr lParam;
            public int iImage;
        }

        private const uint BIF_RETURNONLYFSDIRS = 0x0001;
        private const uint BIF_NEWDIALOGSTYLE = 0x0040;
        private const uint BIF_EDITBOX = 0x0010;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SHBrowseForFolder(ref BROWSEINFO lpbi);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SHGetPathFromIDList(IntPtr pidl, [Out] char[] pszPath);

        [DllImport("ole32.dll")]
        private static extern void CoTaskMemFree(IntPtr pv);

        public static string? Pick(System.Windows.Window owner, string title)
        {
            var bi = new BROWSEINFO
            {
                hwndOwner = new System.Windows.Interop.WindowInteropHelper(owner).Handle,
                lpszTitle = title,
                ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_EDITBOX
            };

            IntPtr pidl = IntPtr.Zero;
            try
            {
                pidl = SHBrowseForFolder(ref bi);
                if (pidl == IntPtr.Zero) return null;

                var buf = new char[260];
                if (!SHGetPathFromIDList(pidl, buf)) return null;
                string path = new string(buf).TrimEnd('\0');
                return string.IsNullOrWhiteSpace(path) ? null : path;
            }
            finally
            {
                if (pidl != IntPtr.Zero) CoTaskMemFree(pidl);
            }
        }
    }
}
