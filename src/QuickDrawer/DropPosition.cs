using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace QuickDrawer;

/// <summary>
/// 重排落点计算：按**容器**里的几何位置算出"应该插到第几项"。
///
/// ⚠️ 为什么要按容器算，而不是按"落在哪个项上"算（2026-10-20 用户反馈）：
///   - 依赖"落在具体项上"时，必须把指针移出源项才能触发下一个项的 Drop，
///     列表模式行高很大 → 位移距离过大；
///   - 最后一项之下没有任何项可落 → 永远放不到末尾。
///
/// 正确做法：拿到指针在容器里的坐标，与每个子项的中线比较，
/// 得出插入下标。这样：
///   - 指针只要越过相邻项的中线就能改变插入位置，位移小；
///   - 容器底部（最后一项之下）自然算出"插到末尾"。
/// </summary>
public static class DropPosition
{
    /// <summary>
    /// 计算指针应该插入到 items 的哪个下标。
    /// </summary>
    /// <param name="container">容器（Panel），坐标以此为基准</param>
    /// <param name="pointInContainer">指针在容器内的坐标</param>
    /// <param name="children">容器的子元素（与 items 一一对应）</param>
    /// <returns>插入下标，范围 [0, children.Count]</returns>
    public static int ComputeIndex(Panel container, Point pointInContainer,
        IReadOnlyList<FrameworkElement> children)
    {
        if (children.Count == 0)
        {
            return 0;
        }

        bool horizontal = IsHorizontal(container, children);

        if (!horizontal)
        {
            // ---- 纵向列表：逐项比较 Y 中线 ----
            for (int i = 0; i < children.Count; i++)
            {
                Point origin = children[i].TranslatePoint(new Point(0, 0), container);
                double mid = origin.Y + children[i].ActualHeight / 2;

                if (pointInContainer.Y < mid)
                {
                    return i;
                }
            }

            return children.Count;   // 落在最后一项之下 → 插到末尾
        }

        // ---- 横向网格：先按行分组，再在行内比较 X 中线 ----
        // ⚠️ 不能只比较 X：第二行的项 X 坐标也是从 0 开始，
        // 只看 X 会把第二行误判成第一行（2026-10-20 探针实测：期望 4 得到 0）。
        List<(List<FrameworkElement> row, double rowTop, double rowBottom)> rows =
            BuildRows(container, children);

        for (int r = 0; r < rows.Count; r++)
        {
            (List<FrameworkElement> row, double rowTop, double rowBottom) = rows[r];

            // 指针在当前行之上 → 插到这一行的第一项
            if (pointInContainer.Y < rowTop)
            {
                return IndexOfChild(children, row[0]);
            }

            // 指针在当前行之内 → 在行内比较 X
            if (pointInContainer.Y <= rowBottom)
            {
                for (int i = 0; i < row.Count; i++)
                {
                    Point origin = row[i].TranslatePoint(new Point(0, 0), container);
                    double mid = origin.X + row[i].ActualWidth / 2;

                    if (pointInContainer.X < mid)
                    {
                        return IndexOfChild(children, row[i]);
                    }
                }

                // 在本行末尾 → 插到本行最后一项之后
                return IndexOfChild(children, row[row.Count - 1]) + 1;
            }
        }

        // 落在所有行之下 → 插到末尾
        return children.Count;
    }

    /// <summary>把子元素按行分组（同一行的元素 Y 相同）。</summary>
    private static List<(List<FrameworkElement> row, double rowTop, double rowBottom)>
        BuildRows(Panel container, IReadOnlyList<FrameworkElement> children)
    {
        var rows = new List<(List<FrameworkElement>, double, double)>();
        List<FrameworkElement> current = new();
        double currentTop = double.NaN;
        double currentBottom = double.NaN;
        double tolerance = 0.0;

        foreach (FrameworkElement child in children)
        {
            Point origin = child.TranslatePoint(new Point(0, 0), container);
            double top = origin.Y;
            double bottom = origin.Y + child.ActualHeight;

            if (current.Count == 0)
            {
                current.Add(child);
                currentTop = top;
                currentBottom = bottom;
                tolerance = Math.Max(1.0, child.ActualHeight / 2);
                continue;
            }

            if (Math.Abs(top - currentTop) <= tolerance)
            {
                current.Add(child);
                currentBottom = Math.Max(currentBottom, bottom);
            }
            else
            {
                rows.Add((current, currentTop, currentBottom));
                current = new List<FrameworkElement> { child };
                currentTop = top;
                currentBottom = bottom;
                tolerance = Math.Max(1.0, child.ActualHeight / 2);
            }
        }

        if (current.Count > 0)
        {
            rows.Add((current, currentTop, currentBottom));
        }

        return rows;
    }

