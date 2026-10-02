using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;
using System.Windows.Media;

namespace Squish;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name!);
        return true;
    }

    protected void Raise(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}

// MARK: - File kinds

public enum FileKind { Image, Pdf, Video, Audio }

public static class FileKinds
{
    // Windows decodes these with its built-in codecs (HEIC, WebP, AVIF and
    // RAW need the free extensions from the Microsoft Store).
    static readonly HashSet<string> Images = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".heic", ".heif", ".webp", ".avif", ".tif", ".tiff",
        ".bmp", ".dib", ".jxr", ".wdp", ".dng", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".rw2", ".raf",
    };
    static readonly HashSet<string> Videos = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".m4v", ".mov", ".3gp", ".3g2", ".mkv", ".avi", ".wmv", ".webm",
    };
    static readonly HashSet<string> Sounds = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp3", ".m4a", ".aac", ".wav", ".wma", ".flac", ".alac",
    };

    /// Animated GIFs are left alone so they keep their animation.
    public static FileKind? Of(string path)
    {
        var ext = Path.GetExtension(path);
        if (ext.Equals(".pdf", StringComparison.OrdinalIgnoreCase)) return FileKind.Pdf;
        if (Images.Contains(ext)) return FileKind.Image;
        if (Videos.Contains(ext)) return FileKind.Video;
        if (Sounds.Contains(ext)) return FileKind.Audio;
        return null;
    }

    public static bool IsMedia(this FileKind kind) => kind is FileKind.Video or FileKind.Audio;
}

// MARK: - Settings

public enum Preset { Small, Balanced, High }

public enum MaxSize { Original = 0, P3840 = 3840, P2560 = 2560, P1920 = 1920, P1280 = 1280 }

public enum ImageFormat { Auto, Jpeg, Png, Heic, Tiff }

public enum VideoCodec { H264, Hevc }

public enum AudioFormat { M4a, Mp3, Wav }

public enum Mode { Compress, Convert }

/// What images become in Convert mode. PDF wraps each image in a page.
public enum ImageTarget { Jpeg, Png, Heic, Tiff, Pdf }

/// What each PDF page becomes in Convert mode.
public enum PageFormat { Jpeg, Png }

public static class SettingsText
{
    public static string Title(this Preset p) => p.ToString();
    public static string Caption(this Preset p) => p switch
    {
        Preset.Small => "Smallest files",
        Preset.Balanced => "Best for most",
        _ => "Near original",
    };
    public static double Quality(this Preset p) => p switch { Preset.Small => 0.50, Preset.Balanced => 0.72, _ => 0.88 };
    public static MaxSize Size(this Preset p) => p switch
    {
        Preset.Small => Squish.MaxSize.P1920,
        Preset.Balanced => Squish.MaxSize.P3840,
        _ => Squish.MaxSize.Original,
    };

    public static int? Pixels(this MaxSize m) => m == Squish.MaxSize.Original ? null : (int)m;
    public static string Label(this MaxSize m) => m == Squish.MaxSize.Original ? "Original" : ((int)m).ToString();

    public static string Label(this ImageFormat f) => f switch
    {
        ImageFormat.Auto => "Auto",
        ImageFormat.Jpeg => "JPEG",
        _ => f.ToString().ToUpperInvariant(),
    };
    public static string Ext(this ImageFormat f) => f switch
    {
        ImageFormat.Jpeg => "jpg",
        ImageFormat.Tiff => "tiff",
        _ => f.ToString().ToLowerInvariant(),
    };

    public static string Label(this VideoCodec c) => c == VideoCodec.Hevc ? "HEVC" : "H.264";
    public static string Label(this AudioFormat f) => f.ToString().ToUpperInvariant();
    public static string Ext(this AudioFormat f) => f.ToString().ToLowerInvariant();
    public static string Title(this Mode m) => m.ToString();

    public static string Label(this ImageTarget t) => t == ImageTarget.Jpeg ? "JPEG" : t.ToString().ToUpperInvariant();
    public static ImageFormat? AsImageFormat(this ImageTarget t) => t switch
    {
        ImageTarget.Jpeg => Squish.ImageFormat.Jpeg,
        ImageTarget.Png => Squish.ImageFormat.Png,
        ImageTarget.Heic => Squish.ImageFormat.Heic,
        ImageTarget.Tiff => Squish.ImageFormat.Tiff,
        _ => null,
    };

    public static string Label(this PageFormat f) => f == PageFormat.Jpeg ? "JPEG" : "PNG";
    public static ImageFormat AsImageFormat(this PageFormat f) => f == PageFormat.Jpeg ? Squish.ImageFormat.Jpeg : Squish.ImageFormat.Png;
}

