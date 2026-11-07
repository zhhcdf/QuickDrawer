using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

// 验证 diagLogEnabled 真的接到 DiagLog.Enabled 上（不只是编译通过）。
// 这是一次纯反射级验证：不启动 WPF 窗口，只调 ConfigStore 反序列化 + 手动赋值，
// 再确认 DiagLog.Write 在 Enabled=false 时确实不落盘。

internal static class Program
{
    private static int Main()
    {
        // ---- 1. 反序列化能否识别 diagLogEnabled ----
        string json = "{\"diagLogEnabled\": false}";
        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        QuickDrawer.AppConfig cfg = JsonSerializer.Deserialize<QuickDrawer.AppConfig>(json, opts)!;

        Console.WriteLine("deserialize diagLogEnabled=false -> DiagLogEnabled = " + cfg.DiagLogEnabled);
        bool ok1 = cfg.DiagLogEnabled == false;

        // 缺省时必须是 true（老 config.json 没有这个字段）
        QuickDrawer.AppConfig cfg2 = JsonSerializer.Deserialize<QuickDrawer.AppConfig>("{}", opts)!;
        Console.WriteLine("deserialize {} -> DiagLogEnabled = " + cfg2.DiagLogEnabled);
        bool ok2 = cfg2.DiagLogEnabled == true;

        // ---- 2. 运行时开关真的生效 ----
        string logPath = QuickDrawer.DiagLog.Path_();
        Console.WriteLine("log path = " + logPath);

        long before = File.Exists(logPath) ? new FileInfo(logPath).Length : 0;

        QuickDrawer.DiagLog.Enabled = false;
        QuickDrawer.DiagLog.Write("selftest", "SHOULD-NOT-APPEAR-A");
        long afterOff = File.Exists(logPath) ? new FileInfo(logPath).Length : 0;
        bool ok3 = before == afterOff;
        Console.WriteLine("Enabled=false: size " + before + " -> " + afterOff + "  (unchanged=" + ok3 + ")");

        QuickDrawer.DiagLog.Enabled = true;
        QuickDrawer.DiagLog.Write("selftest", "SHOULD-APPEAR-B");
        long afterOn = File.Exists(logPath) ? new FileInfo(logPath).Length : 0;
        bool ok4 = afterOn > afterOff;
        Console.WriteLine("Enabled=true : size " + afterOff + " -> " + afterOn + "  (grew=" + ok4 + ")");

        // ---- 3. Redact 兜底：用户目录必须被替换 ----
        string redacted = QuickDrawer.DiagLog.Redact(@"C:\Users\alice\AppData\Roaming\x.lnk");
        bool ok5 = redacted.Contains("%USER%") && !redacted.Contains("alice");
        Console.WriteLine("Redact -> " + redacted);

        bool pass = ok1 && ok2 && ok3 && ok4 && ok5;
        Console.WriteLine("RESULT: " + (pass ? "PASS" : "FAIL"));
        return pass ? 0 : 1;
    }
}
