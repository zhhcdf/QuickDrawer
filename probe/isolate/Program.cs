// Isolate the exact layer that allocates handles.
// Reads N .lnk files through ShellLinkResolver.TryResolve and samples
// GDI/USER/handle counts around it. Pure ASCII.

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;

namespace IsolateProbe
{
    internal static class Program
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetGuiResources(IntPtr hProcess, uint flags);

        private static void Snap(string label)
        {
            using Process p = Process.GetCurrentProcess();
            p.Refresh();
            Console.WriteLine(
                $"{label,-34} WS={p.WorkingSet64 / (1024 * 1024),5}MB " +
                $"handles={p.HandleCount,9} " +
                $"GDI={GetGuiResources(p.Handle, 0),8} " +
                $"USER={GetGuiResources(p.Handle, 1),8}");
            Console.Out.Flush();
        }

        private static int Main(string[] args)
        {
            int take = args.Length > 0 ? int.Parse(args[0]) : 40;

            string app = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string root = Path.Combine(app, @"Microsoft\Windows\Start Menu\Programs");

            var lnks = Directory
                .EnumerateFiles(root, "*.lnk", SearchOption.AllDirectories)
                .Take(take)
                .ToList();

            Console.WriteLine($"testing {lnks.Count} .lnk files");
            Console.WriteLine();

            Snap("baseline");

            // --- Layer 1: ShellLinkResolver.TryResolve (COM) ---
            var resolver = new QuickDrawer.ShellLinkResolver();
            int resolved = 0;
            for (int i = 0; i < lnks.Count; i++)
            {
                if (resolver.TryResolve(lnks[i]) != null) resolved++;
                if ((i + 1) % 10 == 0) Snap($"after COM resolve {i + 1}/{lnks.Count}");
            }
            Console.WriteLine($"   (resolved {resolved}/{lnks.Count})");
            Snap("COM resolve DONE");

            // --- Layer 2: IconService.GetIcon (SHGetFileInfo) ---
            var icons = new List<BitmapSource?>();
            for (int i = 0; i < lnks.Count; i++)
            {
                icons.Add(QuickDrawer.IconService.GetIcon(lnks[i], "app"));
                if ((i + 1) % 10 == 0) Snap($"after icon load {i + 1}/{lnks.Count}");
            }
            Console.WriteLine($"   (loaded {icons.Count} icons)");
            GC.KeepAlive(icons);
            Snap("icon load DONE");

            return 0;
        }
    }
}
