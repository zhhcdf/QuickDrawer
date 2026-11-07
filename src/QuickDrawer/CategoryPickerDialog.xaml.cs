using System.Windows;
using System.Windows.Controls;

namespace QuickDrawer;

/// <summary>
/// 分类选择对话框（问题 4）。
/// 之前添加路径只能进"我的电脑"，因为代码硬编码取了第一个分类。
/// 这里让用户明确选择要加到哪个分类，并支持顺手新建。
/// </summary>
public partial class CategoryPickerDialog : Window
{
    private readonly List<PathCategory> _categories;

    /// <summary>用户最终选中的分类。</summary>
    public PathCategory? Selected { get; private set; }

    public CategoryPickerDialog(List<PathCategory> categories, string title = "选择分类")
    {
        InitializeComponent();
        // 深色主题下标题栏不跟着变色会很割裂，DWM 只能在句柄建好之后设。
        SourceInitialized += (_, _) => ThemeService.ApplyWindowChrome(this);
        _categories = categories;
        Title = title;

        foreach (var c in categories.OrderBy(c => c.Order))
        {
            var item = new ListBoxItem
            {
                Content = c.Name,
                Tag = c
            };
            CategoryList.Items.Add(item);
        }

        if (CategoryList.Items.Count > 0)
        {
            CategoryList.SelectedIndex = 0;
        }
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        if (CategoryList.SelectedItem is ListBoxItem { Tag: PathCategory cat })
        {
            Selected = cat;
            DialogResult = true;
            Close();
            return;
        }

        MessageBox.Show(this, "请选择一个分类。", "QuickDrawer",
            MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void New_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new InputDialog("新建分类", "分类名称：", "新分类") { Owner = this };
        if (dlg.ShowDialog() != true || string.IsNullOrWhiteSpace(dlg.Answer))
        {
            return;
        }

        var cat = new PathCategory
        {
            Name = dlg.Answer.Trim(),
            Order = _categories.Count
        };
        _categories.Add(cat);

        var item = new ListBoxItem { Content = cat.Name, Tag = cat };
        CategoryList.Items.Add(item);
        CategoryList.SelectedItem = item;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}