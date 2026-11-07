using System.Security.Cryptography;
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using QuickDrawer.Native;

namespace QuickDrawer;

/// <summary>剪贴板条目类型。</summary>
public enum ClipKind
{
    Text,
    Html,
    Image,
    Files,
    Rtf,
    Unknown
}

/// <summary>一条剪贴板记录。</summary>
public sealed class ClipEntry : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    public ClipKind Kind { get; set; } = ClipKind.Text;

    /// <summary>预览文本（最多 200 字符）。</summary>
    public string Preview { get; set; } = "";

    /// <summary>完整内容（图片/文件时为 null，图片存文件、文件存路径列表）。</summary>
    public string? Text { get; set; }

    /// <summary>图片保存的路径（相对 blobs 目录）。</summary>
    public string? BlobPath { get; set; }

    /// <summary>复制的文件路径列表。</summary>
    public List<string> Files { get; set; } = new();

    /// <summary>
    /// 锁定标记（2026-10-25 用户需求）：
    /// true 的条目 **不会被容量淘汰、也不会被"清除全部"删掉**，且一直排在列表最前。
    /// 通过 INotifyPropertyChanged 通知 UI 更新按钮样式。
    /// </summary>
    public bool Pinned
    {
        get => _pinned;
        set
        {
            if (_pinned == value)
            {
                return;
            }

            _pinned = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Pinned)));
        }
    }

    private bool _pinned;

    public DateTime CreatedAt { get; set; } = DateTime.Now;

    public string SourceApp { get; set; } = "";

    /// <summary>
    /// 内容指纹，用于去重。图片必须靠它：图片的 Text 恒为 null、Preview 恒为
    /// "图片"，只拿 Text/Preview 算 key 会让**每一张图都得到同一个 key**，
    /// 于是第一张之后的图全被当成"重复"静默丢弃（2026-11-01 实测）。
    /// 非图片条目留 null，ComputeKey 会退回用正文。
    /// </summary>
    public string? ContentHash { get; set; }

    /// <summary>
    /// HTML 条目的 &lt;style&gt; 块（含标签，可为 null）。
    ///
    /// Word / Excel 导出的 HTML 把边框、字体、行高全部写在
    /// &lt;head&gt;&lt;style&gt; 里，正文用 class=xl65 / class=MsoNormal 引用。
    /// 只存正文片段的话，粘回 Word/Excel 就是一堆没有边框的文字（用户
    /// 2026-11-02 报的“无表格样式”）。
    /// </summary>
    public string? HtmlStyle { get; set; }

    /// <summary>占用字节数估算（用于容量控制）。</summary>
    /// <summary>
    /// 条目大小（字节）。2026-11-01 审查 S9：从 int 改成 long。
    /// int 在单条超过 2 GB 时会溢出成负数，EvictIfNeeded 的字节账随之算错，
    /// 从此再也淘汰不掉任何东西。
    /// </summary>
    public long SizeBytes { get; set; }

    private BitmapSource? _thumbnail;
    private bool _thumbnailTried;

    /// <summary>
    /// 列表里的图片缩略图（仅 ClipKind.Image）。
    ///
    /// 懒加载：绑定第一次读它时才解码磁盘上的 DIB，结果缓存在实例里。
    /// 不这样做的话，启动时要把几十张图全部解码进内存。
    /// 读失败（文件被删 / DIB 损坏）就返回 null，UI 自动回退到文字预览。
    /// </summary>
    public BitmapSource? Thumbnail
    {
        get
        {
            if (!_thumbnailTried)
            {
                _thumbnailTried = true;
                if (Kind == ClipKind.Image)
                {
                    _thumbnail = ClipboardService.LoadThumbnail(BlobPath, 88);
                }
            }

            return _thumbnail;
        }
    }

    /// <summary>是否有图片缩略图（XAML 里用来切换显示）。</summary>
    public bool HasThumbnail => Thumbnail is not null;

    private List<List<string>>? _tableRows;

    /// <summary>
    /// HTML 条目里表格的行列文本（最多 4 行 × 6 列）。
    ///
    /// Word / Excel 复制的表格只显示第一个单元格的文字（用户 2026-11-02 报的
    /// 第 4 条），因为预览是把整个片段 StripTags 成一行。这里把行列结构
    /// 保留下来，列表里可以画成一张迷你表格。
    /// </summary>
    public List<List<string>> TableRows
    {
        get
        {
            if (_tableRows is null)
            {
                _tableRows = Kind == ClipKind.Html && !string.IsNullOrEmpty(Text)
                    ? ClipboardService.ParseTableRows(Text!, 4, 6)
                    : new List<List<string>>();
            }

            return _tableRows;
        }
    }

    /// <summary>是否是表格（XAML 里用来切换显示）。</summary>
    public bool HasTable => TableRows.Count > 0;
}

/// <summary>
/// 剪贴板监听与读取服务。
///
/// 关键设计（来自方案 §6.1 的时序竞争分析）：
///   WM_CLIPBOARDUPDATE 只告诉你"变了"，不告诉你"变成了什么"。
///   收到通知后必须自己 OpenClipboard 读取，而此时别的程序可能正持有剪贴板。
///   因此：延迟 + 指数退避重试，且用 GetClipboardSequenceNumber 去重。
/// </summary>
public sealed class ClipboardService : IDisposable
{
    private readonly object _gate = new();
    private readonly List<ClipEntry> _entries = new();
    /// <summary>
    /// 已见内容指纹集合。
    /// M2：原来存的是 `Kind|完整正文`，等于把本次运行复制过的所有正文永久留在内存里；
    /// 改为存 SHA-256 摘要（固定长度 hex），内存占用与内容大小无关。
    /// </summary>
    private readonly HashSet<string> _seen = new(StringComparer.Ordinal);

    /// <summary>
    /// 读取串行化闸门（M15）。
    /// 原来每条 WM_CLIPBOARDUPDATE 都起一个 Task，快速连续复制时多个任务
    /// 同时 OpenClipboard 互相抢，还会对同一条内容重复判断。
    /// </summary>
    private readonly SemaphoreSlim _readGate = new(1, 1);
    private readonly AppConfig _config;

    private IntPtr _hwnd;
    private HwndSource? _source;
    private bool _listening;
    private uint _lastSequence;

    /// <summary>
    /// 抑制窗口内被压掉的最后一次变更的剪贴板序列号（2026-11-05）。
    /// 窗口结束后据此补读一次，避免"用户在这段时间自己复制的内容"被永久丢弃。
    /// </summary>
    private uint _deferredSeq;

    /// <summary>补读任务是否已经挂上（0=没有，1=有），防止每次通知都起一个 Task。</summary>
    private int _reconcileScheduled;

    /// <summary>读闸门连续排不上的次数，用于退避重试。</summary>
    private int _gateMisses;

    /// <summary>有新记录时触发（在 UI 线程外，需要自行切回）。</summary>
    public event Action<ClipEntry>? EntryCaptured;

    /// <summary>条目被移除时触发（超出容量上限被淘汰）。</summary>
    public event Action<ClipEntry>? EntryEvicted;

    public ClipboardService(AppConfig config)
    {
        _config = config;
    }

    private static DateTime _suppressUntilUtc = DateTime.MinValue;

    /// <summary>
    /// 一段时间内不捕获剪贴板（2026-10-30）。
    ///
    /// Why：选中文字悬浮按钮取选中内容时，要靠"模拟 Ctrl+C + 读剪贴板"，
    /// 那会触发 WM_CLIPBOARDUPDATE —— 不抑制的话，用户每选一次文字，
    /// 剪贴板历史里就会多一条重复记录（还有还原时那一次）。
    /// </summary>
    public static void SuppressCapture(TimeSpan duration)
    {
        _suppressUntilUtc = DateTime.UtcNow + duration;
    }

    private static bool IsCaptureSuppressed => DateTime.UtcNow < _suppressUntilUtc;

    /// <summary>当前记录（倒序：最新在前）。调用方需自行加锁或用 Snapshot。</summary>
    public IReadOnlyList<ClipEntry> Snapshot()
    {
        lock (_gate)
        {
            return _entries.OrderByDescending(e => e.Pinned)
                           .ThenByDescending(e => e.CreatedAt)
                           .ToList();
        }
    }

    /// <summary>
    /// 把磁盘上载入的历史交给服务托管（2026-10-25）。
    ///
    /// Why：_entries 原本只装"本次运行捕获"的条目，导致 MaxItems/MaxBytes
    /// 的淘汰只看到新条目 —— 历史条目既不计入容量，锁定了也不受保护。
    /// </summary>
    public void Seed(IEnumerable<ClipEntry> entries)
    {
        // M16：入参是 UI 层的活集合（ObservableCollection）。直接在 lock 里枚举它，
        // 用户此刻若新增/删除一条就会抛 InvalidOperationException。
        // 先在外面拷贝一份，lock 内枚举的是快照。
        List<ClipEntry> copy;
        try
        {
            copy = entries.ToList();
        }
        catch (InvalidOperationException ex)
        {
            DiagLog.Write("clipboard", $"seed skipped: collection changed while copying ({ex.Message})");
            return;
        }

        lock (_gate)
        {
            foreach (ClipEntry e in copy.OrderBy(e => e.CreatedAt))
            {
                _entries.Add(e);
                _seen.Add(ComputeKey(e));
            }
        }
    }

