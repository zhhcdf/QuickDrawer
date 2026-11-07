using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace QuickDrawer;

/// <summary>一张便签卡片。</summary>
public sealed class NoteItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    /// <summary>
    /// 卡片名称（2026-10-25 需求）：卡片工具栏最左侧的可编辑标题。
    /// 为空时显示占位提示；旧数据没有该字段时反序列化为 ""。
    /// </summary>
    public string Title { get; set; } = "";

    public string Text { get; set; } = "";

    /// <summary>颜色标签：yellow / green / blue / pink / gray。默认 yellow。</summary>
    public string Color { get; set; } = "yellow";

    /// <summary>置顶：置顶的卡片排在最前（组内仍按更新时间倒序）。</summary>
    public bool Pinned { get; set; }

    public DateTime UpdatedAt { get; set; } = DateTime.Now;
}

/// <summary>
/// 便签持久化（M4：多卡片）。存储位置 %APPDATA%\QuickDrawer\notes.json。
///
/// 旧格式（v1，单条）是 {"Text": "..."}；新格式（v2）是
/// {"version":2, "notes":[...]}。加载时自动迁移：旧文本成为第一张卡片。
/// </summary>
public static class NoteStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    /// <summary>支持的颜色标签（顺序即 UI 色板顺序）。</summary>
    public static readonly string[] Colors = { "yellow", "green", "blue", "pink", "gray" };

    public static string FilePath => Path.Combine(ConfigStore.BaseDir, "notes.json");

    /// <summary>
    /// 加载全部卡片。文件不存在返回空列表；旧格式自动迁移为一张卡片。
    /// 排序：置顶在前，组内按更新时间倒序。
    ///
    /// 数据保护（发布前审查 B2）：文件存在但两种格式都解析不出来时，
    /// 留档成 notes.json.corrupt-* 并**不写盘**，绝不用空列表覆盖用户的便签。
    /// </summary>
    public static List<NoteItem> Load()
    {
        if (!File.Exists(FilePath))
        {
            return new List<NoteItem>();
        }

        string json;
        try
        {
            json = File.ReadAllText(FilePath);
        }
        catch (Exception ex)
        {
            // 读不出来（被占用/权限）：留档也无意义，直接返回空，本次不写盘。
            DiagLog.Write("notes", $"read failed: {ex.Message}");
            return new List<NoteItem>();
        }

        // v2 新格式
        NoteFileV2? v2 = TryDeserialize<NoteFileV2>(json);
        if (v2?.Notes is not null)
        {
            return Sort(v2.Notes);
        }

        // v1 旧格式：单条文本 → 迁移为第一张卡片
        NoteFileV1? v1 = TryDeserialize<NoteFileV1>(json);
        if (v1 is not null)
        {
            var migrated = new List<NoteItem>();

            if (!string.IsNullOrWhiteSpace(v1.Text))
            {
                migrated.Add(new NoteItem { Text = v1.Text, Color = "yellow" });
            }

            // 空文本说明这根本不是 v1 格式（v2 文件被误当 v1 解析时 Text 为空），
            // 写回会主动清空用户数据，所以只在真有内容时迁移。
            if (migrated.Count > 0)
            {
                Save(migrated);
                DiagLog.Write("notes", $"migrated v1 note to v2 ({migrated.Count} cards)");
                return Sort(migrated);
            }
        }

        // 两种格式都解析不出来：留档，本次返回空列表但绝不覆盖原文件。
        DiagLog.Write("notes", "unrecognized format, leaving file untouched");
        CorruptFile.Archive(FilePath);
        return new List<NoteItem>();
    }

    /// <summary>
    /// 保存全部卡片（原子写：先写临时文件再替换）。
    /// 返回 false 表示写盘失败——调用方必须让用户知道，不能静默当成功。
    /// </summary>
    public static bool Save(List<NoteItem> notes)
    {
        try
        {
            Directory.CreateDirectory(ConfigStore.BaseDir);
            var file = new NoteFileV2 { Version = 2, Notes = notes };
            string tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(file, JsonOptions));
            Compat.MoveOverwrite(tmp, FilePath);
            return true;
        }
        catch (Exception ex)
        {
            DiagLog.Write("notes", $"save failed: {ex.Message}");
            return false;
        }
    }

    /// <summary>排序：置顶在前，组内按更新时间倒序（最近编辑的靠上）。</summary>
    public static List<NoteItem> Sort(List<NoteItem> notes)
        => notes
            .OrderByDescending(n => n.Pinned)
            .ThenByDescending(n => n.UpdatedAt)
            .ToList();

    /// <summary>颜色标签对应的卡片背景色（深色主题下的柔和色）。</summary>
    public static string ColorBrush(string color) => color switch
    {
        "green" => "#2E4A34",
        "blue" => "#2E3A52",
        "pink" => "#4A2E3A",
        "gray" => "#3A3A40",
        _ => "#4A4230"          // yellow（默认）
    };

    private static T? TryDeserialize<T>(string json) where T : class
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    private sealed class NoteFileV1
    {
        [JsonPropertyName("Text")]
        public string Text { get; set; } = "";
    }

    private sealed class NoteFileV2
    {
        [JsonPropertyName("version")]
        public int Version { get; set; } = 2;

        [JsonPropertyName("notes")]
        public List<NoteItem>? Notes { get; set; }
    }
}