namespace QuickDrawer.Assistant;

/// <summary>
/// 一个可内嵌的网页端对话站点（2026-10-26 需求：智能助手页）。
///
/// 为什么是"网页端"而不是官方 API：用户要的就是自己已登录的对话页，
/// 网页端天然带账号、历史、附件上传等能力，不需要另外申请 Key。
/// </summary>
public sealed class AssistantProvider
{
    public AssistantProvider(string id, string name, string url, double defaultZoom)
    {
        Id = id;
        Name = name;
        Url = url;
        DefaultZoom = defaultZoom;
    }

    /// <summary>配置里的稳定 id（同时是 zoom 字典的键）。</summary>
    public string Id { get; }

    public string Name { get; }

    public string Url { get; }

    /// <summary>该站点在 380px 面板下的默认缩放（实测得出，见 AssistantConfig.Zoom）。</summary>
    public double DefaultZoom { get; }
}

/// <summary>
/// 内置站点表。
///
/// 2026-10-26 实测（窗口 380 / CSS 视口 364）：
/// - chat.deepseek.com：docScrollW == clientW，输入框完全在视口内 → 1.0 可用
/// - www.kimi.com：docScrollW 375 > clientW 349（约 26px 横向溢出）→ 0.9 收进来
/// - chatglm.cn：桌面布局，输入框右边缘 683px，需约 690 CSS px → 0.55 + 加宽
/// 注意 kimi.moonshot.cn 会 301 到 www.kimi.com，所以只登记后者。
///
/// 2026-10-31 新增千问（www.qianwen.com）实测（窗口 367 / CSS 视口 353，`probe/domspike --width 367`）：
/// - docScrollW 353 == clientW 353、overflowX=false，输入框 box=[69,404,215,49] 完全在视口内
///   → 自适应，和 DeepSeek 一样 1.0 即可。
/// </summary>
public static class AssistantProviders
{
    public static readonly AssistantProvider DeepSeek =
        new("deepseek", "DeepSeek", "https://chat.deepseek.com/", 1.0);

    /// <summary>千问（阿里）。用户 2026-10-31 需求：插在 DeepSeek 右侧。</summary>
    public static readonly AssistantProvider Qwen =
        new("qwen", "千问", "https://www.qianwen.com/", 1.0);

    public static readonly AssistantProvider Kimi =
        new("kimi", "Kimi", "https://www.kimi.com/", 0.9);

    public static readonly AssistantProvider ChatGlm =
        new("chatglm", "智谱", "https://chatglm.cn/", 0.55);

    public static readonly IReadOnlyList<AssistantProvider> All = new[]
    {
        DeepSeek, Qwen, Kimi, ChatGlm
    };

    /// <summary>
    /// 该 URL 是否属于某个内置站点的域名（含其子域）。
    ///
    /// 用途：助手页可以导航到任意地方（登录要跳第三方），但**程序代替用户往页面里
    /// 灌文字**这件事，只能在页面仍属于该站点自己时做。详见 AssistantService.SendPromptAsync。
    ///
    /// 只做"相等或子域"判断，不做后缀模糊匹配 —— 否则 `evil-deepseek.com` 会被放行。
    /// </summary>
    public static bool IsTrustedHost(string? url)
    {
        if (string.IsNullOrWhiteSpace(url))
        {
            return false;
        }

        if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? parsed))
        {
            return false;
        }

        if (parsed.Scheme != Uri.UriSchemeHttps && parsed.Scheme != Uri.UriSchemeHttp)
        {
            return false;
        }

        string host = parsed.Host;
        if (string.IsNullOrEmpty(host))
        {
            return false;
        }

        foreach (AssistantProvider p in All)
        {
            if (!Uri.TryCreate(p.Url, UriKind.Absolute, out Uri? known))
            {
                continue;
            }

            string knownHost = known.Host;
            if (string.Equals(host, knownHost, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            // 子域放行：host 以 ".已知域名" 结尾
            if (host.EndsWith("." + knownHost, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    public static AssistantProvider? ById(string? id)
    {
        if (string.IsNullOrWhiteSpace(id))
        {
            return null;
        }

        foreach (AssistantProvider p in All)
        {
            if (string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase))
            {
                return p;
            }
        }

        return null;
    }
}
