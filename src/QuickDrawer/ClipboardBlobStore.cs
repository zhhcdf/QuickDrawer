using System.IO;

namespace QuickDrawer;

/// <summary>
/// 剪贴板二进制附件存储（目前只存图片 DIB）。
/// 位置：%APPDATA%\QuickDrawer\blobs\
/// </summary>
public static class ClipboardBlobStore
{
    private static string BlobDir => Path.Combine(ConfigStore.BaseDir, "blobs");

    /// <summary>保存 DIB 字节，返回相对路径（文件名）。</summary>
    public static string? SaveDib(byte[] dib)
    {
        try
        {
            Directory.CreateDirectory(BlobDir);
            string name = $"{Guid.NewGuid():N}.dib";
            File.WriteAllBytes(Path.Combine(BlobDir, name), dib);
            return name;
        }
        catch (Exception ex)
        {
            DiagLog.Write("clipboard", $"save blob failed: {ex.Message}");
            return null;
        }
    }

    /// <summary>按相对路径读取 DIB 字节。</summary>
    public static byte[]? Load(string? relative)
    {
        if (string.IsNullOrWhiteSpace(relative))
        {
            return null;
        }

        try
        {
            string full = Path.Combine(BlobDir, relative);
            return File.Exists(full) ? File.ReadAllBytes(full) : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>删除 blob 文件（条目被淘汰时调用）。</summary>
    public static void Delete(string? relative)
    {
        if (string.IsNullOrWhiteSpace(relative))
        {
            return;
        }

        try
        {
            string full = Path.Combine(BlobDir, relative);
            if (File.Exists(full))
            {
                File.Delete(full);
            }
        }
        catch
        {
            // 删不掉不影响主流程
        }
    }
}
