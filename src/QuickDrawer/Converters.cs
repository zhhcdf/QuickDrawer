using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace QuickDrawer;

/// <summary>bool → Visibility。true 为 Visible，false 为 Collapsed。</summary>
public sealed class BoolToVisConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => value is true ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => value is Visibility.Visible;
}

/// <summary>
/// 颜色标签名（yellow/green/blue/pink/gray）→ 色板小圆点的 Brush。
/// M4：便签卡片颜色选择用。
/// </summary>
public sealed class NoteColorConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        // 2026-10-22：色板圆点走主题资源（跟随系统深浅色）
        string color = value as string ?? "yellow";
        string key = color switch
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

        return BrushFromHex(NoteStore.ColorBrush(color));
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();

    internal static Brush BrushFromHex(string hex)
        => (Brush)(new BrushConverter().ConvertFromString(hex)
           ?? throw new InvalidOperationException($"bad color hex: {hex}"));
}
