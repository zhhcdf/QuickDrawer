using System.Diagnostics;
using System.Text.Json;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using QuickDrawer.Native;

namespace QuickDrawer.Assistant;

/// <summary>
/// 助手页的 WebView2 宿主（2026-10-26 需求；2026-10-29 改为"站点常驻"）。
///
/// 设计取舍：
/// - **每个站点一个 WebView2，常驻一段时间**：早先是单实例 + 切换即 Navigate，
///   但那样每次换站点都要重新加载网页、还丢掉草稿和滚动位置（用户 2026-10-29 反馈）。
///   现在每站一个实例，切站点只是切 Visibility，页面状态原样保留。
/// - **常驻有时限**：`assistant.residentMinutes`（默认 30 分钟）内没再访问的站点会被释放，
///   `assistant.maxResident`（默认 3）限制最多同时常驻几个，超出按最久未用淘汰。
///   常驻一个站点的 WebView2 大约占 100–150MB，三个站点都开就是三份，必须给用户退路。
/// - **懒加载**：窗口打开时不建 WebView2，用户第一次点某个站点才初始化。
/// - **用户数据目录显式指定绝对路径**：单文件发布时默认目录会落在
///   %TEMP%\.net\QuickDrawer\xxxx 解压目录里，重启就丢登录态。
/// - 多个控件共用同一个 <see cref="CoreWebView2Environment"/>（同一个用户数据目录是官方要求）。
/// </summary>
internal sealed class AssistantService : IDisposable
{
    /// <summary>一个站点 = 一个 WebView2 控件 + 它的使用状态。</summary>
    private sealed class Site
    {
        public WebView2 View = null!;
        public string ProviderId = "";
        public bool Navigated;
        public DateTime LastUsedUtc = DateTime.UtcNow;
    }

    private const int IdleSweepSeconds = 30;

    private readonly Grid _host;
    private readonly AppConfig _config;
    private readonly Action<string> _log;
    private readonly Action _zoomChanged;

    /// <summary>
    /// 当前面板宽度相对"常规宽度"的倍数（2026-10-31）。
    /// 加宽时用它等比放大网页缩放，让字体跟着面板一起变大。
    /// </summary>
    private double _widthScale = 1.0;

    private readonly Dictionary<string, Site> _sites = new(StringComparer.Ordinal);
    private Task<CoreWebView2Environment>? _envTask;
    private CoreWebView2Environment? _env;
    private DispatcherTimer? _idleTimer;
    private Site? _active;
    private bool _disposed;
    private bool _reloadAttempted;

    public AssistantService(Grid host, AppConfig config, Action<string> log, Action zoomChanged)
    {
        _host = host;
        _config = config;
        _log = log;
        _zoomChanged = zoomChanged;
    }

    /// <summary>最近一次初始化失败的原因，供界面提示用。</summary>
    public string? LastError { get; private set; }

    public bool IsReady => _env is not null;

    /// <summary>当前显示的站点 id（还没有任何一个时为 null）。</summary>
    public string? CurrentProviderId => _active?.ProviderId;

    /// <summary>当前常驻的站点数（含未显示的）。</summary>
    public int ResidentCount => _sites.Count;

    /// <summary>切到某个站点：常驻的实例直接显示，没建过的才创建并首次导航。</summary>
    public async Task<bool> EnsureAsync(AssistantProvider provider)
    {
        if (_disposed)
        {
            return false;
        }

        Site site = GetOrCreateSite(provider);
        Activate(site);

        if (site.View.CoreWebView2 is null)
        {
            try
            {
                CoreWebView2Environment env = await GetEnvironmentAsync();
                await site.View.EnsureCoreWebView2Async(env);
                WireCore(site);
            }
            catch (WebView2RuntimeNotFoundException ex)
            {
                LastError = "未安装 Microsoft Edge WebView2 Runtime。\n" +
                            "下载：https://developer.microsoft.com/microsoft-edge/webview2/\n\n" +
                            ex.Message;
                _log("webview2 runtime not found");
                return false;
            }
            catch (Exception ex)
            {
                LastError = $"{ex.GetType().Name}: {ex.Message}";
                _log($"webview2 init failed ({provider.Id}): {LastError}");
                return false;
            }
        }

        if (!site.Navigated && site.View.CoreWebView2 is not null)
        {
            site.Navigated = true;
            _log($"provider {provider.Id} -> {provider.Url} (zoom {EffectiveZoomFor(provider):0.00})");
            site.View.CoreWebView2.Navigate(provider.Url);
        }

        ApplyZoom();
        StartIdleTimer();
        return true;
    }

