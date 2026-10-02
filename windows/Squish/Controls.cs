using System.Collections;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Squish;

/// A row of text options. In the plain style the selected one is ink with an
/// accent underline; in the segmented style it's a solid ink block.
public class OptionRow : StackPanel
{
    public static readonly DependencyProperty OptionsProperty = DependencyProperty.Register(
        nameof(Options), typeof(IEnumerable), typeof(OptionRow), new PropertyMetadata(null, (d, _) => ((OptionRow)d).Rebuild()));

    public static readonly DependencyProperty SelectedProperty = DependencyProperty.Register(
        nameof(Selected), typeof(object), typeof(OptionRow),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, (d, _) => ((OptionRow)d).Update()));

    public static readonly DependencyProperty SegmentedProperty = DependencyProperty.Register(
        nameof(Segmented), typeof(bool), typeof(OptionRow), new PropertyMetadata(false, (d, _) => ((OptionRow)d).Rebuild()));

    public IEnumerable? Options { get => (IEnumerable?)GetValue(OptionsProperty); set => SetValue(OptionsProperty, value); }
    public object? Selected { get => GetValue(SelectedProperty); set => SetValue(SelectedProperty, value); }
    public bool Segmented { get => (bool)GetValue(SegmentedProperty); set => SetValue(SegmentedProperty, value); }

    readonly List<(Choice Choice, Button Button, TextBlock Label, FrameworkElement Mark)> _items = [];

    public OptionRow() => Orientation = Orientation.Horizontal;

    void Rebuild()
    {
        Children.Clear();
        _items.Clear();
        if (Options == null) return;
        foreach (var choice in Options.OfType<Choice>())
        {
            var label = new TextBlock
            {
                Text = choice.Label,
                FontSize = Segmented ? 12.5 : 12,
                VerticalAlignment = VerticalAlignment.Center,
                Padding = Segmented ? new Thickness(16, 0, 16, 0) : new Thickness(0, 4, 0, 4),
            };
            FrameworkElement mark = Segmented
                ? new Border { Child = label, MinHeight = 26 }
                : new Rectangle { Height = 1.5, VerticalAlignment = VerticalAlignment.Bottom };
            if (mark is Rectangle underline) underline.SetResourceReference(Shape.FillProperty, "Accent");

            var content = new Grid();
            if (Segmented) content.Children.Add(mark);
            else { content.Children.Add(label); content.Children.Add(mark); }

            var button = new Button
            {
                Content = content,
                Margin = Segmented ? new Thickness(0) : new Thickness(0, 0, 16, 0),
                ToolTip = null,
            };
            button.SetResourceReference(StyleProperty, "Bare");
            button.Click += (_, _) => Selected = choice.Value;
            button.MouseEnter += (_, _) => Update();
            button.MouseLeave += (_, _) => Update();
            Children.Add(button);
            _items.Add((choice, button, label, mark));
        }
        Update();
    }

    void Update()
    {
        foreach (var (choice, button, label, mark) in _items)
        {
            var selected = Equals(choice.Value, Selected);
            if (Segmented)
            {
                label.FontWeight = FontWeights.SemiBold;
                label.SetResourceReference(TextBlock.ForegroundProperty, selected ? "Background" : button.IsMouseOver ? "Ink" : "Muted");
                if (selected) ((Border)mark).SetResourceReference(Border.BackgroundProperty, "Ink");
                else ((Border)mark).Background = Brushes.Transparent;
            }
            else
            {
                label.FontWeight = selected ? FontWeights.Medium : FontWeights.Normal;
                label.SetResourceReference(TextBlock.ForegroundProperty, selected || button.IsMouseOver ? "Ink" : "Muted");
                mark.Visibility = selected ? Visibility.Visible : Visibility.Hidden;
            }
        }
    }
}

