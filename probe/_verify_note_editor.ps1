# 便签独立编辑器门禁（2026-11-08）
#
# 验的是"运行时会崩的那一类问题"，不是编译期能发现的：
#   1. NoteEditorWindow 的 XAML 能不能真正实例化 —— 这条最关键。
#      StaticResource 是运行时解析的，编译通过 ≠ 能打开。
#      曾经这里引用了 DrawerWindow 的局部样式 IconButton，
#      编译 0 错误，但一打开就 XamlParseException。
#   2. 关闭窗口是否把正文写回卡片并触发落盘回调。
#   3. 重复关闭不会二次落盘。
#   4. 插入时间按钮真的插在光标处。
#   5. 字数统计会更新。
#
# 用法：
#   $env:QD_EXE = 'D:\...\QuickDrawer.exe'
#   powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File probe\_verify_note_editor.ps1
#
# 必须是 STA：WPF 窗口只能在 STA 线程上建。
param(
    [string]$Exe = $env:QD_EXE
)

$ErrorActionPreference = 'Stop'

if (-not $Exe) {
    $Exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe'
}
if (-not (Test-Path -LiteralPath $Exe)) {
    throw "QD_EXE not found: $Exe"
}

$script:failures = 0
$script:checks = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:checks++
    if ($ok) {
        Write-Host ("PASS  {0}{1}" -f $name, $(if ($detail) { "  $detail" } else { '' }))
    }
    else {
        $script:failures++
        Write-Host ("FAIL  {0}{1}" -f $name, $(if ($detail) { "  $detail" } else { '' })) -ForegroundColor Red
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

Write-Host "exe: $Exe"
$asm = [System.Reflection.Assembly]::LoadFrom($Exe)
Check 'assembly loaded' ($null -ne $asm) $asm.GetName().Name

$ctorFlags = [System.Reflection.BindingFlags]'Public,NonPublic,Instance'
$fieldFlags = [System.Reflection.BindingFlags]'Public,NonPublic,Instance'
$methodFlags = [System.Reflection.BindingFlags]'Public,NonPublic,Instance'

# --- 类型与入口存在性 -------------------------------------------------------
$editorType = $asm.GetType('QuickDrawer.NoteEditorWindow')
Check 'NoteEditorWindow type exists' ($null -ne $editorType)

$cardType = $asm.GetType('QuickDrawer.NoteCardViewModel')
$itemType = $asm.GetType('QuickDrawer.NoteItem')
Check 'NoteCardViewModel / NoteItem types exist' (($null -ne $cardType) -and ($null -ne $itemType))

$drawerType = $asm.GetType('QuickDrawer.DrawerWindow')
foreach ($m in @('OpenNoteEditor', 'NoteEdit_Click')) {
    $found = $drawerType.GetMethod($m, $methodFlags)
    Check "DrawerWindow.$m exists" ($null -ne $found)
}

# --- 建 Application 与主题字典 ---------------------------------------------
# 窗口里用 DynamicResource 引用主题键，没有字典就是"取不到值"（不报错但显示不完整），
# 而 StaticResource 缺键会直接抛异常 —— 我们的关键检查正是后者。
$app = $null
if ($null -eq [System.Windows.Application]::Current) {
    $app = New-Object System.Windows.Application
}
else {
    $app = [System.Windows.Application]::Current
}

# 主题字典属于 QuickDrawer 程序集，必须用 ";component/" 形式指向它，
# 不能用 ThemeService 里那种 "pack://application:,,,/Themes/Light.xaml" ——
# 那个写法解析到的是**入口程序集**（这里是 PowerShell），会找不到。
try {
    $dict = New-Object System.Windows.ResourceDictionary
    $dict.Source = New-Object Uri 'pack://application:,,,/QuickDrawer;component/Themes/Light.xaml'
    $app.Resources.MergedDictionaries.Insert(0, $dict)
    Check 'theme dictionary loaded' $true
}
catch {
    Check 'theme dictionary loaded' $false $_.Exception.Message
}

# --- 造一张卡片 -------------------------------------------------------------
$item = [System.Activator]::CreateInstance($itemType)
$item.Id = [Guid]::NewGuid().ToString('N')
$item.Title = ''
$item.Text = "第一行`r`n第二行"
$item.Color = 'yellow'
$item.UpdatedAt = [DateTime]::Now

$card = [System.Activator]::CreateInstance($cardType, @($item))
Check 'card created' ($null -ne $card) ("text=" + $card.Text.Replace("`r", '\r').Replace("`n", '\n'))

# --- 关键检查：窗口能不能真的构造出来 --------------------------------------
# 这里如果还引用着 IconButton，会抛 XamlParseException（找不到资源），
# 直接落在下面的 catch 里。
$window = $null
try {
    $ctor = $editorType.GetConstructor($ctorFlags, $null, [Type[]]@($cardType, [System.Windows.Window]), $null)
    Check 'ctor (card, owner) exists' ($null -ne $ctor)

    $window = $ctor.Invoke(@($card, $null))
    Check 'window constructed (XAML resources resolve)' ($null -ne $window)
}
catch {
    $inner = $_.Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    Check 'window constructed (XAML resources resolve)' $false ($inner.GetType().Name + ': ' + $inner.Message)
}

if ($null -eq $window) {
    Write-Host ''
    Write-Host ("RESULT: FAIL ({0} check(s))" -f $script:failures) -ForegroundColor Red
    exit 1
}

# 编辑器自己的资源字典里应该有 EditorToolButton（证明用的是本地样式，不是外部键）
$hasLocalStyle = $false
try {
    $hasLocalStyle = $window.Resources.Contains('EditorToolButton')
}
catch {
    $hasLocalStyle = $false
}
Check 'window defines EditorToolButton locally' $hasLocalStyle

$noteBox = $editorType.GetField('NoteBox', $fieldFlags).GetValue($window)
$statText = $editorType.GetField('StatText', $fieldFlags).GetValue($window)
Check 'NoteBox / StatText fields resolved' (($null -ne $noteBox) -and ($null -ne $statText))

Check 'editor loaded card text' ($noteBox.Text -eq $card.Text) ("box=" + $noteBox.Text.Replace("`r", '\r').Replace("`n", '\n'))

# --- 落盘回调 ----------------------------------------------------------------
$script:saveCount = 0

# PowerShell 里不能直接给 Action 属性赋 scriptblock 之外的东西，
# 但 [Action] 类型转换会把 scriptblock 包成委托。
$window.NotesSaveRequested = [Action]{ $script:saveCount++ }

# --- 显示（离屏）再关闭 ------------------------------------------------------
# 不 Show 就 Close 在部分 WPF 版本上不会触发 Closed，所以这里真的显示到屏幕外。
$window.WindowStartupLocation = 'Manual'
$window.Left = -4000
$window.Top = -4000
$window.ShowInTaskbar = $false
try {
    $window.Show()
    Check 'window shown' $true
}
catch {
    $inner = $_.Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    Check 'window shown' $false ($inner.GetType().Name + ': ' + $inner.Message)
}

# 改正文，然后走「完成」按钮那条路径
$noteBox.Text = "改过的正文`r`n第二行"
$noteBox.CaretIndex = $noteBox.Text.Length

# 字数统计是 DispatcherPriority.Background 异步刷新的，得把队列跑空
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
    [Action]{},
    [System.Windows.Threading.DispatcherPriority]::Background)

