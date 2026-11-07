using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace QuickDrawer.Selection;

/// <summary>
/// 全屏截图遮罩：冻结屏幕 → 拖框选区 → 裁剪出一张位图（2026-11-01 五次需求「截图提问」）。
///
/// 三个关键设计：
/// 1. **先截屏再显示遮罩**。截图必须在遮罩窗口出现之前拍完，否则拍到的就是遮罩自己
///    （半透明黑幕 + 选区框）。做法是把整块虚拟屏幕一次性拷进位图，再把这张位图
///    当作遮罩的底图画出来——用户看到的是"定格的桌面"，拖动选区时底图不会变。
/// 2. **选区亮、其余暗**。底图上盖一层 60% 黑幕，再用同一张位图叠加一个被矩形
///    Clip 裁过的副本，视觉上就是"选区从暗幕里被擦亮"。比画四条边更简单也更准。
/// 3. **坐标只有一套**：窗口用 DIP 布局（SystemParameters.VirtualScreen* 本来就是 DIP），
///    位图是物理像素，两者之间只乘一次 DPI 比例。不要在中间混用 Win32 屏幕坐标。
///
/// 退出方式：拖框松开且选区够大 → 返回裁剪结果；Esc / 右键 / 选区过小 → 返回 null。
/// </summary>
internal sealed class ScreenshotOverlay : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    private const double MinSelectionDip = 4;

    private readonly BitmapSource _frozen;
    private readonly double _scale;

    private readonly Image _bright;
    private readonly Rectangle _frame;
    private readonly TextBlock _size;
    private readonly Canvas _canvas;

    private Point _from;
    private bool _dragging;
    private Rect _rect;

    /// <summary>拖完框的裁剪结果；取消时为 null。ShowDialog 返回后再读。</summary>
    private BitmapSource? _result;

    private ScreenshotOverlay(BitmapSource frozen, Rect dipBounds, double scale)
    {
        _frozen = frozen;
        _scale = scale;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Background = Brushes.Transparent;
        Cursor = Cursors.Cross;
        // 留个标题：探针要靠 FindWindow 找到这个无边框全屏窗（对用户不可见）
        Title = "QuickDrawer Screenshot";
        Left = dipBounds.Left;
        Top = dipBounds.Top;
        Width = dipBounds.Width;
        Height = dipBounds.Height;

        _canvas = new Canvas
        {
            Width = dipBounds.Width,
            Height = dipBounds.Height,
            Background = Brushes.Transparent
        };

        // 底层：定格的桌面
        _canvas.Children.Add(new Image
        {
            Source = frozen,
            Width = dipBounds.Width,
            Height = dipBounds.Height,
            Stretch = Stretch.Fill,
            IsHitTestVisible = false
        });

        // 暗幕
        _canvas.Children.Add(new Rectangle
        {
            Width = dipBounds.Width,
            Height = dipBounds.Height,
            Fill = new SolidColorBrush(Color.FromArgb(0x99, 0x00, 0x00, 0x00)),
            IsHitTestVisible = false
        });

        // 选区：同一张位图 + 矩形裁剪，形成"被擦亮"的效果
        _bright = new Image
        {
            Source = frozen,
            Width = dipBounds.Width,
            Height = dipBounds.Height,
            Stretch = Stretch.Fill,
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
            Clip = new RectangleGeometry(new Rect(0, 0, 0, 0))
        };
        _canvas.Children.Add(_bright);

        _frame = new Rectangle
        {
            Stroke = new SolidColorBrush(Color.FromRgb(0x3A, 0x7B, 0xD5)),
            StrokeThickness = 1.5,
            Fill = Brushes.Transparent,
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed
        };
        _canvas.Children.Add(_frame);

        _size = new TextBlock
        {
            Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(0xB0, 0x1A, 0x1A, 0x1E)),
            FontSize = 11,
            Padding = new Thickness(5, 2, 5, 2),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed
        };
        _canvas.Children.Add(_size);

        Content = _canvas;

        MouseLeftButtonDown += OnDown;
        MouseMove += OnMove;
        MouseLeftButtonUp += OnUp;
        MouseRightButtonDown += (_, _) => Cancel();
        KeyDown += OnKey;
    }

    /// <summary>弹出遮罩让用户拖框选区；返回裁剪后的位图，取消返回 null。</summary>
    public static BitmapSource? CaptureInteractive()
    {
        double scale = GetDpiForSystem() / 96.0;
        if (scale <= 0)
        {
            scale = 1.0;
        }

        var dip = new Rect(
            SystemParameters.VirtualScreenLeft,
            SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenWidth,
            SystemParameters.VirtualScreenHeight);

        BitmapSource? frozen = FreezeScreen(dip, scale);
        if (frozen is null)
        {
            return null;
        }

        var overlay = new ScreenshotOverlay(frozen, dip, scale);
        overlay.ShowDialog();
        return overlay._result;
    }

    /// <summary>把虚拟屏幕整块拷进位图（物理像素）。失败返回 null，调用方按"取消"处理。</summary>
    private static BitmapSource? FreezeScreen(Rect dip, double scale)
    {
        int width = (int)Math.Round(dip.Width * scale);
        int height = (int)Math.Round(dip.Height * scale);
        int originX = (int)Math.Round(dip.Left * scale);
        int originY = (int)Math.Round(dip.Top * scale);
        if (width <= 0 || height <= 0)
        {
            return null;
        }

        try
        {
            using var bmp = new System.Drawing.Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(
                    new System.Drawing.Point(originX, originY),
                    System.Drawing.Point.Empty,
                    new System.Drawing.Size(width, height),
                    System.Drawing.CopyPixelOperation.SourceCopy);
            }

            IntPtr hbitmap = bmp.GetHbitmap();
            try
            {
                BitmapSource source = System.Windows.Interop.Imaging.CreateBitmapSourceFromHBitmap(
                    hbitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                return source;
            }
            finally
            {
                DeleteObject(hbitmap);
            }
        }
        catch (Exception ex)
        {
            DiagLog.Write("shot", "screen freeze failed: " + ex.Message);
            return null;
        }
    }

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        _from = e.GetPosition(_canvas);
        _rect = new Rect(_from, _from);
        _dragging = true;
        UpdateSelectionVisual();
        CaptureMouse();
        e.Handled = true;
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        UpdateSelection(e.GetPosition(_canvas));
    }

    private void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        _dragging = false;
        ReleaseMouseCapture();
        UpdateSelection(e.GetPosition(_canvas));

        if (_rect.Width < MinSelectionDip || _rect.Height < MinSelectionDip)
        {
            Cancel();
            return;
        }

        _result = Crop(_rect);
        DialogResult = _result is not null;
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Cancel();
            e.Handled = true;
            return;
        }

        if (e.Key == Key.Enter && _rect.Width >= MinSelectionDip && _rect.Height >= MinSelectionDip)
        {
            _result = Crop(_rect);
            DialogResult = _result is not null;
            e.Handled = true;
        }
    }

    private void Cancel()
    {
        _result = null;
        DialogResult = false;
    }

    private void UpdateSelection(Point current)
    {
        _rect = new Rect(_from, current);
        _rect.Intersect(new Rect(0, 0, _canvas.Width, _canvas.Height));
        UpdateSelectionVisual();
    }

    private void UpdateSelectionVisual()
    {
        if (_rect.Width <= 0 || _rect.Height <= 0)
        {
            _bright.Visibility = Visibility.Collapsed;
            _frame.Visibility = Visibility.Collapsed;
            _size.Visibility = Visibility.Collapsed;
            return;
        }

        _bright.Visibility = Visibility.Visible;
        _bright.Clip = new RectangleGeometry(_rect);

        _frame.Visibility = Visibility.Visible;
        Canvas.SetLeft(_frame, _rect.X);
        Canvas.SetTop(_frame, _rect.Y);
        _frame.Width = _rect.Width;
        _frame.Height = _rect.Height;

        int w = (int)Math.Round(_rect.Width * _scale);
        int h = (int)Math.Round(_rect.Height * _scale);
        _size.Text = $"{w} × {h}";
        _size.Visibility = Visibility.Visible;

        // 尺寸提示放在选区上方，越界就挪到选区下沿内侧
        double labelTop = _rect.Y - 22;
        if (labelTop < 2)
        {
            labelTop = _rect.Y + _rect.Height + 4;
        }

        Canvas.SetLeft(_size, _rect.X + 2);
        Canvas.SetTop(_size, labelTop);
    }

    private BitmapSource? Crop(Rect dipRect)
    {
        int x = (int)Math.Round(dipRect.X * _scale);
        int y = (int)Math.Round(dipRect.Y * _scale);
        int w = (int)Math.Round(dipRect.Width * _scale);
        int h = (int)Math.Round(dipRect.Height * _scale);

        x = Compat.Clamp(x, 0, Math.Max(0, _frozen.PixelWidth - 1));
        y = Compat.Clamp(y, 0, Math.Max(0, _frozen.PixelHeight - 1));
        w = Compat.Clamp(w, 1, _frozen.PixelWidth - x);
        h = Compat.Clamp(h, 1, _frozen.PixelHeight - y);

        try
        {
            var crop = new CroppedBitmap(_frozen, new Int32Rect(x, y, w, h));
            crop.Freeze();
            DiagLog.Write("shot", $"cropped {w}x{h} at {x},{y} from {_frozen.PixelWidth}x{_frozen.PixelHeight}");
            return crop;
        }
        catch (Exception ex)
        {
            DiagLog.Write("shot", $"crop failed ({w}x{h} at {x},{y}): {ex.Message}");
            return null;
        }
    }
}
