using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Animation;
using Microsoft.Win32;

namespace Squish;

public partial class MainWindow : Window
{
    AppModel Model => AppModel.Shared;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = Model;
        SourceInitialized += (_, _) => RoundCorners();
        StateChanged += (_, _) => FitMaximized();
        PreviewKeyDown += OnKey;
        DragEnter += (_, e) => SetDropTarget(e, true);
        DragOver += (_, e) => SetDropTarget(e, true);
        DragLeave += (_, e) => SetDropTarget(e, false);
        Drop += OnDrop;
        Model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppModel.ShowFineTune)) SpinFineTuneIcon();
        };
        FineTuneIcon.Angle = Model.ShowFineTune ? 45 : 0;
    }

    // MARK: Window chrome

    /// Windows 11 rounds the corners of custom-chrome windows on request.
    void RoundCorners()
    {
        var preference = 2; // DWMWCP_ROUND
        _ = DwmSetWindowAttribute(new WindowInteropHelper(this).Handle, 33, ref preference, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// A maximised custom-chrome window overhangs the screen by its resize border.
    void FitMaximized() =>
        Root.Margin = WindowState == WindowState.Maximized ? new Thickness(7) : new Thickness(0);

    void MinimizeWindow(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    void MaximizeWindow(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    void CloseWindow(object sender, RoutedEventArgs e) => Close();

    void CycleAppearance(object sender, RoutedEventArgs e)
    {
        Model.Appearance = (Model.Appearance + 1) % 3;
        ThemeManager.Apply(Model.Appearance);
    }

    void ToggleFineTune(object sender, RoutedEventArgs e) => Model.ShowFineTune = !Model.ShowFineTune;

    void SpinFineTuneIcon() => FineTuneIcon.BeginAnimation(System.Windows.Media.RotateTransform.AngleProperty,
        new DoubleAnimation(Model.ShowFineTune ? 45 : 0, TimeSpan.FromMilliseconds(200)) { EasingFunction = new CubicEase() });

    // MARK: Keyboard

    void OnKey(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        switch (e.Key)
        {
            case Key.O when ctrl: ChooseFiles(this, e); break;
            case Key.Enter when ctrl: Model.Run(); break;
            case Key.Escape when Model.IsRunning: Model.Stop(); break;
            case Key.D1 when ctrl: Model.Mode = Mode.Compress; break;
            case Key.D2 when ctrl: Model.Mode = Mode.Convert; break;
            default: return;
        }
        e.Handled = true;
    }

    // MARK: Adding files

    void SetDropTarget(DragEventArgs e, bool over)
    {
        var files = e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = files ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
        var on = over && files;

        DropBorder.StrokeDashArray = on ? null : [3, 4];
        DropBorder.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, on ? "Accent" : "Faint");
        if (on) DropBorder.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "AccentWash");
        else DropBorder.Fill = System.Windows.Media.Brushes.Transparent;
        DropArrow.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, on ? "Accent" : "Ink");
        DropArrow.RenderTransform = new System.Windows.Media.TranslateTransform(0, on ? 5 : 0);
        DropTitle.Text = on ? "Release to add" : Model.DropTitle;

        if (on) DropStrip.SetResourceReference(BackgroundProperty, "AccentWash");
        else DropStrip.Background = System.Windows.Media.Brushes.Transparent;
        StripText.Text = on ? "Release to add" : "Drop more files, or";
        StripText.SetResourceReference(System.Windows.Controls.TextBlock.ForegroundProperty, on ? "Accent" : "Muted");
        StripBrowse.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        SetDropTarget(e, false);
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) Model.Add(paths);
    }

    void ChooseFiles(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Title = "Choose files",
            Filter = "Images, PDFs, video and audio|*.jpg;*.jpeg;*.png;*.heic;*.heif;*.webp;*.avif;*.tif;*.tiff;*.bmp;*.dng;"
                   + "*.pdf;*.mp4;*.m4v;*.mov;*.3gp;*.mkv;*.avi;*.wmv;*.webm;*.mp3;*.m4a;*.aac;*.wav;*.wma;*.flac|All files|*.*",
        };
        if (dialog.ShowDialog(this) == true) Model.Add(dialog.FileNames);
    }

    // MARK: Settings

    void PickPreset(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is PresetCell cell) Model.ApplyPreset(cell.Preset);
    }

    void SaveNextToOriginal(object sender, RoutedEventArgs e) => Model.ClearDestination();
    void ChooseFolder(object sender, RoutedEventArgs e) => Model.ChooseDestination();

    // MARK: Queue

    static FileItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as FileItem;

    void RowMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2 && ItemOf(sender) is { } item) AppModel.Open(item);
    }

    void RevealItem(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) AppModel.Reveal(item); }
    void OpenItem(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) AppModel.Open(item); }
    void RemoveItem(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Model.Remove(item); }

    void ClearQueue(object sender, RoutedEventArgs e) => Model.Clear();
    void RunQueue(object sender, RoutedEventArgs e) => Model.Run();
    void StopQueue(object sender, RoutedEventArgs e) => Model.Stop();
}