Check 'stat text updated' ($statText.Text -like '*字*行*') ("stat='" + $statText.Text + "'")

# 插入时间：光标在末尾，应补一个换行再插
$script:insertMethod = $editorType.GetMethod('InsertTime_Click', $methodFlags)
$before = $noteBox.Text
$script:insertMethod.Invoke($window, @($null, $null))
$after = $noteBox.Text
$stampOk = ($after.Length -gt $before.Length) -and ($after -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}')
Check 'insert time stamps at caret' $stampOk ("tail='" + $after.Substring([Math]::Max(0, $after.Length - 20)).Replace("`r", '\r').Replace("`n", '\n') + "'")

$edited = $noteBox.Text

# 走「完成」按钮 → Close() → OnClosed → SaveToCard
$doneMethod = $editorType.GetMethod('Done_Click', $methodFlags)
$doneMethod.Invoke($window, @($null, $null))

Check 'save callback fired once' ($script:saveCount -eq 1) ("count=" + $script:saveCount)
Check 'card text written back' ($card.Text -eq $edited) ("card=" + $card.Text.Replace("`r", '\r').Replace("`n", '\n'))

# 再调一次 SaveToCard，_saved 守卫应该拦住（不能重复落盘）
$saveToCard = $editorType.GetMethod('SaveToCard', $methodFlags)
$saveToCard.Invoke($window, @())
Check 'no double save' ($script:saveCount -eq 1) ("count=" + $script:saveCount)

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host ("RESULT: PASS ({0} checks)" -f $script:checks) -ForegroundColor Green
    exit 0
}
Write-Host ("RESULT: FAIL ({0} check(s))" -f $script:failures) -ForegroundColor Red
exit 1
