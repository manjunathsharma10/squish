#if DEBUG
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Squish;

/// Debug-only: drives the UI through its states, saves window snapshots and
/// writes a log of the results. Used by CI, where there's no one to look.
///   SQUISH_SNAPSHOT=<dir> SQUISH_FILES=<a;b;c> Squish.exe
/// Optional: SQUISH_PRESET (Small/Balanced/High), SQUISH_OUT (output folder),
/// SQUISH_SETTINGS (settings as JSON).
static class DebugSnapshot
{
    public static void RunIfRequested(Window window)
    {
        var dir = Environment.GetEnvironmentVariable("SQUISH_SNAPSHOT");
        if (string.IsNullOrEmpty(dir)) return;
        _ = Run(window, dir);
    }

    static async Task Run(Window window, string dir)
    {
        Directory.CreateDirectory(dir);
        var log = new StringBuilder();
        var model = AppModel.Shared;
        string? Env(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : null;
        try
        {
            var json = new JsonSerializerOptions { PropertyNameCaseInsensitive = true, Converters = { new JsonStringEnumConverter() } };
            var settings = Env("SQUISH_SETTINGS") is { } raw ? JsonSerializer.Deserialize<Settings>(raw, json)! : new Settings();
            if (Env("SQUISH_PRESET") is { } preset) settings = settings.Applying(Enum.Parse<Preset>(preset, ignoreCase: true));
            model.Settings = settings with { Destination = Env("SQUISH_OUT") };
            model.ShowFineTune = false;
            model.Appearance = 1;
            ThemeManager.Apply(1);

            await Task.Delay(1500);
            Capture(window, dir, "1-empty");

            var files = (Env("SQUISH_FILES") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries);
            model.Add(files);
            var started = DateTime.Now;
            bool Ready() => model.IsConvert
                ? model.Prediction(null)?.Complete == true
                : Enum.GetValues<Preset>().All(p => model.Prediction(p)?.Complete == true);
            while (!Ready() && (DateTime.Now - started).TotalSeconds < 180) await Task.Delay(100);
            log.AppendLine($"estimates ready in {(DateTime.Now - started).TotalSeconds:0.0}s");
            await Task.Delay(1000);
            Capture(window, dir, "2-queued");

            model.Run();
            await Task.Delay(500);
            Capture(window, dir, "3-working");
            started = DateTime.Now;
            while (model.IsRunning && (DateTime.Now - started).TotalMinutes < 10) await Task.Delay(200);
            await Task.Delay(800);
            Capture(window, dir, "4-done");

            model.ShowFineTune = true;
            await Task.Delay(500);
            Capture(window, dir, "5-finetune");
            model.Appearance = 2;
            ThemeManager.Apply(2);
            await Task.Delay(500);
            Capture(window, dir, "6-dark");

            if (model.IsCompress)
                foreach (var p in Enum.GetValues<Preset>())
                    if (model.Prediction(p) is { } prediction) log.AppendLine($"predicted {p}: {Formatting.Size(prediction.After)}");
            if (model.IsConvert && model.Prediction(null) is { } convert)
                log.AppendLine($"predicted Convert: {Formatting.Size(convert.After)}");

            var outputs = new HashSet<string>();
            long actual = 0;
            foreach (var item in model.Items)
            {
                if (item.Status != ItemStatus.Done || item.Output == null) actual += item.Size;
                else if (outputs.Add(item.Output)) actual += item.OutputSize ?? 0;
            }
            log.AppendLine($"actual: {Formatting.Size(actual)}");
            foreach (var item in model.Items)
            {
                var output = item.OutputSize is long size ? Formatting.Size(size) : "-";
                log.AppendLine($"{item.Name}\t{item.Status}\t{Formatting.Size(item.Size)} → {output}\t{Path.GetFileName(item.Output ?? "")}\t{item.OutputFormat} {item.OutputInfo}\t{item.Message}");
            }
        }
        catch (Exception error)
        {
            log.AppendLine("ERROR " + error);
        }
        finally
        {
            await File.WriteAllTextAsync(Path.Combine(dir, "log.txt"), log.ToString());
            model.Settings = new Settings();
            model.Appearance = 0;
            model.ShowFineTune = false;
            Application.Current.Shutdown();
        }
    }

    /// Renders the window's content at 2× without needing a screen.
    static void Capture(Window window, string dir, string name)
    {
        var root = (FrameworkElement)window.Content;
        root.UpdateLayout();
        const double scale = 2;
        var bitmap = new RenderTargetBitmap((int)(root.ActualWidth * scale), (int)(root.ActualHeight * scale),
            96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(root);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(Path.Combine(dir, name + ".png"));
        encoder.Save(file);
    }
}
#endif
