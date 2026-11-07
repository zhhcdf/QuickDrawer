using System.Windows;
using QuickDrawer.Native;

namespace QuickDrawer;

/// <summary>
/// 悬浮条「发送」按钮弹出的自定义提示词编辑器（2026-10-31 需求）。
///
/// 与 <see cref="InputDialog"/> 的区别：这里是**多行**输入，而且发送的
/// 是"提示词 + 选中内容"两段，所以要把选中的预览也显示出来让用户确认。
/// </summary>
public partial class PromptEditorDialog : Window
{
    public string Prompt => PromptBox.Text;

    public PromptEditorDialog(string initialPrompt, string selection)
        : this(initialPrompt, selection, null)
    {
    }

    /// <summary>
    /// <paramref name="hintOverride"/> 用于截图提问（2026-11-01 五次需求）：
    /// 那时没有选中文字，提示行要显示的是"截了多大一块"，由调用方给。
    /// </summary>
    public PromptEditorDialog(string initialPrompt, string selection, string? hintOverride)
    {
        InitializeComponent();
        // 深色主题下标题栏不跟着变色会很割裂，DWM 只能在句柄建好之后设。
        SourceInitialized += (_, _) => ThemeService.ApplyWindowChrome(this);

        PromptBox.Text = initialPrompt;
        SelectionHint.Text = hintOverride ?? BuildHint(selection);
    }

    private static string BuildHint(string selection)
    {
        if (string.IsNullOrWhiteSpace(selection))
        {
            return "（没有选中内容，只发这句提示词）";
        }

        string flat = selection.Replace("\r", " ").Replace("\n", " ").Trim();
        if (flat.Length > 80)
        {
            flat = flat.Substring(0, 80) + "…";
        }

        return $"选中内容（{selection.Length} 字）：{flat}";
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        // 2026-10-31（八次）：悬浮条是 WS_EX_NOACTIVATE，点「发送」时进程拿不到
        // 前台权限，ShowDialog() 的激活请求被前台锁拒绝 —— 对话框会停在当前
        // 激活窗口的下一层，输入框也没有光标。XAML 里的 Topmost 只解决 z 序，
        // 这里再用 AttachThreadInput 借前台权限，两件事都要做。
        bool foreground = NativeMethods.ForceForeground(this);
        DiagLog.Write("prompt editor", foreground
            ? "forced to foreground"
            : "could not take foreground (stays topmost only)");

        // 打开就落在提示词末尾，用户能直接接着改；全选反而容易误删
        PromptBox.Focus();
        PromptBox.CaretIndex = PromptBox.Text.Length;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
