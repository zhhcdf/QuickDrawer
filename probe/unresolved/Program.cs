// Hypothesis under test: the leak comes from Classify()'s handling of
// UNRESOLVABLE .lnk files (UWP shortcuts), not from COM resolve or icon load.
//
// Pure ASCII.

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;

namespace UnresolvedProbe
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
                $"{label,-40} WS={p.WorkingSet64 / (1024 * 1024),5}MB " +
                $"handles={p.HandleCount,9} GDI={GetGuiResources(p.Handle, 0),7}");
            Console.Out.Flush();
        }

        private static int Main(string[] args)
        {
            int take = args.Length > 0 ? int.Parse(args[0]) : 159;

            string app = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string progData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            string publicDesktop = Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory);

            var roots = new[]
            {
                Path.Combine(app, @"Microsoft\Windows\Start Menu\Programs"),
                Path.Combine(progData, @"Microsoft\Windows\Start Menu\Programs"),
                desktop,
                publicDesktop
            };

            var lnks = new List<string>();
            foreach (string r in roots)
            {
                if (!Directory.Exists(r)) continue;
                foreach (string f in Directory.EnumerateFiles(r, "*.lnk", SearchOption.AllDirectories))
                {
                    lnks.Add(f);
                    if (lnks.Count >= take) break;
                }
                if (lnks.Count >= take) break;
            }

            Console.WriteLine($"scanning {lnks.Count} .lnk files (the real app paths)");
            Console.WriteLine();

            Snap("baseline");

            var items = new List<QuickDrawer.ShortcutItem>();
            int apps = 0, dirs = 0, files = 0;

            for (int i = 0; i < lnks.Count; i++)
            {
                var item = QuickDrawer.ShortcutStore.Classify(lnks[i]);
                items.Add(item);

                switch (item.Kind)
                {
                    case "app": apps++; break;
                    case "dir": dirs++; break;
                    default: files++; break;
                }

                if ((i + 1) % 20 == 0)
                {
                    Snap($"after Classify {i + 1}/{lnks.Count}");
                    Console.WriteLine($"      so far: app={apps} dir={dirs} file={files}");
                }
            }

            GC.KeepAlive(items);
            Snap("Classify DONE");
            Console.WriteLine($"   app={apps} dir={dirs} file={files}");

            return 0;
        }
    }
}
