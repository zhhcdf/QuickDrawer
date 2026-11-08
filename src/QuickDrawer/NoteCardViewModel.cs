using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace QuickDrawer;

/// <summary>
/// 便签卡片 ViewModel（M4）。
/// 置顶与颜色会改变外观，需要 INotifyPropertyChanged。
/// </summary>
public sealed class NoteCardViewModel : INotifyPropertyChanged
{
    private bool _pinned;
    private string _color;

    public NoteItem Model { get; }

    public string Id => Model.Id;

    public string Text
    {
        get => Model.Text;
        set
        {
            if (Model.Text == value)
            {
                return;
            }

            Model.Text = value;
            Model.UpdatedAt = DateTime.Now;
            OnPropertyChanged();
            OnPropertyChanged(nameof(Preview));
        }
    }

    public bool Pinned
    {
        get => _pinned;
        set
        {
            if (_pinned == value)
            {
                return;
            }

            _pinned = value;
            Model.Pinned = value;
            Model.UpdatedAt = DateTime.Now;
            OnPropertyChanged();
            OnPropertyChanged(nameof(PinGlyph));
            OnPropertyChanged(nameof(PinToolTip));
            OnPropertyChanged(nameof(DeleteToolTip));
        }
    }

    /// <summary>
    /// 卡片名称（2026-10-25 需求）：卡片工具栏最左侧的编辑框。
    /// 只是标签，不参与排序；为空时显示占位提示。
    /// </summary>
    public string Title
    {
        get => Model.Title;
        set
        {
            value ??= "";

            if (Model.Title == value)
            {
                return;
            }

            Model.Title = value;
            Model.UpdatedAt = DateTime.Now;
            OnPropertyChanged();
            OnPropertyChanged(nameof(TitlePlaceholder));
        }
    }

    /// <summary>名称占位提示：名称为空时显示。</summary>
    public Visibility TitlePlaceholder
        => string.IsNullOrEmpty(Model.Title) ? Visibility.Visible : Visibility.Collapsed;

    public string Color
    {
        get => _color;
        set
        {
            if (_color == value)
            {
                return;
            }

            _color = value;
            Model.Color = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CardBackground));
            OnPropertyChanged(nameof(HeaderBackground));
        }
    }

    /// <summary>
    /// 卡片背景色（由颜色标签决定）。
    /// 2026-10-22：从"固定 hex"改为**主题资源键**（TryFindResource），
    /// 跟随系统深浅色 —— 浅色主题下色板是柔和浅色，深色下是暗色。
    /// </summary>
    public Brush CardBackground
    {
        get
        {
            string key = Color switch
            {
                "green" => "NoteGreen",
                "blue" => "NoteBlue",
                "pink" => "NotePink",
                "gray" => "NoteGray",
                _ => "NoteYellow"
            };

            if (System.Windows.Application.Current?.TryFindResource(key) is Brush brush)
            {
                return brush;
            }

            // 主题字典未加载时兜底（理论不可达）
            return NoteColorConverter.BrushFromHex(NoteStore.ColorBrush(Color));
        }
    }

    /// <summary>
    /// 标题工具栏底色（2026-11-05 用户需求：比正文底色深一点）。
    /// 与 <see cref="CardBackground"/> 同源，只是换到 Note*Header 这一档更深的主题键，
    /// 因此切换卡片颜色时标题栏与正文一起变，深浅两套主题各自成立。
    /// </summary>
    public Brush HeaderBackground
    {
        get
        {
            string key = Color switch
            {
                "green" => "NoteGreenHeader",
                "blue" => "NoteBlueHeader",
                "pink" => "NotePinkHeader",
                "gray" => "NoteGrayHeader",
                _ => "NoteYellowHeader"
            };

            if (System.Windows.Application.Current?.TryFindResource(key) is Brush brush)
            {
                return brush;
            }

            // 主题字典未加载时退回正文底色（理论不可达），不至于画出透明/黑色块
            return CardBackground;
        }
    }

    /// <summary>
    /// 置顶/锁定按钮字形：未锁定 📌（仅置顶），已锁定 🔒（置顶 + 不被删除/清空）。
    /// 2026-10-25 需求：置顶按钮同时充当"锁定"，样式必须能看出当前状态。
    /// </summary>
    public string PinGlyph => Pinned ? "🔒" : "📌";

    /// <summary>置顶/锁定按钮的提示文案，随状态变化。</summary>
    public string PinToolTip => Pinned
        ? "已锁定：置顶中，不会被删除或清空。点击解锁"
        : "置顶并锁定（不被删除和清空）";

    /// <summary>删除按钮的提示：锁定后先提示需要解锁。</summary>
    public string DeleteToolTip => Pinned
        ? "已锁定，先点锁解锁才能删除"
        : "删除此卡片";

    /// <summary>锁定状态下删除按钮半透明（仍可点，点了会给提示）。</summary>
    public double DeleteOpacity => Pinned ? 0.35 : 1.0;

    /// <summary>空卡片占位提示。</summary>
    public string Preview => string.IsNullOrWhiteSpace(Text) ? "空卡片…" : "";

    public NoteCardViewModel(NoteItem model)
    {
        Model = model;
        _pinned = model.Pinned;
        _color = model.Color;
    }

    /// <summary>保存后由父级调用：置顶/颜色变化后刷新派生属性。</summary>
    public void RefreshDerived()
    {
        OnPropertyChanged(nameof(CardBackground));
        OnPropertyChanged(nameof(HeaderBackground));
        OnPropertyChanged(nameof(PinGlyph));
        OnPropertyChanged(nameof(PinToolTip));
        OnPropertyChanged(nameof(DeleteToolTip));
        OnPropertyChanged(nameof(DeleteOpacity));
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(TitlePlaceholder));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name ?? ""));
}

