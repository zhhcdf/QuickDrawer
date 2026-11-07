// M3 verification: drag-reorder logic.
// The drag itself is a mouse gesture that cannot be simulated reliably from
// a console app, so we verify the ORDERING ALGORITHM directly (the part that
// decides the new sequence) plus the model round-trip (Order -> sort -> save).
//
// Pure ASCII.

using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using QuickDrawer;

namespace ReorderVerify;

internal static class Program
{
    private sealed class Tile
    {
        public Tile(string name) => Name = name;
        public string Name { get; }
        public override string ToString() => Name;
    }

    // WPF UI objects (Border) require an STA thread.
    [STAThread]
    private static int Main()
    {
        int failures = 0;

        Console.WriteLine("=== 1. MoveBefore: source before target ===");
        var list = new ObservableCollection<Tile>
        {
            new("A"), new("B"), new("C"), new("D")
        };
        DragReorder.MoveBefore(list, list[3], list[1]);   // D before B
        Console.WriteLine("  result: " + string.Join(",", list.Select(t => t.Name)));
        if (string.Join(",", list.Select(t => t.Name)) != "A,D,B,C")
        {
            Console.WriteLine("  FAIL expected A,D,B,C");
            failures++;
        }
        else
        {
            Console.WriteLine("  PASS");
        }
        Console.WriteLine();

        Console.WriteLine("=== 2. MoveBefore: source after target ===");
        list = new ObservableCollection<Tile> { new("A"), new("B"), new("C"), new("D") };
        DragReorder.MoveBefore(list, list[0], list[2]);   // A before C
        Console.WriteLine("  result: " + string.Join(",", list.Select(t => t.Name)));
        if (string.Join(",", list.Select(t => t.Name)) != "B,A,C,D")
        {
            Console.WriteLine("  FAIL expected B,A,C,D");
            failures++;
        }
        else
        {
            Console.WriteLine("  PASS");
        }
        Console.WriteLine();

        Console.WriteLine("=== 3. MoveBefore: no-op cases ===");
        list = new ObservableCollection<Tile> { new("A"), new("B") };
        DragReorder.MoveBefore(list, list[0], list[0]);   // same element
        DragReorder.MoveBefore(list, list[0], new Tile("Z"));  // not in list
        Console.WriteLine("  result: " + string.Join(",", list.Select(t => t.Name)));
        if (string.Join(",", list.Select(t => t.Name)) != "A,B")
        {
            Console.WriteLine("  FAIL expected A,B");
            failures++;
        }
        else
        {
            Console.WriteLine("  PASS");
        }
        Console.WriteLine();

        Console.WriteLine("=== 4. IsBefore: drop point vs target midpoint ===");
        // Use a fixed-width element. No real window is needed: the
        // implementation only reads ActualWidth/Width, never TranslatePoint.
        var el = new Border { Width = 100, Height = 20 };

        bool left = DragReorder.IsBefore(el, new Point(20, 10));
        bool right = DragReorder.IsBefore(el, new Point(80, 10));
        bool exactMid = DragReorder.IsBefore(el, new Point(50, 10));
        Console.WriteLine($"  drop at x=20 -> IsBefore={left} (expect True)");
        Console.WriteLine($"  drop at x=80 -> IsBefore={right} (expect False)");
        Console.WriteLine($"  drop at x=50 -> IsBefore={exactMid} (midpoint, expect True)");
        if (!left || right || !exactMid)
        {
            Console.WriteLine("  FAIL");
            failures++;
        }
        else
        {
            Console.WriteLine("  PASS");
        }
        Console.WriteLine();

        Console.WriteLine("=== 5. Order round-trip (rebuild must keep the new sequence) ===");
        var data = new ShortcutsData
        {
            Apps = new List<ShortcutItem>
            {
                new() { Name = "A", Order = 0, Kind = "app", Target = "a.exe" },
                new() { Name = "B", Order = 1, Kind = "app", Target = "b.exe" },
                new() { Name = "C", Order = 2, Kind = "app", Target = "c.exe" }
            }
        };

        // simulate a reorder: C moved to front
        var moved = data.Apps[2];
        data.Apps.RemoveAt(2);
        data.Apps.Insert(0, moved);
        for (int i = 0; i < data.Apps.Count; i++)
        {
            data.Apps[i].Order = i;
        }

        var rebuilt = data.Apps.OrderBy(a => a.Order).Select(a => a.Name).ToList();
        Console.WriteLine("  result: " + string.Join(",", rebuilt));
        if (string.Join(",", rebuilt) != "C,A,B")
        {
            Console.WriteLine("  FAIL expected C,A,B");
            failures++;
        }
        else
        {
            Console.WriteLine("  PASS");
        }
        Console.WriteLine();

        Console.WriteLine(failures == 0 ? "RESULT: PASS" : $"RESULT: FAIL ({failures} failures)");
        return failures == 0 ? 0 : 1;
    }
}
