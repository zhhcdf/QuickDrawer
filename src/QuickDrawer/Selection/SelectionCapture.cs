using QuickDrawer.Native;
using IDataObject = System.Windows.IDataObject;

namespace QuickDrawer.Selection;

/// <summary>
/// 取用户刚选中的文字。
///
/// ⚠️ 这里**故意不用** UIA 的 <c>TextPatternRange.GetText()</c>：
/// 2026-10-30 实测，对 WinForms 编辑框取选区时它会让整个进程
/// <c>0xC0000005</c> 崩溃（事件日志栈顶 <c>RawTextRange_GetText</c>，
/// 托管 try/catch 拦不住访问违例）。"选个文字"这种高频操作不能带崩进程的路径，
/// 所以只走剪贴板：Ctrl+C → 用剪贴板序列号判断真的换了 → 读出来 → 还原原内容。
///
/// 代价：会短暂改写用户的剪贴板，取完原样写回（文本、图片、文件都还原）；
/// 还原期间通知剪贴板监听"别记录"，免得每选一次文字就往历史里塞一条。
/// </summary>
internal static class SelectionCapture
{
    /// <summary>单次 Ctrl+C 后等剪贴板变化的最长时间（轮询次数 × 间隔 ≈ 800ms）。</summary>
    private const int PollCount = 20;

    private const int PollDelayMs = 40;

    /// <summary>
    /// 连续选中同一段文字时，第一次 Ctrl+C 有时会被剪贴板占用吞掉
    /// （2026-10-30 实测：第二次选区序列号 1.2 秒没动）。补发一次即可。
    /// </summary>
    private const int CopyAttempts = 2;

