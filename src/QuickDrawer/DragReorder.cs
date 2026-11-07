using System.Windows;
using System.Windows.Input;

namespace QuickDrawer;

/// <summary>
/// 拖拽重排的公共逻辑（M3）。
///
/// ⚠️ 关键点（2026-10-20 用户反馈"三项拖拽全都不成功"后修正）：
/// **`DoDragDrop` 必须在 MouseMove 里调用，不能在 DragOver 里调用。**
///
/// 原因：`DragOver` / `Drop` 事件只在 OLE 拖放会话**已经激活**时才会触发，
/// 而会话正是由 `DoDragDrop` 建立的。把 DoDragDrop 写进 DragOver 会形成死锁：
/// 没有会话 → 永远等不到 DragOver → 永远不调用 DoDragDrop → 拖拽无法开始。
///
/// 正确的经典模式：
///   1. PreviewMouseLeftButtonDown  记录按下位置
///   2. PreviewMouseMove           移动超过阈值 → 启动 DoDragDrop
///   3. DragOver（会话中）          只设置 Effects，不启动拖拽
///   4. Drop                        执行重排
/// </summary>
public static class DragReorder
{
    /// <summary>内部重排时携带源对象的数据格式名。</summary>
    public const string DragFormat = "QuickDrawer.ReorderSource";

    private static Point _pressPoint;
    private static FrameworkElement? _pressElement;
    private static bool _buttonDown;

    /// <summary>本次会话是否已经拖过（用于抑制拖拽结束后的误触发 Click）。</summary>
    public static bool DragHappened { get; private set; }

    /// <summary>
    /// 拖拽会话是否正在进行。
    /// Drop 之后必须清掉，否则下一次外部拖入会被误判为"内部重排"。
    /// </summary>
    public static bool SessionActive { get; private set; }

    /// <summary>按下：记录起点与源元素，并记下按键已按下。</summary>
    public static void OnPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        // ⚠️ 必须用**全局鼠标位置**，不能用 e.GetPosition(null)。
        // GetPosition(null) 返回相对源元素原点的坐标：按下时鼠标在元素内（≈0），
        // 移动后仍在元素内（≈几像素），两者差值永远达不到拖拽阈值，
        // 结果就是"拖不动"（2026-10-20 用户反馈的根因）。
        //
        // 也不用 PointToScreen 换算：它依赖元素的变换链，
        // 元素在滚动/动画中时结果不可靠。
        _pressPoint = GetGlobalMousePosition();
        _pressElement = sender as FrameworkElement;
        _buttonDown = true;
        DragHappened = false;
    }

    /// <summary>
    /// 取全局鼠标位置（相对桌面原点）。
    /// 优先用 Mouse.PrimaryDevice 的屏幕坐标；拿不到时退回事件坐标。
    /// </summary>
    private static Point GetGlobalMousePosition()
    {
        try
        {
            // Mouse.GetPosition(null) 相对整个桌面，是稳定的全局坐标。
            return Mouse.GetPosition(null);
        }
        catch
        {
            return default;
        }
    }

    /// <summary>抬起按键：取消拖拽准备状态。</summary>
    public static void OnPreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        _buttonDown = false;
    }

    /// <summary>
    /// 判断移动距离是否超过拖拽启动阈值。
    /// 提取为公开方法，便于用可控坐标做自动化测试
    /// （物理鼠标位置无法在控制台探针里伪造）。
    /// </summary>
    public static bool ExceedsThreshold(Point pressPoint, Point movePoint)
    {
        double dx = Math.Abs(movePoint.X - pressPoint.X);
        double dy = Math.Abs(movePoint.Y - pressPoint.Y);

        return dx >= SystemParameters.MinimumHorizontalDragDistance
            || dy >= SystemParameters.MinimumVerticalDragDistance;
    }

    /// <summary>
    /// 移动：超过阈值才启动拖拽。
    /// 返回 true 表示已启动拖拽，调用方应吞掉这次事件。
    ///
    /// ⚠️ 这里用**自己记录的 _buttonDown**，不用 Mouse.LeftButton：
    ///   - Mouse.LeftButton 读的是系统物理按键状态，在部分场景（远程桌面、
    ///     某些输入设备、UI 自动化）下不可靠；
    ///   - 它也让这段逻辑无法被合成事件测试。
    ///   真实鼠标按下时 PreviewMouseLeftButtonDown 一定先到达，所以自己跟踪是安全的。
    /// </summary>
    public static bool TryStartDrag(object source, MouseEventArgs e)
    {
        if (!_buttonDown)
        {
            return false;
        }

        // 必须是同一个元素上的移动（指针没离开源元素）
        if (_pressElement is not null && !ReferenceEquals(_pressElement, source))
        {
            return false;
        }

        // 移动点也用全局位置，与按下点同坐标系，可直接比较
        Point pos = GetGlobalMousePosition();

        if (!ExceedsThreshold(_pressPoint, pos))
        {
            return false;
        }

        // 把源对象放进 DataObject，落点处就能取回它
        DataObject data = new();
        data.SetData(DragFormat, source);

        DragHappened = true;
        SessionActive = true;
        _pressElement = null;

        // DoDragDrop 是模态的：拖拽结束（放下或按 Esc）后才返回
        DragDrop.DoDragDrop((DependencyObject)source, data, DragDropEffects.Move);

        SessionActive = false;
        _buttonDown = false;
        return true;
    }

    /// <summary>拖拽结束后清理状态（在下一次按下时重置）。</summary>
    public static void Reset()
    {
        _pressElement = null;
        _buttonDown = false;
        DragHappened = false;
        SessionActive = false;
    }

    /// <summary>把源元素移到目标元素之前（按列表顺序）。</summary>
    public static void MoveBefore<T>(IList<T> list, T source, T target)
    {
        int from = IndexOf(list, source);
        int to = IndexOf(list, target);

        if (from < 0 || to < 0 || from == to)
        {
            return;
        }

        list.RemoveAt(from);

        // 移除后目标索引会前移
        if (from < to)
        {
            to--;
        }

        list.Insert(to, source);
    }

    /// <summary>把源元素移到目标元素之后。</summary>
    public static void MoveAfter<T>(IList<T> list, T source, T target)
    {
        int from = IndexOf(list, source);
        int to = IndexOf(list, target);

        if (from < 0 || to < 0 || from == to)
        {
            return;
        }

        list.RemoveAt(from);

        if (from < to)
        {
            to--;
        }

        list.Insert(to + 1, source);
    }

    private static int IndexOf<T>(IList<T> list, T item)
    {
        for (int i = 0; i < list.Count; i++)
        {
            if (EqualityComparer<T>.Default.Equals(list[i], item))
            {
                return i;
            }
        }

        return -1;
    }

    /// <summary>
    /// 根据落点位置判断是插到目标之前还是之后。
    /// 落点在目标左半边 → 之前；右半边 → 之后。
    ///
    /// ⚠️ 不用 TranslatePoint：它依赖元素已完成布局，未布局时返回错误坐标
    /// （2026-10-20 探针实测卡在这里）。改用元素自身宽度算中点。
    /// </summary>
    public static bool IsBefore(FrameworkElement target, Point dropPoint)
    {
        double width = target.ActualWidth > 0 ? target.ActualWidth : target.Width;
        if (double.IsNaN(width) || width <= 0)
        {
            return true;   // 拿不到宽度时保守地插到前面
        }

        // 落点相对 target 的坐标，取中点比较。
        // 用 <= 让中点归入"之前"：必须确定，不能有时前有时后。
        double mid = width / 2;
        return dropPoint.X <= mid;
    }
}
