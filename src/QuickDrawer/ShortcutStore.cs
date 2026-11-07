using System.IO;
using System.Text.Json;

namespace QuickDrawer;

/// <summary>
/// 快捷方式数据读写。存储位置 %APPDATA%\QuickDrawer\shortcuts.json。
/// 数据模型见 Config.cs 的 ShortcutsData / ShortcutItem / PathCategory，
/// 框架设计见 docs/可行性方案.md §8.0 / §8.2。
/// </summary>
public static class ShortcutStore
{
    /// <summary>
    /// .lnk 解析器复用单例：COM 对象有创建开销，且需要及时释放。
    /// </summary>
    private static readonly ShellLinkResolver LnkResolver = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public static string FilePath => Path.Combine(ConfigStore.BaseDir, "shortcuts.json");

    /// <summary>
    /// 首次加载时若没有数据，预置两个分类，让用户一进来就有可点的内容
    /// （否则空面板会让用户以为程序坏了）。
    ///
    /// 数据保护（发布前审查 B2）：只有"文件不存在"才落种子数据；
    /// "文件存在但解析失败"一律留档后**不写盘**，绝不用种子覆盖用户数据。
    /// </summary>
    public static ShortcutsData Load()
    {
        bool existed = File.Exists(FilePath);

        if (existed)
        {
            try
            {
                ShortcutsData? data = JsonSerializer.Deserialize<ShortcutsData>(
                    File.ReadAllText(FilePath), JsonOptions);
                if (data is not null)
                {
                    return data;
                }

                DiagLog.Write("shortcuts", "load returned null, treating as corrupt");
            }
            catch (Exception ex)
            {
                DiagLog.Write("shortcuts", $"load failed: {ex.Message}");
            }

            // 走到这里说明文件存在但读不出来：留档，本次运行用内存里的种子数据。
            // 不调用 Save——原文件（或它的留档）必须原样保留，让用户有机会手工恢复。
            CorruptFile.Archive(FilePath);
            return NewWithSeedCategories();
        }

        var seeded = NewWithSeedCategories();

        // 首次运行立即落盘。
        // 原因：若进程被强杀或崩溃，Closing 事件不会执行，下次启动会重新生成种子数据，
        // 用户已经添加的内容将永久丢失（2026-10-18 实测踩坑）。
        Save(seeded);

        return seeded;
    }

