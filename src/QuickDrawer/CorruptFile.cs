using System.IO;

namespace QuickDrawer;

/// <summary>
/// 损坏文件的保护性处理（发布前审查 B2）。
///
/// 背景：原来三个 Store（shortcuts / notes / config）在反序列化失败时都
/// "catch → 用默认值"，然后**继续按默认值落盘**。结果是用户手改坏一个字符、
/// 或磁盘写一半断电，整个 shortcuts.json 就被种子数据覆盖，数据永久丢失。
///
/// 规则：
///   文件不存在      → 可以用默认值，并落盘（首次运行，正常）。
///   文件存在但读/解析失败 → **绝不覆盖**。把原文件改名成
///                          `xxx.json.corrupt-20261101-165300` 留档，
///                          本次运行用默认值在内存里跑，下次启动用户还能
///                          从留档里手工恢复。
///
/// 留档只保留最近 <see cref="MaxArchives"/> 份，避免反复损坏把目录塞满。
/// </summary>
public static class CorruptFile
{
    private const int MaxArchives = 3;

    private static readonly object Gate = new();
    private static readonly List<string> Notices = new();

    /// <summary>
    /// 取出并清空"本次启动发生了数据损坏"的通知列表（元素是留档文件的完整路径）。
    /// 启动流程拿它决定要不要提示用户。
    /// </summary>
    public static List<string> TakeNotices()
    {
        lock (Gate)
        {
            var copy = new List<string>(Notices);
            Notices.Clear();
            return copy;
        }
    }

    /// <summary>
    /// 把无法解析的文件改名留档。返回留档路径；失败返回 null（此时调用方仍不应覆盖原文件）。
    /// </summary>
    public static string? Archive(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;

            string dir = Path.GetDirectoryName(path) ?? ".";
            string name = Path.GetFileName(path);
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            string archive = Path.Combine(dir, $"{name}.corrupt-{stamp}");

            // 同一秒内连续损坏时避免撞名
            int n = 1;
            while (File.Exists(archive))
            {
                archive = Path.Combine(dir, $"{name}.corrupt-{stamp}-{n++}");
            }

            File.Move(path, archive);
            PruneOld(dir, name);
            DiagLog.Write("corrupt", $"archived {name} -> {Path.GetFileName(archive)}");

            lock (Gate)
            {
                Notices.Add(archive);
            }

            return archive;
        }
        catch (Exception ex)
        {
            DiagLog.Write("corrupt", $"archive failed for {Path.GetFileName(path)}: {ex.Message}");
            return null;
        }
    }

    private static void PruneOld(string dir, string baseName)
    {
        try
        {
            var old = Directory.GetFiles(dir, baseName + ".corrupt-*")
                               .OrderByDescending(f => f)
                               .Skip(MaxArchives)
                               .ToList();
            foreach (string f in old)
            {
                try { File.Delete(f); } catch { /* 留档删不掉不影响主流程 */ }
            }
        }
        catch
        {
            // 清理失败忽略
        }
    }
}