    /// <summary>
    /// 这些程序里 Ctrl+C 会被解释成"中断"（SIGINT），不是复制。
    /// 在里面拖选文字时不能注入 Ctrl+C，否则会打断用户正在跑的命令。
    /// 全部小写，比较时用 OrdinalIgnoreCase。
    /// </summary>
    private static readonly HashSet<string> TerminalProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "conhost",
        "OpenConsole",
        "WindowsTerminal",
        "wt",
        "cmd",
        "powershell",
        "pwsh",
        "mintty",
        "bash",
        "ConEmu",
        "ConEmu64",
        "Cmder",
        "alacritty",
        "wezterm-gui",
        "Hyper"
    };

    /// <summary>
    /// 当前前台窗口是不是终端。是的话就完全不能发 Ctrl+C。
    /// 拿不到进程名时按"不是终端"处理 —— 宁可偶尔漏判，也不要让划词功能整体失效。
    /// </summary>
    private static bool IsForegroundTerminal()
    {
        try
        {
            IntPtr fg = NativeMethods.GetForegroundWindow();
            if (fg == IntPtr.Zero)
            {
                return false;
            }

            NativeMethods.GetWindowThreadProcessId(fg, out uint pid);
            if (pid == 0)
            {
                return false;
            }

            using System.Diagnostics.Process proc = System.Diagnostics.Process.GetProcessById((int)pid);
            return TerminalProcesses.Contains(proc.ProcessName);
        }
        catch
        {
            // 进程刚好退出、权限不足等，都按"不是终端"处理
            return false;
        }
    }

    /// <summary>
    /// 异步捕获当前选中的文字。返回 null 表示没抓到。
    ///
    /// 内部起一个 STA 后台线程跑同步的 <see cref="CaptureOnWorker"/>，
    /// 调用方（UI 线程）在 await 期间完全空闲 —— 修 2026-11-01 审查 S1：
    /// 原实现直接在 UI 线程上 Thread.Sleep 轮询，最坏阻塞 1.6 秒。
    /// </summary>
    public static Task<string?> CaptureAsync()
    {
        var tcs = new TaskCompletionSource<string?>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        // 必须 STA：System.Windows.Clipboard 的成员内部依赖 OLE，
        // 在 MTA 线程上调用会抛 ThreadStateException。
        var thread = new Thread(() =>
        {
            try
            {
                tcs.TrySetResult(CaptureOnWorker());
            }
            catch (Exception ex)
            {
                // 后台线程上的异常不会自己冒到调用方，必须显式转交
                tcs.TrySetException(ex);
            }
        })
        {
            IsBackground = true,
            Name = "QuickDrawer.SelectionCapture"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        return tcs.Task;
    }

    /// <summary>
    /// 同步捕获。**只能在 STA 线程上调用**（由 <see cref="CaptureAsync"/> 负责起线程）。
    /// 内部会 Thread.Sleep 轮询，最长约 1.6 秒。
    /// </summary>
    private static string? CaptureOnWorker()
    {
        // 2026-11-01 审查 S2：终端里 Ctrl+C 是 SIGINT，会打断用户正在跑的命令。
        // 必须在碰剪贴板之前就退出，连快照都不要做。
        if (IsForegroundTerminal())
        {
            DiagLog.Write("selection", "skip: foreground is a terminal");
            return null;
        }

        string? previousText = ReadText();
        ClipboardSnapshot? saved = SnapshotClipboard();

        // 我们自己按 Ctrl+C 会造成两次剪贴板变更（复制、还原），都不该进历史
        ClipboardService.SuppressCapture(TimeSpan.FromMilliseconds(2500));

        // 我们这一次 Ctrl+C 真正改动剪贴板之后记下的序列号。
        // 0 表示"本次根本没动过剪贴板"，此时不需要也不应该还原。
        uint seqAfterCopy = 0;

        // 我们这一次 Ctrl+C 读到的文字（= 用户选中的那段）。
        // 声明在 try 之外，还原时要用它做"剪贴板还是不是我们那份"的内容比对。
        string? copied = null;

        // 我们发 Ctrl+C 时的前台进程。还原守卫要用它判断剪贴板所有者是不是"我们"。
        uint fgPid = 0;

        try
        {
            uint seqBefore = NativeMethods.GetClipboardSequenceNumber();
            IntPtr fg = NativeMethods.GetForegroundWindow();
            NativeMethods.GetWindowThreadProcessId(fg, out fgPid);
            var sw = System.Diagnostics.Stopwatch.StartNew();

            bool seqChanged = false;

            // 补发机制：连续选中同一段文字时，第一次 Ctrl+C 偶尔会被剪贴板占用吞掉
            //（2026-10-30 实测：第二次选区序列号 1.2 秒没动）。补发一次基本都能成功。
            for (int attempt = 0; attempt < CopyAttempts && !seqChanged; attempt++)
            {
                seqBefore = NativeMethods.GetClipboardSequenceNumber();
                NativeMethods.SendCtrlC();

                for (int i = 0; i < PollCount; i++)
                {
                    Thread.Sleep(PollDelayMs);

                    // 序列号变了才算真的复制成功：否则读到的可能还是上一次的内容
                    if (NativeMethods.GetClipboardSequenceNumber() == seqBefore)
                    {
                        continue;
                    }

                    seqChanged = true;
                    seqAfterCopy = NativeMethods.GetClipboardSequenceNumber();
                    copied = ReadText();
                    break;
                }
            }

            // 序列号没赶上但文字已经换了，也算拿到（个别程序复制很快）
            copied ??= ReadText();

            // 诊断：为什么这次没抓到（前台窗口、序列号有没有动、内容长度）
            DiagLog.Write("selection",
                $"capture diag: seq {seqBefore}->{NativeMethods.GetClipboardSequenceNumber()} fg=0x{fg.ToInt64():X} fgPid={fgPid} prev={(previousText?.Length ?? -1)} copied={(copied?.Length ?? -1)} {sw.ElapsedMilliseconds}ms");

            if (string.IsNullOrWhiteSpace(copied))
            {
                return null;
            }

            if (!seqChanged && previousText is not null && copied == previousText)
            {
                // 序列号根本没动而文字又和原来一样：才是真的"没选到"。
                // 反之（序列号变过）内容恰好等于剪贴板旧值是正常场景——
                // 用户可能刚手动复制过同一段话又选中它，必须放行
                //（2026-10-30 反馈"不是每次都弹出"的第二个根因）。
                return null;
            }

            return copied!.Trim();
        }
        finally
        {
            RestoreClipboard(saved, previousText, seqAfterCopy, copied, fgPid);
        }
    }

    private static string? ReadText()
    {
        try
        {
            return System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : null;
        }
        catch
        {
            // 剪贴板被别的进程占着很常见
            return null;
        }
    }

    /// <summary>
    /// 剪贴板的**自包含**副本。
    ///
    /// ⚠️ 只存纯值，**绝不**保存 <see cref="IDataObject"/> 代理。
    /// <c>Clipboard.GetDataObject()</c> 返回的常常是指向源程序的 COM 代理，
    /// 把它交回 <c>OleSetClipboard</c> 会触发跨进程重入（2026-11-02 实测让
    /// Word 在 combase.dll 里 c0000005 反复崩溃）。
    /// </summary>
    private sealed class ClipboardSnapshot
    {
        public string? Text { get; init; }

        public System.Windows.Media.Imaging.BitmapSource? Image { get; init; }

        public string[]? Files { get; init; }

        /// <summary>
        /// "HTML Format" 的**原始字节**（含 Version/StartHTML/EndHTML 头部）。
        /// 必须按字节存：头部里的偏移是从字符串开头算起的 UTF-8 字节数，
        /// 任何一次有损的字符串往返都会让偏移失效，粘回 Word/Excel 就只剩纯文本。
        /// </summary>
        public byte[]? Html { get; init; }

        /// <summary>"Rich Text Format" 的原始字节。</summary>
        public byte[]? Rtf { get; init; }

        public bool IsEmpty => Text is null && Image is null
            && (Files is null || Files.Length == 0)
            && Html is null && Rtf is null;
    }

    private static ClipboardSnapshot? SnapshotClipboard()
    {
        string? text = null;
        System.Windows.Media.Imaging.BitmapSource? image = null;
        string[]? files = null;

        try
        {
            if (System.Windows.Clipboard.ContainsText())
            {
                text = System.Windows.Clipboard.GetText();
            }
        }
        catch
        {
            // 剪贴板被占着很常见，能拿到多少算多少
        }

        try
        {
            if (System.Windows.Clipboard.ContainsImage())
            {
                // 必须 Freeze：位图要跨线程带回 UI 线程再用，未冻结的 BitmapSource
                // 属于创建它的那个线程，跨线程访问会抛 InvalidOperationException。
                var img = System.Windows.Clipboard.GetImage();
                if (img is not null)
                {
                    if (img.CanFreeze)
                    {
                        img.Freeze();
                    }

                    image = img;
                }
            }
        }
        catch
        {
        }

        try
        {
            if (System.Windows.Clipboard.ContainsFileDropList())
            {
                var list = System.Windows.Clipboard.GetFileDropList();
                if (list is not null && list.Count > 0)
                {
                    files = new string[list.Count];
                    list.CopyTo(files, 0);
                }
            }
        }
        catch
        {
        }

        // 富格式只在这里补上：Text/Image/Files 已经在上面按纯值取好了。
        // 2026-11-02 实测：还原时不带这两个格式，先复制 Word 表格再做一次划词取词，
        // 表格结构就没了 —— 用户会发现"刚复制的表格粘出来变成纯文本"。
        byte[]? html = ReadRawFormat(NativeMethods.HtmlFormat);
        byte[]? rtf = ReadRawFormat(NativeMethods.RtfFormat);

        var snap = new ClipboardSnapshot
        {
            Text = text,
            Image = image,
            Files = files,
            Html = html,
            Rtf = rtf
        };
        return snap.IsEmpty ? null : snap;
    }

    private const string HtmlFormatName = "HTML Format";

    private const string RtfFormatName = "Rich Text Format";

    /// <summary>单个富格式快照的上限，防止剪贴板里塞了几百 MB 的 HTML 把内存拖爆。</summary>
    private const int MaxFormatSnapshotBytes = 8 * 1024 * 1024;

    /// <summary>
    /// 按原始字节读一个自定义剪贴板格式。拿不到（剪贴板被占、格式不存在）返回 null。
    ///
    /// 走 Win32 而不是 <c>Clipboard.GetData(fmt)</c>：后者会把 "HTML Format" 解码成
    /// <see cref="string"/>，再编码回去时字节数可能变，头部偏移随之失效。
    /// </summary>
    private static byte[]? ReadRawFormat(uint format)
    {
        if (format == 0)
        {
            return null;
        }

        try
        {
            if (!NativeMethods.OpenClipboard(IntPtr.Zero))
            {
                return null;
            }

            try
            {
                IntPtr h = NativeMethods.GetClipboardData(format);
                if (h == IntPtr.Zero)
                {
                    return null;
                }

                ulong size = (ulong)NativeMethods.GlobalSize(h);
                if (size == 0 || size > MaxFormatSnapshotBytes)
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
                    byte[] buf = new byte[(int)size];
                    System.Runtime.InteropServices.Marshal.Copy(p, buf, 0, buf.Length);
                    return buf;
                }
                finally
                {
                    NativeMethods.GlobalUnlock(h);
                }
            }
            finally
            {
                NativeMethods.CloseClipboard();
            }
        }
        catch
        {
            return null;
        }
    }

    private static void RestoreClipboard(ClipboardSnapshot? saved, string? previousText, uint seqAfterCopy, string? copiedText, uint fgPid)
    {
        try
        {
            // 2026-11-05（第二次）：**还原之前先确认剪贴板还是我们按 Ctrl+C 之后的那个状态**。
            //
            // 原实现无条件写回 saved，只要抓取耗时超过一两秒，用户在等待期间自己
            // 复制的东西就会被我们用"拖拽之前的旧内容"覆盖掉 —— 而且覆盖发生的
            // 时候我们还开着抑制窗口，被覆盖的内容既不在剪贴板里、也没进历史，
            // 用户看到的现象就是"复制了能粘贴，但剪贴板里没有"。
            // 实测（probe/_clip_clobber2.ps1）：拖拽期间写入 QDMARK-…，4 秒后读回
            // 仍是拖拽前的旧文本，RESULT=CLOBBERED。
            //
            // 判定方法：剪贴板序列号只要在 Ctrl+C 之后又被别人推进过，就说明
            // 现在剪贴板里装的是**别人的新内容**，我们无权改动它，直接放弃还原。
            // 2026-11-05（第三次）：序列号守卫有固有盲区。
            //
            // seqAfterCopy 是在轮询里"发现序列号变了"那一刻采的样本。如果用户在
            // 我们按 Ctrl+C 之后、轮询发现之前就自己复制了新内容，我们采到的样本
            // 已经是**用户那次写入之后**的序列号，与当前值相等，守卫判不出来，
            // 照样把用户的剪贴板覆盖掉。
            //
            // 所以真正可靠的是**内容比对**：我们 Ctrl+C 之后剪贴板里的文本必然是
            // copied（未 Trim 的原文）。还原前再读一次，只要不等于 copied，就说明
            // 这期间有别人写过，放弃还原 —— 把内容留给用户，宁可我们少还原一次。
            //
            // 放弃还原的后果只是剪贴板里留着用户刚选中的那段文字（那本来也是
            // Ctrl+C 的正常结果），比覆盖掉用户刚复制的东西轻得多。
            // 2026-11-05（第四次）：内容比对也有盲区 —— 如果用户那次写入发生在
            // 我们 ReadText() 之前，我们读到的 copied 就是**用户的内容**，与当前
            // 剪贴板内容相等，比对照样放行。
            //
            // 真正能分辨"谁写的"的是剪贴板所有者：我们自己按 Ctrl+C 时，剪贴板的
            // 所有者就是收到按键的那个前台进程；用户从别的窗口复制时，所有者是
            // 用户那个进程。实测（probe/_clip_owner_probe.ps1）：
            //   程序 Ctrl+C 后        → ownerHwnd=0x1074E ownerPid=18108 (= fgPid)
            //   PowerShell 写剪贴板后 → ownerHwnd=0x3E08DA ownerPid=12252 (= 写入方)
            uint ownerPid = 0;
            IntPtr ownerHwnd = NativeMethods.GetClipboardOwner();
            int ownerError = ownerHwnd == IntPtr.Zero ? System.Runtime.InteropServices.Marshal.GetLastWin32Error() : 0;
            if (ownerHwnd != IntPtr.Zero)
            {
                NativeMethods.GetWindowThreadProcessId(ownerHwnd, out ownerPid);
            }

            // 查不到所有者时**放弃还原**，不要当成"没有所有者、可以放心写"。
            // 实测（probe/_clip_owner_hit.ps1）：别的进程正高频写剪贴板时，
            // GetClipboardOwner 常在我们这一瞬间返回 NULL（对方正开着剪贴板），
            // 若此时放行，守卫就形同虚设 —— 宁可少还原一次，也不能覆盖用户内容。
            if (ownerHwnd == IntPtr.Zero || (ownerPid != 0 && ownerPid != fgPid))
            {
                DiagLog.Write("selection",
                    $"restore skipped: clipboard owner not ours (hwnd={ownerHwnd} ownerPid={ownerPid} fgPid={fgPid} err={ownerError})");
                return;
            }

            string? currentText = ReadText();
            bool unchanged = copiedText is null
                ? currentText is null
                : string.Equals(currentText, copiedText, StringComparison.Ordinal);

            if (!unchanged)
            {
                DiagLog.Write("selection",
                    $"restore skipped: clipboard content changed by someone else (ours={copiedText?.Length ?? -1} now={currentText?.Length ?? -1})");
                return;
            }

            if (seqAfterCopy == 0)
            {
                // 本次连 Ctrl+C 都没让序列号动过，剪贴板里始终是原来的东西，无需还原
                return;
            }

            uint current = NativeMethods.GetClipboardSequenceNumber();
            if (current != seqAfterCopy)
            {
                DiagLog.Write("selection",
                    $"restore skipped: clipboard changed by someone else (seq {seqAfterCopy}->{current})");
                return;
            }

            // 2026-11-05：还原本身也是一次剪贴板写入，同样会触发 WM_CLIPBOARDUPDATE。
            // 光靠 CaptureOnWorker 开头那个 2.5 秒窗口不够 —— 实测有的抓取要 1.9 秒，
            // 叠上轮询与还原就顶到窗口边缘，窗口一过期，我们写回的旧内容就会被
            // 当成"用户刚复制的"再记一条（生产日志里确实有窗口之外的通知）。
            // 在真正写之前重新武装一个短窗口，精确覆盖这一次还原。
            ClipboardService.SuppressCapture(TimeSpan.FromMilliseconds(800));

            if (saved is not null)
            {
                // 用新构造的 DataObject 装纯值 —— 不把外部代理交回 OLE。
                var data = new System.Windows.DataObject();
                bool any = false;

                if (saved.Text is not null)
                {
                    data.SetText(saved.Text);
                    any = true;
                }

                if (saved.Image is not null)
                {
                    data.SetImage(saved.Image);
                    any = true;
                }

                if (saved.Files is not null && saved.Files.Length > 0)
                {
                    var col = new System.Collections.Specialized.StringCollection();
                    col.AddRange(saved.Files);
                    data.SetFileDropList(col);
                    any = true;
                }

                // 富格式用 MemoryStream 交回去：WPF 会把这串字节原样 SetClipboardData，
                // 偏移保持有效，Word/Excel 粘回去还是表格。
                if (saved.Html is not null && saved.Html.Length > 0)
                {
                    data.SetData(HtmlFormatName, new System.IO.MemoryStream(saved.Html));
                    any = true;
                }

                if (saved.Rtf is not null && saved.Rtf.Length > 0)
                {
                    data.SetData(RtfFormatName, new System.IO.MemoryStream(saved.Rtf));
                    any = true;
                }

                if (any)
                {
                    // copy:true 把数据真正拷进剪贴板，避免源程序关闭后变成空壳。
                    // 这里的源对象是**我们自己的**托管 DataObject，不会再重入别人。
                    System.Windows.Clipboard.SetDataObject(data, true);
                }

                return;
            }

            // 2026-11-01 审查 S3：快照拿不到（saved == null，剪贴板正被别的进程占着，
            // 很常见）时，**绝对不能**去 Clear —— 那会把用户剪贴板里原有的内容直接抹掉，
            // 用户丢了东西还不知道是谁干的。宁可留着我们刚 Ctrl+C 出来的那段选中文字，
            // 也不清空。只有确实读到过旧文本（previousText 非 null）时才写回。
            if (previousText is not null)
            {
                System.Windows.Clipboard.SetText(previousText);
            }
        }
        catch
        {
            // 还原失败不算致命：最坏情况是剪贴板里留着用户刚选的那段文字
        }
    }
}
