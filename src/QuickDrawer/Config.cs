using System.Text.Json.Serialization;

namespace QuickDrawer;

/// <summary>
/// 应用配置。对应 docs/可行性方案.md §7.2。
/// 已按 2026-10-18 决策锁定默认值（见方案 §11）。
/// </summary>
public sealed class AppConfig
{
    private const int CurrentVersion = 4;

    [JsonPropertyName("version")]
    public int Version { get; set; } = CurrentVersion;

    /// <summary>决策 #2：抽屉停靠边缘，默认右侧。</summary>
    [JsonPropertyName("dock")]
    public DockConfig Dock { get; set; } = new();

    /// <summary>决策 #4：默认热键 Win+Alt+N。</summary>
    [JsonPropertyName("hotkey")]
    public HotkeyConfig Hotkey { get; set; } = new();

    /// <summary>
    /// 截图提问热键（2026-11-01 七次需求）。
    /// 与唤出抽屉的 <see cref="Hotkey"/> 分开两路：一处按错不至于两条功能一起废。
    /// Key 为空串表示"不注册"（用户可以在设置页关掉它，只用工具栏那个按钮）。
    /// </summary>
    [JsonPropertyName("shotHotkey")]
    public HotkeyConfig ShotHotkey { get; set; } = new()
    {
        Mods = new() { "win", "alt" },
        Key = "S",
    };

    [JsonPropertyName("clipboard")]
    public ClipboardConfig Clipboard { get; set; } = new();

    [JsonPropertyName("notes")]
    public NotesConfig Notes { get; set; } = new();

    /// <summary>
    /// 智能助手页（2026-10-26 需求）：内嵌 WebView2 的站点与缩放配置。
    /// </summary>
    [JsonPropertyName("assistant")]
    public AssistantConfig Assistant { get; set; } = new();

    /// <summary>
    /// 展示方式（2026-10-19 用户需求：文件/目录增加列表方式）。
    /// </summary>
    [JsonPropertyName("layout")]
    public LayoutConfig Layout { get; set; } = new();

    [JsonPropertyName("theme")]
    public string Theme { get; set; } = "auto";

    [JsonPropertyName("startWithWindows")]
    public bool StartWithWindows { get; set; }

    /// <summary>
    /// 诊断日志开关（2026-11-01 发布前审查 B1）。
    /// 默认 true —— 托盘程序出问题时没有日志基本无法排查。
    /// 隐私靠 <see cref="DiagLog.Redact"/> 与"只记事实不记内容"保证，
    /// 不靠关掉日志；但确有人不想留任何痕迹，给一个干净的开关。
    /// 关掉后 <see cref="DiagLog.Write"/> 直接 return，不做任何磁盘写入。
    /// </summary>
    [JsonPropertyName("diagLogEnabled")]
    public bool DiagLogEnabled { get; set; } = true;
}

/// <summary>
/// 展示方式配置。
/// </summary>
public sealed class LayoutConfig
{
    /// <summary>应用区：icon（每行 8 个）| list（一行一个带名称与路径）</summary>
    [JsonPropertyName("apps")]
    public string Apps { get; set; } = "icon";

    /// <summary>路径区：icon（图标网格）| list（一行一个，可显示完整路径）</summary>
    [JsonPropertyName("paths")]
    public string Paths { get; set; } = "list";

    /// <summary>
    /// 目录路径区高度（DIP）。0 = 自动（按内容高度，默认）。
    /// 2026-10-24 用户需求：便签/剪贴板区顶部的分隔条可上下拖动，拖动改的就是本值；
    /// 便签区始终吃满剩余空间。
    /// </summary>
    [JsonPropertyName("pathAreaHeight")]
    public double PathAreaHeight { get; set; }
}

public sealed class DockConfig
{
    /// <summary>"left" | "right"</summary>
    [JsonPropertyName("edge")]
    public string Edge { get; set; } = "right";

    /// <summary>决策 #3："float"（悬浮，不挤压工作区）| "dock"（停靠，AppBar 预留）</summary>
    [JsonPropertyName("mode")]
    public string Mode { get; set; } = "float";

    /// <summary>
    /// 面板宽度。决策 #6：可拖拽，默认 380，范围 300–560。
    /// </summary>
    [JsonPropertyName("width")]
    public int Width { get; set; } = 380;

    [JsonPropertyName("minWidth")]
    public int MinWidth { get; set; } = 300;

    [JsonPropertyName("maxWidth")]
    public int MaxWidth { get; set; } = 560;

    /// <summary>
    /// 抽屉拉手（决策 #5）：面板收起后屏幕侧边显示悬浮拉手，
    /// 鼠标停靠自动弹出、离开自动收起。
    /// </summary>
    [JsonPropertyName("handle")]
    public HandleConfig Handle { get; set; } = new();