    /// <summary>
    /// 标记某条目已由本程序写回剪贴板：下一轮捕获会按"已见"跳过，
    /// 不会因为点击粘贴而多出一条重复记录。
    /// </summary>
    public void SuppressRecapture(ClipEntry entry)
    {
        lock (_gate)
        {
            _seen.Add(ComputeKey(entry));
        }
    }

    /// <summary>清空服务侧记录；keepPinned=true 时保留锁定条目。</summary>
    public void Clear(bool keepPinned = false)
    {
        lock (_gate)
        {
            if (!keepPinned)
            {
                _entries.Clear();
                _seen.Clear();
                return;
            }

            for (int i = _entries.Count - 1; i >= 0; i--)
            {
                if (_entries[i].Pinned)
                {
                    continue;
                }

                _seen.Remove(ComputeKey(_entries[i]));
                _entries.RemoveAt(i);
            }
        }
    }

    /// <summary>
    /// 开始监听。
    ///
    /// ⚠️ 必须自己挂钩窗口消息：`AddClipboardFormatListener` 只是让系统把
    /// WM_CLIPBOARDUPDATE 发到这个窗口，**不会**自动调用任何回调。
    /// 2026-10-20 探针实测：只注册监听而不挂钩，通知一次都收不到。
    /// </summary>
    public void Start(IntPtr hwnd, HwndSource? source)
    {
        if (!_config.Clipboard.Enabled)
        {
            return;
        }

        _hwnd = hwnd;
        _source = source;

        bool ok = NativeMethods.AddClipboardFormatListener(hwnd);
        _listening = ok;

        if (source is not null)
        {
            source.AddHook(WndProc);
        }

        DiagLog.Write("clipboard", ok
            ? "listener registered and message hook attached"
            : $"AddClipboardFormatListener failed, err={Marshal.GetLastWin32Error()}");
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_CLIPBOARDUPDATE)
        {
            OnClipboardUpdated();
        }