    /// <summary>返回 false 表示写盘失败——调用方必须让用户知道。</summary>
    public static bool Save(ShortcutsData data)
    {
        try
        {
            Directory.CreateDirectory(ConfigStore.BaseDir);
            string tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(data, JsonOptions));
            Compat.MoveOverwrite(tmp, FilePath);
            DiagLog.Write("shortcuts",
                $"saved: apps={data.Apps.Count} categories={data.Categories.Count} paths={data.Paths.Count}");
            return true;
        }
        catch (Exception ex)
        {
            DiagLog.Write("shortcuts", $"save failed: {ex.Message}");
            return false;
        }
    }

    private static ShortcutsData NewWithSeedCategories()
    {
        var data = new ShortcutsData();

        // 预置"我的电脑"分类，并把本机盘符放进去
        var myPc = new PathCategory { Name = "我的电脑", Order = 0, Expanded = true };
        data.Categories.Add(myPc);

        int order = 0;
        foreach (var drive in DriveInfo.GetDrives())
        {
            if (!drive.IsReady)
            {
                continue;
            }

            data.Paths.Add(new ShortcutItem
            {
                Kind = "drive",
                Name = drive.Name.TrimEnd('\\'),
                Target = drive.RootDirectory.FullName,
                CategoryId = myPc.Id,
                Order = order++
            });
        }

        // 预置一个空的"常用"分类
        data.Categories.Add(new PathCategory { Name = "常用", Order = 1, Expanded = true });

        return data;
    }

    /// <summary>
    /// 扫描系统里已安装的应用程序，用于"快捷方式列表"添加方式（问题 2 的次优选）。
    ///
    /// 扫描范围（覆盖绝大多数用户日常使用的软件）：
    ///   - %APPDATA%\Microsoft\Windows\Start Menu\Programs        （用户级开始菜单）
    ///   - %ProgramData%\Microsoft\Windows\Start Menu\Programs     （所有用户级）
    ///   - %USERPROFILE%\Desktop                                  （桌面快捷方式）
    ///   - %PUBLIC%\Desktop                                       （公共桌面）
    ///
    /// ⚠️ 必须自己递归，**不能用 Directory.EnumerateFiles(..., SearchOption.AllDirectories)**。
    /// 2026-10-19 实测：AllDirectories 会跟随目录联接（junction / symlink）。
    /// 本机桌面下的 pnpm `node_modules\.pnpm\` 里有数千个联接且互相指向，
    /// 导致遍历失控——进程内存涨到 3.1 GB、句柄近千万、CPU 打满，
    /// 对应用户报告的"内存 3-4GB、时不时卡顿"。
    /// 对照：跳过联接的自定义递归只需 1.72 秒即可数完 159 个 .lnk。
    ///
    /// 按显示名去重。
    /// </summary>
    public static List<ShortcutItem> ScanInstalledApps(CancellationToken ct = default)
    {
        var found = new Dictionary<string, ShortcutItem>(StringComparer.OrdinalIgnoreCase);

        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        string publicDir = Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory);
        string userDesktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

        foreach (string root in new[]
        {
            Path.Combine(appData, @"Microsoft\Windows\Start Menu\Programs"),
            Path.Combine(programData, @"Microsoft\Windows\Start Menu\Programs"),
            userDesktop,
            publicDir
        })
        {
            CollectSafe(root, 0, found, ct);
        }

        var list = found.Values
            .OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

        DiagLog.Write("scan", $"found {list.Count} installed applications");
        return list;
    }

    /// <summary>递归深度上限。开始菜单的正常层级不超过 4 层。</summary>
    private const int MaxScanDepth = 6;

    /// <summary>安全递归：跳过目录联接 / 符号链接，并限制深度与总耗时。</summary>
    private static void CollectSafe(string dir, int depth,
        Dictionary<string, ShortcutItem> into, CancellationToken ct)
    {
        if (depth > MaxScanDepth || ct.IsCancellationRequested)
        {
            return;
        }

        try
        {
            foreach (string file in Directory.EnumerateFiles(dir, "*.lnk"))
            {
                ct.ThrowIfCancellationRequested();
                TryAdd(into, file);
            }
        }
        catch (Exception ex)
        {
            DiagLog.Write("scan", $"skip files in {dir}: {ex.Message}");
            return;
        }

        string[] subdirs;
        try
        {
            subdirs = Directory.GetDirectories(dir);
        }
        catch (Exception ex)
        {
            DiagLog.Write("scan", $"skip dirs in {dir}: {ex.Message}");
            return;
        }

        foreach (string sub in subdirs)
        {
            ct.ThrowIfCancellationRequested();

            // 关键：跳过重解析点（junction / symlink）。
            // 不跳过会在 pnpm 之类的目录结构里无限递归。
            if (IsReparsePoint(sub))
            {
                continue;
            }

            CollectSafe(sub, depth + 1, into, ct);
        }
    }

    /// <summary>
    /// 判断路径是否为重解析点（目录联接 / 符号链接 / 其他 reparse point）。
    /// </summary>
    internal static bool IsReparsePoint(string path)
    {
        try
        {
            FileAttributes attrs = File.GetAttributes(path);
            return (attrs & FileAttributes.ReparsePoint) != 0;
        }
        catch
        {
            // 取不到属性就当作普通目录（例如无权访问），
            // 真正的保护由 MaxScanDepth 兜底。
            return false;
        }
    }

    private static void TryAdd(Dictionary<string, ShortcutItem> into, string lnkPath)
    {
        try
        {
            var item = Classify(lnkPath);
            // 只要应用，目录/文件不是这个列表的范畴
            if (item.Kind != "app")
            {
                return;
            }

            string key = item.Name;
            if (!into.ContainsKey(key))
            {
                into[key] = item;
            }
        }
        catch
        {
            // 单个条目失败不影响整体
        }
    }

    /// <summary>
    /// 按 Kind 推断一个快捷方式项，用于拖入时的自动识别。
    ///
    /// .lnk 处理要点（2026-10-18 用户反馈问题 1）：
    /// 用户从桌面拖进来的是 .lnk，必须解析出真实目标才能判断该放应用区还是目录区，
    /// 否则会被当成普通文件误放进"我的电脑"。
    /// </summary>
    public static ShortcutItem Classify(string path)
    {
        string ext = Path.GetExtension(path).ToLowerInvariant();

        // ---- .lnk：解析真实目标后再分流 ----
        if (ext == ".lnk")
        {
            string? real = LnkResolver.TryResolve(path);
            if (!string.IsNullOrWhiteSpace(real))
            {
                string realExt = Path.GetExtension(real).ToLowerInvariant();
                bool isExe = realExt is ".exe" or ".com";
                bool isDir = Directory.Exists(real);

                return new ShortcutItem
                {
                    Kind = isExe ? "app" : isDir ? "dir" : "file",
                    // 应用/目录显示 lnk 自己的名字（如 "Visual Studio Code"），更符合用户认知
                    Name = isExe || isDir
                        ? LnkResolver.GetDisplayName(path)
                        : Path.GetFileName(real),
                    Target = real!
                };
            }

            // 解析失败：多为 UWP/虚拟对象（实测 File Explorer.lnk、eSearch.lnk 属于此类）。
            // 它们没有真实文件系统路径，本就不该进应用区，按文件处理。
            DiagLog.Write("shortcuts", $"no resolvable target for .lnk (likely UWP): {path}");
            return new ShortcutItem
            {
                Kind = "file",
                Name = LnkResolver.GetDisplayName(path),
                Target = path
            };
        }

        // ---- .exe：应用 ----
        if (ext == ".exe" || ext == ".com")
        {
            return new ShortcutItem
            {
                Kind = "app",
                Name = Path.GetFileNameWithoutExtension(path),
                Target = path
            };
        }

        // ---- 盘符 ----
        if (path.Length == 3 && path[1] == ':' && path[2] == '\\')
        {
            return new ShortcutItem { Kind = "drive", Name = path.TrimEnd('\\'), Target = path };
        }

        // ---- 目录 / 文件 ----
        if (Directory.Exists(path))
        {
            return new ShortcutItem
            {
                Kind = "dir",
                Name = Path.GetFileName(path.TrimEnd('\\')),
                Target = path
            };
        }

        if (File.Exists(path))
        {
            return new ShortcutItem { Kind = "file", Name = Path.GetFileName(path), Target = path };
        }

        return new ShortcutItem { Kind = "file", Name = Path.GetFileName(path), Target = path };
    }
}