    /// <summary>离开助手页：只隐藏控件，不销毁——页面在时限内继续常驻。</summary>
    public void Hide()
    {
        foreach (Site site in _sites.Values)
        {
            if (site.View.Visibility != Visibility.Collapsed)
            {
                site.View.Visibility = Visibility.Collapsed;
            }
        }
    }

    private Site GetOrCreateSite(AssistantProvider provider)
    {
        if (_sites.TryGetValue(provider.Id, out Site? existing))
        {
            existing.LastUsedUtc = DateTime.UtcNow;
            return existing;
        }

        var view = new WebView2
        {
            Visibility = Visibility.Collapsed,
            DefaultBackgroundColor = System.Drawing.Color.Transparent,
        };
        AutomationProperties.SetName(view, "AssistantView:" + provider.Id);
        AutomationProperties.SetAutomationId(view, "AssistantView:" + provider.Id);
        Panel.SetZIndex(view, 0);

        _host.Children.Insert(0, view);

        var site = new Site { View = view, ProviderId = provider.Id };
        _sites[provider.Id] = site;
        _log($"site created: {provider.Id} (resident={_sites.Count})");

        EnforceResidentCap(site);
        return site;
    }

    /// <summary>超过 maxResident 时淘汰最久未用的非当前站点。</summary>
    private void EnforceResidentCap(Site justCreated)
    {
        int cap = Math.Max(1, _config.Assistant.MaxResident);
        while (_sites.Count > cap)
        {
            Site? victim = null;
            foreach (Site s in _sites.Values)
            {
                if (ReferenceEquals(s, justCreated) || ReferenceEquals(s, _active))
                {
                    continue;
                }

                if (victim is null || s.LastUsedUtc < victim.LastUsedUtc)
                {
                    victim = s;
                }
            }

            if (victim is null)
            {
                return;
            }

            Release(victim, "resident cap");
        }
    }

    private void Activate(Site site)
    {
        _active = site;
        site.LastUsedUtc = DateTime.UtcNow;

        foreach (Site s in _sites.Values)
        {
            Visibility want = ReferenceEquals(s, site) ? Visibility.Visible : Visibility.Collapsed;
            if (s.View.Visibility != want)
            {
                s.View.Visibility = want;
            }
        }
    }

    private async Task<CoreWebView2Environment> GetEnvironmentAsync()
    {
        if (_env is not null)
        {
            return _env;
        }

        _envTask ??= CreateEnvironmentAsync();

        try
        {
            _env = await _envTask;
            return _env;
        }
        catch
        {
            // 2026-11-01 审查 S5：初始化失败不能把 faulted Task 永久缓存下来。
            // 否则用户按提示装好 WebView2 Runtime 之后，每次 await 仍然立刻抛
            // 同一个异常，只能重启程序。置回 null 让下一次调用重新尝试。
            _envTask = null;
            _env = null;
            throw;
        }
    }

    private async Task<CoreWebView2Environment> CreateEnvironmentAsync()
    {
        string userData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuickDrawer",
            "WebView2");
        Directory.CreateDirectory(userData);

        CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, userData, null);
        _log($"webview2 ready (runtime {env.BrowserVersionString}, userData={userData})");
        return env;
    }

    private void WireCore(Site site)
    {
        CoreWebView2 core = site.View.CoreWebView2;

        // 状态栏 / 滑动导航在这么窄的面板里只是干扰
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsSwipeNavigationEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = true;
        core.Settings.IsPasswordAutosaveEnabled = true;
        core.Settings.IsGeneralAutofillEnabled = true;

        // 探针锚点：导航一行日志，端到端测试靠它断言"确实到了某个站点"。
        // 隐私（B1）：只记 host，不记完整 URL——完整 URL 可能含搜索词、会话 id、token。
        core.NavigationStarting += (_, e) => _log($"navigate {SafeHost(e.Uri)} ({site.ProviderId})");
        core.NavigationCompleted += (_, e) =>
            _log(e.IsSuccess ? $"navigation completed ({site.ProviderId})" : $"navigation failed ({site.ProviderId}): {e.WebErrorStatus}");
        core.DocumentTitleChanged += (_, _) => { };

        // 登录类弹窗（"使用微信登录"等）在窄面板里不能开新窗：
        // 拦下来改成当前视图导航，用户仍能完成登录，且不会冒出无父窗口。
        core.NewWindowRequested += (_, e) =>
        {
            e.Handled = true;
            if (!string.IsNullOrWhiteSpace(e.Uri))
            {
                // 隐私（B1）：只记 host，不记完整 URL。
                _log($"popup redirected to view: {SafeHost(e.Uri)}");
                core.Navigate(e.Uri);
            }
        };

        // 麦克风/摄像头/地理位置一律不给：助手页不需要，也避免弹权限框打断
        core.PermissionRequested += (_, e) =>
        {
            _log($"permission denied: {e.PermissionKind}");
            e.State = CoreWebView2PermissionState.Deny;
        };

        core.DownloadStarting += (_, e) => _log($"download started: {SafeHost(e.DownloadOperation.Uri)}");

        // 渲染进程崩溃只自动救一次，避免崩溃循环
        core.ProcessFailed += (_, e) =>
        {
            _log($"process failed ({site.ProviderId}): {e.ProcessFailedKind}");
            if (!_reloadAttempted)
            {
                _reloadAttempted = true;
                core.Reload();
            }
        };
    }

    /// <summary>
    /// 该站点在"常规面板宽度"下的缩放（配置值，不含宽度乘数）。
    /// </summary>
    public double ZoomFor(AssistantProvider provider)
    {
        if (_config.Assistant.Zoom.TryGetValue(provider.Id, out double z) && z > 0.2 && z <= 2.0)
        {
            return z;
        }

        return provider.DefaultZoom;
    }

    /// <summary>
    /// 助手页缩放的硬上限（2026-11-03 用户需求：「所有助手页面内容最大保持 1.0」）。
    ///
    /// 为什么是 1.0 而不是 WebView2 支持的 2.0：加宽面板的目的是"看更多内容"，
    /// 不是"把字放大"。以前按宽度等比放大，DeepSeek / 千问这类本来就 1.0 的站点
    /// 一加宽就放大到 1.55，字反而比常规宽度更挤。现在上限锁死 1.0：
    /// 只允许把**压得太小**的站点补到 1.0 为止。
    /// </summary>
    public const double MaxZoom = 1.0;

    /// <summary>
    /// 实际生效的缩放 = 站点基础缩放 × 宽度乘数，再夹到 [0.1, MaxZoom]。
    ///
    /// 宽度乘数只在"加宽 + 允许随宽度缩放"时大于 1（2026-10-31 用户反馈）。
    /// 但上限是 1.0，所以这个乘数只对**基准缩放小于 1.0** 的站点还有意义：
    /// - DeepSeek / 千问（基准 1.00）：乘完仍被夹回 1.00，加宽不再改变字号；
    /// - Kimi（基准 0.90）、智谱（基准 0.55）：加宽后逐步补到 1.00 封顶。
    ///
    /// 下界仍是 0.1 —— WebView2 的 ZoomFactor 内部支持范围就是 0.1–2.0，
    /// 低于 0.1 会被静默归一化。
    /// </summary>
    public double EffectiveZoomFor(AssistantProvider provider)
    {
        double baseZoom = ZoomFor(provider);
        double scale = _widthScale <= 0 ? 1.0 : _widthScale;
        double zoom = baseZoom * scale;

        if (zoom < 0.1) zoom = 0.1;
        if (zoom > MaxZoom) zoom = MaxZoom;
        return zoom;
    }

    /// <summary>
    /// 设置"当前面板宽度 / 常规面板宽度"的倍数，并立即重新套用缩放。
    /// scale=1 表示常规宽度（缩放回到配置值）；>1 表示加宽后的等比放大。
    /// </summary>
    public void SetWidthScale(double scale)
    {
        if (scale <= 0 || double.IsNaN(scale) || double.IsInfinity(scale))
        {
            scale = 1.0;
        }

        if (Math.Abs(_widthScale - scale) < 0.001)
        {
            return;
        }

        _widthScale = scale;
        _log($"width scale -> {scale:0.00}");
        ApplyZoom();
    }

    public void ApplyZoom()
    {
        if (_active is null)
        {
            return;
        }

        AssistantProvider? p = AssistantProviders.ById(_active.ProviderId);
        if (p is null || _active.View.CoreWebView2 is null)
        {
            return;
        }

        double zoom = EffectiveZoomFor(p);
        if (Math.Abs(_active.View.ZoomFactor - zoom) > 0.001)
        {
            _active.View.ZoomFactor = zoom;
            _log($"zoom {p.Id} = {zoom:0.00} (base {ZoomFor(p):0.00} x scale {_widthScale:0.00})");
        }

        _zoomChanged();
    }

    public void GoBack()
    {
        if (_active?.View.CoreWebView2?.CanGoBack == true)
        {
            _active.View.CoreWebView2.GoBack();
        }
    }

    public void GoForward()
    {
        if (_active?.View.CoreWebView2?.CanGoForward == true)
        {
            _active.View.CoreWebView2.GoForward();
        }
    }

    public void Reload() => _active?.View.CoreWebView2?.Reload();

    public void GoHome()
    {
        AssistantProvider? p = AssistantProviders.ById(_active?.ProviderId);
        if (p is not null)
        {
            _active?.View.CoreWebView2?.Navigate(p.Url);
        }
    }

    /// <summary>
    /// 把一段文本发到当前站点：先聚焦页面里的输入框，再用 CDP 的 Input.insertText 写进去，
    /// 最后用 CDP 派发 Enter。走浏览器自己的输入管线，React 的受控状态会同步，
    /// 也不依赖窗口是否在前台（面板是 ShowActivated=false，SendInput 根本打不进去）。
    ///
    /// 2026-10-30 实测（probe/domspike）：inserText + Enter 真的把消息发出去了，AI 也回了。
    /// </summary>
    public async Task<bool> SendPromptAsync(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        CoreWebView2? core = _active?.View.CoreWebView2;
        if (core is null)
        {
            LastError = "助手页还没有加载完成";
            return false;
        }

        if (!EnsureTrustedPage(core))
        {
            return false;
        }

        try
        {
            const string focusJs = "(() => { const t = document.querySelector('textarea'); if (t) { t.focus(); return 'textarea'; } const c = document.querySelector('[contenteditable]'); if (c) { c.focus(); return 'editable'; } return 'none'; })()";

            // 冷启动时 Navigate 刚发起，SPA 还没渲染出 composer：实测 130ms 就查会拿到 none，
            // 所以最多等 10 秒（40 x 250ms），这是"面板收起时选中文字直接发"的必需条件。
            string focus = "none";
            for (int attempt = 0; attempt < 40; attempt++)
            {
                focus = await core.ExecuteScriptAsync(focusJs);
                focus = focus?.Trim('"') ?? "none";
                if (!string.Equals(focus, "none", StringComparison.Ordinal))
                {
                    break;
                }

                await Task.Delay(250);
            }

            _log($"composer focus -> \"{focus}\"");
            if (string.Equals(focus, "none", StringComparison.Ordinal))
            {
                LastError = "没找到输入框，可能页面还没加载完";
                return false;
            }

            await core.CallDevToolsProtocolMethodAsync("Input.insertText", JsonSerializer.Serialize(new { text }));
            await Task.Delay(160);

            await core.CallDevToolsProtocolMethodAsync(
                "Input.dispatchKeyEvent",
                "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}");
            await core.CallDevToolsProtocolMethodAsync(
                "Input.dispatchKeyEvent",
                "{\"type\":\"char\",\"text\":\"\r\",\"unmodifiedText\":\"\r\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}");
            await core.CallDevToolsProtocolMethodAsync(
                "Input.dispatchKeyEvent",
                "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}");

            _log($"prompt sent to {_active?.ProviderId} ({text.Length} chars)");
            return true;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            _log("send prompt failed: " + ex.Message);
            return false;
        }
    }

    /// <summary>
    /// 把"一段文字 + 一张图"发到当前站点（2026-11-01 五次需求：截图提问）。
    ///
    /// 为什么要单开一个方法：<see cref="SendPromptAsync"/> 只走 `Input.insertText`，
    /// 那是纯文本通道，图片根本没有入口。发图必须借**系统剪贴板**——
    /// 把图放进剪贴板，再用 CDP 派发 Ctrl+V，走的是浏览器自己的粘贴处理器，
    /// 各站点的上传/预览逻辑（React 受控组件）才会正常触发。
    ///
    /// 两个容易踩的点：
    /// 1. 剪贴板是**全局共享**资源，用完必须还原，而且要在 finally 里还原；
    /// 2. 直接 `SendInput` 打 Ctrl+V 不行——面板是 ShowActivated=false，
    ///    键盘焦点根本不在 WebView2 上。必须走 CDP（同 SendPromptAsync 的注释）。
    /// </summary>
    public async Task<bool> SendPromptWithImageAsync(string text, BitmapSource image)
    {
        CoreWebView2? core = _active?.View.CoreWebView2;
        if (core is null)
        {
            LastError = "助手页还没有加载完成";
            return false;
        }

        if (!EnsureTrustedPage(core))
        {
            return false;
        }

        try
        {
            if (!await FocusComposerAsync(core))
            {
                return false;
            }

            // 剪贴板快照：用户的剪贴板里可能正装着别的东西
            IDataObject? saved = null;
            uint seqAfterWrite = 0;
            try
            {
                saved = Clipboard.GetDataObject();
            }
            catch (Exception ex)
            {
                _log("clipboard snapshot failed: " + ex.Message);
            }

            try
            {
                // 2026-11-01（六次）：发截图时会把这张图写进剪贴板（Ctrl+V 的唯一通路），
                // 那会触发 WM_CLIPBOARDUPDATE —— 不抑制的话用户自己的剪贴板历史里会多出一条
                // 截图记录（实测 diag: "captured Image '图片' from QuickDrawer"）。
                // 3 秒覆盖"放入 -> 粘贴 -> 还原"整个过程。
                ClipboardService.SuppressCapture(TimeSpan.FromSeconds(3));

                Clipboard.SetImage(image);
                seqAfterWrite = NativeMethods.GetClipboardSequenceNumber();
                _log($"shot placed on clipboard ({image.PixelWidth}x{image.PixelHeight} px)");

                // Ctrl+V：modifiers=2 是 Ctrl（1=Alt, 2=Ctrl, 4=Meta, 8=Shift）
                await core.CallDevToolsProtocolMethodAsync(
                    "Input.dispatchKeyEvent",
                    "{\"type\":\"keyDown\",\"key\":\"v\",\"code\":\"KeyV\",\"windowsVirtualKeyCode\":86,\"nativeVirtualKeyCode\":86,\"modifiers\":2}");
                await core.CallDevToolsProtocolMethodAsync(
                    "Input.dispatchKeyEvent",
                    "{\"type\":\"keyUp\",\"key\":\"v\",\"code\":\"KeyV\",\"windowsVirtualKeyCode\":86,\"nativeVirtualKeyCode\":86,\"modifiers\":2}");

                // 上图是异步的（要编码、要传服务端/生成本地预览），给足时间
                await Task.Delay(900);
                string attached = await core.ExecuteScriptAsync(CountComposerImagesJs);
                int count = int.TryParse(attached?.Trim('"'), out int parsed) ? parsed : 0;
                _log($"composer images after paste -> {count}");

                if (count == 0)
                {
                    // CDP 的 Ctrl+V 在个别站点不会触发粘贴处理器：退到 JS 直接派发
                    // 一个带 DataTransfer 的 paste 事件，这是网页端通用的"伪造粘贴"手法。
                    _log("paste produced no image, falling back to synthetic paste event");
                    count = await DispatchSyntheticPasteAsync(core, image);
                }

                if (count == 0)
                {
                    LastError = "页面没有接收这张图（可能不支持粘贴图片）";
                    return false;
                }

                // 图挂上去之后再写文字：有些站点在收到图时会把输入框清空
                if (!string.IsNullOrWhiteSpace(text))
                {
                    await core.CallDevToolsProtocolMethodAsync("Input.insertText", JsonSerializer.Serialize(new { text }));
                    await Task.Delay(160);
                }

                await DispatchEnterAsync(core);
                _log($"prompt with image sent to {_active?.ProviderId} ({text.Length} chars, {image.PixelWidth}x{image.PixelHeight} px)");
                return true;
            }
            finally
            {
                RestoreClipboard(saved, seqAfterWrite);
            }
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            _log("send prompt with image failed: " + ex.Message);
            return false;
        }
    }

    /// <summary>数一下输入区里已经挂了几张本地图（blob:/data:）——判断"图有没有粘上去"的唯一客观依据。</summary>
    private const string CountComposerImagesJs =
        "(() => document.querySelectorAll('img[src^=\"blob:\"], img[src^=\"data:image\"]').length)()";

    /// <summary>把输入框聚焦（同 SendPromptAsync 里的 40 x 250ms 轮询），失败时已写好 LastError。</summary>
    private async Task<bool> FocusComposerAsync(CoreWebView2 core)
    {
        const string focusJs = "(() => { const t = document.querySelector('textarea'); if (t) { t.focus(); return 'textarea'; } const c = document.querySelector('[contenteditable]'); if (c) { c.focus(); return 'editable'; } return 'none'; })()";

        string focus = "none";
        for (int attempt = 0; attempt < 40; attempt++)
        {
            focus = await core.ExecuteScriptAsync(focusJs);
            focus = focus?.Trim('"') ?? "none";
            if (!string.Equals(focus, "none", StringComparison.Ordinal))
            {
                break;
            }

            await Task.Delay(250);
        }

        _log($"composer focus -> \"{focus}\"");
        if (string.Equals(focus, "none", StringComparison.Ordinal))
        {
            LastError = "没找到输入框，可能页面还没加载完";
            return false;
        }

        return true;
    }

    private async Task DispatchEnterAsync(CoreWebView2 core)
    {
        await core.CallDevToolsProtocolMethodAsync(
            "Input.dispatchKeyEvent",
            "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}");
        await core.CallDevToolsProtocolMethodAsync(
            "Input.dispatchKeyEvent",
            "{\"type\":\"char\",\"text\":\"\r\",\"unmodifiedText\":\"\r\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}");
        await core.CallDevToolsProtocolMethodAsync(
            "Input.dispatchKeyEvent",
            "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"nativeVirtualKeyCode\":13}");
    }

    /// <summary>剪贴板粘贴不生效时的退路：在页面里构造一个带 File 的 paste 事件。</summary>
    private async Task<int> DispatchSyntheticPasteAsync(CoreWebView2 core, BitmapSource image)
    {
        byte[] png = EncodePng(image);
        if (png.Length == 0)
        {
            return 0;
        }

        string base64 = Convert.ToBase64String(png);
        string js = "(() => {\n" +
            "  try {\n" +
            "    const b = atob('" + base64 + "');\n" +
            "    const a = new Uint8Array(b.length);\n" +
            "    for (let i = 0; i < b.length; i++) a[i] = b.charCodeAt(i);\n" +
            "    const f = new File([a], 'shot.png', { type: 'image/png' });\n" +
            "    const dt = new DataTransfer();\n" +
            "    dt.items.add(f);\n" +
            "    const target = document.activeElement || document.body;\n" +
            "    const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });\n" +
            "    target.dispatchEvent(ev);\n" +
            "    return document.querySelectorAll('img[src^=\"blob:\"], img[src^=\"data:image\"]').length;\n" +
            "  } catch (e) { return -1; }\n" +
            "})()";

        await Task.Delay(700);
        string result = await core.ExecuteScriptAsync(js);
        _log($"synthetic paste -> {result}");
        return int.TryParse(result?.Trim('"'), out int count) ? Math.Max(count, 0) : 0;
    }

    private static byte[] EncodePng(BitmapSource image)
    {
        try
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(image));
            using var stream = new MemoryStream();
            encoder.Save(stream);
            return stream.ToArray();
        }
        catch (Exception ex)
        {
            DiagLog.Write("shot", "png encode failed: " + ex.Message);
            return Array.Empty<byte>();
        }
    }

    private void RestoreClipboard(IDataObject? saved, uint seqAfterWrite)
    {
        try
        {
            if (saved is not null)
            {
                // 2026-11-05（第二次）：序列号变了就说明这张截图写入之后，
                // 剪贴板又被别人（用户自己按 Ctrl+C）改过 —— 此时再写回 saved
                // 就是拿旧内容盖掉用户刚复制的东西，而且盖的时候抑制窗口还开着，
                // 被盖掉的内容连历史都进不去。放弃还原，把剪贴板留给用户。
                if (seqAfterWrite != 0)
                {
                    uint current = NativeMethods.GetClipboardSequenceNumber();
                    if (current != seqAfterWrite)
                    {
                        _log($"clipboard restore skipped: changed by someone else (seq {seqAfterWrite}->{current})");
                        return;
                    }
                }

                // 2026-11-05：还原这次写入同样会触发 WM_CLIPBOARDUPDATE。
                // 发截图那条路只在写入图片前武装了 3 秒窗口，而"上图 + 打字 + 回车"
                // 可能超过 3 秒，窗口一过期就把还原的旧内容当成新复制记进历史。
                // 写之前重新武装一个短窗口，精确覆盖这一次还原。
                ClipboardService.SuppressCapture(TimeSpan.FromMilliseconds(800));
                Clipboard.SetDataObject(saved, true);
            }

            // saved == null 表示"取快照时就失败了"，不是"剪贴板本来是空的"。
            // 这种情况下剪贴板里是用户自己的内容，清空它是纯粹的破坏
            // （2026-11-01 审查 S3）。宁可留着不动，也不要抹掉。
            // Selection/SelectionCapture.cs 的同类逻辑已按同样原则修过。
        }
        catch (Exception ex)
        {
            // 剪贴板被别的进程占着时 SetDataObject 会抛 ExternalException，不算致命
            _log("clipboard restore failed: " + ex.Message);
        }
    }

    /// <summary>
    /// 2026-11-01 审查 S4：自动发送前确认页面还属于该站点自己。
    ///
    /// 为什么要这道闸：助手页允许导航到任意地址（登录要跳 open.weixin.qq.com 等第三方），
    /// 而"面板收起时选中文字直接发"会往**当前页面**的输入框 insertText + 回车。
    /// 页面一旦被带到第三方站点，用户选中的文字就被自动发了出去，没有任何提示。
    /// 这是整个程序里唯一的静默外泄路径。
    ///
    /// 注意用户自己在页面里手动输入不受此限 —— 那是他看着屏幕在操作，
    /// 需要设防的只有"程序代替用户灌内容"这个动作。
    /// </summary>
    private bool EnsureTrustedPage(CoreWebView2 core)
    {
        string? currentUrl = core.Source;
        if (AssistantProviders.IsTrustedHost(currentUrl))
        {
            return true;
        }

        _log($"send blocked: page left the provider ({SafeHost(currentUrl)})");
        LastError = "当前页面已离开该站点，为避免把选中内容发给别的网站，已取消发送";
        return false;
    }

    /// <summary>
    /// 隐私（B1）：日志里只出现 URL 的 host，不出现完整 URL。
    /// 完整 URL 会带上搜索词、会话 id、有时还有 token，而 diag.log 是用户
    /// 提 issue 时会贴出去的文件。解析失败时退化成 "invalid-uri"。
    /// </summary>
    private static string SafeHost(string? uri)
    {
        if (string.IsNullOrWhiteSpace(uri)) return "none";
        try
        {
            return Uri.TryCreate(uri, UriKind.Absolute, out Uri? parsed) && !string.IsNullOrEmpty(parsed.Host)
                ? parsed.Host
                : "opaque";
        }
        catch
        {
            return "invalid-uri";
        }
    }

    /// <summary>把当前页面交给系统浏览器（窄面板里实在用不了时的退路）。</summary>
    public void OpenInBrowser()
    {
        string? url = _active?.View.CoreWebView2?.Source;
        if (string.IsNullOrWhiteSpace(url))
        {
            url = AssistantProviders.ById(_active?.ProviderId)?.Url;
        }

        if (string.IsNullOrWhiteSpace(url))
        {
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            _log($"opened in system browser: {url}");
        }
        catch (Exception ex)
        {
            _log($"open browser failed: {ex.Message}");
        }
    }

    private void StartIdleTimer()
    {
        if (_idleTimer is not null)
        {
            return;
        }

        _idleTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(IdleSweepSeconds) };
        _idleTimer.Tick += (_, _) => SweepIdleSites();
        _idleTimer.Start();
    }

    /// <summary>超过 residentMinutes 没访问的站点释放掉，把内存还回去。</summary>
    private void SweepIdleSites()
    {
        int minutes = Math.Max(1, _config.Assistant.ResidentMinutes);
        DateTime now = DateTime.UtcNow;
        List<Site> expired = new();

        foreach (Site s in _sites.Values)
        {
            if (ReferenceEquals(s, _active))
            {
                continue;
            }

            if ((now - s.LastUsedUtc).TotalMinutes >= minutes)
            {
                expired.Add(s);
            }
        }

        foreach (Site s in expired)
        {
            Release(s, $"idle {minutes} min");
        }
    }

    private void Release(Site site, string reason)
    {
        _log($"site released: {site.ProviderId} ({reason}, resident={_sites.Count - 1})");
        _sites.Remove(site.ProviderId);

        if (ReferenceEquals(site, _active))
        {
            _active = null;
        }

        try
        {
            _host.Children.Remove(site.View);
        }
        catch
        {
            // 控件树可能已在关闭流程中拆掉
        }

        try
        {
            site.View.Dispose();
        }
        catch
        {
            // 退出阶段控件可能已失效，忽略
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_idleTimer is not null)
        {
            _idleTimer.Stop();
            _idleTimer = null;
        }

        foreach (Site site in _sites.Values.ToList())
        {
            Release(site, "dispose");
        }

        _sites.Clear();
        _active = null;
        _env = null;
        _envTask = null;
    }
}
