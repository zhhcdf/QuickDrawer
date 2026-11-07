using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace QuickDrawer;

/// <summary>
/// 剪贴板历史的持久化。
///
/// 决策 #7：**内容用 DPAPI 加密**（ProtectedData，CurrentUser 作用域）。
/// 效果：文件被拷到别的机器/别的用户下也解不开，用户无感。
/// 这是开源项目最重要的信任信号之一（方案 §10.2）。
///
/// 2026-11-01（发布前审查 B7）：原实现只加密 Text，Preview（前 200 字符）、
/// Files（完整路径列表）、SourceApp（进程名，会暴露用户在用什么密码管理器）
/// 全部明文落盘 —— 实测 clipboard.json 直接可读。现在改为每条记录把
/// {Text, Preview, Files, SourceApp} 序列化成一个载荷整体加密，
/// 仍然每条只调一次 Protect，开销不变。
///
/// 保持明文的字段：Id / Kind / Pinned / CreatedAt / SizeBytes / BlobPath。
/// 它们不含用户内容，且淘汰逻辑要按 SizeBytes 算字节账，不能要求先解密。
///
/// 存储位置：%APPDATA%\\QuickDrawer\\clipboard.json
/// </summary>
public static class ClipboardStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    public static string FilePath => Path.Combine(ConfigStore.BaseDir, "clipboard.json");

    /// <summary>当前存储格式版本。2 = 敏感字段整体加密。</summary>
    private const int CurrentVersion = 2;

    /// <summary>
    /// 每条记录里需要加密的敏感字段。
    /// 单独定义成类型是为了序列化时字段名稳定，将来加字段也不会破坏旧文件。
    /// </summary>
    private sealed class SecretPayload
    {
        public string? Text { get; set; }
        public string Preview { get; set; } = "";
        public List<string> Files { get; set; } = new();
        public string SourceApp { get; set; } = "";

        /// <summary>HTML 条目的 &lt;style&gt; 块。旧文件没有这个字段，反序列化后为 null。</summary>
        public string? HtmlStyle { get; set; }
    }

    /// <summary>磁盘上的记录格式（内容字段是密文）。</summary>
    private sealed class StoredEntry
    {
        public string Id { get; set; } = "";
        public string Kind { get; set; } = "Text";

        /// <summary>v2：敏感字段的整体密文（Base64）。</summary>
        public string? EncryptedPayload { get; set; }

        /// <summary>v1 遗留字段：仅用于读旧文件，写入时恒为 null。</summary>
        public string? EncryptedText { get; set; }

        /// <summary>v1 遗留字段：旧文件里的明文预览。v2 写入时恒为空串。</summary>
        public string Preview { get; set; } = "";

        /// <summary>v1 遗留字段：旧文件里的明文文件列表。</summary>
        public List<string> Files { get; set; } = new();

        /// <summary>v1 遗留字段：旧文件里的明文来源进程名。</summary>
        public string SourceApp { get; set; } = "";

        public string? BlobPath { get; set; }
        public bool Pinned { get; set; }
        public string CreatedAt { get; set; } = "";
        public long SizeBytes { get; set; }
    }

    private sealed class StoredFile
    {
        public int Version { get; set; } = CurrentVersion;
        public List<StoredEntry> Entries { get; set; } = new();
    }

    /// <summary>
    /// 一条记录的不可变快照。
    /// 存在的理由（S8）：保存要对每条跑一次 DPAPI 再整表重写文件，几百条时是肉眼可见的卡顿。
    /// 把"读活对象"（必须 UI 线程，微秒级）和"加密 + 写盘"（可以在任何线程，几十毫秒）分开，
    /// 前者留在 UI 线程，后者丢给后台。
    /// </summary>
    public sealed class ClipSnapshot
    {
        public ClipSnapshot(string id, string kind, string? text, string preview,
            List<string> files, string sourceApp, string? blobPath, bool pinned,
            string createdAt, long sizeBytes, string? htmlStyle = null)
        {
            Id = id;
            Kind = kind;
            Text = text;
            Preview = preview;
            Files = files;
            SourceApp = sourceApp;
            BlobPath = blobPath;
            Pinned = pinned;
            CreatedAt = createdAt;
            SizeBytes = sizeBytes;
            HtmlStyle = htmlStyle;
        }

        public string Id { get; }
        public string Kind { get; }
        public string? Text { get; }
        public string Preview { get; }
        public List<string> Files { get; }
        public string SourceApp { get; }
        public string? BlobPath { get; }
        public bool Pinned { get; }
        public string CreatedAt { get; }
        public long SizeBytes { get; }
        public string? HtmlStyle { get; }
    }

    /// <summary>
    /// 把活对象拍成快照。**必须在 UI 线程调用**（读的是可变的 ClipEntry）。
    /// 只做字段拷贝，不含 DPAPI 与磁盘 IO。
    /// </summary>
    public static List<ClipSnapshot> SnapshotAll(IEnumerable<ClipEntry> entries)
    {
        var snaps = new List<ClipSnapshot>();

        foreach (ClipEntry e in entries)
        {
            snaps.Add(new ClipSnapshot(
                e.Id,
                e.Kind.ToString(),
                e.Text,
                e.Preview ?? "",
                e.Files is null ? new List<string>() : new List<string>(e.Files),
                e.SourceApp ?? "",
                e.BlobPath,
                e.Pinned,
                e.CreatedAt.ToString("o"),
                e.SizeBytes,
                e.HtmlStyle));
        }

        return snaps;
    }

    /// <summary>加密并保存。UI 线程用这个（内部先拍快照）。返回 false 表示写盘失败。</summary>
    public static bool Save(IEnumerable<ClipEntry> entries) => SaveSnapshot(SnapshotAll(entries));

    /// <summary>
    /// 加密并保存（快照版）。DPAPI 与磁盘 IO 都在这里，**可以任意线程调用**。
    /// 返回 false 表示写盘失败——调用方必须让用户知道，否则用户以为存下来了。
    /// </summary>
    public static bool SaveSnapshot(IReadOnlyList<ClipSnapshot> snaps)
    {
        try
        {
            var stored = new StoredFile();

            foreach (ClipSnapshot e in snaps)
            {
                StoredEntry s = new()
                {
                    Id = e.Id,
                    Kind = e.Kind,
                    BlobPath = e.BlobPath,
                    Pinned = e.Pinned,
                    CreatedAt = e.CreatedAt,
                    SizeBytes = e.SizeBytes
                };

                // 一条记录一次 DPAPI 调用：把全部敏感字段打成载荷整体加密。
                var payload = new SecretPayload
                {
                    Text = e.Text,
                    Preview = e.Preview,
                    Files = e.Files,
                    SourceApp = e.SourceApp,
                    HtmlStyle = e.HtmlStyle
                };
                s.EncryptedPayload = Protect(JsonSerializer.Serialize(payload, JsonOptions));

                stored.Entries.Add(s);
            }

            Directory.CreateDirectory(ConfigStore.BaseDir);
            string tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(stored, JsonOptions), Encoding.UTF8);
            Compat.MoveOverwrite(tmp, FilePath);

            DiagLog.Write("clipboard", $"saved {stored.Entries.Count} entries (encrypted)");
            return true;
        }
        catch (Exception ex)
        {
            DiagLog.Write("clipboard", $"save failed: {ex.Message}");
            return false;
        }
    }

    /// <summary>读取并解密。</summary>
    public static List<ClipEntry> Load()
    {
        var result = new List<ClipEntry>();

        try
        {
            if (!File.Exists(FilePath))
            {
                return result;
            }

            StoredFile? stored = JsonSerializer.Deserialize<StoredFile>(
                File.ReadAllText(FilePath, Encoding.UTF8), JsonOptions);

            if (stored is null)
            {
                return result;
            }

            foreach (StoredEntry s in stored.Entries)
            {
                ClipEntry e = new()
                {
                    Id = s.Id,
                    Kind = Enum.TryParse<ClipKind>(s.Kind, out ClipKind k) ? k : ClipKind.Unknown,
                    BlobPath = s.BlobPath,
                    Pinned = s.Pinned,
                    SizeBytes = s.SizeBytes
                };

                if (DateTime.TryParse(s.CreatedAt, out DateTime created))
                {
                    e.CreatedAt = created;
                }

                bool payloadOk = false;
                if (s.EncryptedPayload is not null)
                {
                    // 解密失败（换了用户/系统）时该条内容留空，不影响其余条目。
                    string? json = Unprotect(s.EncryptedPayload);
                    if (json is not null)
                    {
                        try
                        {
                            SecretPayload? payload = JsonSerializer.Deserialize<SecretPayload>(json, JsonOptions);
                            if (payload is not null)
                            {
                                e.Text = payload.Text;
                                e.Preview = payload.Preview ?? "";
                                e.Files = payload.Files ?? new List<string>();
                                e.SourceApp = payload.SourceApp ?? "";
                                e.HtmlStyle = payload.HtmlStyle;
                                payloadOk = true;
                            }
                        }
                        catch (JsonException ex)
                        {
                            DiagLog.Write("clipboard", $"payload decode failed: {ex.Message}");
                        }
                    }
                }

                // v1 兼容：旧文件没有载荷，敏感字段在明文字段里。
                if (!payloadOk)
                {
                    e.Preview = s.Preview;
                    e.Files = s.Files ?? new List<string>();
                    e.SourceApp = s.SourceApp;

                    if (s.EncryptedText is not null)
                    {
                        e.Text = Unprotect(s.EncryptedText);
                    }
                }

                result.Add(e);
            }

            DiagLog.Write("clipboard", $"loaded {result.Count} entries");
        }
        catch (Exception ex)
        {
            DiagLog.Write("clipboard", $"load failed: {ex.Message}");
        }

        return result;
    }

    /// <summary>用 DPAPI 加密（CurrentUser 作用域）。</summary>
    public static string Protect(string plain)
    {
        byte[] data = Encoding.UTF8.GetBytes(plain);
        byte[] cipher = ProtectedData.Protect(
            data, optionalEntropy: null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(cipher);
    }

    /// <summary>DPAPI 解密。失败返回 null。</summary>
    public static string? Unprotect(string base64)
    {
        try
        {
            byte[] cipher = Convert.FromBase64String(base64);
            byte[] plain = ProtectedData.Unprotect(
                cipher, optionalEntropy: null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>清空历史（含 blob 文件）。</summary>
    public static void Clear()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                File.Delete(FilePath);
            }

            string blobDir = Path.Combine(ConfigStore.BaseDir, "blobs");
            if (Directory.Exists(blobDir))
            {
                Directory.Delete(blobDir, recursive: true);
            }

            DiagLog.Write("clipboard", "history cleared");
        }
        catch (Exception ex)
        {
            DiagLog.Write("clipboard", $"clear failed: {ex.Message}");
        }
    }
}