    [JsonPropertyName("autoHide")]
    public bool AutoHide { get; set; } = true;

    /// <summary>
    /// 面板固定（2026-10-25 需求）：顶部栏"固定"按钮激活时，
    /// 鼠标离开面板也不自动收起。状态持久化，重启后保持。
    /// </summary>
    [JsonPropertyName("pinPanel")]
    public bool PinPanel { get; set; }

    /// <summary>热区宽度（像素，96 DPI 基准）。</summary>
    [JsonPropertyName("hotZonePx")]
    public int HotZonePx { get; set; } = 6;
}

public sealed class HandleConfig
{
    /// <summary>是否启用拉手。</summary>
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    /// <summary>拉手宽度（像素）。</summary>
    [JsonPropertyName("widthPx")]
    public int WidthPx { get; set; } = 8;

    /// <summary>
    /// 拉手高度（像素）。
    /// 2026-10-20 用户反馈迭代：80px 太短 → 160px 偏长 → 定为 120px
    /// （约为工作区高度的 1/8，兼顾好找与不碍眼）。
    /// </summary>
    [JsonPropertyName("heightPx")]
    public int HeightPx { get; set; } = 120;

    /// <summary>
    /// 鼠标离开后自动收起的延迟（毫秒）。
    /// 用户反馈"收起的速度可以稍微调快一点点"：800 → 600。
    /// </summary>
    [JsonPropertyName("collapseDelayMs")]
    public int CollapseDelayMs { get; set; } = 600;

    /// <summary>
    /// 全屏应用（游戏 / 全屏视频）运行时隐藏拉手（2026-11-08 用户需求）：
    /// "为了避免在全屏游戏等情况下误触拉手，影响游戏体验"。
    ///
    /// 默认开启。用户可以在托盘菜单里随时关掉 —— 万一检测误判或游戏假死
    /// 卡在全屏状态，这是唯一的逃生门（拉手已经被藏起来了，点不到它）。
    /// </summary>
    [JsonPropertyName("hideInFullscreen")]
    public bool HideInFullscreen { get; set; } = true;
}

public sealed class HotkeyConfig
{
    [JsonPropertyName("mods")]
    public List<string> Mods { get; set; } = new() { "win", "alt" };

    [JsonPropertyName("key")]
    public string Key { get; set; } = "N";
}

public sealed class ClipboardConfig
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    [JsonPropertyName("maxItems")]
    public int MaxItems { get; set; } = 500;

    [JsonPropertyName("maxBytes")]
    public long MaxBytes { get; set; } = 2L * 1024 * 1024 * 1024;

    /// <summary>
    /// 单条上限（2026-11-01 审查 S9）。
    ///
    /// MaxBytes 管的是"总量"，管不住"单条"：一条 500 MB 的图片照样会先落盘再参与淘汰。
    /// 32 MB 对剪贴板历史足够 —— 文本按 2 字节/字符算相当于 1600 万字符，
    /// 图片相当于约 2800x2800 的 32 位位图，覆盖绝大多数截图。
    /// </summary>
    [JsonPropertyName("maxItemBytes")]
    public long MaxItemBytes { get; set; } = 32L * 1024 * 1024;

    [JsonPropertyName("captureImages")]
    public bool CaptureImages { get; set; } = true;

    [JsonPropertyName("captureFiles")]
    public bool CaptureFiles { get; set; } = true;

    [JsonPropertyName("captureHtml")]
    public bool CaptureHtml { get; set; } = true;

    // 2026-11-01（发布前审查 B8）：这里原本有两个配置项，现已删除 ——
    //   · encryptWithDpapi：从未被读取，关掉它并不会真的停用加密（加密是强制的）；
    //   · ignorePatterns：从未被读取，"忽略敏感内容"功能根本没实现。
    // 留着就是虚假承诺。如果将来要做"按内容跳过捕获"，请连同真正的过滤逻辑一起加，
    // 不要只加一个不起作用的开关。
}

public sealed class NotesConfig
{
    [JsonPropertyName("alwaysOnTop")]
    public bool AlwaysOnTop { get; set; }

    /// <summary>
    /// 便签正文的字号（DIP，2026-11-03 用户需求："在设置里增加一项便签内容字体调节设置"）。
    ///
    /// 这个字段 2026-10-18 就写进配置了，但**从来没有被任何代码读取过** ——
    /// 卡片正文一直是 XAML 里写死的 12，改它不会有任何效果。
    /// 与 diagLogEnabled / EncryptWithDpapi 是同一类"配置项写了却没接上"的错误，
    /// 现在真正接上了：DrawerWindow.ApplyNoteFontSize() 把它写进
    /// App.xaml 的 NoteBodyFontSize / NoteBodyLineHeight 两个资源。
    ///
    /// 默认值从 14 改成 12：14 是当年随手写的、从未生效过的值，
    /// 真实渲染一直是 12。改成 12 才能让老用户升级后外观不变，
    /// 由 v4 迁移统一改写（见 ConfigStore.Migrate）。
    /// </summary>
    [JsonPropertyName("fontSize")]
    public int FontSize { get; set; } = 12;

