// M3 drop-position verification.
//
// The user reported: "in list mode the drag has to travel past one item before
// it works, the travel distance is too large, and it cannot be moved to the
// last row".
//
// Root cause: the drop position was computed from "which item did I land on",
// which forces the pointer to leave the source item before the next item's
// Drop fires, and leaves no target below the last item.
//
// Fix: compute the insert index from the CONTAINER geometry
// (DropPosition.ComputeIndex).
//
// This probe builds real WrapPanels with real children and verifies the
// computed insert index -- including the "below the last item" case that
// used to be impossible.
//
// Pure ASCII.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using QuickDrawer;

namespace DropPosVerify;

internal static class Program
{
    private sealed class Item
    {
        public Item(string n) => Name = n;
        public string Name { get; }
    }

    [STAThread]
    private static int Main()
    {
        int failures = 0;

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var window = new Window
        {
            Width = 600, Height = 500, ShowInTaskbar = false, Left = -3000,
            Content = new Grid()
        };
        window.Show();
        Pump(app, 200);

        // ---------- Case 1: vertical list, 4 items ----------
        Console.WriteLine("=== 1. vertical list (4 items, 40px tall each) ===");
        var vPanel = new WrapPanel { Orientation = Orientation.Vertical, Width = 200 };
        var vItems = new List<Item> { new("A"), new("B"), new("C"), new("D") };
        foreach (Item it in vItems)
        {
            vPanel.Children.Add(new Border
            {
                Width = 180, Height = 40, Background = Brushes.Gray,
                Child = new TextBlock { Text = it.Name }
            });
        }
        ((Grid)window.Content).Children.Add(vPanel);
        Pump(app, 200);

        var vVisuals = DropPosition.GetVisualChildren(vPanel);
        Console.WriteLine($"  visual children: {vVisuals.Count} (expect 4)");
        Console.WriteLine($"  layout is vertical: {!DropPosition.IsHorizontal(vPanel, vVisuals)} (expect True)");
        Console.WriteLine();

        // Item tops: 0, 40, 80, 120. Midlines: 20, 60, 100, 140.
        Check(failures, ref failures, "above item 0 (y=5)", vPanel, vVisuals, new Point(10, 5), 0);
        Check(failures, ref failures, "item 0 upper half (y=10)", vPanel, vVisuals, new Point(10, 10), 0);
        Check(failures, ref failures, "item 0 lower half (y=35)", vPanel, vVisuals, new Point(10, 35), 1);
        Check(failures, ref failures, "item 1 lower half (y=75)", vPanel, vVisuals, new Point(10, 75), 2);
        Check(failures, ref failures, "item 2 lower half (y=115)", vPanel, vVisuals, new Point(10, 115), 3);
        // The case that used to be impossible:
        Check(failures, ref failures, "BELOW last item (y=200)", vPanel, vVisuals, new Point(10, 200), 4);

        // ---------- Case 2: horizontal grid, 2 rows x 4 cols ----------
        Console.WriteLine();
        Console.WriteLine("=== 2. horizontal grid (8 items, 4 per row) ===");
        var hPanel = new WrapPanel { Orientation = Orientation.Horizontal, Width = 400 };
        for (int i = 0; i < 8; i++)
        {
            hPanel.Children.Add(new Border
            {
                Width = 100, Height = 50, Background = Brushes.SlateBlue,
                Child = new TextBlock { Text = "i" + i }
            });
        }
        ((Grid)window.Content).Children.Add(hPanel);
        Pump(app, 200);

        var hVisuals = DropPosition.GetVisualChildren(hPanel);
        Console.WriteLine($"  visual children: {hVisuals.Count} (expect 8)");
        Console.WriteLine($"  layout is horizontal: {DropPosition.IsHorizontal(hPanel, hVisuals)} (expect True)");
        Console.WriteLine();

        // Row 1: x = 0,100,200,300 (midlines 50,150,250,350). Row 2 at y=50.
        Check(failures, ref failures, "before i0 (x=10)", hPanel, hVisuals, new Point(10, 10), 0);
        Check(failures, ref failures, "i0 right half (x=90)", hPanel, hVisuals, new Point(90, 10), 1);
        Check(failures, ref failures, "i1 right half (x=190)", hPanel, hVisuals, new Point(190, 10), 2);
        Check(failures, ref failures, "row2 i4 (x=10,y=60)", hPanel, hVisuals, new Point(10, 60), 4);
        Check(failures, ref failures, "BELOW last row (x=10,y=200)", hPanel, hVisuals, new Point(10, 200), 8);

        window.Close();
        app.Shutdown();

        Console.WriteLine();
        Console.WriteLine(failures == 0 ? "RESULT: PASS" : $"RESULT: FAIL ({failures} failures)");
        return failures == 0 ? 0 : 1;
    }

    private static void Check(int _, ref int failures, string label, Panel panel,
        List<FrameworkElement> visuals, Point p, int expected)
    {
        int actual = DropPosition.ComputeIndex(panel, p, visuals);
        bool ok = actual == expected;
        if (!ok)
        {
            failures++;
        }

        Console.WriteLine($"  {label,-28} -> index {actual} (expect {expected})  {(ok ? "PASS" : "FAIL")}");
    }

    private static void Pump(Application app, int ms)
    {
        DateTime until = DateTime.UtcNow.AddMilliseconds(ms);
        while (DateTime.UtcNow < until)
        {
            app.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Background);
            Thread.Sleep(10);
        }
    }
}
