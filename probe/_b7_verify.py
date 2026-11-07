# -*- coding: utf-8 -*-
"""B7 验证：直接调用编译产物里的 ClipboardStore，检查落盘格式。

为什么不用"启动程序手动复制一次"来验证：
  · 需要人工操作，不可重复；
  · 当前有个旧实例在跑（PID 25004），会抢单实例锁。

隔离手段：给子进程设 APPDATA=<临时目录>，让 ConfigStore.BaseDir 指向那里，
**完全不碰真实的 %APPDATA%\\QuickDrawer\\clipboard.json**。
（.NET 的 SpecialFolder.ApplicationData 在 Windows 上读 APPDATA 环境变量。）

断言：① 落盘 JSON 里没有明文 Preview/Text/Files/SourceApp；② 有 EncryptedPayload；
③ Version == 2；④ Load 能完整还原。
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, 'probe', '_b7test')
DLL = os.path.join(ROOT, 'src', 'QuickDrawer', 'bin', 'Release', 'net10.0-windows', 'win-x64', 'QuickDrawer.dll')

assert os.path.exists(DLL), 'missing ' + DLL

os.makedirs(PROJ, exist_ok=True)

csproj = '''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <Nullable>disable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <UseWPF>true</UseWPF>
    <AssemblyName>B7Test</AssemblyName>
    <RootNamespace>B7Test</RootNamespace>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="Program.cs" />
    <Reference Include="QuickDrawer">
      <HintPath>%s</HintPath>
    </Reference>
  </ItemGroup>
</Project>
''' % DLL

program = r'''using System;
using System.Collections.Generic;
using System.IO;
using QuickDrawer;

internal static class Program
{
    private static int Main()
    {
        string path = ClipboardStore.FilePath;
        Console.WriteLine("store path: " + path);

        var entries = new List<ClipEntry>
        {
            new()
            {
                Id = "test1",
                Kind = ClipKind.Text,
                Text = "SECRET-BODY-12345",
                Preview = "SECRET-PREVIEW-67890",
                SourceApp = "KeePass",
                SizeBytes = 42
            },
            new()
            {
                Id = "test2",
                Kind = ClipKind.Files,
                Preview = "SECRET-FILEPREVIEW",
                Files = new List<string> { @"C:\SECRET\a.txt", @"C:\SECRET\b.txt" },
                SourceApp = "explorer",
                SizeBytes = 100
            }
        };

        ClipboardStore.Save(entries);

        string raw = File.ReadAllText(path);

        Console.WriteLine("--- raw json (first 1000 chars) ---");
        Console.WriteLine(raw.Length > 1000 ? raw.Substring(0, 1000) : raw);

        bool leakPreview = raw.Contains("SECRET-PREVIEW-67890");
        bool leakBody = raw.Contains("SECRET-BODY-12345");
        bool leakFile = raw.Contains(@"C:\SECRET\a.txt");
        bool leakApp = raw.Contains("KeePass");
        bool hasPayload = raw.Contains("EncryptedPayload");
        bool version2 = raw.Contains("\"Version\": 2");

        Console.WriteLine("--- assertions ---");
        Console.WriteLine("leak Preview        : " + leakPreview);
        Console.WriteLine("leak Text           : " + leakBody);
        Console.WriteLine("leak Files          : " + leakFile);
        Console.WriteLine("leak SourceApp      : " + leakApp);
        Console.WriteLine("has EncryptedPayload: " + hasPayload);
        Console.WriteLine("Version == 2        : " + version2);

        List<ClipEntry> back = ClipboardStore.Load();
        Console.WriteLine("loaded count: " + back.Count);
        foreach (ClipEntry e in back)
        {
            Console.WriteLine("  id=" + e.Id + " kind=" + e.Kind +
                              " text=" + (e.Text ?? "<null>") +
                              " preview=" + e.Preview +
                              " files=" + string.Join(",", e.Files) +
                              " src=" + e.SourceApp);
        }

        bool roundtrip = back.Count == 2
                         && back[0].Text == "SECRET-BODY-12345"
                         && back[0].Preview == "SECRET-PREVIEW-67890"
                         && back[0].SourceApp == "KeePass"
                         && back[1].Files.Count == 2
                         && back[1].Files[0] == @"C:\SECRET\a.txt"
                         && back[1].Preview == "SECRET-FILEPREVIEW";

        Console.WriteLine("roundtrip OK: " + roundtrip);

        bool pass = !leakPreview && !leakBody && !leakFile && !leakApp
                    && hasPayload && version2 && roundtrip;
        Console.WriteLine(pass ? "RESULT: PASS" : "RESULT: FAIL");
        return pass ? 0 : 1;
    }
}
'''

with open(os.path.join(PROJ, 'B7Test.csproj'), 'w', encoding='utf-8') as f:
    f.write(csproj)
with open(os.path.join(PROJ, 'Program.cs'), 'w', encoding='utf-8') as f:
    f.write(program)

sandbox = tempfile.mkdtemp(prefix='b7appdata-')
env = dict(os.environ)
env['APPDATA'] = sandbox

try:
    r = subprocess.run(['dotnet', 'run', '--project', PROJ, '-c', 'Release', '-v', 'q', '--nologo'],
                       cwd=ROOT, capture_output=True, text=True, encoding='utf-8',
                       errors='replace', env=env)
    print(r.stdout)
    if r.stderr.strip():
        print('--- stderr ---')
        print(r.stderr)
    code = r.returncode
finally:
    shutil.rmtree(sandbox, ignore_errors=True)

sys.exit(code)
