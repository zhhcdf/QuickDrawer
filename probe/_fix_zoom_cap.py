import sys

def rd(p):
    with open(p, 'rb') as f:
        raw = f.read()
    bom = raw.startswith(b'\xef\xbb\xbf')
    if bom:
        raw = raw[3:]
    crlf = b'\r\n' in raw
    return raw.decode('utf-8').replace('\r\n', '\n'), bom, crlf

def wr(p, s, bom, crlf):
    if crlf:
        s = s.replace('\n', '\r\n')
    data = s.encode('utf-8')
    if bom:
        data = b'\xef\xbb\xbf' + data
    with open(p, 'wb') as f:
        f.write(data)

def patch(p, pairs):
    s, bom, crlf = rd(p)
    for i, (old, new) in enumerate(pairs):
        c = s.count(old)
        assert c == 1, (p, 'anchor%d' % (i + 1), c)
        s = s.replace(old, new)
    wr(p, s, bom, crlf)
    print('patched', p, 'bom=', bom, 'crlf=', crlf)

# ---------------- 1) AssistantService.cs ----------------
patch('src/QuickDrawer/Assistant/AssistantService.cs', [(
'''    /// <summary>
    /// 实际生效的缩放 = 站点基础缩放 × 宽度乘数。
    ///
    /// 宽度乘数只在"加宽 + 允许随宽度缩放"时大于 1（2026-10-31 用户反馈：
    /// 以前加宽只拉长页面、字不变大；现在字体随面板等比放大）。
    /// 上限 2.0 —— WebView2 的 ZoomFactor 内部支持范围就是 0.1–2.0，
    /// 超出会被静默归一化，反而与预期不符。
    /// </summary>
    public double EffectiveZoomFor(AssistantProvider provider)
    {
        double baseZoom = ZoomFor(provider);
        double scale = _widthScale <= 0 ? 1.0 : _widthScale;
        double zoom = baseZoom * scale;

        if (zoom < 0.1) zoom = 0.1;
        if (zoom > 2.0) zoom = 2.0;
        return zoom;
    }''',
'''    /// <summary>
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
    }''',
)])

# ---------------- 2) Config.cs 注释 ----------------
patch('src/QuickDrawer/Config.cs', [(
'''    /// true = 缩放 × (当前面板宽 / 常规面板宽)，文字和布局一起等比放大；
    /// false = 恢复旧行为（只拉长页面，字号不变）。''',
'''    /// true = 缩放 × (当前面板宽 / 常规面板宽)，但**结果上限固定 1.0**
    ///        （2026-11-03 用户需求「所有助手页面内容最大保持 1.0」）——
    ///        所以只有基准缩放低于 1.0 的站点（Kimi 0.9 / 智谱 0.55）会真的变大，
    ///        DeepSeek / 千问基准就是 1.0，加宽后字号不再变化；
    /// false = 完全不乘，各站点保持基准缩放（只拉长页面）。''',
)])

# ---------------- 3) SettingsWindow.xaml 文案 ----------------
patch('src/QuickDrawer/SettingsWindow.xaml', [
(
'''            <CheckBox x:Name="ZoomScaleCheck" Content="助手页加宽时字体等比放大"''',
'''            <CheckBox x:Name="ZoomScaleCheck" Content="助手页加宽时把小号站点补到 1.0"''',
),
(
'''                       Text="开启后，助手页点“加宽”时网页缩放会按宽度比例放大，字体跟着变大"''',
'''                       Text="缩放上限固定 1.0。开启后加宽时只把偏小的站点（Kimi 0.9、智谱 0.55）补到 1.0 为止；DeepSeek / 千问本来就是 1.0，字号不变，只是显示更多内容"''',
),
])