    /// <summary>
    /// 决策 #3：便签栏右侧的清除按钮，清除前是否要求确认。
    /// 便签是用户数据，误清代价高，默认要求确认。
    /// </summary>
    [JsonPropertyName("confirmBeforeClear")]
    public bool ConfirmBeforeClear { get; set; } = true;
}

/// <summary>
/// 智能助手页配置（2026-10-26）。
///
/// 背景（实测，见 docs/可行性方案.md §32）：面板宽 380 时
/// DeepSeek 自适应良好、Kimi 略微横向溢出、智谱清言是桌面布局完全放不下，
/// 所以每个站点各自有自己的缩放比例，另有"一键加宽"开关临时把面板拉宽。
/// </summary>
public sealed class AssistantConfig
{
    /// <summary>是否启用助手页（关掉后第三页标签仍显示，但只给提示）。</summary>
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    /// <summary>上次停留的站点 id：deepseek | kimi | chatglm。</summary>
    [JsonPropertyName("activeProviderId")]
    public string ActiveProviderId { get; set; } = "deepseek";

    /// <summary>助手页"加宽"开关（仅助手页生效，切走自动回落）。</summary>
    [JsonPropertyName("widen")]
    public bool Widen { get; set; }

    /// <summary>加宽后的面板宽度（DIP）。默认 620，上限受工作区宽度约束。</summary>
    [JsonPropertyName("widenWidth")]
    public double WidenWidth { get; set; } = 620;

    /// <summary>
    /// 加宽时网页缩放是否随面板宽度等比放大（2026-10-31 用户反馈）。
    ///
    /// 背景：以前"加宽"只改窗口宽度，WebView2 的 ZoomFactor 一动没动，
    /// 于是 CSS 视口变宽、但 1 CSS px 的物理尺寸不变 —— 页面只是"变长"，
    /// 字体大小完全没变，用户反馈"加宽后字没变大"。
    /// true = 缩放 × (当前面板宽 / 常规面板宽)，但**结果上限固定 1.0**
    ///        （2026-11-03 用户需求「所有助手页面内容最大保持 1.0」）——
    ///        所以只有基准缩放低于 1.0 的站点（Kimi 0.9 / 智谱 0.55）会真的变大，
    ///        DeepSeek / 千问基准就是 1.0，加宽后字号不再变化；
    /// false = 完全不乘，各站点保持基准缩放（只拉长页面）。
    /// </summary>
    [JsonPropertyName("zoomScaleWithWidth")]
    public bool ZoomScaleWithWidth { get; set; } = true;

    /// <summary>
    /// 站点常驻时长（分钟）：离开某个站点超过这个时长就释放它的 WebView2，把内存还回去。
    /// 常驻一份站点约 100–150MB，默认 30 分钟（2026-10-29 需求：切换不再重新加载）。
    /// </summary>
    [JsonPropertyName("residentMinutes")]
    public int ResidentMinutes { get; set; } = 15;

    /// <summary>最多同时常驻几个站点（默认 3，即三个站点全开）；超出按最久未用淘汰。</summary>
    [JsonPropertyName("maxResident")]
    public int MaxResident { get; set; } = 3;

    /// <summary>
    /// 每站点缩放比例（面板常规宽度下的基准值）。
    /// 实测：Kimi 0.75 以下才不横向溢出；
    /// 智谱清言需要约 690 CSS px 才能把输入框放进视口，380 面板下缩放救不回来，
    /// 所以给 0.55 让它至少能看到输入框的一半，配合"加宽"使用。
    /// 千问（2026-10-31）：367 窗口 / 353 CSS 视口下无横向溢出，与 DeepSeek 同为 1.0。
    /// </summary>
    [JsonPropertyName("zoom")]
    public Dictionary<string, double> Zoom { get; set; } = new()
    {
        ["deepseek"] = 1.0,
        ["qwen"] = 1.0,
        ["kimi"] = 0.9,
        ["chatglm"] = 0.55
    };

