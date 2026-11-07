# QuickDrawer 发布前审查报告

审查日期：2026-11-01
审查范围：`src/QuickDrawer/` 全部 43 个源文件（13,334 行）+ 全部 XAML + 主题 + 仓库卫生 + 运行时实测
方法：4 个子代理逐行审查 + 本人复核关键结论 + 本机实测取证（日志/内存/体积/API 调用/注册表）

---

## 一、总结论

**当前状态不建议直接发布。** 功能完成度确实到了你的设计预期，但有三类问题会在开源后立刻变成 issue：

1. **隐私**：诊断日志默认开启、明文、无限增长，且 README 主动引导用户贴出来 —— 里面有剪贴板正文、完整用户目录、导航 URL。
2. **数据丢失**：`shortcuts.json` / `notes.json` / `config.json` 解析失败时静默清空并覆盖原文件。
3. **功能假象**：搜索框没有任何事件绑定（打字无反应）；文件复制捕获 100% 失败（API 名拼错）；`EncryptWithDpapi` 和 `IgnorePatterns` 两个配置项从未被读取。

**做得好的地方也很多**（重构时别改坏）：四处存储都是原子写（tmp + rename）；DPAPI 作用域正确；`IconService` 有 256 条硬上限；WebView2 回收链路完整不是泄漏；全项目零 `Effect`/`DropShadowEffect`；破坏性操作全部有确认无裸删除；无硬编码密钥、无个人路径进源码。

---

## 二、体积（你的硬指标）

### 实测数据

| 方案 | 体积 | 零依赖 | 备注 |
|---|---|---|---|
| **现状**：自包含 + 压缩单文件 | **65.36 MB** | ✅ | `publish/QuickDrawer.exe` = 65,357,604 B |
| 自包含 + 关闭原生库自解压 | **61.45 MB** | ✅ | 但不再是单文件，输出 68 MB 文件夹（11 项） |
| 自包含 + 非单文件 | **143 MB** | ✅ | 265 个文件 |
| **框架依赖 + 单文件** | **1.65 MB** | ❌ | 需用户装 .NET 10 Desktop Runtime |
| 框架依赖 + 非单文件 | 2.5 MB | ❌ | 其中 `QuickDrawer.dll` 仅 **252,928 B** |

### 关键事实

**65 MB 里 99.6% 是 .NET 运行时，不是你写的代码。** 应用自身全部代码编译后只有 **253 KB**。

已验证无效的优化：
- **IL 裁剪不可用**：`-p:PublishTrimmed=true` 直接被 SDK 拒绝 —— `error NETSDK1168: 启用剪裁时，不支持或不推荐使用 WPF。` 这是官方硬拒绝，不是配置问题。
- **剔除调试符号无效**：加 `-p:DebugType=none -p:DebugSymbols=false -p:GenerateDocumentationFile=false` 重新发布，exe 从 65,357,604 B 变成 65,357,427 B，**只差 177 字节**。pdb 本来就没进单文件。

### 另一个被忽视的"体积"问题

