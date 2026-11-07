# Fix the regression introduced by the S1 "pure value snapshot" change:
# SelectionCapture.RestoreClipboard only put back Text/Image/Files, so a Word table
# copied before a selection capture came back as plain text (HTML Format + Rich Text
# Format were dropped). The crash was caused by handing Word's COM *proxy* back to
# OleSetClipboard - not by reading the rich formats - so we can snapshot them as raw
# bytes and restore them safely.
#
# Raw bytes matter: "HTML Format" carries UTF-8 *byte* offsets from the start of the
# string, so any lossy string round-trip invalidates them and Word silently degrades to
# plain-text paste.

import io, sys

PATH = r"D:\Documents\DeepSeek\快捷桌面项目\src\QuickDrawer\Selection\SelectionCapture.cs"

src = io.open(PATH, encoding="utf-8").read()
orig = src

# ---- 1. extend ClipboardSnapshot with the rich formats -----------------------------
old = (
    "        public string[]? Files { get; init; }\n"
    "\n"
    "        public bool IsEmpty => Text is null && Image is null && (Files is null || Files.Length == 0);\n"
    "    }\n"
)
new = (
    "        public string[]? Files { get; init; }\n"
    "\n"
    "        /// <summary>\n"
    "        /// \"HTML Format\" 的**原始字节**（含 Version/StartHTML/EndHTML 头部）。\n"
    "        /// 必须按字节存：头部里的偏移是从字符串开头算起的 UTF-8 字节数，\n"
    "        /// 任何一次有损的字符串往返都会让偏移失效，粘回 Word/Excel 就只剩纯文本。\n"
    "        /// </summary>\n"
    "        public byte[]? Html { get; init; }\n"
    "\n"
    "        /// <summary>\"Rich Text Format\" 的原始字节。</summary>\n"
    "        public byte[]? Rtf { get; init; }\n"
    "\n"
    "        public bool IsEmpty => Text is null && Image is null\n"
    "            && (Files is null || Files.Length == 0)\n"
    "            && Html is null && Rtf is null;\n"
    "    }\n"
)
assert src.count(old) == 1, "anchor 1 count=%d" % src.count(old)
src = src.replace(old, new)

# ---- 2. capture the rich formats in SnapshotClipboard ------------------------------
old = "        var snap = new ClipboardSnapshot { Text = text, Image = image, Files = files };\n"
new = (
    "        // 富格式只在这里补上：Text/Image/Files 已经在上面按纯值取好了。\n"
    "        // 2026-11-02 实测：还原时不带这两个格式，先复制 Word 表格再做一次划词取词，\n"
    "        // 表格结构就没了 —— 用户会发现\"刚复制的表格粘出来变成纯文本\"。\n"
    "        byte[]? html = ReadRawFormat(NativeMethods.HtmlFormat);\n"
    "        byte[]? rtf = ReadRawFormat(NativeMethods.RtfFormat);\n"
    "\n"
    "        var snap = new ClipboardSnapshot\n"
    "        {\n"
    "            Text = text,\n"
    "            Image = image,\n"
    "            Files = files,\n"
    "            Html = html,\n"
    "            Rtf = rtf\n"
    "        };\n"
)
assert src.count(old) == 1, "anchor 2 count=%d" % src.count(old)
src = src.replace(old, new)

