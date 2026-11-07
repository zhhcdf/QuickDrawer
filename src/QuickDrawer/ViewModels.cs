using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;

namespace QuickDrawer;

/// <summary>
/// 应用磁贴 ViewModel（第一区）。
/// 决策 #1：图标小、无文字标签，名称通过 ToolTip 悬停显示。
/// </summary>
public sealed class AppTileViewModel : INotifyPropertyChanged
{
    private BitmapSource? _icon;

    public ShortcutItem Model { get; }

    public string Name => Model.Name;

    public BitmapSource? Icon => _icon ??= IconService.GetAppIcon(Model.Target) ?? IconService.Fallback();

    public AppTileViewModel(ShortcutItem model) => Model = model;

    public event PropertyChangedEventHandler? PropertyChanged;

    public void RefreshIcon()
    {
        _icon = null;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Icon)));
    }
}

/// <summary>
/// 路径项 ViewModel（第二区，分类内的一项）。
/// 属性全部来自 Model 且运行期不变，故不需要 INotifyPropertyChanged。
/// </summary>
public sealed class PathItemViewModel
{
    private BitmapSource? _icon;

    public ShortcutItem Model { get; }

    public string Name => Model.Name;

    public string Target => Model.Target;

    public BitmapSource? Icon => _icon ??= IconService.GetIcon(Model.Target, Model.Kind) ?? IconService.Fallback();

    /// <summary>
    /// 对应的 Button 实例，由 DrawerWindow 在布局加载后回填。
    /// 用途：切换"图标 / 列表"布局时直接替换 Button.Content（2026-10-19）。
    /// </summary>
    public Button? Button { get; set; }

    public PathItemViewModel(ShortcutItem model) => Model = model;
}

/// <summary>
/// 分类 ViewModel（第二区）。持有分类元数据与该分类下的路径项。
/// </summary>
public sealed class CategoryViewModel : INotifyPropertyChanged
{
    private bool _expanded;

    public PathCategory Model { get; }

    public string Id => Model.Id;

    public string Name => Model.Name;

    /// <summary>
    /// 搜索中：强制展开，让命中项可见。
    /// 只影响显示，**不改写** Model.Expanded —— 否则搜完一次就把用户的折叠状态永久改掉了。
    /// </summary>
    public bool SearchExpand { get; set; }

    /// <summary>
    /// 由搜索逻辑调用：强制展开 / 恢复用户原有状态。
    /// 必须走这个方法而不是直接赋值，否则绑定收不到 <see cref="Expanded"/> 的变化通知。
    /// </summary>
    public void SetSearchExpand(bool value)
    {
        if (SearchExpand == value)
        {
            return;
        }

        SearchExpand = value;
        OnPropertyChanged(nameof(Expanded));
        OnPropertyChanged(nameof(Arrow));
    }

    /// <summary>展开/折叠状态，双向绑定到 ToggleButton。</summary>
    public bool Expanded
    {
        get => SearchExpand || _expanded;
        set
        {
            if (_expanded == value)
            {
                return;
            }

            _expanded = value;
            Model.Expanded = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(Arrow));
        }
    }

    /// <summary>折叠箭头：展开时朝下，折叠时朝右。</summary>
    public string Arrow => Expanded ? "▾" : "▸";

    /// <summary>
    /// 分类内含盘符项（kind=drive）时为真：该分类**强制横向排列**，
    /// 不随全局列表/图标模式切换（2026-10-23 用户需求：盘符固定横排、加宽间距）。
    /// </summary>
    public bool ForceHorizontal => Items.Any(i => i.Model.Kind == "drive");

    public ObservableCollection<PathItemViewModel> Items { get; } = new();

    public CategoryViewModel(PathCategory model)
    {
        Model = model;
        _expanded = model.Expanded;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