    /// <summary>找到某个子元素在原列表中的下标。</summary>
    private static int IndexOfChild(IReadOnlyList<FrameworkElement> children, FrameworkElement target)
    {
        for (int i = 0; i < children.Count; i++)
        {
            if (ReferenceEquals(children[i], target))
            {
                return i;
            }
        }

        return 0;
    }

    /// <summary>判断容器是横向排列还是纵向排列。</summary>
    public static bool IsHorizontal(Panel container, IReadOnlyList<FrameworkElement> children)
    {
        if (children.Count < 2)
        {
            // 只有一个项时，看它的宽高比：宽大于高说明是横向的一格
            FrameworkElement only = children[0];
            return only.ActualWidth > only.ActualHeight;
        }

        // 第二个项的 X 与第一个项接近 → 同一行，横向排列
        Point o0 = children[0].TranslatePoint(new Point(0, 0), container);
        Point o1 = children[1].TranslatePoint(new Point(0, 0), container);

        bool sameRow = Math.Abs(o1.Y - o0.Y) < Math.Max(1.0, children[0].ActualHeight / 2);
        bool sideBySide = Math.Abs(o1.X - o0.X) > Math.Max(1.0, children[0].ActualWidth / 2);

        return sameRow && sideBySide;
    }

    /// <summary>取容器下所有对应 items 的可视子元素（按可视顺序）。</summary>
    public static List<FrameworkElement> GetVisualChildren(Panel container)
    {
        var result = new List<FrameworkElement>();

        foreach (UIElement child in container.Children)
        {
            if (child is FrameworkElement fe && fe.Visibility == Visibility.Visible)
            {
                result.Add(fe);
            }
        }

        return result;
    }

    /// <summary>找到承载某个 item 的可视元素（通过 DataContext 匹配）。</summary>
    public static FrameworkElement? FindVisualFor(Panel container, object dataContext)
    {
        foreach (UIElement child in container.Children)
        {
            if (child is FrameworkElement fe && fe.DataContext == dataContext)
            {
                return fe;
            }
        }

        return null;
    }

    /// <summary>
    /// 从一个元素**向上**找到承载它的 Panel。
    /// 用于：已知某个子项元素，找它所在的 Panel。
    /// </summary>
    public static Panel? FindPanel(DependencyObject start)
    {
        DependencyObject? current = start;

        while (current is not null)
        {
            if (current is Panel panel)
            {
                return panel;
            }

            current = VisualTreeHelper.GetParent(current);
        }

        return null;
    }

    /// <summary>
    /// 从一个元素**向下**找到它内部的第一个 Panel。
    /// 用于：ItemsControl → 它的 ItemsPanel（WrapPanel）。
    /// </summary>
    public static Panel? FindPanelBelow(DependencyObject start)
    {
        int count = VisualTreeHelper.GetChildrenCount(start);

        for (int i = 0; i < count; i++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(start, i);

            if (child is Panel panel)
            {
                return panel;
            }

            Panel? deeper = FindPanelBelow(child);
            if (deeper is not null)
            {
                return deeper;
            }
        }

        return null;
    }

    /// <summary>
    /// 取 ItemsControl 内部承载 items 的 Panel。
    /// ⚠️ ContainerFromItem 只有 ListBox/ListView 有，ItemsControl 没有；
    /// 这里用可视树向下查找（ItemsControl 的 ItemsPanel 是它的可视后代）。
    /// </summary>
    public static Panel? GetItemsPanel(ItemsControl host)
    {
        // ListBox 的 ItemsPanel 在 ScrollViewer 里，需要向下多找一层。
        Panel? found = FindPanelBelow(host);
        if (found is not null)
        {
            return found;
        }

        // 兜底：从第一个数据项的可视容器反查
        if (host.Items.Count > 0)
        {
            object first = host.Items[0];
            if (host.ItemContainerGenerator.ContainerFromItem(first) is DependencyObject container)
            {
                return FindPanel(container);
            }
        }

        return null;
    }
}