/// <summary>
/// 便签卡片集合（M4）：持有全部卡片并负责持久化时机。
/// </summary>
public sealed class NotesViewModel
{
    private readonly Action _save;

    public ObservableCollection<NoteCardViewModel> Cards { get; } = new();

    public NotesViewModel(Action save)
    {
        _save = save;
    }

    public void LoadFrom(IEnumerable<NoteItem> items)
    {
        Cards.Clear();
        foreach (NoteItem item in items)
        {
            Cards.Add(new NoteCardViewModel(item));
        }
    }

    public NoteCardViewModel AddNew()
    {
        var note = new NoteItem { Text = "", Color = "yellow" };
        var vm = new NoteCardViewModel(note);
        Cards.Insert(0, vm);
        _save();
        return vm;
    }

    public void Remove(NoteCardViewModel card)
    {
        Cards.Remove(card);
        _save();
    }

    public void TogglePin(NoteCardViewModel card)
    {
        card.Pinned = !card.Pinned;
        Sort();
        _save();
    }

    /// <summary>
    /// 重排：置顶在前，组内按更新时间倒序。
    /// 2026-11-08：从 TogglePin 里提出来变成公开方法 —— 独立编辑器关闭时
    /// 会把 Model.UpdatedAt 刷新，卡片的应然位置也跟着变，那边需要同一套排序。
    /// 用 Cards.Move 而不是重新赋 ItemsSource，否则 ListBox 会整体重建、丢滚动位置。
    /// </summary>
    public void Sort()
    {
        var ordered = NoteStore.Sort(Cards.Select(c => c.Model).ToList());
        var orderedVms = ordered
            .Select(m => Cards.First(c => c.Id == m.Id))
            .ToList();

        int index = 0;
        foreach (NoteCardViewModel vm in orderedVms)
        {
            Cards.Move(Cards.IndexOf(vm), index);
            index++;
        }
    }

    public void SetColor(NoteCardViewModel card, string color)
    {
        card.Color = color;
        _save();
    }

    public List<NoteItem> ToModels()
        => Cards.Select(c => c.Model).ToList();
}