        return IntPtr.Zero;
    }

    public void Stop()
    {
        if (!_listening)
        {
            return;
        }

        _source?.RemoveHook(WndProc);
        NativeMethods.RemoveClipboardFormatListener(_hwnd);
        _listening = false;
        DiagLog.Write("clipboard", "listener removed");
    }

    /// <summary>
    /// 处理 WM_CLIPBOARDUPDATE：延迟后读取剪贴板。
    /// 立即读取会失败（别的程序还持有剪贴板），所以异步延迟。
    /// </summary>
    public void OnClipboardUpdated()
    {
        if (IsCaptureSuppressed)
        {
            // 2026-11-05（用户报"复制了内容、能粘贴，但历史里没有"）：
            // 原来这里直接 return —— 抑制窗口（划词 2.5 秒 / 发截图 3 秒）内发生的
            // **所有**剪贴板变更都被丢掉，包括用户自己在划词之后立刻复制的东西。
            // 现在只记下这次变更的序列号，窗口结束后补读一次，不再静默丢弃。
            Volatile.Write(ref _deferredSeq, NativeMethods.GetClipboardSequenceNumber());
            DiagLog.Write("clipboard", "capture deferred (suppressed by selection watcher)");
            ScheduleSuppressReconcile();
            return;
        }

        _ = Task.Run(async () =>
        {
            // M15：一次只允许一个读取任务操作剪贴板。快速连复制时后来的会排队，
            // 保证不会有两个任务同时 OpenClipboard 互抢，也不会重复处理同一条内容。
            //
            // 2026-11-05：原来超时 5 秒就直接 return，那次通知就**永远丢了**
            //（生产日志里 "read skipped: previous read still running" 出现 23 次）。
            // 一次读取最长也就 1 秒出头，20 秒超时几乎不会真的触发；真触发了也退避重试。
            bool entered = await _readGate.WaitAsync(TimeSpan.FromSeconds(20));
            if (!entered)
            {
                if (Interlocked.Increment(ref _gateMisses) <= 10)
                {
                    DiagLog.Write("clipboard", "read gate busy, retrying");
                    await Task.Delay(200);
                    OnClipboardUpdated();
                }
                else
                {
                    Interlocked.Exchange(ref _gateMisses, 0);
                    DiagLog.Write("clipboard", "read gate busy after 10 retries, giving up");
                }

                return;
            }

            Interlocked.Exchange(ref _gateMisses, 0);

            try
            {
                ClipEntry? entry = await ReadWithRetryAsync();
                if (entry is null)
                {
                    return;
                }

                lock (_gate)
                {
                    // 单条大小闸：先于去重判断，省得把巨型内容的 key 也塞进 _seen
                    if (entry.SizeBytes > _config.Clipboard.MaxItemBytes)
                    {
                        DiagLog.Write("clipboard",
                            $"dropped {entry.Kind}: {entry.SizeBytes}B exceeds per-item limit {_config.Clipboard.MaxItemBytes}B");
                        return;
                    }

                    // 去重：同内容不重复记录。留一行日志，
                    // 否则"复制了却没多出一条"永远分不清是去重还是压根没读到。
                    string key = ComputeKey(entry);
                    if (_seen.Contains(key))
                    {
                        DiagLog.Write("clipboard", "dedup: identical content already in history");
                        return;
                    }

                    _seen.Add(key);

                    // 容量控制。返回 false 表示这条本身就不该进（超总量上限）。
                    if (!EvictIfNeeded(entry))
                    {
                        _seen.Remove(key);
                        return;
                    }

                    _entries.Add(entry);
                }

                EntryCaptured?.Invoke(entry);
                // 隐私（B1）：只记类型与字节数。正文、预览、来源进程名一律不记——
                // 来源进程名会暴露用户在用哪个密码管理器（1Password / KeePass 等）。
                DiagLog.Write("clipboard",
                    $"captured {entry.Kind} {entry.SizeBytes}B id={entry.Id}");
            }
            catch (Exception ex)
            {
                DiagLog.Write("clipboard", $"capture failed: {ex.Message}");
            }
            finally
            {
                _readGate.Release();
            }
        });
    }

    /// <summary>
    /// 抑制窗口到期后补读一次（2026-11-05）。
    ///
    /// 为什么要有：抑制窗口（划词 2.5 秒 / 发截图 3 秒）期间的所有
    /// WM_CLIPBOARDUPDATE 原来都被丢掉。那段时间里我们自己的读写确实不该记，
    /// 但**用户自己的复制也不该被吞**。现在窗口一结束就对着当前内容补读一次，
    /// 是不是我们写的由去重键裁定：我们写回的是旧内容、已经在历史里，会被去重挡掉。
    /// </summary>
    private void ScheduleSuppressReconcile()
    {
        if (Interlocked.Exchange(ref _reconcileScheduled, 1) == 1)
        {
            return;
        }

        _ = Task.Run(async () =>
        {
            try
            {
                // 抑制窗口可能被后一次 SuppressCapture 延长（例如还原前又武装了一次），
                // 所以这里循环等到它真正过期。
                while (true)
                {
                    TimeSpan left = _suppressUntilUtc - DateTime.UtcNow;
                    if (left <= TimeSpan.Zero)
                    {
                        break;
                    }

                    await Task.Delay(left + TimeSpan.FromMilliseconds(30));
                }

                uint seq = Volatile.Read(ref _deferredSeq);
                Volatile.Write(ref _deferredSeq, 0);
                Interlocked.Exchange(ref _reconcileScheduled, 0);

                if (seq == 0 || seq == _lastSequence)
                {
                    return;
                }

                DiagLog.Write("clipboard", $"reconcile after suppression (seq {seq})");
                OnClipboardUpdated();
            }
            catch (Exception ex)
            {
                Interlocked.Exchange(ref _reconcileScheduled, 0);
                DiagLog.Write("clipboard", "suppress reconcile failed: " + ex.Message);
            }
        });
    }

    /// <summary>读取剪贴板，失败则退避重试。</summary>
    private async Task<ClipEntry?> ReadWithRetryAsync()
    {
        // 2026-11-05：**取消原来的固定 80ms 首延迟**。
        // 原来每条通知都先睡 80 毫秒再读，这期间用户若又复制了一次，
        // 我们读到的就已经是新的那份 —— 前一份**永远不会进历史**
        //（Windows 剪贴板只保留最新内容，读晚了就是永久丢失）。
        // 现在第 0 次立即读，失败了再按 backoff 退避。
        int[] backoff = { 60, 120, 240, 480 };

        for (int attempt = 0; attempt <= backoff.Length; attempt++)
        {
            if (attempt > 0)
            {
                await Task.Delay(backoff[attempt - 1]);
            }

            uint seq = NativeMethods.GetClipboardSequenceNumber();
            if (seq == _lastSequence && attempt > 0)
            {
                // 序列号没变，说明内容其实没变（或已被别人改回），放弃
                return null;
            }

            ClipEntry? entry = TryReadClipboard();
            if (entry is not null)
            {
                _lastSequence = seq;
                return entry;
            }
        }

        DiagLog.Write("clipboard", "gave up reading after retries (clipboard kept locked by another app)");
        return null;
    }

    /// <summary>尝试读取一次剪贴板内容。</summary>
    private ClipEntry? TryReadClipboard()
    {
        if (!NativeMethods.OpenClipboard(_hwnd))
        {
            return null;   // 别的程序正持有，稍后重试
        }

        try
        {
            // 按优先级探测可用格式
            uint format = 0;
            // CF_HTML / CF_RTF 是**注册格式**，id 由 RegisterClipboardFormatW 在运行时
            // 分配（从 0xC000 起，每个会话不同）。实测本机 "HTML Format" = 0xC0F3、
            // "Rich Text Format" = 0xC095。原代码写死 0x00000100 / 0x000004C8，
            // 永远命中不了，所以 hasHtml 一直是 false（2026-11-01 定位）。
            uint htmlId = NativeMethods.HtmlFormat;
            uint rtfId = NativeMethods.RtfFormat;

            bool hasText = false, hasAnsiText = false, hasHtml = false, hasRtf = false;
            bool hasImage = false, hasFiles = false;

            while ((format = NativeMethods.EnumClipboardFormats(format)) != 0)
            {
                if (format == NativeMethods.CF_UNICODETEXT) hasText = true;
                else if (format == NativeMethods.CF_TEXT
                      || format == NativeMethods.CF_OEMTEXT) hasAnsiText = true;
                else if (format == NativeMethods.CF_HDROP) hasFiles = true;
                else if (format == NativeMethods.CF_BITMAP || format == NativeMethods.CF_DIB
                      || format == NativeMethods.CF_DIBV5) hasImage = true;
                else if (htmlId != 0 && format == htmlId) hasHtml = true;
                else if (rtfId != 0 && format == rtfId) hasRtf = true;
            }

            // 优先顺序：文件 > 文本 > HTML > 图片
            if (hasFiles && _config.Clipboard.CaptureFiles)
            {
                ClipEntry? files = ReadFiles();
                if (files is not null)
                {
                    return files;
                }

                // 2026-11-05：原来这里是 `return ReadFiles();` —— 读到 null
                //（句柄拿不到、路径过长等）就整条丢掉，连同时存在的文本 / 图片
                // 也一起丢。读不到就继续往下走。
            }

            // **为什么 HTML/RTF 必须排在文本前面**：Word / Excel / 浏览器复制表格或
            // 富文本时，会**同时**放 CF_UNICODETEXT + "HTML Format" + "Rich Text
            // Format"。原顺序让纯文本先 return，富格式永远读不到，粘回去就只剩一行行
            // 文字、表格结构丢失 —— 这就是"Word/Excel 表格无法保持原格式"的根因。
            //
            // 反过来，纯文本场景（记事本、终端）根本没有 HTML/RTF，不会误判。
            if (hasHtml && _config.Clipboard.CaptureHtml)
            {
                ClipEntry? html = ReadHtml();
                if (html is not null)
                {
                    return html;
                }
            }

            if (hasRtf && _config.Clipboard.CaptureHtml)
            {
                ClipEntry? rtf = ReadRtf();
                if (rtf is not null)
                {
                    return rtf;
                }
            }

            if (hasText || hasAnsiText)
            {
                ClipEntry? t = ReadText();
                if (t is not null)
                {
                    return t;
                }
            }

            if (hasImage && _config.Clipboard.CaptureImages)
            {
                return ReadImage();
            }

            return null;
        }
        finally
        {
            NativeMethods.CloseClipboard();
        }
    }

    private ClipEntry? ReadText()
    {
        IntPtr h = NativeMethods.GetClipboardData(NativeMethods.CF_UNICODETEXT);
        bool ansi = false;

        if (h == IntPtr.Zero)
        {
            // 2026-11-05：只有 CF_TEXT / CF_OEMTEXT 的程序（老式 Win32、
            // 部分终端与编辑器）原来走不到这里 —— 格式探测阶段就被判定成
            // "没有文本"，整条复制静默丢失。
            h = NativeMethods.GetClipboardData(NativeMethods.CF_TEXT);
            ansi = true;
        }

        if (h == IntPtr.Zero)
        {
            h = NativeMethods.GetClipboardData(NativeMethods.CF_OEMTEXT);
            ansi = true;
        }

        if (h == IntPtr.Zero)
        {
            return null;
        }

        IntPtr p = NativeMethods.GlobalLock(h);
        if (p == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            string? s = ansi ? Marshal.PtrToStringAnsi(p) : Marshal.PtrToStringUni(p);
            if (string.IsNullOrEmpty(s))
            {
                return null;
            }

            return new ClipEntry
            {
                Kind = ClipKind.Text,
                Text = s,
                Preview = Truncate(s.Replace('\r', ' ').Replace('\n', ' ').Trim(), 200),
                SourceApp = GetSourceApp(),
                SizeBytes = (long)s.Length * 2
            };
        }
        finally
        {
            NativeMethods.GlobalUnlock(h);
        }
    }

    private ClipEntry? ReadHtml()
    {
        // "HTML Format" 剪贴板格式：以 "Version:0.9\r\n" 开头，之后是 HTML 片段
        // id 必须运行时向系统要（理由见 TryReadClipboard 的注释）。
        uint htmlId = NativeMethods.HtmlFormat;
        if (htmlId == 0)
        {
            return null;
        }

        IntPtr h = NativeMethods.GetClipboardData(htmlId);
        if (h == IntPtr.Zero)
        {
            return null;
        }

        IntPtr p = NativeMethods.GlobalLock(h);
        if (p == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            // ⚠️ 必须按字节读再解码，不能 PtrToStringUni（理由见 DecodeHtmlBytes）。
            ulong size = (ulong)NativeMethods.GlobalSize(h);
            if (size == 0 || size > int.MaxValue)
            {
                return null;
            }

            byte[] buf = new byte[(int)size];
            Marshal.Copy(p, buf, 0, buf.Length);

            // M8：CF_HTML 是"偏移表 + 完整 HTML 文档"的复合格式：
            //   Version:0.9\r\n
            //   StartHTML:0000000105\r\nEndHTML:...\r\nStartFragment:...\r\nEndFragment:...\r\n
            //   <html><head><style>...</style></head><body><!--StartFragment-->正文<!--EndFragment--></body></html>
            //
            // ⚠️ 四个偏移都是**UTF-8 字节偏移**，不是解码后的字符偏移。
            // 把字节偏移当字符偏移去 Substring 是 2026-11-02 那轮
            // "预览显示 Normal 0" 的根因（证据见 TryExtractHtml 的注释）。
            if (!TryExtractHtml(buf, out string fragment, out string style))
            {
                return null;
            }

            return new ClipEntry
            {
                Kind = ClipKind.Html,
                Text = fragment,
                // <head> 里的 <style> 块。Word/Excel 用 class=xl65 之类引用它里面的边框定义，
                // 只写回片段的话这些 class 没有定义，粘出来就没有表格样式。
                HtmlStyle = style,
                Preview = BuildHtmlPreview(fragment),
                SourceApp = GetSourceApp(),
                SizeBytes = (long)fragment.Length * 2
            };
        }
        finally
        {
            NativeMethods.GlobalUnlock(h);
        }
    }

    /// <summary>
    /// 读 "Rich Text Format"。Word 复制带格式内容时同时提供 HTML 与 RTF，
    /// 通常 HTML 分支先命中；RTF 兜住只提供 RTF 的程序（旧版 Office、部分编辑器）。
    /// </summary>
    private ClipEntry? ReadRtf()
    {
        uint rtfId = NativeMethods.RtfFormat;
        if (rtfId == 0)
        {
            return null;
        }

        IntPtr h = NativeMethods.GetClipboardData(rtfId);
        if (h == IntPtr.Zero)
        {
            return null;
        }

        IntPtr p = NativeMethods.GlobalLock(h);
        if (p == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            // RTF 是 ANSI 字节流（7-bit 控制字 + 8-bit 正文）。
            string? s = Marshal.PtrToStringAnsi(p);
            if (string.IsNullOrEmpty(s) || !s.TrimStart().StartsWith(@"{\rtf", StringComparison.Ordinal))
            {
                return null;
            }

            return new ClipEntry
            {
                Kind = ClipKind.Rtf,
                Text = s,
                Preview = Truncate(StripRtf(s), 200),
                SourceApp = GetSourceApp(),
                SizeBytes = (long)s.Length * 2
            };
        }
        finally
        {
            NativeMethods.GlobalUnlock(h);
        }
    }

    private ClipEntry? ReadFiles()
    {
        IntPtr h = NativeMethods.GetClipboardData(NativeMethods.CF_HDROP);
        if (h == IntPtr.Zero)
        {
            return null;
        }

        IntPtr p = NativeMethods.GlobalLock(h);
        if (p == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            // 发布前审查 B4：原代码调用 NativeMethods.DragQueryFileCount()，
            // 但 shell32.dll 里根本没有这个导出——实测调用抛
            // EntryPointNotFoundException，导致"复制文件"100% 捕获失败
            // （生产日志 grep "captured Files" 为 0 条）。
            // 正确做法：DragQueryFile 的 iFile 传 0xFFFFFFFF 即返回文件总数。
            uint count = NativeMethods.DragQueryFile(h, 0xFFFFFFFF, IntPtr.Zero, 0, 0);
            var files = new List<string>();

            for (uint i = 0; i < count && files.Count < 200; i++)
            {
                // 第一次调用取所需缓冲区长度（cch=0）
                uint len = NativeMethods.DragQueryFile(h, i, IntPtr.Zero, 0, 0);
                if (len == 0)
                {
                    continue;
                }

                // 发布前审查 B5：len 是**字符数**，缓冲区必须按字符数 × 2 字节分配。
                // 原来只分配 len+2 字节（少一半），而 DragQueryFile 在
                // CharSet.Unicode 下会写 len+1 个宽字符 = 2*(len+1) 字节，
                // 属于非托管堆越界写。B4 修好之后这条路会真的走通，必须先修这里。
                IntPtr buf = Marshal.AllocHGlobal((int)(len + 1) * 2);
                try
                {
                    // 第二次调用取内容。签名：DragQueryFile(hDrop, iFile, lpszFile, cch, flags)
                    uint got = NativeMethods.DragQueryFile(h, i, buf, len + 1, 0);
                    if (got > 0)
                    {
                        files.Add(Marshal.PtrToStringUni(buf) ?? "");
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buf);
                }
            }

            if (files.Count == 0)
            {
                return null;
            }

            string first = files[0];
            string name = files.Count == 1
                ? Path.GetFileName(first)
                : $"{Path.GetFileName(first)} 等 {files.Count} 项";

            return new ClipEntry
            {
                Kind = ClipKind.Files,
                Files = files,
                Preview = name,
                SourceApp = GetSourceApp(),
                SizeBytes = files.Sum(f => (long)f.Length * 2)
            };
        }
        finally
        {
            NativeMethods.GlobalUnlock(h);
        }
    }

    private ClipEntry? ReadImage()
    {
        // 从 DIB 取位图。内存块以 BITMAPINFOHEADER(BITMAPV5HEADER) 开头。
        // M7：格式探测把 CF_DIBV5 也算作"有图片"，但这里原来只取 CF_DIB，
        // 于是只提供 V5 的应用（部分截图/绘图工具）复制的图片被静默丢弃。
        // CF_DIBV5 的头部是 BITMAPV5HEADER，**前 40 字节与 BITMAPINFOHEADER 完全一致**，
        // 所以直接整块存下来、写回时仍按 CF_DIB 提交是可行的。
        IntPtr h = NativeMethods.GetClipboardData(NativeMethods.CF_DIB);
        if (h == IntPtr.Zero)
        {
            h = NativeMethods.GetClipboardData(NativeMethods.CF_DIBV5);
        }

        if (h == IntPtr.Zero)
        {
            // 有些截图 / 绘图工具**只**提供 CF_BITMAP（GDI 句柄，不是内存块）。
            // 探测阶段已经把它算作"有图片"，若不在这里转换就会读不到 -> 整条
            // 静默丢弃，表现为"截图后历史里什么都没有"。所以这里补一条回退。
            return ReadBitmapFallback();
        }

        IntPtr p = NativeMethods.GlobalLock(h);
        if (p == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            int size = (int)NativeMethods.GlobalSize(h);
            byte[] dib = new byte[size];
            Marshal.Copy(p, dib, 0, size);

            string? blob = ClipboardBlobStore.SaveDib(dib);
            if (blob is null)
            {
                return null;
            }

            return new ClipEntry
            {
                Kind = ClipKind.Image,
                BlobPath = blob,
                Preview = "图片",
                // 图片没有 Text/Preview 内容可哈希，必须把 DIB 字节算成指纹，
                // 否则所有图片共用一个去重 key、只有第一张能进历史。
                ContentHash = ComputeBytesHash(dib),
                SourceApp = GetSourceApp(),
                SizeBytes = size
            };
        }
        finally
        {
            NativeMethods.GlobalUnlock(h);
        }
    }

    /// <summary>
    /// CF_BITMAP 回退：把 GDI 位图句柄转成自包含的 DIB 字节。
    /// 只有在 CF_DIB / CF_DIBV5 都拿不到时才走到这里。
    /// </summary>
    private ClipEntry? ReadBitmapFallback()
    {
        IntPtr hbm = NativeMethods.GetClipboardData(NativeMethods.CF_BITMAP);
        if (hbm == IntPtr.Zero)
        {
            return null;
        }

        var bmp = new NativeMethods.BITMAP();
        if (NativeMethods.GetObject(hbm, Marshal.SizeOf(typeof(NativeMethods.BITMAP)), ref bmp) == 0)
        {
            return null;
        }

        int width = bmp.bmWidth;
        int height = bmp.bmHeight;
        if (width <= 0 || height <= 0)
        {
            return null;
        }

        // 统一转成 32bpp BI_RGB：不用操心调色板和压缩，写回时 CF_DIB 也认。
        var header = new NativeMethods.BITMAPINFOHEADER
        {
            biSize = (uint)Marshal.SizeOf(typeof(NativeMethods.BITMAPINFOHEADER)),
            biWidth = width,
            biHeight = height,          // 正数 = 自底向上，与 GetDIBits 输出一致
            biPlanes = 1,
            biBitCount = 32,
            biCompression = NativeMethods.BI_RGB,
            biSizeImage = (uint)(width * height * 4)
        };

        byte[] pixels = new byte[width * height * 4];

        IntPtr hdc = NativeMethods.GetDC(IntPtr.Zero);
        if (hdc == IntPtr.Zero)
        {
            return null;
        }

        IntPtr memDc = NativeMethods.CreateCompatibleDC(hdc);
        if (memDc == IntPtr.Zero)
        {
            NativeMethods.ReleaseDC(IntPtr.Zero, hdc);
            return null;
        }

        IntPtr old = NativeMethods.SelectObject(memDc, hbm);
        try
        {
            int scanned = NativeMethods.GetDIBits(memDc, hbm, 0, (uint)height,
                pixels, ref header, NativeMethods.DIB_RGB_COLORS);
            if (scanned == 0)
            {
                return null;
            }
        }
        finally
        {
            if (old != IntPtr.Zero)
            {
                NativeMethods.SelectObject(memDc, old);
            }

            NativeMethods.DeleteDC(memDc);
            NativeMethods.ReleaseDC(IntPtr.Zero, hdc);
        }

        // 拼成完整 DIB：40 字节头 + 像素，这样落盘格式和 CF_DIB 分支完全一致。
        int headerSize = (int)header.biSize;
        byte[] dib = new byte[headerSize + pixels.Length];
        IntPtr hp = Marshal.AllocHGlobal(headerSize);
        try
        {
            Marshal.StructureToPtr(header, hp, false);
            Marshal.Copy(hp, dib, 0, headerSize);
        }
        finally
        {
            Marshal.FreeHGlobal(hp);
        }

        Buffer.BlockCopy(pixels, 0, dib, headerSize, pixels.Length);

        string? blob = ClipboardBlobStore.SaveDib(dib);
        if (blob is null)
        {
            return null;
        }

        return new ClipEntry
        {
            Kind = ClipKind.Image,
            BlobPath = blob,
            Preview = "图片",
            ContentHash = ComputeBytesHash(dib),
            SourceApp = GetSourceApp(),
            SizeBytes = dib.Length
        };
    }

    /// <summary>取剪贴板拥有者进程名（作为来源应用）。</summary>
    private string GetSourceApp()
    {
        try
        {
            IntPtr owner = NativeMethods.GetClipboardOwner();
            if (owner == IntPtr.Zero)
            {
                return "";
            }

            uint pid = 0;
            NativeMethods.GetWindowThreadProcessId(owner, out pid);
            if (pid == 0)
            {
                return "";
            }

            using Process? p = Process.GetProcessById((int)pid);
            return p?.ProcessName ?? "";
        }
        catch
        {
            return "";
        }
    }

    /// <summary>
    /// 容量控制：超出上限时淘汰最旧的未固定条目。
    ///
    /// ⚠️ 必须按"**加入新条目之后**"的数量来判断。
    /// 2026-10-20 实测：先按加入前的 Count 判断，淘汰后 Count 变小导致循环提前退出，
    /// 结果 MaxItems=5 却留下了 8 条。
    /// </summary>
    private bool EvictIfNeeded(ClipEntry incoming)
    {
        // 2026-11-01 审查 S9/M6：单条就超过总上限时，淘汰完所有非锁定项也没用 ——
        // 原代码在这里 break 出去，调用方照样把这条 Add 进来，结果是
        // "淘汰光了别人，自己还是超限"。这种条目从一开始就不该进。
        if (incoming.SizeBytes > _config.Clipboard.MaxBytes)
        {
            DiagLog.Write("clipboard",
                $"dropped oversized entry: {incoming.SizeBytes}B > {_config.Clipboard.MaxBytes}B");
            return false;
        }

        // 加入后将会有的条目数与字节数
        int countAfterAdd = _entries.Count + 1;
        long bytesAfterAdd = _entries.Sum(e => (long)e.SizeBytes) + incoming.SizeBytes;

        while (bytesAfterAdd > _config.Clipboard.MaxBytes
               || countAfterAdd > _config.Clipboard.MaxItems)
        {
            // 找最旧的未固定条目（_entries 按时间升序插入，最前面最旧）
            int? idx = null;
            for (int i = 0; i < _entries.Count; i++)
            {
                if (!_entries[i].Pinned)
                {
                    idx = i;
                    break;
                }
            }

            if (idx is null)
            {
                break;   // 全是固定项，不再淘汰
            }

            ClipEntry removed = _entries[idx.Value];
            _entries.RemoveAt(idx.Value);
            countAfterAdd--;
            bytesAfterAdd -= removed.SizeBytes;

            // M2：淘汰后必须把指纹一起清掉，否则被淘汰的内容本运行内再复制一次
            // 会被误判成"已见"而不再记录。
            _seen.Remove(ComputeKey(removed));

            EntryEvicted?.Invoke(removed);
            // 隐私（B1）：只记类型与字节数，不记被淘汰条目的内容。
            DiagLog.Write("clipboard", $"evicted {removed.Kind} {removed.SizeBytes}B");
        }

        return true;
    }

    /// <summary>
    /// 去重键：同类型同内容视为重复。
    /// M2：key 里只放内容摘要、不放原文——原来 HashSet 把全部正文长驻内存。
    /// </summary>
    private static string ComputeKey(ClipEntry e)
    {
        string content = e.Kind switch
        {
            ClipKind.Files => string.Join("|", e.Files),
            // 图片的 Text 恒为 null、Preview 恒为 "图片"，走下面那条 fallback
            // 会让每张图得到同一个 key。
            ClipKind.Image => e.ContentHash ?? e.BlobPath ?? e.Id,
            _ => e.Text ?? e.Preview ?? ""
        };

        byte[] hash; using (var sha = SHA256.Create()) { hash = sha.ComputeHash(Encoding.UTF8.GetBytes(content)); }
        return $"{e.Kind}|{BitConverter.ToString(hash).Replace("-", "")}";
    }

    /// <summary>把条目写回系统剪贴板（用户点击历史记录时用）。</summary>
    /// <summary>把纯文本放到剪贴板（CF_UNICODETEXT）。调用方必须已持有剪贴板。</summary>
    private static bool WriteTextPayload(string text)
    {
        IntPtr mem = NativeMethods.GlobalAlloc(NativeMethods.GMEM_MOVEABLE,
            (UIntPtr)((text.Length + 1) * 2));
        if (mem == IntPtr.Zero) return false;

        IntPtr p = NativeMethods.GlobalLock(mem);
        try
        {
            // 必须写 UTF-16 字节：Marshal.Copy(char[], ...) 会按 1 字节/元素复制，
            // 中文会变乱码（2026-10-20 探针实录）。
            byte[] utf16 = Encoding.Unicode.GetBytes(text + "\0");
            Marshal.Copy(utf16, 0, p, utf16.Length);
        }
        finally
        {
            NativeMethods.GlobalUnlock(mem);
        }

        return NativeMethods.SetClipboardData(NativeMethods.CF_UNICODETEXT, mem) != IntPtr.Zero;
    }

    private const string HtmlStartMarker = "<!--StartFragment-->";
    private const string HtmlEndMarker = "<!--EndFragment-->";

    /// <summary>
    /// 把 HTML 片段包装成 "HTML Format" 并放到剪贴板。调用方必须已持有剪贴板。
    ///
    /// 格式（Windows 规范）：
    ///   Version:0.9 + CRLF
    ///   StartHTML:0000000107 + CRLF
    ///   EndHTML:... + CRLF
    ///   StartFragment:... + CRLF
    ///   EndFragment:... + CRLF
    ///   CRLF
    ///   &lt;!--StartFragment--&gt;正文&lt;!--EndFragment--&gt;
    ///
    /// 所有偏移都是**从字符串开头算起的 UTF-8 字节数**（不是字符数），且包含头部
    /// 自身。写错 Word/Excel 会忽略格式、退化成纯文本粘贴。
    /// </summary>
    private static bool WriteHtmlPayload(string fragment, string? style = null)
    {
        if (string.IsNullOrEmpty(fragment)) return false;

        uint htmlId = NativeMethods.HtmlFormat;
        if (htmlId == 0) return false;

        // 片段若已自带 StartFragment 注解就不再重复包一层。
        bool wrapped = fragment.IndexOf(HtmlStartMarker, StringComparison.Ordinal) >= 0;
        string inner = wrapped ? fragment : HtmlStartMarker + fragment + HtmlEndMarker;

        // 把 <style> 拼回 <head>。Word/Excel 的表格边框、字体、行高全在这里，
        // 丢了就是“粘回去没有表格样式”。没有 style 时保持原来的裸片段形式。
        string body = inner;
        if (!string.IsNullOrEmpty(style))
        {
            body = "<html><head>" + style + "</head><body>" + inner + "</body></html>";
        }

        const string HEAD_FMT =
            "Version:0.9\r\n" +
            "StartHTML:{0:0000000000}\r\n" +
            "EndHTML:{1:0000000000}\r\n" +
            "StartFragment:{2:0000000000}\r\n" +
            "EndFragment:{3:0000000000}\r\n" +
            "\r\n";

        // 头部各字段是固定 10 位宽度，所以长度与具体数值无关：
        // 先用占位值格式化一次，量出真实字节长度，再据此算偏移。
        // 硬编码 105/107、"StartFragment" 13/20 这种估算正是踩坑来源。
        int headLen = Encoding.UTF8.GetByteCount(string.Format(HEAD_FMT, 0, 0, 0, 0));

        // 偏移一律在**最终 body**上量。把 body 切成 prefix / 片段 / suffix 三段，
        // 偏移 = headLen + 前两段的 UTF-8 字节数。这样无论有没有 style 包装都对。
        int markerAt = body.IndexOf(HtmlStartMarker, StringComparison.Ordinal);
        int endMarkerAt = body.IndexOf(HtmlEndMarker, StringComparison.Ordinal);

        int fragStart;
        int fragEnd;
        if (markerAt >= 0 && endMarkerAt > markerAt)
        {
            int afterMarker = markerAt + HtmlStartMarker.Length;
            fragStart = headLen + Encoding.UTF8.GetByteCount(body.Substring(0, afterMarker));
            fragEnd = headLen + Encoding.UTF8.GetByteCount(body.Substring(0, endMarkerAt));
        }
        else
        {
            fragStart = headLen;
            fragEnd = headLen + Encoding.UTF8.GetByteCount(body);
        }

        int htmlStart = headLen;
        int htmlEnd = headLen + Encoding.UTF8.GetByteCount(body);

        string full = string.Format(HEAD_FMT, htmlStart, htmlEnd, fragStart, fragEnd) + body;
        byte[] bytes = Encoding.UTF8.GetBytes(full + "\0");

        IntPtr mem = NativeMethods.GlobalAlloc(NativeMethods.GMEM_MOVEABLE, (UIntPtr)bytes.Length);
        if (mem == IntPtr.Zero) return false;

        IntPtr p = NativeMethods.GlobalLock(mem);
        try
        {
            Marshal.Copy(bytes, 0, p, bytes.Length);
        }
        finally
        {
            NativeMethods.GlobalUnlock(mem);
        }

        return NativeMethods.SetClipboardData(htmlId, mem) != IntPtr.Zero;
    }

    public static bool WriteBack(ClipEntry entry)
    {
        try
        {
            if (!NativeMethods.OpenClipboard(IntPtr.Zero))
            {
                return false;
            }

            try
            {
                NativeMethods.EmptyClipboard();

                switch (entry.Kind)
                {
                    case ClipKind.Text:
                    {
                        string text = entry.Text ?? "";
                        IntPtr mem = NativeMethods.GlobalAlloc(NativeMethods.GMEM_MOVEABLE,
                            (UIntPtr)((text.Length + 1) * 2));
                        if (mem == IntPtr.Zero) return false;

                        IntPtr p = NativeMethods.GlobalLock(mem);
                        try
                        {
                            // ⚠️ 必须写 UTF-16 字节。用 Marshal.Copy(char[], ...) 会按
                            // 1 字节/元素复制，高字节全丢，中文会变成乱码
                            // （2026-10-20 探针实测：write-back 回来的内容为空/乱码）。
                            byte[] utf16 = Encoding.Unicode.GetBytes(text + "\0");
                            Marshal.Copy(utf16, 0, p, utf16.Length);
                        }
                        finally
                        {
                            NativeMethods.GlobalUnlock(mem);
                        }

                        NativeMethods.SetClipboardData(NativeMethods.CF_UNICODETEXT, mem);
                        return true;
                    }

                    case ClipKind.Files:
                    {
                        if (entry.Files.Count == 0) return false;

                        // 构造 DROPFILES 结构
                        const int DROPFILES_SIZE = 20;
                        int chars = entry.Files.Sum(f => f.Length + 1) + 1;
                        int bytes = DROPFILES_SIZE + chars * 2;

                        IntPtr mem = NativeMethods.GlobalAlloc(NativeMethods.GMEM_MOVEABLE, (UIntPtr)bytes);
                        if (mem == IntPtr.Zero) return false;

                        IntPtr p = NativeMethods.GlobalLock(mem);
                        try
                        {
                            byte[] head = new byte[DROPFILES_SIZE];
                            // pFiles 是文件列表相对结构体开头的**字节**偏移，恒为 DROPFILES_SIZE。
                            // 原来写成 chars（字符数）是错的：pFiles=20 与文件名长度无关。
                            BitConverter.GetBytes((uint)DROPFILES_SIZE).CopyTo(head, 0);
                            // pt 在偏移 4（POINT，8 字节），非拖放场景保持 0；
                            // 原来写在偏移 8 会覆盖 fNC（偏移 12）。
                            BitConverter.GetBytes(1).CopyTo(head, 16);                   // fWide = TRUE
                            Marshal.Copy(head, 0, p, DROPFILES_SIZE);

                            int offset = DROPFILES_SIZE;
                            foreach (string f in entry.Files)
                            {
                                byte[] fb = Encoding.Unicode.GetBytes(f + "\0");
                                Marshal.Copy(fb, 0, p + offset, fb.Length);
                                offset += fb.Length;
                            }

                            // 列表末尾还要一个额外的 NUL（chars 里已预留 1 个字符）。
                            // GMEM_MOVEABLE 不清零，不显式写这 2 字节就是未初始化内存。
                            Marshal.Copy(new byte[2], 0, p + offset, 2);
                        }
                        finally
                        {
                            NativeMethods.GlobalUnlock(mem);
                        }

                        NativeMethods.SetClipboardData(NativeMethods.CF_HDROP, mem);
                        return true;
                    }

                    case ClipKind.Image:
                    {
                        byte[]? dib = ClipboardBlobStore.Load(entry.BlobPath);
                        if (dib is null) return false;

                        IntPtr mem = NativeMethods.GlobalAlloc(NativeMethods.GMEM_MOVEABLE, (UIntPtr)dib.Length);
                        if (mem == IntPtr.Zero) return false;

                        IntPtr p = NativeMethods.GlobalLock(mem);
                        try
                        {
                            Marshal.Copy(dib, 0, p, dib.Length);
                        }
                        finally
                        {
                            NativeMethods.GlobalUnlock(mem);
                        }

                        NativeMethods.SetClipboardData(NativeMethods.CF_DIB, mem);
                        return true;
                    }

                    case ClipKind.Html:
                    {
                        if (WriteHtmlPayload(entry.Text ?? "", entry.HtmlStyle))
                        {
                            return true;
                        }

                        // HTML 写失败就退回纯文本：内容还在，只是丢了格式。
                        string preview = entry.Preview ?? "";
                        return preview.Length > 0 && WriteTextPayload(preview);
                    }

                    case ClipKind.Rtf:
                    {
                        // RTF 本身就是要提交的字节流，不需要额外封装。
                        string rtf = entry.Text ?? "";
                        if (rtf.Length == 0) return false;

                        uint rtfId = NativeMethods.RtfFormat;
                        if (rtfId == 0) return false;

                        // RTF 是面向字节的格式（控制字 7-bit + 正文按 ANSI 码页），
                        // 在中文系统上 Encoding.Default 就是 GBK，与 Word 写入时一致。
                        byte[] bytes = Encoding.Default.GetBytes(rtf + "\0");
                        IntPtr mem = NativeMethods.GlobalAlloc(NativeMethods.GMEM_MOVEABLE, (UIntPtr)bytes.Length);
                        if (mem == IntPtr.Zero) return false;

                        IntPtr p = NativeMethods.GlobalLock(mem);
                        try
                        {
                            Marshal.Copy(bytes, 0, p, bytes.Length);
                        }
                        finally
                        {
                            NativeMethods.GlobalUnlock(mem);
                        }

                        return NativeMethods.SetClipboardData(rtfId, mem) != IntPtr.Zero;
                    }

                    default:
                        return false;
                }
            }
            finally
            {
                NativeMethods.CloseClipboard();
            }
        }
        catch (Exception ex)
        {
            DiagLog.Write("clipboard", $"write back failed: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// 从 CF_HTML 复合格式里切出 HTML 片段。
    /// 解析失败时退回"跳过头部偏移表"的朴素做法，至少不会把偏移数字当内容。
    /// </summary>
    /// <summary>
    /// 把 CF_HTML 的原始字节解码成字符串。
    ///
    /// 规范里 "HTML Format" 是 **UTF-8** 字节流，不是 UTF-16。用
    /// <c>Marshal.PtrToStringUni</c> 读会把每个中文字符的 3 个 UTF-8 字节
    /// 当成 1.5 个 UTF-16 码元，整条内容变乱码（2026-11-02 实测：ASCII 头
    /// "Version:0.9" 被读成 6556 7372 6F69 3A6E 2E31 0D30 530A）。
    ///
    /// 少数程序会写 UTF-16LE，因此按前导字节判定：UTF-16LE 的 ASCII 文本
    /// 每隔一个字节就是 0。
    /// </summary>
    private static string DecodeHtmlBytes(byte[] bytes)
    {
        int len = Array.IndexOf(bytes, (byte)0);
        if (len < 0)
        {
            len = bytes.Length;
        }

        if (len == 0)
        {
            return string.Empty;
        }

        bool looksUtf16 = len >= 4 && bytes[0] != 0 && bytes[1] == 0 && bytes[3] == 0;
        return looksUtf16
            ? Encoding.Unicode.GetString(bytes, 0, len - (len % 2))
            : Encoding.UTF8.GetString(bytes, 0, len);
    }

    /// <summary>
    /// 从 CF_HTML 复合载荷里切出片段与 &lt;style&gt; 块。
    ///
    /// **所有头部偏移都是 UTF-8 字节偏移**（Windows 规范）。2026-11-02 实测
    /// Word 16.0 的载荷：原始 40623 字节、解码后 40569 字符，StartFragment
    /// 声明 39666，恰好等于字节坐标下 &lt;!--StartFragment--&gt; 的结束位置
    /// （字符坐标下是 39612）。旧实现把 39666 当字符下标去 Substring，
    /// EndFragment(40583) 又超过字符总长 40569，于是校验失败、退化成"跳过
    /// 头部空行"的兜底路径，从 Word 的 &lt;head&gt; 里切走一大段 CSS，
    /// 预览就成了 "Normal 0 false false false EN-US ZH-CN X-NONE 7.8 磅"。
    /// </summary>
    private static bool TryExtractHtml(byte[] raw, out string fragment, out string style)
    {
        fragment = string.Empty;
        style = string.Empty;

        // 头部是纯 ASCII，先按 ASCII 解析出四个偏移。
        int headProbe = Math.Min(raw.Length, 4096);
        string head = Encoding.ASCII.GetString(raw, 0, headProbe);

        int startHtml = FindHeaderOffset(head, "StartHTML");
        int endHtml = FindHeaderOffset(head, "EndHTML");
        int startFrag = FindHeaderOffset(head, "StartFragment");
        int endFrag = FindHeaderOffset(head, "EndFragment");

        // 片段：StartFragment..EndFragment。两个偏移都必须落在载荷内。
        bool offsetsUsable = startFrag >= 0 && endFrag > startFrag && endFrag <= raw.Length;
        if (offsetsUsable)
        {
            fragment = ExtractTableAware(raw, startFrag, endFrag);
        }
        else
        {
            fragment = ExtractHtmlFragmentFallback(DecodeHtmlBytes(raw));
        }

        if (fragment.Length == 0)
        {
            return false;
        }

        // <style> 块在 <head> 里，位于 StartHTML..StartFragment 之间。
        // 取不到就留空（纯文本片段本来就没有 style）。
        if (startHtml >= 0 && startFrag > startHtml && startFrag <= raw.Length)
        {
            string headHtml = DecodeHtmlBytes(Slice(raw, startHtml, startFrag));
            style = ExtractStyleBlock(headHtml);
        }

        return true;
    }

    /// <summary>从 &lt;head&gt; 文本里取出 &lt;style&gt;...&lt;/style&gt; 整块（含标签）。</summary>
    private static string ExtractStyleBlock(string html)
    {
        int at = html.IndexOf("<style", StringComparison.OrdinalIgnoreCase);
        if (at < 0)
        {
            return string.Empty;
        }

        int close = html.IndexOf("</style>", at, StringComparison.OrdinalIgnoreCase);
        if (close < 0)
        {
            return string.Empty;
        }

        close += "</style>".Length;
        return html.Substring(at, close - at);
    }

    /// <summary>
    /// 按 StartFragment/EndFragment 取片段，并在需要时把范围扩到外层 &lt;table&gt;。
    ///
    /// 为什么必须扩：Excel 复制单元格区域时，CF_HTML 的 StartFragment/EndFragment
    /// 只圈住 &lt;col&gt;/&lt;tr&gt;/&lt;td&gt;，把 &lt;table&gt; 开闭标签留在片段外
    /// （实测 &lt;table 在字节 1791 &lt; StartFragment=1915，&lt;/table&gt; 在 2250 &gt; EndFragment=2230）。
    /// 存下来的片段因此没有表格结构，写回后粘进 Excel 只是若干散落的单元格文本。
    /// Word 的片段自带 &lt;table&gt;，走这里不会改动。
    /// </summary>
    private static string ExtractTableAware(byte[] raw, int start, int end)
    {
        string text = DecodeHtmlBytes(Slice(raw, start, end));
        bool hasCell = text.IndexOf("<tr", StringComparison.OrdinalIgnoreCase) >= 0
                    || text.IndexOf("<td", StringComparison.OrdinalIgnoreCase) >= 0;
        bool hasTable = text.IndexOf("<table", StringComparison.OrdinalIgnoreCase) >= 0;

        if (!hasCell || hasTable)
        {
            return text;
        }

        // 标签是纯 ASCII。latin-1（28591）是单字节一一映射，字符下标等于字节下标，
        // 因此可以拿整段载荷当字符串搜标签，再用同一组下标切字节。
        string latin = Encoding.GetEncoding(28591).GetString(raw);

        int open = latin.LastIndexOf("<table", start, StringComparison.OrdinalIgnoreCase);
        int close = open >= 0
            ? latin.IndexOf("</table>", end, StringComparison.OrdinalIgnoreCase)
            : -1;
        if (open < 0 || close < 0)
        {
            return text;
        }

        string widened = DecodeHtmlBytes(Slice(raw, open, close + "</table>".Length));

        // 扩展后两个片段标记会落在内部，剥掉它们，免得写回时 marker 定位漂移。
        widened = widened.Replace(HtmlStartMarker, string.Empty)
                         .Replace(HtmlEndMarker, string.Empty);

        return widened.Trim();
    }

    private static byte[] Slice(byte[] raw, int start, int end)
    {
        byte[] part = new byte[end - start];
        Buffer.BlockCopy(raw, start, part, 0, part.Length);
        return part;
    }

    /// <summary>
    /// 兜底：偏移不可用（头部缺失 / 写入方不规范）时，按标记或空行切。
    /// 只在 TryExtractHtml 的字节偏移路径失败后调用。
    /// </summary>
    private static string ExtractHtmlFragmentFallback(string raw)
    {
        int sf = raw.IndexOf(HtmlStartMarker, StringComparison.Ordinal);
        int ef = raw.IndexOf(HtmlEndMarker, StringComparison.Ordinal);
        if (sf >= 0 && ef > sf)
        {
            int from = sf + HtmlStartMarker.Length;
            return raw.Substring(from, ef - from);
        }

        // 头部一定以空行结束，HTML 从空行之后开始。
        int blank = raw.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        int skip = 4;
        if (blank < 0)
        {
            blank = raw.IndexOf("\n\n", StringComparison.Ordinal);
            skip = 2;
        }

        if (blank < 0) return raw.Trim();
        int fragStart = blank + skip;
        return fragStart < raw.Length ? raw.Substring(fragStart).Trim() : string.Empty;
    }

    /// <summary>读 CF_HTML 头部形如 "StartFragment:00000123" 的十进制偏移。</summary>
    private static int FindHeaderOffset(string raw, string name)
    {
        int at = raw.IndexOf(name + ":", StringComparison.Ordinal);
        if (at < 0)
        {
            return -1;
        }

        int i = at + name.Length + 1;
        while (i < raw.Length && raw[i] == ' ')
        {
            i++;
        }

        int digitsStart = i;
        while (i < raw.Length && raw[i] >= '0' && raw[i] <= '9')
        {
            i++;
        }

        if (i == digitsStart)
        {
            return -1;
        }

        return int.TryParse(raw.Substring(digitsStart, i - digitsStart), out int value) ? value : -1;
    }

    /// <summary>
    /// 生成 HTML 条目的列表预览。
    ///
    /// 表格（Word / Excel）走专用路径：按行收集单元格文本，用 " | " 连接，
    /// 这样列表里能看出是个几行几列的表，而不是只显示第一个单元格。
    /// 非表格退回 StripTags 的纯文本。
    /// </summary>
    private static string BuildHtmlPreview(string fragment)
    {
        if (fragment.IndexOf("<table", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            string grid = BuildTablePreview(fragment);
            if (grid.Length > 0)
            {
                return Truncate(grid, 200);
            }
        }

        return Truncate(StripTags(fragment), 200);
    }

    /// <summary>
    /// 把 HTML 表格解析成行列文本（最多 maxRows 行 × maxCols 列）。
    /// 列表里的迷你表格用它渲染；也用来生成纯文本预览。
    /// </summary>
    public static List<List<string>> ParseTableRows(string html, int maxRows, int maxCols)
    {
        var rows = new List<List<string>>();
        if (string.IsNullOrEmpty(html))
        {
            return rows;
        }

        int rowStart = 0;
        while (rows.Count < maxRows)
        {
            int trAt = html.IndexOf("<tr", rowStart, StringComparison.OrdinalIgnoreCase);
            if (trAt < 0) break;

            int trEnd = html.IndexOf("</tr>", trAt, StringComparison.OrdinalIgnoreCase);
            if (trEnd < 0) trEnd = html.Length;

            var cells = new List<string>();
            int cellAt = trAt;
            while (cells.Count < maxCols)
            {
                int tdAt = html.IndexOf("<td", cellAt, StringComparison.OrdinalIgnoreCase);
                if (tdAt < 0 || tdAt > trEnd) break;

                int tdEnd = html.IndexOf("</td>", tdAt, StringComparison.OrdinalIgnoreCase);
                if (tdEnd < 0 || tdEnd > trEnd) break;

                int open = html.IndexOf('>', tdAt);
                string inner = open >= 0 && open < tdEnd ? html.Substring(open + 1, tdEnd - open - 1) : string.Empty;
                string cell = StripTags(inner).Replace('\r', ' ').Replace('\n', ' ').Trim();
                if (cell.Length > 0 && cell != "\u3000")
                {
                    cells.Add(cell);
                }

                cellAt = tdEnd + 5;
            }

            if (cells.Count > 0)
            {
                rows.Add(cells);
            }

            rowStart = trEnd + 5;
        }

        return rows;
    }

    /// <summary>
    /// 把磁盘上的 DIB 解码成小尺寸缩略图（已 Freeze，可跨线程用）。
    ///
    /// DIB 就是 BMP 文件去掉前 14 字节文件头。这里把头补回去，交给 WIC 解码，
    /// 比自己手写像素拷贝安全得多（要处理 8/16/24/32bpp、行对齐、顶图底图、调色板）。
    /// </summary>
    public static BitmapSource? LoadThumbnail(string? blobPath, int maxWidth)
    {
        if (string.IsNullOrWhiteSpace(blobPath))
        {
            return null;
        }

        try
        {
            byte[]? dib = ClipboardBlobStore.Load(blobPath);
            if (dib is null || dib.Length < 40)
            {
                return null;
            }

            // 像素数据的偏移**不能写死 54**。
            // 写死 54 只对 40 字节 BITMAPINFOHEADER + 无调色板成立；
            // 剪贴板上常见的是 BITMAPV5HEADER（biSize=124）或带调色板的 8bpp，
            // 那时像素真实位置是 14+biSize+palette，写 54 会指到头部里面。
            int biSize = BitConverter.ToInt32(dib, 0);
            int biBitCount = BitConverter.ToUInt16(dib, 14);
            int biClrUsed = (int)BitConverter.ToUInt32(dib, 32);
            if (biSize < 40 || biSize > dib.Length)
            {
                return null;
            }

            int paletteEntries = biClrUsed != 0
                ? biClrUsed
                : (biBitCount <= 8 ? 1 << biBitCount : 0);
            int pixelOffset = 14 + biSize + paletteEntries * 4;

            // BITMAPFILEHEADER："BM" + 文件字节数 + 保留 + 像素数据偏移
            int fileSize = 14 + dib.Length;
            byte[] bmp = new byte[fileSize];
            bmp[0] = (byte)'B';
            bmp[1] = (byte)'M';
            bmp[2] = (byte)(fileSize & 0xFF);
            bmp[3] = (byte)((fileSize >> 8) & 0xFF);
            bmp[4] = (byte)((fileSize >> 16) & 0xFF);
            bmp[5] = (byte)((fileSize >> 24) & 0xFF);
            bmp[10] = (byte)(pixelOffset & 0xFF);
            bmp[11] = (byte)((pixelOffset >> 8) & 0xFF);
            bmp[12] = (byte)((pixelOffset >> 16) & 0xFF);
            bmp[13] = (byte)((pixelOffset >> 24) & 0xFF);
            Buffer.BlockCopy(dib, 0, bmp, 14, dib.Length);

            BitmapImage img = new();
            using (MemoryStream ms = new(bmp, writable: false))
            {
                img.BeginInit();
                img.StreamSource = ms;
                img.CacheOption = BitmapCacheOption.OnLoad;
                img.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;

                // 位图头部给出的宽度大于目标宽时才降采样；小图保持原样。
                // biWidth 在所有 DIB 头变体里都是第 4 字节。
                int width = BitConverter.ToInt32(dib, 4);
                if (width > maxWidth)
                {
                    img.DecodePixelWidth = maxWidth;
                }

                img.EndInit();
            }

            img.Freeze();
            return img;
        }
        catch (Exception ex)
        {
            DiagLog.Write("clipboard", $"thumbnail failed: {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>把 HTML 表格拍成 "单元格 | 单元格" 的多行文本（最多 4 行 × 6 列）。</summary>
    private static string BuildTablePreview(string html)
    {
        var lines = new List<string>();
        int rowStart = 0;

        while (lines.Count < 4)
        {
            int trAt = html.IndexOf("<tr", rowStart, StringComparison.OrdinalIgnoreCase);
            if (trAt < 0) break;

            int trEnd = html.IndexOf("</tr>", trAt, StringComparison.OrdinalIgnoreCase);
            if (trEnd < 0) trEnd = html.Length;

            var cells = new List<string>();
            int cellAt = trAt;
            while (cells.Count < 6)
            {
                int tdAt = html.IndexOf("<td", cellAt, StringComparison.OrdinalIgnoreCase);
                if (tdAt < 0 || tdAt > trEnd) break;

                int tdEnd = html.IndexOf("</td>", tdAt, StringComparison.OrdinalIgnoreCase);
                if (tdEnd < 0 || tdEnd > trEnd) break;

                int open = html.IndexOf('>', tdAt);
                string inner = open >= 0 && open < tdEnd ? html.Substring(open + 1, tdEnd - open - 1) : string.Empty;
                string cell = StripTags(inner).Replace('\r', ' ').Replace('\n', ' ').Trim();
                if (cell.Length > 0 && cell != "\u3000")
                {
                    cells.Add(cell);
                }

                cellAt = tdEnd + 5;
            }

            if (cells.Count > 0)
            {
                lines.Add(string.Join(" | ", cells));
            }

            rowStart = trEnd + 5;
        }

        return string.Join("\n", lines);
    }

    private static string StripTags(string html)
    {
        var sb = new System.Text.StringBuilder(html.Length);
        bool inTag = false;
        foreach (char c in html)
        {
            if (c == '<') inTag = true;
            else if (c == '>') inTag = false;
            else if (!inTag) sb.Append(c);
        }
        return System.Net.WebUtility.HtmlDecode(sb.ToString()).Trim();
    }

    /// <summary>对二进制内容算 SHA-256（十六进制），用于图片去重。</summary>
    private static string ComputeBytesHash(byte[] data)
    {
        using var sha = SHA256.Create();
        return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "");
    }

    /// <summary>从 RTF 里粗略抽一段可读文本做预览（不完整解析控制字，够预览用）。</summary>
    /// <summary>RTF 的 \ucN：\uNNNN 后面跟几个 \'hh 回退字符。默认 1。</summary>
    private static int _rtfUcSkip = 1;

    private static string StripRtf(string rtf)
    {
        _rtfUcSkip = 1;
        var sb = new System.Text.StringBuilder(rtf.Length / 2);

        // RTF 里大量「目标分组」（{\fonttbl ...}、{\colortbl ...}、{\stylesheet ...}、
        // {\info ...}、{\*\...}）只有声明价值，正文一个字都没有。不跳过它们，
        // 预览就会变成字体名和样式名 —— 复制 Excel 表格时尤其明显。
        var skip = new System.Collections.Generic.Stack<bool>();
        bool skipping = false;

        int i = 0;
        while (i < rtf.Length)
        {
            char c = rtf[i];

            if (c == (char)123)
            {
                // 进入新分组：看第一个 token 是不是要整组跳过的目标。
                skip.Push(skipping);
                if (!skipping)
                {
                    string word = PeekRtfControlWord(rtf, i + 1);
                    if (IsRtfDestination(word))
                    {
                        skipping = true;
                    }
                }

                i++;
                continue;
            }

            if (c == (char)125)
            {
                if (skip.Count > 0)
                {
                    skipping = skip.Pop();
                }

                i++;
                continue;
            }

            if (c == (char)92)
            {
                i++;
                if (i >= rtf.Length)
                {
                    break;
                }

                if (!char.IsLetter(rtf[i]))
                {
                    // 控制符号：\'hh 是十六进制字节，\{ \} \\ 是字面量。
                    if (rtf[i] == (char)39 && i + 2 < rtf.Length)
                    {
                        i += 3;
                        continue;
                    }

                    if (!skipping && (rtf[i] == (char)123 || rtf[i] == (char)125 || rtf[i] == (char)92))
                    {
                        sb.Append(rtf[i]);
                    }

                    i++;
                    continue;
                }

                int wordStart = i;
                while (i < rtf.Length && char.IsLetter(rtf[i]))
                {
                    i++;
                }

                int wordLen = i - wordStart;

                // \uNNNN 是 Unicode 转义，参数带符号位（负数表示相对当前码位）。
                // 它必须被还原成字符，否则中文（Word/Excel 常整段用 \u 表示）会被整段丢弃。
                int paramStart = i;
                bool paramNegative = i < rtf.Length && rtf[i] == (char)45;
                if (paramNegative)
                {
                    i++;
                }

                int paramDigits = i;
                while (i < rtf.Length && char.IsDigit(rtf[i]))
                {
                    i++;
                }

                bool hasParam = i > paramDigits || paramNegative;
                if (wordLen == 1 && string.CompareOrdinal(rtf, wordStart, "u", 0, 1) == 0 && hasParam)
                {
                    if (!skipping)
                    {
                        int value = 0;
                        for (int k = paramDigits; k < i; k++)
                        {
                            value = (value * 10) + (rtf[k] - (char)48);
                        }

                        if (paramNegative)
                        {
                            value = -value;
                        }

                        if (value < 0)
                        {
                            value += 65536;
                        }

                        if (value >= 0 && value <= 0xFFFF)
                        {
                            sb.Append((char)value);
                        }
                    }

                    // \ucN 声明的回退字符个数由后续 \'hh 序列补足，这里一并跳过，
                    // 否则会重复输出（\u24207\'d0'f2 里 'd0'f2 就是回退）。
                    int fallbacks = _rtfUcSkip;
                    while (fallbacks > 0 && i + 3 < rtf.Length && rtf[i] == (char)92 && rtf[i + 1] == (char)39)
                    {
                        i += 4;
                        fallbacks--;
                    }

                    continue;
                }

                if (i < rtf.Length && rtf[i] == (char)32)
                {
                    i++;
                }

                // \ucN 声明 Unicode 转义后面跟几个回退字符（默认 1）。
                if (wordLen == 2 && string.CompareOrdinal(rtf, wordStart, "uc", 0, 2) == 0 && i > paramDigits)
                {
                    int uc = 0;
                    for (int k = paramDigits; k < i; k++)
                    {
                        uc = (uc * 10) + (rtf[k] - (char)48);
                    }

                    _rtfUcSkip = uc;
                }

                if (skipping)
                {
                    continue;
                }

                // 表格结构转成可读分隔符，否则所有单元格会粘成一串。
                if (wordLen == 4 && string.CompareOrdinal(rtf, wordStart, "cell", 0, 4) == 0)
                {
                    sb.Append(" | ");
                }
                else if (wordLen == 3 && string.CompareOrdinal(rtf, wordStart, "row", 0, 3) == 0)
                {
                    sb.Append('\n');
                }
                else if (wordLen == 3 && string.CompareOrdinal(rtf, wordStart, "par", 0, 3) == 0)
                {
                    sb.Append('\n');
                }
                else if (wordLen == 4 && string.CompareOrdinal(rtf, wordStart, "line", 0, 4) == 0)
                {
                    sb.Append('\n');
                }

                continue;
            }

            if (!skipping)
            {
                sb.Append(c);
            }

            i++;
        }

        // \cell 前后会留下 " | \n | " 这种冗余，压一下再返回。
        string text = sb.ToString().Replace("\r", string.Empty);
        while (text.Contains("  "))
        {
            text = text.Replace("  ", " ");
        }

        text = text.Replace(" | \n", "\n").Replace("\n | ", "\n").Replace(" |  | ", " | ");

        // \row 与 \par 都会产出换行，Word/Excel 常在行末连用两者，压成单个换行。
        while (text.Contains("\n\n"))
        {
            text = text.Replace("\n\n", "\n");
        }

        // 每行末尾多余的 " | "（空尾单元格）去掉，空行也一并丢弃。
        var lines = new System.Collections.Generic.List<string>();
        foreach (string line in text.Split('\n'))
        {
            string t = line.Trim();

            // 首列为空时行首会留一个孤立的 "|"，去掉。
            while (t.StartsWith("| ", StringComparison.Ordinal) || t == "|")
            {
                t = t.Length > 1 ? t.Substring(2).TrimStart() : string.Empty;
            }

            while (t.EndsWith(" |", StringComparison.Ordinal))
            {
                t = t.Substring(0, t.Length - 2).TrimEnd();
            }

            if (t.Length > 0)
            {
                lines.Add(t);
            }
        }

        return System.Net.WebUtility.HtmlDecode(string.Join("\n", lines)).Trim();
    }

    /// <summary>读 rtf[pos] 起（跳过分隔符）的第一个控制字，用于判断分组类型。</summary>
    private static string PeekRtfControlWord(string rtf, int pos)
    {
        while (pos < rtf.Length && (rtf[pos] == (char)32 || rtf[pos] == (char)10 || rtf[pos] == (char)13))
        {
            pos++;
        }

        if (pos >= rtf.Length || rtf[pos] != (char)92)
        {
            return string.Empty;
        }

        pos++;
        if (pos < rtf.Length && rtf[pos] == (char)42)
        {
            // \* 表示「可忽略目标」，整组都不是正文。
            return "*";
        }

        int start = pos;
        while (pos < rtf.Length && char.IsLetter(rtf[pos]))
        {
            pos++;
        }

        return pos > start ? rtf.Substring(start, pos - start) : string.Empty;
    }

    /// <summary>这些分组里没有正文，整组跳过。</summary>
    private static bool IsRtfDestination(string word)
    {
        switch (word)
        {
            case "*":
            case "fonttbl":
            case "colortbl":
            case "stylesheet":
            case "info":
            case "pict":
            case "object":
            case "header":
            case "footer":
            case "footnote":
            case "listtable":
            case "listoverridetable":
            case "rsidtbl":
            case "generator":
            case "themedata":
            case "colorschememapping":
            case "latentstyles":
            case "datastore":
            case "xmlnstbl":
                return true;
            default:
                return false;
        }
    }

    internal static string Truncate(string s, int max)
        => s.Length <= max ? s : s.Substring(0, max) + "…";

    public void Dispose()
    {
        Stop();
    }
}
