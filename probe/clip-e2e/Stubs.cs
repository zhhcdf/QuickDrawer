// Redirect the app data directory for the end-to-end probe.
//
// ConfigStore normally lives in App.xaml.cs (WPF code-behind that cannot be
// linked into a console project). Linking this stub lets ClipboardStore /
// ClipboardBlobStore write into an isolated temp directory, so the probe never
// touches the user's real %APPDATA%\QuickDrawer\clipboard.json.
//
// QD_E2E_DIR selects the directory; without it we fall back to the real path.
//
// Pure ASCII.

using System.IO;

namespace QuickDrawer
{
    public static class ConfigStore
    {
        public static string BaseDir
        {
            get
            {
                string? dir = Environment.GetEnvironmentVariable("QD_E2E_DIR");
                if (!string.IsNullOrEmpty(dir))
                {
                    Directory.CreateDirectory(dir);
                    return dir!;
                }

                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "QuickDrawer");
            }
        }
    }
}
