using System.IO;
using System.Text.Json;
using System.Threading;
using System.Windows;

namespace QuickDrawer;

/// <summary>
/// 应用入口：加载配置、创建抽屉窗口。
/// </summary>
public partial class App : Application
{
    // 单实例互斥锁。
    // 没有它时，用户重复双击会让多个进程互相抢占同一个全局热键，
    // 后续进程全部报 ERROR_HOTKEY_ALREADY_REGISTERED(1409)，且窗口藏在屏幕外
    // 看不见也关不掉，只能去任务管理器杀。这是 2026-10-18 用户实际遇到的问题。
    private const string MutexName = "Global\\QuickDrawer.SingleInstance";
    private Mutex? _singleInstanceMutex;

    // 只有真正拿到所有权的进程才允许 ReleaseMutex。
    // 第二个进程虽然构造了 Mutex 对象，但不拥有它，调用 ReleaseMutex 会抛
    // ApplicationException: "Object synchronization method was called from an
    // unsynchronized block of code."（2026-10-18 实测踩坑）
    private bool _ownsMutex;

    public static AppConfig Config { get; private set; } = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // 2026-10-22：全局异常兜底日志。
        // 用户报告"点设置整个应用就退出"，但日志里没有任何痕迹——
        // 未处理异常默认直接杀进程，必须先让它留痕才能定位。
        // 2026-11-01 审查 S6：异常必须让用户看见。
        // 以前三个钩子都只写日志、且 UI 线程异常没有 Handled = true ——
        // 托盘程序会因为一次 UI 异常直接消失，用户完全不知道发生了什么。
        DispatcherUnhandledException += (_, ex) =>
        {
            DiagLog.Write("crash", $"UI thread: {ex.Exception.GetType().Name}: {ex.Exception.Message}\n{ex.Exception.StackTrace}");

            // 保住进程：托盘程序不该因为一次 UI 异常就整个消失。
            ex.Handled = true;
            ShowNotice("界面出了点问题，但程序还在运行。\n详细信息已写入诊断日志。", CrashNoticeDuration);
        };

        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
        {
            if (ex.ExceptionObject is Exception exception)
            {
                DiagLog.Write("crash", $"domain: {exception.GetType().Name}: {exception.Message}\n{exception.StackTrace}");
                // 域异常无法阻止退出，只能尽力提示一次
                ShowNotice("程序遇到无法恢复的错误，即将退出。\n详细信息已写入诊断日志。", CrashNoticeDuration);
            }
        };

        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, ex) =>
        {
            DiagLog.Write("crash", $"task: {ex.Exception.GetType().Name}: {ex.Exception.Message}");
            // 后台任务的异常不弹窗（会变成噪音），但要标记为已观察，
            // 否则 .NET 可能把它升级成进程级未处理异常。
            ex.SetObserved();
        };

        // WPF 数据绑定需要 CultureInfo。若 csproj 误开 InvariantGlobalization，
        // 会在 Show() 时抛 "Cannot find non-neutral culture related to 'en-us'"。
        // 这里做启动自检，把问题暴露成可读信息而不是随机崩溃（2026-10-18 实测）。
        try
        {
            _ = System.Globalization.CultureInfo.CurrentCulture;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "启动失败：当前发布配置移除了区域信息，WPF 数据绑定无法工作。\n\n" +
                "请检查 QuickDrawer.csproj 中 InvariantGlobalization 是否为 true。\n\n" + ex.Message,
                "QuickDrawer 启动失败", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        // 先加载配置，再创建窗口（不能用 StartupUri，那会在 OnStartup 前构造窗口）
        Config = ConfigStore.Load();

        // 诊断日志开关必须在这里立刻生效 —— 再晚一点，启动过程的日志就已经落盘了。
        // DiagLog.Enabled 是 public static，默认 true；只有用户显式关掉才改。
        DiagLog.Enabled = Config.DiagLogEnabled;

        // M5：跟随系统深浅色主题（必须在窗口构造前应用，
        // 面板的 DynamicResource 在 InitializeComponent 解析期间就要解析）
        ThemeService.ApplySystemTheme();

        _singleInstanceMutex = new Mutex(true, MutexName, out bool createdNew);
        _ownsMutex = createdNew;

        if (!createdNew)
        {
            // 已有实例在运行。
            // 关键1：绝不能用模态 MessageBox 提示——它会把第二个进程挂住等用户点击，
            //        进程迟迟不退出，用户会以为又开了一份（2026-10-18 实测踩坑）。
            // 关键2：本进程不拥有互斥锁，绝不能 ReleaseMutex（见 _ownsMutex 注释）。
            DiagLog.Write("single-instance",
                "another instance already holds the mutex; refusing to start a second one");

            ShowAlreadyRunningNotice();
            Shutdown();
            return;
        }

        DiagLog.Write("single-instance", "mutex acquired; this is the first instance");
        DiagLog.Write("config",
            $"edge={Config.Dock.Edge} mode={Config.Dock.Mode} width={Config.Dock.Width} " +
            $"hotkey={string.Join("+", Config.Hotkey.Mods)}+{Config.Hotkey.Key}");

        MainWindow = new DrawerWindow(Config);
        MainWindow.Show();

        // 数据保护（B2）：本次启动如果归档过损坏文件，必须告诉用户。
        // 否则用户只会看到"我的便签/快捷方式全没了"，以为程序把数据吞了。
        ReportCorruptFiles();
    }

    /// <summary>
    /// 把本次启动归档的损坏文件告诉用户。没有损坏就什么都不做。
    /// </summary>
    private static void ReportCorruptFiles()
    {
        List<string> archived = CorruptFile.TakeNotices();
        if (archived.Count == 0)
        {
            return;
        }

        DiagLog.Write("corrupt", $"reporting {archived.Count} archived file(s) to the user");

        string names = string.Join("\n", archived.ConvertAll(Path.GetFileName));
        ShowNotice(
            "以下文件读取失败，已备份到原目录后按默认值继续运行：\n" +
            names +
            "\n\n你的旧数据没有被删除，可以从这些备份文件里找回。",
            TimeSpan.FromSeconds(12));
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_ownsMutex)
        {
            try
            {
                _singleInstanceMutex?.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // 理论上不该发生（已用 _ownsMutex 守门），但不能让清理逻辑炸掉退出流程
            }
        }
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }

    /// <summary>崩溃提示停留时长。</summary>
    private static readonly TimeSpan CrashNoticeDuration = TimeSpan.FromSeconds(8);

    // 提示限流：异常风暴时不要刷出几百个窗口。
    // 2026-11-01 审查 S6 加。
    private static readonly object NoticeGate = new();
    private static DateTime _lastNoticeUtc = DateTime.MinValue;

    /// <summary>
    /// 弹一个自动关闭的**非模态**提示窗。
    ///
    /// 为什么非模态：这个程序全程只有托盘，用 MessageBox 会把 UI 线程挂住等用户点击，
    /// 在异常处理路径上等于二次伤害（App.xaml.cs 里"已在运行"那段注释记录过同样的坑）。
    ///
    /// 可以从任意线程调用：非 UI 线程会被转投到 Dispatcher。
    /// 10 秒内只弹一次；提示本身失败也绝不抛异常（否则会盖掉真正的错误）。
    /// </summary>
    public static void ShowNotice(string text, TimeSpan duration)
    {
        try
        {
            lock (NoticeGate)
            {
                DateTime now = DateTime.UtcNow;
                if ((now - _lastNoticeUtc) < TimeSpan.FromSeconds(10))
                {
                    return;
                }

                _lastNoticeUtc = now;
            }

            System.Windows.Threading.Dispatcher? dispatcher = Current?.Dispatcher;
            if (dispatcher is null)
            {
                return;
            }

            if (!dispatcher.CheckAccess())
            {
                dispatcher.BeginInvoke(() => ShowNotice(text, duration));
                return;
            }

            var notice = new Window
            {
                SizeToContent = SizeToContent.WidthAndHeight,
                MaxWidth = 420,
                WindowStyle = WindowStyle.None,
                ResizeMode = ResizeMode.NoResize,
                ShowInTaskbar = false,
                ShowActivated = false,
                Topmost = true,
                Background = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromRgb(0x2D, 0x2D, 0x38)),
                WindowStartupLocation = WindowStartupLocation.CenterScreen,
                Content = new System.Windows.Controls.TextBlock
                {
                    Text = text,
                    Foreground = System.Windows.Media.Brushes.White,
                    FontSize = 13,
                    LineHeight = 20,
                    Margin = new Thickness(20, 16, 20, 16),
                    TextWrapping = TextWrapping.Wrap
                }
            };

            notice.Loaded += (_, _) =>
            {
                System.Windows.Threading.DispatcherTimer timer = new()
                {
                    Interval = duration
                };
                timer.Tick += (_, _) =>
                {
                    timer.Stop();
                    try
                    {
                        notice.Close();
                    }
                    catch
                    {
                        // 窗口可能已经被关掉了
                    }
                };
                timer.Start();
            };

            // 用 Show() 而不是 ShowDialog()：绝不阻塞消息循环。
            notice.Show();
        }
        catch
        {
            // 提示失败不能掩盖真正的错误
        }
    }

    /// <summary>
    /// "已在运行"提示：一个自动关闭的非模态小窗口。
    /// 不用 MessageBox，因为它模态且会把进程挂住直到用户点击。
    /// </summary>
    private static void ShowAlreadyRunningNotice()
    {
        var notice = new Window
        {
            Width = 300,
            Height = 90,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            Topmost = true,
            Background = System.Windows.Media.Brushes.DimGray,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            Content = new System.Windows.Controls.TextBlock
            {
                Text = "QuickDrawer 已在运行\n按 Win+Alt+N 唤出侧边栏",
                Foreground = System.Windows.Media.Brushes.White,
                FontSize = 14,
                TextAlignment = System.Windows.TextAlignment.Center,
                VerticalAlignment = System.Windows.VerticalAlignment.Center
            }
        };

        notice.Loaded += (_, _) =>
        {
            System.Windows.Threading.DispatcherTimer timer = new()
            {
                Interval = TimeSpan.FromSeconds(2.5)
            };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                notice.Close();
            };
            timer.Start();
        };

        notice.ShowDialog();
    }
}

