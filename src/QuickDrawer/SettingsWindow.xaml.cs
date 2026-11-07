using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace QuickDrawer;

/// <summary>
/// 设置页（M5）。
///
/// 与抽屉不同，这里是**普通激活窗口**：用户主动打开它编辑配置，
/// 需要正常的焦点行为与前台感。
///
/// 所有改动即时生效并落盘（无"确定"按钮）。
/// 热键修改用"点击修改 → 按键捕获"模式。
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly AppConfig _config;
    private readonly DrawerWindow _owner;

    /// <summary>配置被修改后由抽屉应用（如重新注册热键、刷新宽度）。</summary>
    public event Action<AppConfig>? SettingsChanged;

    /// <summary>
    /// 当前正在采集哪一路热键（2026-11-01 七次：从 bool 改成枚举）。
    /// 原来只有一个 bool，加了截图热键后两路共用同一个采集状态，
    /// 会出现"点了截图热键的修改，却在改唤出热键"的错误绑定。
    /// </summary>
    private HotkeyTarget _capturingHotkey;

    private enum HotkeyTarget
    {
        None = 0,
        Toggle = 1,
        Shot = 2,
    }
    private bool _loading;

    /// <summary>
    /// ⚠️ `_loading = true` 必须在 InitializeComponent() **之前**（2026-10-22 踩坑）：
    /// Slider 的 Minimum 会把默认 Value(0) 抬到下限，ValueChanged 在
    /// XAML 解析期间就触发 —— 此时 _config/_owner 还是 null，
    /// 防护若未生效就是 NRE，直接杀死进程（用户实测"点设置整个应用退出"）。
    /// 这与 2026-10-18 便签区 IsChecked 触发 Checked 是同一类坑。
    /// </summary>
    public SettingsWindow(DrawerWindow owner, AppConfig config)
    {
        _loading = true;        // 先立防护，再解析 XAML
        _owner = owner;
        _config = config;

        InitializeComponent();
        // 深色主题下标题栏不跟着变色会很割裂，DWM 只能在句柄建好之后设。
        SourceInitialized += (_, _) => ThemeService.ApplyWindowChrome(this);
        Owner = owner;

        LoadValues();
    }

    private void LoadValues()
    {
        // 注意：_loading 已在构造器里置 true；这里只是保持原语义的写法。
        WidthSlider.Value = _config.Dock.Width;
        HandleHeightSlider.Value = _config.Dock.Handle.HeightPx;
        CollapseDelaySlider.Value = _config.Dock.Handle.CollapseDelayMs;
        NoteFontSlider.Value = _config.Notes.FontSize;
        HotkeyText.Text = $"{string.Join("+", _config.Hotkey.Mods)}+{_config.Hotkey.Key}";
        RefreshHotkeyHint();
        RefreshShotHotkeyText();
        ZoomScaleCheck.IsChecked = _config.Assistant.ZoomScaleWithWidth;

        // 2026-11-01 用户反馈：宽度数值标签"始终为默认 380，与实际数值不符"。
        // 根因：上面三个 Slider 的 Value 赋值全在 _loading=true 期间，
        // 而数字标签（WidthText/HandleHeightText/CollapseDelayText）**只在
        // ValueChanged 里**刷新 —— 加载路径根本不写它们，所以它们一直显示
        // XAML 里写死的初值（380 / 120 / 600），跟真实配置无关。
        // Slider.Value 传的是同一份配置值，直接用它同步标签，不重复取 config，
        // 保证"滑块位置"和"数字"永远来自同一个数。
        RefreshValueLabels();

        LoadPresets();

        _loading = false;   // 防护解除，之后的 ValueChanged 是用户操作
    }

    /// <summary>
    /// 把三个滑块的当前值同步到旁边的数字标签。
    /// 加载、拖动、外部改动都走这里，避免标签与滑块再次分叉。
    /// </summary>
    private void RefreshValueLabels()
    {
        WidthText.Text = ((int)WidthSlider.Value).ToString();
        HandleHeightText.Text = ((int)HandleHeightSlider.Value).ToString();
        CollapseDelayText.Text = ((int)CollapseDelaySlider.Value).ToString();
        NoteFontText.Text = ((int)NoteFontSlider.Value).ToString();
    }

    private void SaveAndApply()
    {
        if (_loading)
        {
            return;
        }

        // 发布前审查 M4：保存失败必须让用户看见，不能显示"已保存"却什么都没写进去。
        bool ok = ConfigStore.Save(_config);
        SettingsChanged?.Invoke(_config);
        StatusText.Text = ok
            ? $"已保存 {DateTime.Now:HH:mm:ss}"
            : "保存失败：无法写入配置目录（磁盘满或没有权限）";
    }

    /* ---------- 面板宽度 ---------- */

    private void WidthSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading)
        {
            return;
        }

        int width = (int)e.NewValue;
        _config.Dock.Width = width;
        WidthText.Text = width.ToString();
        _owner.Width = width;

        if (_owner.IsOpen)
        {
            // 面板正展开时重新贴边定位
            _owner.RepositionOpen();
        }

        // 2026-10-31：常规宽度变了，助手页的"宽度倍数"基准也跟着变，
        // 重新算一次缩放，否则加宽时的放大比例会偏。
        _owner.RefreshAssistantZoom();

        SaveAndApply();
    }

    /* ---------- 便签字号（2026-11-03 用户需求） ---------- */

    /// <summary>
    /// 便签正文字号。
    ///
    /// 改动即时生效：_owner.ApplyNoteFontSize() 把新值写进 App 级资源，
    /// 卡片正文用的是 DynamicResource，界面当场就变，不需要重建卡片或重启。
    /// 拖滑块时每一格都会落盘一次 —— 与其它几个滑块保持一致的行为，
    /// 配置写的是本地小文件，代价可以忽略。
    /// </summary>
    private void NoteFontSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading)
        {
            return;
        }

        int size = (int)e.NewValue;
        _config.Notes.FontSize = size;
        NoteFontText.Text = size.ToString();

        _owner.ApplyNoteFontSize();

        SaveAndApply();
    }

    /* ---------- 热键 ---------- */

    private void HotkeyCapture_Click(object sender, RoutedEventArgs e)
    {
        BeginCapture(HotkeyTarget.Toggle);
    }

    private void ShotHotkeyCapture_Click(object sender, RoutedEventArgs e)
    {
        BeginCapture(HotkeyTarget.Shot);
    }

    /// <summary>
    /// 切换采集目标。再点同一路等于取消（行为与改造前一致）。
    /// </summary>
    private void BeginCapture(HotkeyTarget target)
    {
        if (_capturingHotkey == target)
        {
            StopCapture();
            return;
        }

        _capturingHotkey = target;

        if (target == HotkeyTarget.Shot)
        {
            ShotHotkeyCapture.Content = "按下组合键…";
            ShotHotkeyHint.Text = "请按下新的截图热键（必须含 Win/Ctrl/Alt/Shift 之一 + 字母或数字）；Esc 取消";
            ResetToggleCaptureVisual();
            ShotHotkeyCapture.Focus();
        }
        else
        {
            HotkeyCapture.Content = "按下组合键…";
            HotkeyHint.Text = "请按下新组合键（必须包含 Win/Ctrl/Alt/Shift 之一 + 字母或数字）；Esc 取消";
            ResetShotCaptureVisual();
            HotkeyCapture.Focus();
        }
    }

    private void StopCapture()
    {
        _capturingHotkey = HotkeyTarget.None;
        ResetToggleCaptureVisual();
        ResetShotCaptureVisual();
    }

    private void ResetToggleCaptureVisual()
    {
        HotkeyCapture.Content = "修改";
        RefreshHotkeyHint();
    }

    /// <summary>
    /// 显示唤出热键的提示文本。
    ///
    /// 关键：首选组合被别的程序占用时，抽屉会自动降级到备选（Win+Shift+V 等），
    /// 这时配置里写的和实际生效的**不是同一个键**。原来界面只显示配置值，
    /// 用户会以为自己按了个"没反应"的键。这里把实际生效的组合一并说出来。
    /// </summary>
    private void RefreshHotkeyHint()
    {
        const string baseHint = "点击“修改”后按下新组合键（含 Win/Ctrl/Alt/Shift）";

        string configured = HotkeyText.Text;
        string active = _owner?.ActiveHotkeyLabel ?? string.Empty;

        if (string.IsNullOrEmpty(active)
            || active.StartsWith("(", StringComparison.Ordinal)
            || string.Equals(active, configured, StringComparison.OrdinalIgnoreCase))
        {
            HotkeyHint.Text = baseHint;
            return;
        }

        HotkeyHint.Text = $"首选热键被占用，本次运行实际生效的是 {active}（配置值重启后重新尝试）";
    }

    private void ResetShotCaptureVisual()
    {
        ShotHotkeyCapture.Content = "修改";
        ShotHotkeyHint.Text = "全局按下即进入截图框选；“关闭”后只能用助手页工具栏的截图按钮";
    }

    /// <summary>把「关闭」（空 key）写进配置并重新注册，同时刷新显示。</summary>
    private void ShotHotkeyClear_Click(object sender, RoutedEventArgs e)
    {
        _capturingHotkey = HotkeyTarget.None;
        ResetShotCaptureVisual();

        _config.ShotHotkey.Key = string.Empty;
        RefreshShotHotkeyText();

        string? result = _owner.RegisterShotHotkey();
        ShotHotkeyHint.Text = result is null
            ? "截图热键已关闭，只能用工具栏按钮"
            : $"关闭失败（{result}）";

        SaveAndApply();
    }

    /// <summary>
    /// 刷新截图热键显示。Key 为空时显示「已关闭」——
    /// 空字符串如果直接拼出来会变成 "win+alt+"，看不出是故意关掉的。
    /// </summary>
    private void RefreshShotHotkeyText()
    {
        HotkeyConfig cfg = _config.ShotHotkey;
        ShotHotkeyText.Text = string.IsNullOrWhiteSpace(cfg.Key)
            ? "已关闭"
            : $"{string.Join("+", cfg.Mods)}+{cfg.Key}";
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (_capturingHotkey == HotkeyTarget.None)
        {
            base.OnKeyDown(e);
            return;
        }

        if (e.Key == Key.Escape)
        {
            StopCapture();
            e.Handled = true;
            return;
        }

        bool forShot = _capturingHotkey == HotkeyTarget.Shot;
        TextBlock hint = forShot ? ShotHotkeyHint : HotkeyHint;

        // 收集修饰键
        var mods = new List<string>();
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows)) mods.Add("win");
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) mods.Add("ctrl");
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) mods.Add("alt");
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) mods.Add("shift");

        if (mods.Count == 0)
        {
            hint.Text = "至少需要一个修饰键（Win/Ctrl/Alt/Shift）";
            e.Handled = true;
            return;
        }

        // 主键（字母或数字）
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;

        if (key is not (>= Key.A and <= Key.Z or >= Key.D0 and <= Key.D9))
        {
            hint.Text = "主键需要是字母或数字";
            e.Handled = true;
            return;
        }

        string keyName = key.ToString();

        // 两路撞成同一个组合键时直接拒绝：RegisterHotKey 对同一窗口的
        // 重复组合键会失败，而且 WM_HOTKEY 只会落到先注册的那一路，
        // 表现出来是"截图热键变成了唤出面板"，很难自己看懂。
        HotkeyConfig other = forShot ? _config.Hotkey : _config.ShotHotkey;
        if (!string.IsNullOrWhiteSpace(other.Key)
            && string.Equals(other.Key.Trim(), keyName, StringComparison.OrdinalIgnoreCase)
            && SameMods(other.Mods, mods))
        {
            hint.Text = forShot
                ? "与唤出热键相同，请换一个组合键"
                : "与截图热键相同，请换一个组合键";
            e.Handled = true;
            return;
        }

        HotkeyConfig target = forShot ? _config.ShotHotkey : _config.Hotkey;
        target.Mods = mods;
        target.Key = keyName;

        _capturingHotkey = HotkeyTarget.None;
        ResetToggleCaptureVisual();
        ResetShotCaptureVisual();

        if (forShot)
        {
            RefreshShotHotkeyText();
            string? shotResult = _owner.RegisterShotHotkey();
            ShotHotkeyHint.Text = shotResult is null
                ? "截图热键已更新"
                : $"注册失败（{shotResult}）";
        }
        else
        {
            HotkeyText.Text = $"{string.Join("+", mods)}+{_config.Hotkey.Key}";
            string? result = _owner.ReregisterHotkey();
            HotkeyHint.Text = string.IsNullOrEmpty(result)
                ? "热键已更新"
                : $"注册失败（{result}），已保留原热键";
        }

        SaveAndApply();
        e.Handled = true;
    }

    /// <summary>比较两组修饰键名是否等价（顺序无关，忽略大小写）。</summary>
    private static bool SameMods(List<string> a, List<string> b)
    {
        static string Norm(string m) => m.Trim().ToLowerInvariant() switch
        {
            "control" => "ctrl",
            var other => other
        };

        var left = a.Select(Norm).Where(s => s.Length > 0).Distinct().OrderBy(s => s).ToList();
        var right = b.Select(Norm).Where(s => s.Length > 0).Distinct().OrderBy(s => s).ToList();
        return left.SequenceEqual(right);
    }

    /* ---------- 开机自启（2026-11-01 三次从设置页移除） ---------- */

    // 用户反馈：「设置页里的开机自启选项和菜单里的重复了」。
    // 现在只有面板菜单（DrawerWindow.OpenAppMenu）一个入口，它直接读写
    // AutoStart.SetEnabled + _config.StartWithWindows，不再需要这里的处理器。
    // 保留注释是为了避免以后有人看到 Config.StartWithWindows 又把勾选框加回来。

    /* ---------- 助手页：字体随宽度缩放（2026-10-31） ---------- */

    private void ZoomScaleCheck_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading)
        {
            return;
        }

        _config.Assistant.ZoomScaleWithWidth = ZoomScaleCheck.IsChecked == true;

        // 立刻重算缩放：开启时按当前宽度比例放大，关闭时回到基础缩放
        _owner.RefreshAssistantZoom();

        SaveAndApply();
    }

    /* ---------- 悬浮按钮预设提示词（2026-10-31 七次） ---------- */

    /// <summary>
    /// 编辑用的条目副本。列表直接绑这个集合，
    /// 用户改完一个字段就同步回 _config.Assistant.Prompts 再落盘。
    /// </summary>
    private sealed class PresetItem : INotifyPropertyChanged
    {
        private string _label = "";
        private string _instruction = "";

        public string Id { get; set; } = "";

        public string Label
        {
            get => _label;
            set
            {
                if (_label == value)
                {
                    return;
                }

                _label = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Label)));
            }
        }

        public string Instruction
        {
            get => _instruction;
            set
            {
                if (_instruction == value)
                {
                    return;
                }

                _instruction = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Instruction)));
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }

    private readonly ObservableCollection<PresetItem> _presets = new();

    private void LoadPresets()
    {
        _presets.Clear();

        foreach (PromptPreset p in _config.Assistant.Prompts)
        {
            _presets.Add(new PresetItem
            {
                Id = p.Id,
                Label = p.Label,
                Instruction = p.Instruction,
            });
        }

        PresetList.ItemsSource = _presets;
        PresetList.SelectedIndex = _presets.Count > 0 ? 0 : -1;
        RefreshPresetEditors();
    }

    /// <summary>把当前选中项填进右侧两个编辑框（未选中时清空并禁用）。</summary>
    private void RefreshPresetEditors()
    {
        PresetItem? item = PresetList.SelectedItem as PresetItem;

        bool has = item is not null;
        PresetLabelBox.IsEnabled = has;
        PresetInstructionBox.IsEnabled = has;
        PresetRemoveButton.IsEnabled = has;

        PresetLabelBox.Text = item?.Label ?? "";
        PresetInstructionBox.Text = item?.Instruction ?? "";
    }

    /// <summary>把编辑区的内存副本整体写回配置（保持列表顺序）。</summary>
    private void SyncPresetsToConfig()
    {
        _config.Assistant.Prompts = _presets
            .Select(p => new PromptPreset { Id = p.Id, Label = p.Label, Instruction = p.Instruction })
            .ToList();
    }

    private void PresetList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }

        RefreshPresetEditors();
    }

    private void PresetLabelBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (_loading || PresetList.SelectedItem is not PresetItem item)
        {
            return;
        }

        if (item.Label == PresetLabelBox.Text)
        {
            return;
        }

        item.Label = PresetLabelBox.Text;
        SyncPresetsToConfig();
        SaveAndApply();
    }

    private void PresetInstructionBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (_loading || PresetList.SelectedItem is not PresetItem item)
        {
            return;
        }

        if (item.Instruction == PresetInstructionBox.Text)
        {
            return;
        }

        item.Instruction = PresetInstructionBox.Text;
        SyncPresetsToConfig();
        SaveAndApply();
    }

    private void PresetAdd_Click(object sender, RoutedEventArgs e)
    {
        // 用时间戳做 id，避免和用户已有条目撞名
        var item = new PresetItem
        {
            Id = "custom" + DateTime.Now.ToString("HHmmss"),
            Label = "新按钮",
            Instruction = "请处理下面的内容，只给结果。",
        };

        _presets.Add(item);
        SyncPresetsToConfig();

        PresetList.SelectedItem = item;
        RefreshPresetEditors();
        PresetLabelBox.Focus();
        PresetLabelBox.SelectAll();

        SaveAndApply();
    }

    private void PresetRemove_Click(object sender, RoutedEventArgs e)
    {
        if (PresetList.SelectedItem is not PresetItem item)
        {
            return;
        }

        int index = _presets.IndexOf(item);
        _presets.Remove(item);
        SyncPresetsToConfig();

        // 删完选同位置的下一个，列表空了就清空编辑区
        if (_presets.Count > 0)
        {
            PresetList.SelectedIndex = Math.Min(index, _presets.Count - 1);
        }

        RefreshPresetEditors();
        SaveAndApply();
    }

    /* ---------- 拉手高度 / 收起延迟 ---------- */

    private void HandleHeightSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading)
        {
            return;
        }

        int h = (int)e.NewValue;
        _config.Dock.Handle.HeightPx = h;
        HandleHeightText.Text = h.ToString();
        SaveAndApply();
    }

    private void CollapseDelaySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading)
        {
            return;
        }

        int ms = (int)e.NewValue;
        _config.Dock.Handle.CollapseDelayMs = ms;
        CollapseDelayText.Text = ms.ToString();
        SaveAndApply();
    }

    private void Window_Closed(object sender, EventArgs e)
    {
        // 释放对 DrawerWindow 的引用，让设置页可被 GC
        // （Owner 赋 null 在 Window 上是合法的：无属主窗口）
        ClearOwnerReference();
        SettingsChanged = null;
    }

    private void ClearOwnerReference()
    {
        try
        {
            // Window.Owner 是 null 容忍的；这里显式清引用防泄漏
            Owner = null!;
        }
        catch
        {
            // 理论上不会失败；防御性捕获避免关闭流程被打断
        }
    }
}