/// A one-pixel slider with tick marks at the preset positions.
public sealed class HairSlider : FrameworkElement
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(HairSlider),
        new FrameworkPropertyMetadata(0.5, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault | FrameworkPropertyMetadataOptions.AffectsRender));

    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public double Minimum { get; set; } = 0.2;
    public double Maximum { get; set; } = 1;
    public DoubleCollection? Ticks { get; set; }

    bool _dragging;

    public HairSlider()
    {
        Height = 22;
        Focusable = true;
        Cursor = Cursors.Hand;
        ThemeManager.Changed += InvalidateVisual;
    }

    Brush Res(string key) => (Brush)(TryFindResource(key) ?? Brushes.Gray);

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var y = Math.Round(ActualHeight / 2) + 0.5;
        var span = Maximum - Minimum;
        var x = (Value - Minimum) / span * w;

        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, w, ActualHeight)); // hit area
        dc.DrawRectangle(Res("Line"), null, new Rect(0, y - 0.5, w, 1));
        foreach (var tick in Ticks ?? [])
            dc.DrawRectangle(Res("Faint"), null, new Rect(Math.Round((tick - Minimum) / span * w), y - 2.5, 1, 5));
        dc.DrawRectangle(Res("Ink"), null, new Rect(0, y - 0.5, Math.Max(0, x), 1));
        var r = _dragging || IsKeyboardFocused ? 6.5 : 5.5;
        dc.DrawEllipse(Res("Ink"), null, new Point(x, y), r, r);
    }

    void SetFrom(double x) =>
        Value = Math.Round((Minimum + Math.Clamp(x / ActualWidth, 0, 1) * (Maximum - Minimum)) * 100) / 100;

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        _dragging = true;
        Focus();
        CaptureMouse();
        SetFrom(e.GetPosition(this).X);
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (_dragging) SetFrom(e.GetPosition(this).X);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        _dragging = false;
        ReleaseMouseCapture();
        InvalidateVisual();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        var step = e.Key switch { Key.Left or Key.Down => -0.01, Key.Right or Key.Up => 0.01, _ => 0 };
        if (step == 0) return;
        Value = Math.Round(Math.Clamp(Value + step, Minimum, Maximum), 2);
        e.Handled = true;
    }

    protected override void OnGotKeyboardFocus(KeyboardFocusChangedEventArgs e) => InvalidateVisual();
    protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs e) => InvalidateVisual();
}

/// Small uppercase label with wide tracking. WPF has no letter-spacing, so
/// each character is drawn with a little extra advance.
public sealed class Caps : FrameworkElement
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(Caps), new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ForegroundProperty = TextElement.ForegroundProperty.AddOwner(
        typeof(Caps), new FrameworkPropertyMetadata(Brushes.Gray, FrameworkPropertyMetadataOptions.AffectsRender | FrameworkPropertyMetadataOptions.Inherits));

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public Brush Foreground { get => (Brush)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }
    public double Tracking { get; set; } = 1.4;
    public double Size { get; set; } = 10;

    Typeface Face => new(new FontFamily("Segoe UI Variable Text, Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);

    IEnumerable<FormattedText> Glyphs()
    {
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var c in (Text ?? "").ToUpperInvariant())
            yield return new FormattedText(c.ToString(), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Face, Size, Foreground, dpi);
    }

    protected override Size MeasureOverride(Size available)
    {
        var glyphs = Glyphs().ToList();
        var width = glyphs.Sum(g => g.WidthIncludingTrailingWhitespace + Tracking) - (glyphs.Count > 0 ? Tracking : 0);
        return new Size(Math.Max(0, width), glyphs.Count > 0 ? glyphs.Max(g => g.Height) : Size * 1.3);
    }

    protected override void OnRender(DrawingContext dc)
    {
        double x = 0;
        foreach (var glyph in Glyphs())
        {
            dc.DrawText(glyph, new Point(x, 0));
            x += glyph.WidthIncludingTrailingWhitespace + Tracking;
        }
    }
}

// MARK: - Converters

/// true → Visible. Pass "invert" to flip.
public sealed class VisibleWhen : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var on = value switch { bool b => b, string s => s.Length > 0, null => false, _ => true };
        if (parameter as string == "invert") on = !on;
        return on ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// Progress (0–1) × the available width, for the hairline progress bars.
public sealed class Fraction : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object? parameter, CultureInfo culture) =>
        values is [double fraction, double width] && double.IsFinite(width) ? Math.Max(0, fraction * width) : 0.0;

    public object[] ConvertBack(object value, Type[] targetTypes, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}