public sealed record ConvertOptions
{
    public ImageTarget Image { get; init; } = ImageTarget.Jpeg;
    /// Images → PDF: one PDF holding every image, instead of one each.
    public bool CombineImages { get; init; }
    public PageFormat Pages { get; init; } = PageFormat.Jpeg;
    public int PageDpi { get; init; } = 150;
    public VideoCodec VideoCodec { get; init; } = VideoCodec.H264;
    public AudioFormat Audio { get; init; } = AudioFormat.M4a;
    public double Quality { get; init; } = 0.85;
}

/// Immutable, so a copy can key the size estimates.
public sealed record Settings
{
    public Mode Mode { get; init; } = Mode.Compress;
    public double Quality { get; init; } = Squish.Preset.Balanced.Quality();
    public MaxSize MaxSize { get; init; } = Squish.Preset.Balanced.Size();
    public ImageFormat ImageFormat { get; init; } = ImageFormat.Auto;
    public VideoCodec VideoCodec { get; init; } = VideoCodec.H264;
    public AudioFormat AudioFormat { get; init; } = AudioFormat.M4a;
    public bool KeepMetadata { get; init; }
    public string? Destination { get; init; }
    public ConvertOptions Convert { get; init; } = new();

    [JsonIgnore]
    public Preset? Preset => Enum.GetValues<Preset>()
        .Cast<Preset?>()
        .FirstOrDefault(p => Math.Abs(p!.Value.Quality() - Quality) < 0.005 && p.Value.Size() == MaxSize);

    public Settings Applying(Preset preset) => this with { Quality = preset.Quality(), MaxSize = preset.Size() };

    /// What the engines run with. Compress keeps each file's format (audio
    /// becomes AAC). Convert takes its targets from `Convert`, at full size.
    [JsonIgnore]
    public Settings Effective => Mode == Mode.Compress
        ? this with { ImageFormat = ImageFormat.Auto, AudioFormat = AudioFormat.M4a, Convert = new() }
        : this with
        {
            Quality = Convert.Quality,
            MaxSize = MaxSize.Original,
            ImageFormat = Convert.Image.AsImageFormat() ?? ImageFormat.Auto,
            VideoCodec = Convert.VideoCodec,
            AudioFormat = Convert.Audio,
        };

    /// Everything that affects output size; where files are saved doesn't.
    [JsonIgnore]
    public Settings SizeKey => Effective with { Destination = null };
}

// MARK: - Engine results

public sealed record EngineOutput(string Path, string Ext, string Info, string? FormatLabel = null);

/// A predicted output size, before the "keep the original if it isn't
/// smaller" rule is applied.
public sealed record EngineEstimate(long Bytes, string Ext);

public sealed class EngineException(string message) : Exception(message);

/// Thrown in Convert mode when a file is already in the target format.
public sealed class AlreadyInFormatException(string format) : Exception(format)
{
    public string Format { get; } = format;
}

/// Predicted total for the whole queue under one set of settings.
public sealed record Prediction(long Before, long After, bool Complete)
{
    public double Saving => Before > 0 ? 1 - (double)After / Before : 0;
}

// MARK: - Queue item

public enum ItemStatus { Ready, Working, Done, Skipped, Failed }

public sealed class FileItem : Observable
{
    public FileItem(string path, FileKind kind, long size)
    {
        Path = path;
        Kind = kind;
        Size = size;
    }

    public string Path { get; }
    public FileKind Kind { get; }
    public long Size { get; }
    public string Name => System.IO.Path.GetFileName(Path);
    public string Format => System.IO.Path.GetExtension(Path).TrimStart('.').ToUpperInvariant();

    /// Lets the model preview conversions ("HEIC → JPEG") in each row.
    public static Func<FileItem, (string Label, bool Already)?>? TargetPreview { get; set; }

    string _info = "";
    public string Info { get => _info; set { if (Set(ref _info, value)) Raise(nameof(Detail)); } }

    ImageSource? _thumbnail, _thumbnailMono;
    public ImageSource? Thumbnail { get => _thumbnail; set { if (Set(ref _thumbnail, value)) Raise(nameof(HasThumbnail)); } }
    public ImageSource? ThumbnailMono { get => _thumbnailMono; set => Set(ref _thumbnailMono, value); }
    public bool HasThumbnail => Thumbnail != null;

    ItemStatus _status;
    public ItemStatus Status { get => _status; set { if (Set(ref _status, value)) Refresh(); } }

