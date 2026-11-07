import io, sys

P = "README.md"
src = io.open(P, encoding="utf-8").read()

# ---------- 1. 体积说明整节替换（原 26-81 行） ----------
start = src.index("## 体积说明")
end = src.index("## 使用方法")
old_block = src[start:end]
assert old_block.count("## 体积说明") == 1

new_block = u"""## 体积说明

发布产物是一个 **18 个文件的文件夹，合计 2.84 MB**（其中 exe 自身 282 KB）。

它不是单文件，也不是自包含的：目标是 **.NET Framework 4.8**，这是 Windows 10 1903+ 与 Windows 11 的系统组件，目标机器无需安装任何东西。

| 部分 | 体积 | 说明 |
|---|---|---|
| **应用自身代码**（`QuickDrawer.exe`，47 个源文件） | **282 KB** | 全部业务逻辑 |
| WebView2 托管层与加载器 | 1.00 MB | `Microsoft.Web.WebView2.Core/Wpf/WinForms.dll` + x64 `WebView2Loader.dll` |
| JSON 序列化栈 | 870 KB | `System.Text.Json` 及它依赖的 `Encodings.Web`、`IO.Pipelines`；net48 不自带 |
| 异步与内存支撑库 | 366 KB | `System.Memory`、`Numerics.Vectors`、`Buffers`、`ValueTuple`、`Bcl.AsyncInterfaces`、`Tasks.Extensions`、`Unsafe` |
| 调试符号（可选） | 74 KB | `QuickDrawer.pdb`，可删除 |

### 为什么是这个数字

要求是"其他 Windows 电脑无需特殊依赖直接运行"。满足这一条有两条路：

| 路线 | 体积 | 目标机器要求 | 取舍 |
|---|---|---|---|
| **.NET Framework 4.8（当前）** | **2.84 MB** | 无（系统组件） | **选定** |
| .NET 10 自包含单文件 | 65.39 MB | 无 | 免装依赖，但 99.6% 是运行时；单文件每次启动会在 `%TEMP%\\.net\\` 解压原生库，实测累积 66 个目录、319 MB 且从不清理 |
| .NET 10 框架依赖 | 1.65 MB | 需装 .NET 10 Desktop Runtime | 违背"零依赖" |

选 net48 的理由：体积降到 1/23，同时仍然零依赖。代价是失去新版 BCL API（见下节"踩过的坑"）。

### 曾经考虑过但不可行

**WPF 不支持 IL 裁剪**——微软明确禁止（[Known trimming incompatibilities](https://aka.ms/dotnet-illink/wpf)），不是配置问题。实测 `-p:PublishTrimmed=true` 直接失败：

```
error NETSDK1168: 启用剪裁时，不支持或不推荐使用 WPF。
```

所以自包含路线没法靠裁剪把 65 MB 压下来——这才是当初决定换框架的原因。

### 迁移到 net48 踩过的坑

80 个编译错误逐个清零，运行时逐项验证。要动目标框架的话，这些是最花时间的部分：

1. **`System.Index` / `System.Range` 不可用（34 处）** —— `arr[..n]`、`arr[a..b]` 全要改成 `Substring` 或索引重算。这是工作量主体。
2. **新版 BCL API 缺失** —— `Math.Clamp`(16)、`Environment.ProcessId`(6)、`TickCount64`(2)、`ProcessPath`(2)、`SHA256.HashData`(2)、`Convert.ToHexString`(2)、`string.Join(char, ...)`(2)，统一收在 `Compat.cs` 垫片里。
3. **`File.Move(src, dst, overwrite: true)` 不存在（8 处）** —— 四处 Store 的原子写都依赖它，垫片成"存在则先删除再移动"。
4. **`Microsoft.Win32.OpenFolderDialog` 是 .NET 8+ 独有（1 处）** —— 换成 `FolderPicker.cs` 里对 `SHBrowseForFolder` 的 P/Invoke。
   ⚠️ **不要用 `<UseWindowsForms>true</UseWindowsForms>` + `FolderBrowserDialog`**：实测会立刻引入 **52 个 `CS0104` 类型歧义错误**（`Point` / `TextBox` / `DragEventArgs` / `MouseEventArgs` / `Brush` / `Application` / `IDataObject` 在 `System.Windows.Forms` 与 `System.Windows.*` 下重名），不可行。
5. **`IsExternalInit` 缺失（4 处）** —— record 与 init-only 属性需要，4 行垫片。
6. **WebView2 走 `net462` 目标** —— 该 NuGet 包官方提供，无需降级。
7. **可空引用类型注解缺失（6 处警告）** —— .NET Framework 4.8 的引用程序集没带 `[NotNullWhen(false)]` 这类注解，`string.IsNullOrWhiteSpace` 之后编译器学不到"已排除 null"。已用 `!` 断言补齐，不是 `NoWarn` 掩盖。

**已实测可用**：单实例互斥、配置读取、DPAPI 剪贴板解密、全局热键、剪贴板监听、鼠标钩子、窗口定位、托盘图标、布局还原、**助手页 WebView2 加载**（拉起 6 个 `msedgewebview2` 进程，DeepSeek 首页与输入框正常渲染）、划词选区、深色标题栏。

完整实测记录（每类错误数量、垫片代码、运行时日志、一次 `BadImageFormatException` 的排查过程）见 [docs/修正记录.md](docs/修正记录.md)。

**顺带的好处**：net48 不能单文件发布，也就没有 `%TEMP%\\.net\\` 那份解压残留；工作集从 271.9 MB 降到约 95 MB。

"""

