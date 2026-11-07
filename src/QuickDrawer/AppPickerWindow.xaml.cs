using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace QuickDrawer;

/// <summary>
/// 应用选择器列表项。
/// 实现 INotifyPropertyChanged 是为了让"懒加载图标"生效：
/// Icon 赋值后必须通知 WPF 重新取 Source，否则界面永远空白。
/// </summary>
public sealed class AppChoice : System.ComponentModel.INotifyPropertyChanged
{
    private BitmapSource? _icon;

    public ShortcutItem Item { get; init; } = new();

    public string DisplayName => Item.Name;

    public string DisplayPath => Item.Target;

    public bool IsChecked { get; set; }

    /// <summary>图标。首次为 null，由 LoadIconsIncrementallyAsync 分批填充。</summary>
    public BitmapSource? Icon
    {
        get => _icon;
        set
        {
            _icon = value;
            PropertyChanged?.Invoke(this,
                new System.ComponentModel.PropertyChangedEventArgs(nameof(Icon)));
        }
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>
/// "快捷方式列表"添加窗口（问题 2 的次优方式）。
/// 扫描已安装应用，多选后一次加入。
/// </summary>
public partial class AppPickerWindow : Window
{
    /// <summary>用户勾选的应用。</summary>
    public List<ShortcutItem> Selected { get; } = new();

    public AppPickerWindow()
    {
        InitializeComponent();
        // 深色主题下标题栏不跟着变色会很割裂，DWM 只能在句柄建好之后设。
        SourceInitialized += (_, _) => ThemeService.ApplyWindowChrome(this);
        Loaded += (_, _) => LoadAsync();
    }

    private async void LoadAsync()
    {
        StatusText.Text = "正在扫描已安装的应用…";
        ListBox.Items.Clear();

        // 扫描可能稍慢，允许用户在关窗时取消它
        CancellationTokenSource cts = new();
        Closed += (_, _) => cts.Cancel();

        List<ShortcutItem> apps;
        try
        {
            apps = await Task.Run(() => ShortcutStore.ScanInstalledApps(cts.Token), cts.Token);
        }
        catch (OperationCanceledException)
        {
            return;   // 用户关掉了窗口
        }
        catch (Exception ex)
        {
            // 之前这里没有 try/catch：扫描一抛异常，async void 就静默死了，
            // 界面永远停在"正在扫描…"（2026-10-19 用户反馈问题 1）
            StatusText.Text = $"扫描失败：{ex.Message}";
            DiagLog.Write("picker", $"ScanInstalledApps threw: {ex}");
            return;
        }

        // ⚠️ 性能关键（2026-10-19 用户反馈内存 3-4GB + 卡顿）：
        // 这一段绝不能同步做。旧代码对每个应用立即调 GetAppIcon（COM + 文件 IO），
        // 159 个应用会阻塞 UI 线程数秒，并把大量 BitmapSource 缓存进内存。
        // 现在：先只放文字条目，图标在 UI 呈现后再按需取。
        foreach (var app in apps)
        {
            ListBox.Items.Add(new AppChoice { Item = app });
        }

        StatusText.Text = apps.Count > 0
            ? $"找到 {apps.Count} 个应用，勾选后点「添加」（图标稍后陆续显示）"
            : "没有扫描到应用。可改用「浏览文件」手动选择 exe。";

        DiagLog.Write("picker", $"scan finished: {apps.Count} apps listed, icons load lazily");

        // 等布局完成、列表滚动停稳后再分批补图标，避免与用户交互抢 UI 线程
        if (apps.Count > 0)
        {
            await LoadIconsIncrementallyAsync();
        }
    }

    /// <summary>
    /// 分批补图标：每批之间让出 UI 线程，用户随时可操作。
    /// </summary>
    private async Task LoadIconsIncrementallyAsync()
    {
        const int BatchSize = 8;

        for (int i = 0; i < ListBox.Items.Count; i += BatchSize)
        {
            int end = Math.Min(i + BatchSize, ListBox.Items.Count);

            for (int j = i; j < end; j++)
            {
                if (ListBox.Items[j] is AppChoice { Icon: null } choice)
                {
                    // 单个图标失败不影响整体
                    choice.Icon = IconService.GetAppIcon(choice.Item.Target);
                }
            }

            // 让出线程，保持界面响应
            await Task.Delay(20);

            // 若窗口已关闭，停止加载
            if (!IsLoaded)
            {
                return;
            }
        }

        StatusText.Text = $"找到 {ListBox.Items.Count} 个应用，勾选后点「添加」";
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        foreach (object? o in ListBox.Items)
        {
            if (o is AppChoice { IsChecked: true } choice)
            {
                Selected.Add(choice.Item);
            }
        }

        if (Selected.Count == 0)
        {
            MessageBox.Show(this, "请至少勾选一个应用。", "QuickDrawer",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        DialogResult = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        // 列表方式找不到时的兜底：直接浏览 exe
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择应用程序",
            Filter = "可执行文件 (*.exe)|*.exe|快捷方式 (*.lnk)|*.lnk",
            Multiselect = true
        };

        if (dlg.ShowDialog(this) != true)
        {
            return;
        }

        foreach (string f in dlg.FileNames)
        {
            var item = ShortcutStore.Classify(f);
            item.Kind = "app";
            Selected.Add(item);
        }

        DialogResult = true;
        Close();
    }
}