/// <summary>
/// 配置读写。存储位置：%APPDATA%\QuickDrawer\config.json（见方案 §7.1）
/// </summary>
public static class ConfigStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public static string BaseDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "QuickDrawer");

    public static string FilePath => Path.Combine(BaseDir, "config.json");

    public static AppConfig Load()
    {
        string path = FilePath;

        if (!File.Exists(path))
        {
            return new AppConfig();   // 首次运行
        }

        try
        {
            string json = File.ReadAllText(path);
            AppConfig? config = JsonSerializer.Deserialize<AppConfig>(json, JsonOptions);
            if (config is null)
            {
                DiagLog.Write("config", "deserialize returned null, treating as corrupt");
                CorruptFile.Archive(path);
                return new AppConfig();
            }

            // 配置迁移：旧版本文件里存着过时的值，
            // 只改代码默认值对已有 config.json 不生效（2026-10-20 踩过）。
            if (Migrate(config))
            {
                Save(config);
                DiagLog.Write("config", $"migrated config to version {config.Version}");
            }

            return config;
        }
        catch (Exception ex)
        {
            // 数据保护（B2）：配置存在但解析失败时留档，本次用默认值在内存里跑，
            // 不写盘覆盖——否则用户手改坏一个逗号就丢掉全部自定义设置。
            DiagLog.Write("config", $"load failed: {ex.Message}");
            CorruptFile.Archive(path);
            return new AppConfig();
        }
    }

    /// <summary>
    /// 配置版本迁移。返回 true 表示已修改（需要写回磁盘）。
    /// </summary>
    private static bool Migrate(AppConfig config)
    {
        bool changed = false;

        if (config.Version < 2)
        {
            // v1 → v2：拉手尺寸加大（用户反馈"拉手长度可以再长一点"）
            config.Dock.Handle.HeightPx = 160;
            config.Dock.Handle.WidthPx = 8;
            config.Version = 2;
            changed = true;
        }

        if (config.Version < 3)
        {
            // v2 → v3：用户反馈 160px 偏长 → 120px；收起延迟 800 → 600ms
            config.Dock.Handle.HeightPx = 120;
            config.Dock.Handle.CollapseDelayMs = 600;
            config.Version = 3;
            changed = true;
        }

        if (config.Version < 4)
        {
            // v3 → v4：便签字号正式接上（2026-11-03 用户需求）。
            //
            // NotesConfig.FontSize 从 2026-10-18 就存在，但没有任何代码读过它，
            // 卡片正文一直是 XAML 写死的 12。老用户 config.json 里躺着那个
            // 从未生效的 14，直接接上会让他们一升级字就变大 —— 不是他们要求的变化。
            // 所以统一改写成 12（= 真实渲染值），外观保持不变，
            // 之后用户自己在设置里拖才是主动选择。
            config.Notes.FontSize = 12;
            config.Version = 4;
            changed = true;
        }

        return changed;
    }

    /// <summary>
    /// 保存配置。返回 false 表示写盘失败（磁盘满/只读/被占用）。
    ///
    /// 发布前审查 M4：原来这里没有任何 try/catch，磁盘满时直接抛到 UI 线程，
    /// 被全局兜底吞掉后用户看到的是"设置改了但重启就没了"，且毫无提示。
    /// </summary>
    public static bool Save(AppConfig config)
    {
        try
        {
            Directory.CreateDirectory(BaseDir);
            string tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(config, JsonOptions));
            Compat.MoveOverwrite(tmp, FilePath);
            return true;
        }
        catch (Exception ex)
        {
            DiagLog.Write("config", $"save failed: {ex.Message}");
            return false;
        }
    }
}
