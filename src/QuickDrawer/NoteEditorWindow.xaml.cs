using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using QuickDrawer.Native;

namespace QuickDrawer;

/// <summary>
/// 便签的独立纯文本编辑器（2026-11-08 用户需求）。
///
/// 需求原文："我想给便签卡片增加一个双击区域（或者单击按钮）打开一个独立编辑器
///           进行文字编辑，关闭自动保存为便签的功能。"
/// 用户澄清（同一轮）：
///   - 「不要富文本元素了，编辑器也是纯文本。保持卡片本身也能编辑」
///   - 「不要富文本相关的工具了」
///
/// 所以这里**不是**记事本那种带格式的编辑器，而是一个纯粹的放大编辑区：
/// 卡片正文只有 150px 高（App.xaml 的 NoteBodyMaxHeight），写长一点就要在小窗里
/// 反复滚动；独立窗口把这件事解决掉，同时保持数据仍是 <see cref="NoteItem.Text"/>
/// 这一个 string —— 不改 notes.json 格式、不改搜索、不改预览。
///
/// 保存时机：**关闭即保存**（用户选了这一项）。不留"未保存就要丢"的窗口：
///   - 点「完成」→ Close() → Closed 事件里回写
///   - 点标题栏 ✕  → 同上
///   - 按 Esc       → Close()
/// 只在一个地方落盘（<see cref="SaveToCard"/>），避免三条路径各写一遍。
/// </summary>
public partial class NoteEditorWindow : Window
{
    private readonly NoteCardViewModel _card;

    /// <summary>
    /// 这张编辑器正在编辑的卡片。宿主（<see cref="DrawerWindow.OpenNoteEditor"/>）
    /// 用它判断"再点一次同一张卡"应该激活已有窗口而不是另开一个。
    /// </summary>
    public NoteCardViewModel Card => _card;

    /// <summary>防止 Closed 在构造失败/重复触发时二次写回。</summary>
    private bool _saved;

    /// <summary>
    /// <paramref name="owner"/>：面板窗口。<see cref="WindowStartupLocation.Manual"/> +
    /// 手工定位是为了把编辑窗口放在**卡片所在的显示器**上 —— 多显示器时
    /// CenterOwner 会跟着面板跑到另一块屏，用户刚双击的那张卡反而看不见了。
    /// </summary>
    public NoteEditorWindow(NoteCardViewModel card, Window? owner)
    {
        InitializeComponent();

        _card = card;

        // 深色主题下标题栏不跟着变色会很割裂，DWM 只能在句柄建好之后设。
        SourceInitialized += (_, _) => ThemeService.ApplyWindowChrome(this);

        if (owner is not null)
        {
            // 不用 Owner 绑定（会把编辑窗口钉在面板之上，面板收起后编辑窗口也跟着隐藏），
            // 只借它算位置。
            Rect work = NativeMethods.GetWorkAreaForCursor();
            PlaceOn(work);
        }

        Title = string.IsNullOrWhiteSpace(card.Title) ? "便签" : card.Title;
        NoteBox.Text = card.Text;

        // 载入后光标放到末尾（与卡片内双击进入编辑态的行为一致），
        // 用户多半是想接着写，而不是回头改开头。
        Loaded += (_, _) =>
        {
            NoteBox.Focus();
            NoteBox.CaretIndex = NoteBox.Text.Length;
            NoteBox.ScrollToEnd();
            UpdateStat();
        };
    }

    /// <summary>
    /// 把窗口摆在光标所在显示器的中偏右，并夹在 work area 内（多显示器/高 DPI 下
    /// 副屏可能是负坐标，不能假设 0,0 是左上角）。
    /// </summary>
    private void PlaceOn(Rect work)
    {
        Width = Math.Max(MinWidth, Math.Min(760, work.Width * 0.4));
        Height = Math.Max(MinHeight, Math.Min(640, work.Height * 0.7));

        double left = work.Left + (work.Width - Width) / 2;
        double top = work.Top + (work.Height - Height) / 2;

        // 相对面板往左让一点，避免正好盖住卡片列表
        Left = Math.Max(work.Left + 16, left - work.Width * 0.08);
        Top = Math.Max(work.Top + 16, top);
        WindowStartupLocation = WindowStartupLocation.Manual;
    }

    protected override void OnClosed(EventArgs e)
    {
        // 唯一落盘点：无论从哪条路径关掉，都在这里写回卡片。
        SaveToCard();
        base.OnClosed(e);
    }

    private void SaveToCard()
    {
        if (_saved)
        {
            return;
        }

        _saved = true;

        string text = NoteBox.Text ?? "";

        // 没改过就不写盘。否则"打开看一眼就关掉"也会重写 notes.json，
        // 而这份文件是用户数据，无故改写会白白刷掉 mtime、多一次落盘失败的风险。
        if (_card.Text == text)
        {
            return;
        }

        // 走 ViewModel 的 setter：它会更新 UpdatedAt 并触发 PropertyChanged，
        // 卡片正文（双向绑同一属性）因此立即刷新，不用手动重建列表。
        _card.Text = text;

        // 落盘。SaveNotesToDisk 由宿主注入的回调负责，失败会弹提示，
        // 所以这里不额外处理返回值。
        NotesSaveRequested?.Invoke();
    }

    /// <summary>
    /// 请求宿主把便签集合写盘。由 <see cref="DrawerWindow"/> 在打开编辑器时注入，
    /// 这样编辑器不用知道 NoteStore 的存在，也避免重复实现"保存失败要提示"的路径。
    /// </summary>
    public Action? NotesSaveRequested { get; set; }

    private void Done_Click(object sender, RoutedEventArgs e) => Close();

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        // Esc 关闭即保存，与点 ✕ 等价。不弹"确定放弃吗" —— 用户要的就是
        // "关闭自动保存"，再追问一次等于把简单操作复杂化。
        if (e.Key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None)
        {
            Close();
            e.Handled = true;
        }
    }

    private void Undo_Click(object sender, RoutedEventArgs e) => NoteBox.Undo();

    private void Redo_Click(object sender, RoutedEventArgs e) => NoteBox.Redo();

    /// <summary>在光标处插入当前日期时间 —— 纯文本便签最常用的"工具"。</summary>
    private void InsertTime_Click(object sender, RoutedEventArgs e)
    {
        string stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm");
        int caret = NoteBox.CaretIndex;

        // 避免紧贴着已有序号/文字拼在一起：光标前不是行首就补一个换行
        bool atLineStart = caret == 0 || NoteBox.Text[caret - 1] == '\n';
        string insert = atLineStart ? stamp + " " : Environment.NewLine + stamp + " ";

        NoteBox.Text = NoteBox.Text.Insert(caret, insert);
        NoteBox.CaretIndex = caret + insert.Length;
        NoteBox.Focus();
    }

    private void NoteBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
        => UpdateStat();

    /// <summary>
    /// 字数 / 行数统计。用 Dispatcher.BeginInvoke 而不是同步刷新：
    /// TextChanged 在大段粘贴时会连续触发，同步统计等于每敲一个字符扫一遍全文。
    /// </summary>
    private bool _statPending;

    private void UpdateStat()
    {
        if (_statPending)
        {
            return;
        }

        _statPending = true;
        Dispatcher.BeginInvoke(
            new Action(() =>
            {
                _statPending = false;
                string text = NoteBox.Text ?? "";
                int chars = text.Length;
                int lines = text.Length == 0 ? 1 : text.Count(c => c == '\n') + 1;
                StatText.Text = $"{chars} 字 · {lines} 行";
            }),
            DispatcherPriority.Background);
    }
}