    /// <summary>
    /// 选中文字后弹出的提示词按钮（2026-10-30 需求）。
    /// 用户原话：预设翻译、解释、润色、改写等，且"提示词要求直接给出结果，不显示思考内容"，
    /// 所以每条后面都统一追加一句"只给结果"，避免模型先输出推理过程。
    /// </summary>
    [JsonPropertyName("prompts")]
    public List<PromptPreset> Prompts { get; set; } =
    [
        new() { Id = "translate", Label = "翻译", Instruction = "把下面这段内容翻译成中文（若原文已是中文则译成英文），只给译文，不要解释。" },
        new() { Id = "explain", Label = "解释", Instruction = "解释下面这段内容的意思和要点，直接给出结论。" },
        new() { Id = "polish", Label = "润色", Instruction = "润色下面这段文字，让它更通顺自然，只给润色后的文本。" },
        new() { Id = "rewrite", Label = "改写", Instruction = "改写下面这段内容，保持原意但表达更清晰简洁，只给改写结果。" }
    ];

    /// <summary>选中文字时是否弹悬浮按钮。</summary>
    [JsonPropertyName("selectionPopup")]
    public bool SelectionPopup { get; set; } = true;

    /// <summary>
    /// 悬浮条最左侧「发送」按钮弹出的自定义提示词（2026-10-31 需求）。
    ///
    /// 与 <see cref="Prompts"/> 的区别：Presets 是点一下就直接发的固定条目，
    /// 这条是"每次发送前都弹出来让你改一句"的草稿——改完点确定才发，
    /// 并且把改动写回这里，下次再点「发送」还是上次编辑过的内容。
    /// </summary>
    [JsonPropertyName("customPrompt")]
    public string CustomPrompt { get; set; } = "总结下面这段内容的要点，只给要点，不要解释。";
}

/// <summary>一条"选中文字后可用"的提示词预设。</summary>
public sealed class PromptPreset
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    /// <summary>按钮上显示的两个字。</summary>
    [JsonPropertyName("label")]
    public string Label { get; set; } = "";

    /// <summary>拼在选中内容前面的指令文本。</summary>
    [JsonPropertyName("instruction")]
    public string Instruction { get; set; } = "";
}

/* ==================== 快捷方式数据模型（新框架 §8.2） ==================== */

/// <summary>
/// 一个快捷方式项（应用 / 盘符 / 目录 / 文件）。
/// 对应方案 §7.3，新增 kind 以区分显示图标与点击行为。
/// </summary>
public sealed class ShortcutItem
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    /// <summary>
    /// app   → 第一区（应用程序，图标小、无文字标签）
    /// drive → 盘符（C:\ 等）
    /// dir   → 目录
    /// file  → 文件
    /// </summary>
    [JsonPropertyName("kind")]
    public string Kind { get; set; } = "app";

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    /// <summary>目标路径。app 为 exe 路径或 AUMID；drive/dir/file 为完整路径。</summary>
    [JsonPropertyName("target")]
    public string Target { get; set; } = "";

    /// <summary>启动参数（仅 app 有意义）。</summary>
    [JsonPropertyName("args")]
    public string Args { get; set; } = "";

    /// <summary>所属分类 ID。null 表示未分类（仅第二区允许未分类）。</summary>
    [JsonPropertyName("categoryId")]
    public string? CategoryId { get; set; }

    [JsonPropertyName("order")]
    public int Order { get; set; }

    [JsonPropertyName("createdAt")]
    public string CreatedAt { get; set; } = DateTime.UtcNow.ToString("o");

    [JsonPropertyName("lastUsedAt")]
    public string? LastUsedAt { get; set; }

    [JsonPropertyName("useCount")]
    public int UseCount { get; set; }
}

/// <summary>
/// 路径分类（第二区专用）。如"我的电脑"、"常用"、"开发工具"。
/// </summary>
public sealed class PathCategory
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("order")]
    public int Order { get; set; }

    /// <summary>是否展开。折叠状态需持久化。</summary>
    [JsonPropertyName("expanded")]
    public bool Expanded { get; set; } = true;

    [JsonPropertyName("createdAt")]
    public string CreatedAt { get; set; } = DateTime.UtcNow.ToString("o");
}

/// <summary>
/// 完整的快捷方式数据。存储位置 %APPDATA%\QuickDrawer\shortcuts.json。
/// </summary>
public sealed class ShortcutsData
{
    /// <summary>第一区：常用应用（手动挑选用频最高的，不自动铺满）。</summary>
    [JsonPropertyName("apps")]
    public List<ShortcutItem> Apps { get; set; } = new();

    /// <summary>第二区：路径分类。</summary>
    [JsonPropertyName("categories")]
    public List<PathCategory> Categories { get; set; } = new();

    /// <summary>第二区：路径项（归属某个分类）。</summary>
    [JsonPropertyName("paths")]
    public List<ShortcutItem> Paths { get; set; } = new();
}