    string _message = "";
    /// Why a file was skipped or failed.
    public string Message { get => _message; set { if (Set(ref _message, value)) Refresh(); } }

    double? _progress;
    /// Null while working means the engine can't report progress.
    public double? Progress { get => _progress; set { if (Set(ref _progress, value)) Raise(nameof(ProgressValue), nameof(IsIndeterminate), nameof(Trailing)); } }

    public string? Output { get; set; }
    public string OutputFormat { get; set; } = "";
    public Mode? OutputMode { get; set; }
    public long? OutputSize { get; set; }
    public string OutputInfo { get; set; } = "";
    /// Set when this image became one page of a combined PDF.
    public (int Number, int Of)? Page { get; set; }

    /// Predicted size after processing, keyed by `Settings.SizeKey`.
    public Dictionary<Settings, long> Estimates { get; } = new();

    public double? Saving => Status == ItemStatus.Done && OutputSize is long output && Size > 0 ? 1 - (double)output / Size : null;

    // MARK: Display

    public bool IsWorking => Status == ItemStatus.Working;
    public bool IsDone => Status == ItemStatus.Done;
    public bool IsFailed => Status == ItemStatus.Failed;
    public bool IsVivid => Status == ItemStatus.Done;
    public bool CanRemove => Status != ItemStatus.Working;
    public bool IsIndeterminate => IsWorking && Progress == null;
    public double ProgressValue => Progress ?? 0;

    public string Detail
    {
        get
        {
            switch (Status)
            {
                case ItemStatus.Failed:
                case ItemStatus.Skipped:
                    return Message;
                case ItemStatus.Done:
                    var same = Format == OutputFormat || (Format == "JPEG" && OutputFormat == "JPG");
                    var formats = same ? OutputFormat : $"{Format} → {OutputFormat}";
                    return Join(formats, OutputInfo);
                default:
                    // In Convert mode, preview what the file will become.
                    var target = TargetPreview?.Invoke(this);
                    var shown = target is { } t ? (t.Already ? $"{Format} · already {t.Label}" : $"{Format} → {t.Label}") : Format;
                    return Join(shown, Info);
            }
        }
    }

    /// Right-hand column: size, progress, or before → after.
    public string Trailing => Status switch
    {
        ItemStatus.Working => Progress is double p ? $"{(int)(p * 100)}%" : "Working",
        ItemStatus.Done when Page is { } page => $"{Formatting.Size(Size)} → page {page.Number}",
        ItemStatus.Done => $"{Formatting.Size(Size)} → {Formatting.Size(OutputSize ?? 0)}",
        _ => Formatting.Size(Size),
    };

    public string SavingText => Saving is double s && Page == null ? Formatting.Percent(s) : "";
    public bool SavingIsGood => Saving is >= 0.005; // orange only marks a real saving
    public bool TrailingIsQuiet => Status == ItemStatus.Skipped;

    public void Refresh() => Raise(nameof(Detail), nameof(Trailing), nameof(SavingText), nameof(SavingIsGood),
        nameof(IsWorking), nameof(IsDone), nameof(IsFailed), nameof(IsVivid), nameof(CanRemove), nameof(IsIndeterminate),
        nameof(ProgressValue), nameof(TrailingIsQuiet));

    static string Join(params string[] parts) => string.Join(" · ", parts.Where(p => !string.IsNullOrEmpty(p)));
}

// MARK: - Formatting

public static class Formatting
{
    static readonly CultureInfo Culture = CultureInfo.CurrentCulture;

    /// Decimal units, like Finder and macOS ("765 KB", "1.6 MB").
    public static string Size(long bytes)
    {
        double b = bytes;
        if (b < 1000) return bytes == 1 ? "1 byte" : $"{bytes} bytes";
        if (b < 1_000_000) return (b / 1000).ToString("0", Culture) + " KB";
        if (b < 1_000_000_000) return (b / 1_000_000).ToString("0.0", Culture) + " MB";
        return (b / 1_000_000_000).ToString("0.00", Culture) + " GB";
    }

    /// Never rounds a real file down to "−100%".
    public static string Percent(double saving)
    {
        var value = (int)Math.Round(Math.Abs(saving) * 100);
        if (saving > 0) value = Math.Min(value, 99);
        if (value == 0) return "0%";
        return saving >= 0 ? $"−{value}%" : $"+{value}%";
    }

    public static string Duration(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds <= 0) return "";
        var s = (int)Math.Round(seconds);
        return s >= 3600 ? $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}";
    }

    public static string Dimensions(int w, int h) => $"{w} × {h}";

    public static string Pages(int count) => count == 1 ? "1 page" : $"{count} pages";
}
