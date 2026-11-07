using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace QuickDrawer;

/// <summary>
/// 轻量诊断日志。写到 %APPDATA%\QuickDrawer\logs\diag.log。
///
/// 用途：抽屉窗口是 NOACTIVATE + 可透明的，MainWindowTitle / MainWindowHandle
/// 在外部探测时常常读不到值（用户实测遇到过），靠外部观察很难判断窗口到底
/// 显示没有。应用自己把状态写进日志，是唯一可靠的取证手段。
///
/// 隐私约束（2026-11-01 发布前审查 B1）：
/// 本文件是开源项目里唯一会被用户主动贴到 GitHub issue 的文件，
/// 所以三条硬规则：
///   1. 绝不记录用户内容——剪贴板正文、便签文本、选中文本、页面 URL 一律不写。
///      需要记录时用 <see cref="Describe"/> 只写长度/类型/数量。
///   2. 绝不记录完整路径——<see cref="Redact"/> 会把 C:\Users\&lt;名&gt; 换成 %USER%，
///      且调用点应当优先只记文件名。
///   3. 有上限——超过 2 MB 自动滚动为 diag.log.1（只保留一份），
///      用户可用 <see cref="Enabled"/> 或 config 的 diagLogEnabled 关掉。
///
/// 脱敏在 <see cref="Write"/> 内部无条件执行，不受任何开关影响。
/// </summary>
public static class DiagLog
{
    /// <summary>单个日志文件的大小上限，超过即滚动。</summary>
    private const long MaxBytes = 2L * 1024 * 1024;

    private static readonly object Gate = new();
    private static readonly string LogPath;

    /// <summary>
    /// 是否写日志。默认开启——托盘程序没有日志就无法排查；
    /// 隐私由脱敏与"不记录内容"保证，不靠关闭日志。
    /// 用户可在 config.json 里设 diagLogEnabled=false 关闭。
    /// </summary>
    public static bool Enabled { get; set; } = true;

    /// <summary>
    /// 把 Windows 用户目录里的用户名替换成 %USER%。
    /// 例：C:\Users\%USER%\AppData\Roaming\x.lnk → C:\Users\%USER%\AppData\Roaming\x.lnk
    /// </summary>
    private static readonly Regex UserProfileRx =
        new(@"(?<pre>[A-Za-z]:\\Users\\)[^\\\r\n""']+", RegexOptions.Compiled);

    static DiagLog()
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "QuickDrawer", "logs");
            Directory.CreateDirectory(dir);
            LogPath = Path.Combine(dir, "diag.log");
        }
        catch
        {
            LogPath = Path.Combine(Path.GetTempPath(), "quickdrawer-diag.log");
        }
    }

    /// <summary>
    /// 描述一段用户内容而不泄露它。日志里凡是想记录"某段文本"的地方都必须走这里。
    /// 只输出长度，不输出任何字符。
    /// </summary>
    public static string Describe(string? text)
        => text is null ? "null" : $"{text.Length} chars";

    /// <summary>脱敏：把路径里的用户名换成 %USER%。对非路径文本无副作用。</summary>
    public static string Redact(string? detail)
    {
        if (string.IsNullOrEmpty(detail)) return detail ?? "";
        try
        {
            return UserProfileRx.Replace(detail, "${pre}%USER%");
        }
        catch
        {
            return detail!;
        }
    }

    public static void Write(string stage, string detail)
    {
        if (!Enabled) return;

        try
        {
            string line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{stage}] {Redact(detail)}";
            lock (Gate)
            {
                RotateIfNeeded();
                File.AppendAllText(LogPath, line + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch
        {
            // 日志失败绝不能影响主流程
        }
    }

    /// <summary>超过上限时把当前文件滚成 diag.log.1（覆盖旧的 .1）。</summary>
    private static void RotateIfNeeded()
    {
        try
        {
            var fi = new FileInfo(LogPath);
            if (!fi.Exists || fi.Length < MaxBytes) return;

            string archive = LogPath + ".1";
            if (File.Exists(archive)) File.Delete(archive);
            File.Move(LogPath, archive);
        }
        catch
        {
            // 滚动失败就继续追加，不影响主流程
        }
    }

    public static string Path_() => LogPath;
}
