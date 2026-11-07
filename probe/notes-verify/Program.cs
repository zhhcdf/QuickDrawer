// M4 verification: NoteStore multi-card round-trip + v1 migration.
//
// The user's real notes.json is backed up and restored by the driver script;
// this probe itself uses a throwaway %APPDATA% path only via NoteStore's own
// FilePath. To avoid touching the real file, the probe points the store at a
// temp directory by testing NoteStore against copies it writes itself.
//
// NoteStore.FilePath is fixed to %APPDATA%\QuickDrawer\notes.json, so the
// driver script backs the real file up first. This probe just calls
// Load/Save/Sort and checks behaviour.
//
// Pure ASCII.

using QuickDrawer;

namespace NotesVerify;

internal static class Program
{
    private static int Main()
    {
        int failures = 0;

        string real = NoteStore.FilePath;
        string backup = real + ".probe-backup";
        bool hadReal = File.Exists(real);
        if (hadReal)
        {
            File.Copy(real, backup, overwrite: true);
        }

        try
        {
            Console.WriteLine("=== 1. v1 migration: old single-note format ===");
            File.WriteAllText(real, "{\n  \"Text\": \"old single note\"\n}");
            List<NoteItem> migrated = NoteStore.Load();
            Console.WriteLine($"  cards after migration: {migrated.Count} (expect 1)");
            Console.WriteLine($"  text  : \"{migrated[0].Text}\" (expect \"old single note\")");
            Console.WriteLine($"  color : {migrated[0].Color} (expect yellow)");
            bool ok1 = migrated.Count == 1 && migrated[0].Text == "old single note";
            Console.WriteLine($"  file rewritten as v2? {(File.ReadAllText(real)).Contains("\"version\"")}");
            if (!ok1) failures++;

            Console.WriteLine();
            Console.WriteLine("=== 2. v1 migration: empty old note ===");
            File.WriteAllText(real, "{\n  \"Text\": \"\"\n}");
            List<NoteItem> empty = NoteStore.Load();
            Console.WriteLine($"  cards: {empty.Count} (expect 0 -- empty old note yields no card)");
            if (empty.Count != 0) failures++;

            Console.WriteLine();
            Console.WriteLine("=== 3. v2 round-trip: 3 cards with colors/pins ===");
            var cards = new List<NoteItem>
            {
                new() { Text = "plain", Color = "yellow" },
                new() { Text = "pinned blue", Color = "blue", Pinned = true },
                new() { Text = "green one", Color = "green" }
            };
            NoteStore.Save(cards);
            List<NoteItem> loaded = NoteStore.Load();
            Console.WriteLine($"  saved 3, loaded {loaded.Count} (expect 3)");
            Console.WriteLine($"  texts preserved: {string.Join("|", loaded.Select(c => c.Text))}");
            Console.WriteLine($"  pinned preserved: {string.Join("|", loaded.Select(c => c.Pinned))}");
            Console.WriteLine($"  colors preserved: {string.Join("|", loaded.Select(c => c.Color))}");
            bool ok3 = loaded.Count == 3
                       && loaded.Any(c => c.Text == "pinned blue" && c.Pinned && c.Color == "blue")
                       && loaded.Any(c => c.Text == "green one" && c.Color == "green");
            if (!ok3) failures++;

            Console.WriteLine();
            Console.WriteLine("=== 4. Sort: pinned first, then newest first ===");
            var t0 = DateTime.Now;
            var list = new List<NoteItem>
            {
                new() { Text = "old-unpinned", Pinned = false, UpdatedAt = t0.AddHours(-2) },
                new() { Text = "new-unpinned", Pinned = false, UpdatedAt = t0 },
                new() { Text = "old-pinned", Pinned = true, UpdatedAt = t0.AddHours(-3) },
                new() { Text = "new-pinned", Pinned = true, UpdatedAt = t0.AddMinutes(-1) }
            };
            List<NoteItem> sorted = NoteStore.Sort(list);
            string order = string.Join(" > ", sorted.Select(c => c.Text));
            Console.WriteLine($"  order: {order}");
            Console.WriteLine($"  expect: new-pinned > old-pinned > new-unpinned > old-unpinned");
            bool ok4 = order == "new-pinned > old-pinned > new-unpinned > old-unpinned";
            if (!ok4) failures++;

            Console.WriteLine();
            Console.WriteLine("=== 5. ColorBrush covers every supported color ===");
            foreach (string c in NoteStore.Colors)
            {
                string hex = NoteStore.ColorBrush(c);
                Console.WriteLine($"  {c,-7} -> {hex}");
                if (!hex.StartsWith('#')) failures++;
            }

            Console.WriteLine();
            Console.WriteLine("=== 6. missing file -> empty list ===");
            File.Delete(real);
            List<NoteItem> none = NoteStore.Load();
            Console.WriteLine($"  cards: {none.Count} (expect 0)");
            if (none.Count != 0) failures++;
        }
        finally
        {
            // restore the user's real notes.json
            if (hadReal && File.Exists(backup))
            {
                File.Move(backup, real, overwrite: true);
                Console.WriteLine();
                Console.WriteLine("(real notes.json restored)");
            }
            else if (File.Exists(real))
            {
                File.Delete(real);
            }
            else if (File.Exists(backup))
            {
                File.Delete(backup);
            }
        }

        Console.WriteLine();
        Console.WriteLine(failures == 0 ? "RESULT: PASS" : $"RESULT: FAIL ({failures} failures)");
        return failures == 0 ? 0 : 1;
    }
}