`IncludeNativeLibrariesForSelfExtract=true` 让程序每次启动把原生库解压到 `%TEMP%\.net\QuickDrawer\<随机名>\`，**从不清理**。

本机实测：**66 个残留目录，合计 319 MB**。每个约 8-9 MB（含 `D3DCompiler_47_cor3.dll` 4.7 MB、`wpfgfx_cor3.dll` 1.96 MB 等 7 项）。最早的是 10 月 25 日，7 天没清理。

> 也就是说：安装包 65 MB，但用户磁盘上会被悄悄占掉 300+ MB。这在开源项目里会被当成 bug 报上来。

### 建议

**方案 A（推荐，短期）：保持自包含单文件，但补上自解压清理。**

- 维持 65 MB，符合"零依赖开箱即用"的硬约束。
- 启动时清理 `%TEMP%\.net\QuickDrawer\` 下超过 7 天的目录（注意跳过当前进程正在用的那个）。
- 发布产物要排除：3 个 WebView2 XML 文档（`Core.xml` 615 KB + `Wpf.xml` 144 KB + `WinForms.xml` 42 KB = 801 KB）和 `QuickDrawer.pdb`（79 KB）。
- 在 README 里说明"65 MB 中 99.6% 是 .NET 运行时，应用本体 253 KB" —— 主动解释比被人质疑要好。

**方案 B（推荐，中期，能同时解决体积和零依赖）：迁移到 .NET Framework 4.8。**

这是唯一能同时满足你两个硬约束的路线：

- **零依赖成立**：.NET Framework 4.8 在 Windows 10 1903+ 和 Windows 11 上是**系统组件**（本机实测 `Release=533320`、`Version=4.8.09032`，无需安装）。
- **体积会降到约 2 MB**（估算，未实测）：WPF 应用在 net48 下通常 300-800 KB，加上 WebView2 的 4 个 dll 约 1 MB。
- **WebView2 官方支持**：`microsoft.web.webview2/1.0.4314.35` 包内 `lib/` 只有 `net462` 目标，官方就是这么发的，兼容性风险低。

代价（已实测，不是猜测）：我试过改 `net48` + `SelfContained=false`，**有 66 个编译错误**，集中在：

| 类别 | 位置 | 修法 |
|---|---|---|
| `Environment.ProcessPath` / `ProcessId` / `TickCount64` | 多处 | 换 `Process.GetCurrentProcess()` / `Stopwatch` |
| `File.Move(overwrite:)` | 3 处 Store | 先 `File.Delete` 再 `Move` |
| `System.Index` / `System.Range`（`[^1]`、`[a..b]`） | `DropPosition.cs:87`、`ClipboardService.cs:445`、`SelectionWatcher.cs:161`、`PromptEditorDialog.xaml.cs:43` | 加 `System.Memory` 包，或改写成 `Substring` |
| `Math.Clamp` | `ScreenshotOverlay.cs:322-324` | 自定义一行 |
| `ProtectedData` / `DataProtectionScope` | `ClipboardStore.cs:153-165` | 加 `System.Security.Cryptography.ProtectedData` 包 |
| `record` 类型 | `MouseHook.cs:123`、`AppPickerWindow.xaml.cs:18` | 补 `IsExternalInit` 垫片，或改 class |
| `string.Join(char, List<string>)` | `ClipboardService.cs:648` | 改 `string.Join("", ...)` |

工作量估计 **1-2 天**，风险点是 WebView2 和 COM 互操作在 net48 下的运行验证（未做）。

**方案 C（不推荐）：框架依赖 1.65 MB。** 体积最优，但违背你"其他电脑无需特殊依赖直接运行"的硬约束 —— 用户要先装 .NET 10 Desktop Runtime（约 60 MB 下载）。除非你愿意在 README 里写清前置条件。

**我的建议**：先按方案 A 发布 v0.1.0（补上自解压清理 + 产物清理 + README 说明），把方案 B 作为 v0.2.0 的目标。理由：方案 B 虽然诱人，但要改 66 处 + 重新验证所有原生互操作，在没测试的情况下压着发布期限做，风险大于收益。

---

## 三、发布阻塞项（必须修，8 项）

### B1. 诊断日志泄露隐私 【严重】

**问题**：`src/QuickDrawer/DiagLog.cs` 无脱敏、无轮转、无开关，`Write()` 内 `try{}catch{}` 吞掉所有异常。实测 14 天积累 **1.24 MB / 15,817 行**。

**泄露什么**（都有真实样本）：

- **剪贴板正文**：`ClipboardService.cs:282-283` 记前 40 字符；`:639` 记 30 字符；**`DrawerWindow.xaml.cs:2967` 记完整 `entry.Preview`，完全不截断**（最长 200 字符）。实测日志里有：
  ```
  2026-10-21 21:11:32.660 [clipboard] pinned 应用区拖拽重排	拖动磁贴改顺序，落点在目标左/右半边决定插入位置，顺序落盘 ...
  ```
- **来源应用名**：会记录 `msedge`、`1Password`、`KeePass` —— 等于告诉别人你用什么密码管理器。
- **完整用户目录**：`ShortcutStore.cs:172/183/277`、`ShellLink.cs:151`、`IconService.cs:93`、`AutoStart.cs:52`。实测 234 行含 `C:\Users\%USER%`。
- **导航 URL**：`AssistantService.cs:249` 记每次导航的完整 URL。
- **屏幕坐标与窗口矩形**：`[handle] auto-hidden after 504ms outside the panel (cursor=(1390,571) rect=(1520,0)-(1920,1032) inHandle=False)`

**为什么这是最高优先级**：`README.md` 第 100 行明确指引用户排查时看 `diag.log`。开源项目里"贴日志提 issue"是标准动作 —— 等于**你在引导用户把剪贴板内容和用户名贴到公开的 GitHub issue 里**。

**修法**（一处改动解决三件事）：

1. **脱敏**：日志只记 `Kind` + `SizeBytes` + 条目 Id，**永不记 `Preview`/`Text`/`Files`/`SourceApp`**。路径类日志改为只记文件名，或用 `Environment.UserName` 替换成 `%USER%`。
2. **轮转**：超过 2 MB 滚动为 `diag.1.log`，只保留 2 份。
3. **开关**：`Config` 加 `DiagLogEnabled`，默认 **false**；提供一个"导出诊断日志"菜单项，导出时自动脱敏。

### B2. 数据丢失：解析失败静默覆盖 【严重】

- **`shortcuts.json`**：`ShortcutStore.cs:36-52` 的 `catch` 只写日志，然后流程继续落到 `Save(seeded)`（第 51 行）—— **无条件用种子数据覆盖你的原文件**。触发条件：JSON 截断、手改坏、字段类型不匹配。
- **`notes.json`**：`NoteStore.cs:122-132` 的 `TryDeserialize` 吞异常返回 null，`:57-78` 两条解析都失败就 `return new List<NoteItem>()`，之后任何保存即覆盖。**更糟的是** `:58` 判空后落 v1 分支，v1 解析成功但 `Text` 为空时，`:74` 会 `Save(migrated)` **主动写空**。
- **`config.json`**：`App.xaml.cs:200-206` 同样静默回退默认值，只 `Debug.WriteLine`，用户零提示。

**修法**：区分"文件不存在"（可以落种子）和"文件存在但解析失败"（把原文件重命名为 `.corrupt-<时间戳>`，弹窗告知，**绝不写盘**）。

### B3. 搜索框是死控件 【严重 · 欺骗性 UI】

`DrawerWindow.xaml:274-278` 有个 `x:Name="SearchBox"` 的 TextBox，`Text="搜索…"`。**全项目 `grep SearchBox` 只有这一处定义，零引用** —— 没有 `TextChanged`，没有过滤逻辑，`Text="搜索…"` 是字面文本。

实际体验：点击后光标落在"搜索…"后面，接着输入得到「搜索…abc」，列表纹丝不动。

**修法**：要么实现过滤（推荐，这是面板最高价值的入口），要么删掉。留一个假搜索框比没有更伤害信任。

### B4. 文件复制捕获 100% 失败 【严重 · 功能失效】

`Native/Native.cs:221` 声明了 `DragQueryFileCount`：
```csharp
[DllImport("shell32.dll", SetLastError = true)]
public static extern uint DragQueryFileCount(IntPtr hDrop, uint flags);
```

**这个函数在 shell32.dll 里根本不存在。** 我实测调用：
```
DragQueryFileCount CALL FAILED: EntryPointNotFoundException :: 无法在 DLL"shell32.dll"中找到名为"DragQueryFileCount"的入口点。
DragQueryFile CALLED OK, returned 0
```

生产日志佐证：`capture failed: Entry point was not found.` 出现 8 次，`captured Files` **0 次**（`captured Text` 200 次、`captured Image` 1 次）。

而 `CaptureFiles` 默认是 `true` —— 用户在资源管理器复制文件，**一条都进不了历史**。

**修法**：删掉这个声明，改用 `DragQueryFile(h, 0xFFFFFFFF, IntPtr.Zero, 0, 0)` 取数量。

**⚠️ 必须同时修 B5，否则从"功能失效"变成"堆损坏"。**

### B5. 缓冲区少分配一半（堆溢出） 【严重 · 当前被 B4 掩盖】

`ClipboardService.cs:491`：
```csharp
IntPtr buf = Marshal.AllocHGlobal((int)len + 2);   // 按字节分配
```
但 `:495` 的 `DragQueryFile(h, i, buf, len + 1, 0)` 在 `CharSet.Unicode` 下会写 `len+1` 个**宽字符** = `2*(len+1)` 字节。20 字符的路径需要 42 字节，只分配了 22 字节 —— 非托管堆越界写。

**修法**：改成 `Marshal.AllocHGlobal((int)(len + 1) * 2)`。

### B6. exe 没有应用图标 【中等 · 但影响第一印象】

- 全项目**没有任何 `.ico` 文件**，`QuickDrawer.csproj` 未设 `ApplicationIcon`。
- 实测 `publish/QuickDrawer.exe` 提取出来的是 **.NET/WPF 通用默认图标**（蓝色方块 + 列表线条）。
- 讽刺的是托盘图标是**程序化绘制**的（`TrayIcon.cs:100-135`，圆角深色方块 + 三条抽屉线条），有品牌感。

**修法**：用托盘图标的同一套视觉生成一个多尺寸 `.ico`（16/24/32/48/256），在 csproj 加 `<ApplicationIcon>app.ico</ApplicationIcon>`。

### B7. 剪贴板"加密"叙事与实现不符 【中等 · 但涉及信任】

`ClipboardStore.cs:11-13` 声明"内容用 DPAPI 加密（CurrentUser 作用域）……文件被拷到别的机器/别的用户下也解不开"。

实际 `StoredEntry`（`:29-38`）同时存 `Preview`（明文）和 `EncryptedText`。**只有 `Text` 走 `Protect`，`Preview` 和 `Files` 都是明文。**

实测 `clipboard.json` 直接可读，前 5 条：
```
Kind=Text | Preview=[dsh-turn-memory]
Kind=Text | Preview=[npm: https://www.npmjs.com/package/dshmarket/v/1.73.7 … dist-tag: latest]
Kind=Text | Preview=[https://github.com/dsh-market/dsh-market]
```

`Preview` 存的是前 **200 字符**（`ClipboardService.cs:408`）—— 密码、token、URL 的关键部分往往就在前 200 字符里。

**修法**（二选一）：① README 里如实说明"完整正文加密，预览前 200 字符明文"；② 预览也走 DPAPI，内存里解密后显示。推荐 ②，工作量不大。

### B8. 两个配置项是假承诺 【中等】

`Config.cs:184` 的 `EncryptWithDpapi` 和 `:187` 的 `IgnorePatterns`，**全仓 grep 只有定义处，零读取点**。

- "可关闭加密" → 关闭了也不生效。
- "忽略敏感内容" → 根本没实现。

**修法**：要么实现，要么删掉。留着未使用的配置项写进 config.json 会让读代码的人以为功能存在。

---

## 四、源码问题

### 严重（会导致卡死 / 数据丢失 / 静默外泄）

**S1. 划词捕获阻塞 UI 线程最长 1.6 秒**
`Selection/SelectionCapture.cs:31` 的 `Capture()` 用 `Thread.Sleep(40)` 轮询，`PollCount=20` × `CopyAttempts=2`。调用链是 `SelectionWatcher.cs:115` → `:142`，**在 UI 线程同步执行**。Ctrl+C 无效或剪贴板被占用时，整个托盘程序卡死（连托盘菜单都点不动）。
→ 修法：挪到 STA 工作线程，或改成 `await Task.Delay` 事件驱动。

**S2. 全局注入 Ctrl+C 没有黑名单**
`Native/Native.cs:157-165` 的 `SendCtrlC()` 无条件发 `SendInput`。**全项目没有 conhost / WindowsTerminal / pwsh / cmd.exe / powershell 任何黑名单。**
→ 在终端里拖选文字 = 发 SIGINT，直接打断用户正在跑的命令。这是最容易被吐槽"流氓软件"的行为。

**S3. 快照失败会清空用户剪贴板**
`SelectionCapture.cs:126-150` 和 `AssistantService.cs:658-673` 的 `RestoreClipboard`：`saved` 为 null（剪贴板被占用，很常见）时走到 `Clipboard.Clear()` —— **用户剪贴板内容被直接抹掉**。
→ 修法：`saved == null` 时什么都不做。

**S4. 助手页无导航白名单，选中文本可能静默外泄**
`AssistantService.cs:249` 的 `NavigationStarting` 只记日志，**从不 `e.Cancel = true`**；`:256-264` 把**任意 URI** 导航到当前视图；`SendPromptAsync` 拿到 `core` 后**不校验 `core.Source` 的 host** 就注入文本并回车。
→ 视图一旦被导航到第三方站点，用户的选中文本会被自动键入并发出，全程无提示。这是唯一的静默外泄路径。
→ 修法：白名单校验 host（只允许 4 个预设站点），不匹配则拒绝导航 + 拒绝发送。

**S5. WebView2 环境初始化失败后永久不可用**
`AssistantService.cs:211-220`：`_envTask ??= CreateEnvironmentAsync(); _env = await _envTask;` —— 失败后缓存的是 faulted Task，后续每次 await 抛同一异常。用户装了 WebView2 Runtime 也救不回，只能重启程序。
→ 修法：catch 后把 `_envTask` 置 null，允许重试。

**S6. 全局异常有日志但无提示**
`App.xaml.cs:35-49` 三个钩子都只写 `DiagLog.Write("crash", ...)`，`DispatcherUnhandledException` 里**没有 `ex.Handled = true`** —— UI 线程任何未捕获异常直接杀进程，用户看到程序突然消失，没有任何提示。

**S7. 托盘图标 HICON 从不销毁**
`TrayIcon.cs:138-151` 的 `Dispose()` 只做 `Shell_NotifyIcon(NIM_DELETE)` 和 hook 清理，`_data.hIcon` 未 `DestroyIcon`。每次创建托盘图标都泄漏一个 GDI 句柄。

**S8. 剪贴板全量重写 + 逐条加密，全在 UI 线程**
`DrawerWindow.xaml.cs:2746` → `:2971` → `ClipboardStore.cs:85`：每次捕获都全量重写 `clipboard.json`，并对**每一条**重跑 DPAPI `Protect`。500 条历史时，每次复制都要加密 500 次。

**S9. 无单条大小上限**
`ClipboardService.cs:410` 文本 `SizeBytes = s.Length * 2` 不设限；`:549-551` 图片整块复制不设限；`Config.cs:171` 的 `MaxBytes` 默认 **2 GB**。而 `SizeBytes` 是 `int`，超 2 GB 溢出成负数，淘汰逻辑的字节账直接算错。

### 中等（择要）

| 项 | 位置 | 影响 |
|---|---|---|
| `_seen` 集合永不清理 | `ClipboardService.cs:644-652` | key 是完整正文，本次运行内所有复制过的全文永久驻留内存 |
| 淘汰在 `lock` 内同步切 UI 线程 | `ClipboardService.cs:276/638` + `DrawerWindow.xaml.cs:2765-2773` | 潜在死锁【推断，未复现】 |
| DROPFILES 结构写错 | `ClipboardService.cs:710-713` | `pFiles` 应为固定 20 却写成字符数；`pt` 偏移写错覆盖 `fNC` |
| 超限条目仍被加入 | `ClipboardService.cs:614-640` | 单条超限时淘汰完非锁定项后 `break`，该条目照样进历史 |
| CF_DIBV5 静默丢失 | `ClipboardService.cs:344-346` vs `:535` | 格式探测认作有图，读取只取 `CF_DIB` |
| CF_HTML 解析错 | `ClipboardService.cs:444-445` | 取到的是偏移表文本不是 HTML 片段 |
| 图标失败缓存永久生效 | `IconService.cs:96` + `:43-46` | 一次取图失败，该路径永不重试直到被 256 条挤出 |
| UNC 路径触发 SMB 连接 | `IconService.cs:77` | `File.Exists` 对 UNC 会真发连接，可能泄露 NTLM 哈希 |
| `ConfigStore.Save` 无 try/catch | `App.xaml.cs:237-243` | 磁盘满即抛，3 个调用点均未捕获 |
| 主题不跟随系统切换 | `ThemeService.cs:31-36` | 只在启动读一次注册表，无 `WM_SETTINGCHANGE` 监听 |
| 热键静默降级 | `DrawerWindow.xaml.cs:610-628` | 5 级回退链，成功了 UI 也不显示实际生效键 |
| 单实例第二实例不唤出 | `App.xaml.cs` | 用户双击图标没反应，只有个 2.5 秒自动关的提示窗 |
| 列表无虚拟化 | `DrawerWindow.xaml:323-363`（AppsList WrapPanel）、`:585`（NotesList） | 仅 `ClipboardList`（`:772-774`）正确开了 `IsVirtualizing` + `Recycling` |
| 属性 getter 内调 `SHGetFileInfo` | `ViewModels.cs:22/49` | UI 线程绑定求值时同步 I/O |
| `WM_CLIPBOARDUPDATE` 空实现 | `DrawerWindow.xaml.cs:277-280` | 有分支无逻辑 |

### 代码结构

`DrawerWindow.xaml.cs` 是 **3574 行的 God Class**，承担热键、动画、自动隐藏、拖拽、四个面板、托盘菜单、布局持久化。子代理给出了 12 个文件的拆分方案（`HotkeyManager.cs`、`DrawerAnimation.cs`、`AutoHideWatchdog.cs`、`DragDropController.cs`、`NotesPanelView.cs`、`ClipboardPanelView.cs`、`AssistantPanelView.cs`、`LayoutPersistence.cs` 等）。

建议分三批做，不要一次重构：
1. **零行为变更**：`VisualTreeHelpers`、`HotkeyManager`、`LayoutPersistence`
2. **需回归测试**：`DrawerAnimation`、`AutoHideWatchdog`
3. **先拆 `NotesPanelView` 验证模式**，再推广

> 注意：不要用 `partial class` 糊弄，那只是把 3574 行拆成 3 个 1200 行的文件，没解决问题。

### 死代码（grep 无调用点，可直接删）

`DrawerWindow.xaml.cs:2681 FindVisualChild<T>`、`DropPosition.cs:194 FindVisualFor`、`DragReorder.cs` 的 `MoveBefore`/`MoveAfter`/`IsBefore`/`Reset`/`DragHappened`、`HandleWindow.xaml.cs:31 HoverChanged`。

---

## 五、UI 设计

### 严重

**U1. 搜索框是死控件** —— 见 B3。

**U2. 路径项名称硬编码 Gainsboro，浅色主题下完全看不见**
`DrawerWindow.xaml.cs:3321`：`Foreground = System.Windows.Media.Brushes.Gainsboro`。这段代码由 `ApplyPathLayout()` 在运行时**替换掉** XAML 里用 `TextPrimary` 的模板。

对比度实测：浅色面板 **1.27:1**、浅色便签黄 **1.13:1**（WCAG AA 要求 4.5:1）。等于功能不可用。

同文件的 `BuildListRow`（`:3340`）用的是 `SetResourceReference(..., "TextPrimary")` —— 说明这是漏改，不是设计。

**修法：1 行。** 改成 `SetResourceReference(TextBlock.ForegroundProperty, "TextPrimary")`。

**U3. 便签卡片次要文字对比度全线不合格**
`TextMuted` 用在便签卡上，实测：深色 黄3.53 / 绿3.48 / 蓝4.05 / 粉4.28 / 灰4.01；浅色 4.04 / 3.80 / 3.61 / 3.77 / 3.94。全部低于 4.5。

**修法**：卡片场景改用 `TextSecondary`（8.39 / 9.98），改一处令牌解决 10 个不合格项。

**U4. 三个对话框完全不跟随主题，浅色下弹黑方块**
硬编码深色配色的文件：`AppPickerWindow.xaml`（10 处）、`CategoryPickerDialog.xaml`（7 处）、`InputDialog.xaml`（7 处）、`HandleWindow.xaml`（3 处）、`PromptEditorDialog.xaml:43`（1 处）。

对照：`PromptEditorDialog.xaml:10` 和 `SettingsWindow.xaml:8` **已经正确用了** `{DynamicResource DialogBackground}` —— 写法项目里就有，只是没推广。

**修法**：约 40 行替换。浅色下弹黑方块是"不专业"的第一印象来源。

**U5. 深色主题下对话框标题栏仍是白色**
全项目**从未导入 `DwmSetWindowAttribute`**。走系统标题栏的 `SettingsWindow` / `CategoryPickerDialog` / `PromptEditorDialog` 在深色主题下标题栏保持系统浅色，内容区却是深色 —— 截图 `probe/dialog-theme-settings.png` 肉眼可见割裂。

**修法**：加 `DwmSetWindowAttribute(hwnd, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, ref dark, sizeof(int))`，在 `SourceInitialized` 时调用。

**U6. 全部对话框无 Esc 关闭、无 Enter 提交**
全项目 XAML 里 `IsCancel` / `IsDefault` / `InputBindings` / `KeyDown` **零命中**。

受影响最大的是 `InputDialog.xaml:33-38` —— 它用于新建/重命名分类（4 个调用点），输完按 Enter 没反应。

**修法**：主按钮加 `IsDefault="True"`、取消按钮加 `IsCancel="True"`。一行一个。

**U7. 交互目标远小于 32px（触摸不可用）**
色板 14×14、分类折叠 16px、置顶 22×20、删除✕ 22×20、剪贴板锁定 22×22、`IconButton` Style 写死 24×24、滚动条实测 **4px**。

`IconButton` 把 `Width`/`Height` 写进 Style，所有派生按钮都被 24px 卡死。

**U8. 「新建便签」按钮文字被裁掉一半**
`DrawerWindow.xaml:754-759` 用了 `IconButton` Style（该 Style 在 `:42-43` 写死 `Width="24"`），而 Content 是「＋ 新建便签」6 个字符。截图实测文字包围盒只有 22px 宽，右半被裁 —— **截图里能直接看到的最明显 bug**。

**修法：1 行。** 换成普通 Button 或加 `Width="Auto" MinWidth="88"`。

### 中等

| 项 | 说明 |
|---|---|
| 左边缘 7 种基线 | 标签行 x=9、便签卡 x=10、搜索框 x=11、目录路径 x=12、分类名 x=14、应用磁贴 x=15、路径项图标 x=30。全文件 19 种不同 Margin 值 |
| 无全局控件样式 | `App.xaml` 只有 `BoolToVis`。设置页里 Slider 是原生凹槽、CheckBox 是原生方框、GroupBox 是 2006 年的 etched 边框 —— 和扁平圆角的主面板像两个产品拼的 |
| 令牌缺失 | FontSize 6 档（12×21、13×16、11×13、10×5、14×3、9×1），11 和 12 混用于同层级；CornerRadius 5 档；无间距标尺、无 Danger 色 |
| 死令牌 | `SectionBackground` 在两套主题都定义，**全项目零引用** |
| 选中态只靠颜色且该色不合格 | `ProviderChip` 选中态是 `AccentText` 浅蓝字，浅色下 #2F7BD8 on #F6F6F8 = **3.93**，不合格。而这是助手页当前站点的唯一标识 |
| 主按钮直角饱和蓝 | #3A7BD5 白字 4.22，直角，与整屏扁平圆角割裂 |
| 长文本缺截断 | 全项目 `TextTrimming` 仅 4 处。分类名无 trimming 无 MaxWidth，20 字会把「＋」挤出可视区 |
| 无键盘可达性 | 分类右键菜单只有 `MouseRightButtonDown`，键盘用户无法重命名/删除分类；全项目无 `TabIndex` |
| 无障碍名称覆盖不足 | DrawerWindow 19 个 Button 仅 8 个有 `AutomationProperties.Name`；纯图标按钮（⋮ ＋ 🗑 色板）读屏完全无内容；其他三个对话框全为 0 |
| WebView2 白底直角贴边 | `AssistantHost`（`:914`）是纯 Grid，无圆角无边框无内边距 —— 网页白色直角与面板圆角半透明背景硬接，像贴了张纸 |
| 图标风格混杂 | 🌐 是彩色 emoji 比邻居大一圈偏色；全项目 📌🔒🗑📝📋🤖＋⋮✕≡▦‹ 混用 emoji 与几何字符。建议统一 Segoe Fluent Icons |
| 便签阅读态无法看全文 | `:721-722` MaxHeight=150 + CharacterEllipsis，只有进编辑态才有滚动条。想浏览长便签得先进编辑，语义错 |
| 分隔条过重 | 10px 深灰实心带常显横贯全宽，截图实测 y=461-471 |
| 「关闭」语义歧义 | `SettingsWindow.xaml:82-87` 的「关闭」实际是**禁用截图热键**，用户会以为是关窗口。建议改「禁用」 |

### 做得对的（重构时别改坏）

- 全项目**零 `Effect`/`DropShadowEffect`/`BlurEffect`** —— 最容易被写坏的地方避开了
- 图标走 `IconService` 静态缓存 + 32×32 后 `Freeze()`，不是每项建 BitmapImage
- 破坏性操作**全部有确认，无裸删除**（清空便签、清空剪贴板、删便签、删分类），且文案含"此操作不可撤销"
- 两套主题字典 **15 个键完全对齐**，注释记录了设计依据
- `AutomationProperties` 在 DrawerWindow 有 16 处、SettingsWindow 有 6 处

### 如果只改 5 处（影响面 ÷ 成本，合计 < 200 行）

1. **修「新建便签」截断** —— `DrawerWindow.xaml:754-759`，**1 行**。截图里唯一"明显坏了"的地方。
2. **修 Gainsboro 硬编码** —— `DrawerWindow.xaml.cs:3321`，**1 行**。浅色下 1.27:1 等于功能不可用。
3. **三对话框接主题 + 补 Esc/Enter** —— 约 40 行。浅色下弹黑方块是"不专业"第一印象的来源；InputDialog 无 Enter 是最高频摩擦。
4. **补最小全局控件样式集** —— 新建 `Themes/Controls.xaml`，Button/TextBox/CheckBox/Slider/GroupBox 五个隐式样式，约 80 行。
5. **收敛令牌** —— FontSize→11/12/13/14，CornerRadius→4/6/8，新增 SpacingXs/Sm/Md/Lg(4/8/12/16)，替换 19 种裸 Margin，约 60 处。

---

## 六、仓库与文档

### README 严重过时

`README.md`（141 行）与实际脱节：

- 第 23 行仍写"**阶段：M0–M4 完成，M5 进行中**"
- 第 38-42 行"M5 待做：设置页 / 多显示器适配验证 / 暗色浅色主题" —— **这三项实际全部完成了**
- 第 67-73 行体积表写 61.86 MB / 133.31 MB —— **实测已 65.36 MB / 143 MB**
- 第 135 行路线图仍写"**M1 骨架（进行中）**"
- 第 137-141 行"下一步"仍是 M1/M2 的待办
- 第 100 行日志路径写成 `%APPDATA%\\QuickDrawer\\logs\\diag.log`（双反斜杠，markdown 会渲染成 `\\`）
- **完全没提**智能助手（WebView2）、划词选区、托盘、开机自启、DPAPI 这些已交付能力

保留有价值的部分：已锁定决策表、拖拽重排三代算法表、12 项探针 PASS 表、构建命令（含"发布前必须先关掉正在运行的实例"）。

### 仓库卫生

- **`.gitignore` 不覆盖 `probe/*.png` 和 `probe/*.txt`**。实测存在 8 个会进仓库的探针产物（截图 + 文本输出）。
- **`docs/可行性方案.md` 有 2 处个人路径**：
  - 第 1658 行：`Failed to create directory [C:\Users\%USER%\AppData\Local\Temp\.net\QuickDrawer\xxxx]`
  - 第 2088 行：`webview2 ready (runtime 156.0.4314.50, userData=C:\Users\%USER%\AppData\Local\QuickDrawer\WebView2)`
- 源码本身**干净**：`grep C:\Users`、`D:\Documents`、`%USER%`、`token`、`sk-` 在 `src/` 下零命中。硬编码 URL 只有 5 个公开站点。
- 该项目目录**不是 git 仓库**（`git log` 返回 exit 128）。发布前必须实际 `git add -n .` 核对。
- 实际会进仓库的约 230 个文件 / 3.98 MB。`probe/domspike/` 虽占 64 MB 但全是 bin/obj，已被正确忽略。

### 缺少的东西

- 无 `global.json`、无 `Directory.Build.props`、无 CI 配置
- **无任何单元测试**（`find -iname "*test*"` 只命中三个开发期探针工程）

---

## 七、建议的发布路线

### 阶段一：发布前必做（估计 2-3 天）

- [ ] B1 日志脱敏 + 轮转 + 开关（**最高优先级**）
- [ ] B2 数据损坏保护（三个 Store）
- [ ] B3 搜索框：实现或删除
- [ ] B4 + B5 文件捕获（两个必须一起改）
- [ ] B6 生成 `.ico` + csproj 加 `ApplicationIcon`
- [ ] B7 预览加密或 README 如实说明
- [ ] B8 删掉两个未使用的配置项（或实现）
- [ ] U2 Gainsboro（1 行）
- [ ] U8 「新建便签」截断（1 行）
- [ ] U4 三对话框接主题 + U6 补 Esc/Enter（约 40 行）
- [ ] 清理 `publish/` 里的 XML 和 pdb
- [ ] 加自解压目录清理（319 MB 那个问题）
- [ ] 重写 README（去掉过期的 M0-M5 阶段表，补上实际功能）
- [ ] `.gitignore` 补 `probe/*.png`、`probe/*.txt`
- [ ] `docs/可行性方案.md` 清掉 2 处 `%USER%`
- [ ] `git init` + `git add -n .` 核对

### 阶段二：发布后第一批（估计 3-5 天）

- [ ] S1 划词捕获挪出 UI 线程
- [ ] S2 终端黑名单
- [ ] S3 快照失败不清空剪贴板
- [ ] S4 导航白名单
- [ ] S5 WebView2 环境可重试
- [ ] S6 全局异常加用户提示
- [ ] S7 托盘 HICON 销毁
- [ ] U5 深色标题栏
- [ ] U3 便签卡对比度
- [ ] U7 交互目标放大到 32px
- [ ] 拆 `DrawerWindow.xaml.cs`（第一批：零行为变更的三个）

### 阶段三：v0.2.0

- [ ] 迁移 .NET Framework 4.8（体积 65 MB → 约 2 MB，同时保持零依赖）
- [ ] 或者：接受框架依赖的 1.65 MB，README 写清前置条件

---

## 八、一句话总结

**功能做完了，工程细节还没到可以见人的程度。** 最该先修的不是那 3574 行的 God Class，而是三件小事：日志脱敏、搜索框、那个拼错的 API 名 —— 它们分别对应"用户提 issue 会泄露隐私"、"第一眼就是假的"、"功能根本没工作"。