# ---- 3. add ReadRawFormat + the two format-name constants -------------------------
old = "    private static void RestoreClipboard(ClipboardSnapshot? saved, string? previousText)\n"
new = (
    "    private const string HtmlFormatName = \"HTML Format\";\n"
    "\n"
    "    private const string RtfFormatName = \"Rich Text Format\";\n"
    "\n"
    "    /// <summary>单个富格式快照的上限，防止剪贴板里塞了几百 MB 的 HTML 把内存拖爆。</summary>\n"
    "    private const int MaxFormatSnapshotBytes = 8 * 1024 * 1024;\n"
    "\n"
    "    /// <summary>\n"
    "    /// 按原始字节读一个自定义剪贴板格式。拿不到（剪贴板被占、格式不存在）返回 null。\n"
    "    ///\n"
    "    /// 走 Win32 而不是 <c>Clipboard.GetData(fmt)</c>：后者会把 \"HTML Format\" 解码成\n"
    "    /// <see cref=\"string\"/>，再编码回去时字节数可能变，头部偏移随之失效。\n"
    "    /// </summary>\n"
    "    private static byte[]? ReadRawFormat(uint format)\n"
    "    {\n"
    "        if (format == 0)\n"
    "        {\n"
    "            return null;\n"
    "        }\n"
    "\n"
    "        try\n"
    "        {\n"
    "            if (!NativeMethods.OpenClipboard(IntPtr.Zero))\n"
    "            {\n"
    "                return null;\n"
    "            }\n"
    "\n"
    "            try\n"
    "            {\n"
    "                IntPtr h = NativeMethods.GetClipboardData(format);\n"
    "                if (h == IntPtr.Zero)\n"
    "                {\n"
    "                    return null;\n"
    "                }\n"
    "\n"
    "                ulong size = (ulong)NativeMethods.GlobalSize(h);\n"
    "                if (size == 0 || size > MaxFormatSnapshotBytes)\n"
    "                {\n"
    "                    return null;\n"
    "                }\n"
    "\n"
    "                IntPtr p = NativeMethods.GlobalLock(h);\n"
    "                if (p == IntPtr.Zero)\n"
    "                {\n"
    "                    return null;\n"
    "                }\n"
    "\n"
    "                try\n"
    "                {\n"
    "                    byte[] buf = new byte[(int)size];\n"
    "                    System.Runtime.InteropServices.Marshal.Copy(p, buf, 0, buf.Length);\n"
    "                    return buf;\n"
    "                }\n"
    "                finally\n"
    "                {\n"
    "                    NativeMethods.GlobalUnlock(h);\n"
    "                }\n"
    "            }\n"
    "            finally\n"
    "            {\n"
    "                NativeMethods.CloseClipboard();\n"
    "            }\n"
    "        }\n"
    "        catch\n"
    "        {\n"
    "            return null;\n"
    "        }\n"
    "    }\n"
    "\n"
    "    private static void RestoreClipboard(ClipboardSnapshot? saved, string? previousText)\n"
)
assert src.count(old) == 1, "anchor 3 count=%d" % src.count(old)
src = src.replace(old, new)

# ---- 4. restore the rich formats --------------------------------------------------
old = (
    "                if (any)\n"
    "                {\n"
    "                    // copy:true 把数据真正拷进剪贴板，避免源程序关闭后变成空壳。\n"
)
new = (
    "                // 富格式用 MemoryStream 交回去：WPF 会把这串字节原样 SetClipboardData，\n"
    "                // 偏移保持有效，Word/Excel 粘回去还是表格。\n"
    "                if (saved.Html is not null && saved.Html.Length > 0)\n"
    "                {\n"
    "                    data.SetData(HtmlFormatName, new System.IO.MemoryStream(saved.Html));\n"
    "                    any = true;\n"
    "                }\n"
    "\n"
    "                if (saved.Rtf is not null && saved.Rtf.Length > 0)\n"
    "                {\n"
    "                    data.SetData(RtfFormatName, new System.IO.MemoryStream(saved.Rtf));\n"
    "                    any = true;\n"
    "                }\n"
    "\n"
    "                if (any)\n"
    "                {\n"
    "                    // copy:true 把数据真正拷进剪贴板，避免源程序关闭后变成空壳。\n"
)
assert src.count(old) == 1, "anchor 4 count=%d" % src.count(old)
src = src.replace(old, new)

if src == orig:
    print("NO CHANGE")
    sys.exit(1)

io.open(PATH, "w", encoding="utf-8-sig", newline="").write(src)
print("OK patched", PATH)