src = src[:start] + new_block + src[end:]

# ---------- 2. 构建节替换 ----------
start = src.index("## 构建")
end = src.index("## 目录结构")
old_build = src[start:end]
assert old_build.count("dotnet publish") == 1

new_build = u"""## 构建

需要 .NET SDK（构建 net48 需要 .NET Framework 4.8 Developer Pack 或参考程序集包，已通过 `Microsoft.NETFramework.ReferenceAssemblies` 自动获取）。

```powershell
# 调试构建
dotnet build QuickDrawer.sln -c Release

# 发布前必须先关掉正在运行的实例，否则 exe 被占用会导致发布失败
Get-Process QuickDrawer -ErrorAction SilentlyContinue | Stop-Process -Force

# 发布（框架依赖，输出 18 个文件的文件夹）
dotnet publish src\\QuickDrawer\\QuickDrawer.csproj -c Release -o publish
```

> ⚠️ **不要把产物发布到项目工作区目录内测试**。本项目开发时工作区被工具加了 `Everyone Deny DeleteSubdirectoriesAndFiles` 的沙箱 ACE，继承到整棵子树后，从这里启动的 .NET Framework 进程在部分机器上会写不了 `%APPDATA%` 下的日志（表现为程序能跑但 `diag.log` 一字不增，甚至 `0xE0434352` 直接退出）。发布到工作区外即可，与程序本身无关。

### 已知的构建约束

这几项都是实测踩过的坑，改动前请先读 csproj 里的注释：

| 设置 | 不能这么做的原因 |
|---|---|
| 缺 `PlatformTarget=x64` | NuGet 按默认 x86 挑原生资源，产物里会塞进 32 位 `WebView2Loader.dll`，64 位进程加载它抛 `BadImageFormatException (0x8007000B)`，**只有助手页挂，其他功能全正常**，极易误判成 WebView2 坏了。`<Platforms>x64</Platforms>` 只是"本工程可构建哪些平台"的声明，不决定编译目标 |
| `InvariantGlobalization=true` | WPF 数据绑定在 `BindingExpressionBase.GetCulture()` 需要 `CultureInfo`，会抛 `Cannot find non-neutral culture related to 'en-us'.`，程序在 `Show()` 时崩溃 |
| `PublishTrimmed=true` | WPF 明确不支持裁剪，SDK 直接报 `NETSDK1168` |
| 显式引用 `System.Security.Cryptography.ProtectedData` | 该包随 Windows Desktop SDK 自动提供，显式引用触发 `NU1510` |
| `RuntimeIdentifier` / `PublishSingleFile` / `EnableCompressionInSingleFile` / `IncludeNativeLibrariesForSelfExtract` | net48 不支持单文件发布，这几项在本工程里已移除 |

`.lnk` 解析依赖 COM interop（`IShellLinkW`），所以 `EnableComInterop` 必须为 `true`。

**判断产物架构别用错工具**：PE 头的 COFF machine 字段对 AnyCPU 程序集恒为 `0x14c`，看着像 x86 其实不是。要读 COR20 header 的 Flags（`ILONLY=0x1` / `BIT32_REQUIRED=0x2` / `BIT32_PREFERRED=0x10000`）。仓库里有现成脚本：

```powershell
python probe/_pe_platform.py publish/QuickDrawer.exe publish/WebView2Loader.dll
```

---

"""

src = src[:start] + new_build + src[end:]

io.open(P, "w", encoding="utf-8", newline="\n").write(src)
print("OK README rewritten, %d bytes, %d lines" % (len(src.encode("utf-8")), src.count(chr(10)) + 1))
