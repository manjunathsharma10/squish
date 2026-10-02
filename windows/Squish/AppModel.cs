using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RecycleBin = Microsoft.VisualBasic.FileIO.FileSystem;
using RecycleOption = Microsoft.VisualBasic.FileIO.RecycleOption;
using UIOption = Microsoft.VisualBasic.FileIO.UIOption;
using Squish.Engines;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace Squish;

/// A value and its label, for the rows of text options.
public sealed record Choice(object Value, string Label);

/// One of the three presets, with its predicted total.
public sealed class PresetCell(Preset preset) : Observable
{
    public Preset Preset { get; } = preset;
    public string Title => Preset.Title();
    public string Caption => Preset.Caption();

    bool _selected;
    public bool IsSelected { get => _selected; set => Set(ref _selected, value); }

    Prediction? _prediction;
    bool _visible;
    public void Update(Prediction? prediction, bool visible)
    {
        _prediction = prediction;
        _visible = visible;
        Raise(nameof(ShowPrediction), nameof(Predicted), nameof(Percent), nameof(IsComplete), nameof(Help));
    }

    public bool ShowPrediction => _visible;
    public string Predicted => _prediction is { } p ? $"≈ {Formatting.Size(p.After)}" : "—";
    public string Percent => _prediction is { } p ? Formatting.Percent(p.Saving) : "";
    public bool IsComplete => _prediction?.Complete ?? false;
    public string Help => _prediction is { } p
        ? $"About {Formatting.Size(p.After)} with {Title}{(p.Complete ? "" : " (still estimating)")}"
        : $"{Title}: quality {(int)(Preset.Quality() * 100)}, up to {Preset.Size().Label()} px";
}

public sealed class AppModel : Observable
{
    public static AppModel Shared { get; } = new();

    public ObservableCollection<FileItem> Items { get; } = [];
    public IReadOnlyList<PresetCell> Presets { get; } = Enum.GetValues<Preset>().Select(p => new PresetCell(p)).ToList();

    Settings _settings;
    int _appearance;
    bool _showFineTune;
    readonly List<FileItem> _batch = [];
    CancellationTokenSource? _run;
    CancellationTokenSource? _estimates;
    CancellationTokenSource? _noticeTimer;

    AppModel()
    {
        var prefs = Prefs.Load();
        _settings = prefs.Settings;
        _appearance = prefs.Appearance;
        _showFineTune = prefs.FineTune;
        FileItem.TargetPreview = ConversionTarget;
        Items.CollectionChanged += (_, _) => QueueChanged();
        _ = DetectCodecs();
    }

    // MARK: Settings

    public Settings Settings
    {
        get => _settings;
        set
        {
            if (_settings == value) return;
            _settings = value;
            Save();
            // Finished files no longer reflect the settings; let them run again.
            if (!IsRunning)
                foreach (var item in Items.Where(i => i.Status != ItemStatus.Ready)) { item.Message = ""; item.Status = ItemStatus.Ready; }
            foreach (var item in Items) item.Refresh();
            Raise(nameof(Mode), nameof(IsCompress), nameof(IsConvert), nameof(Quality), nameof(MaxSize), nameof(VideoCodec),
                nameof(KeepMetadata), nameof(DestinationLabel), nameof(HasDestination), nameof(ConvertImage), nameof(CombineImages),
                nameof(ShowCombine), nameof(Pages), nameof(PageDpi), nameof(ConvertCodec), nameof(ConvertAudio), nameof(ConvertQuality),
                nameof(PrimaryLabel), nameof(DropTitle), nameof(CanRun), nameof(ShowFineTunePanel));
            RefreshPredictions();
            ScheduleEstimates();
        }
    }

    public Mode Mode { get => Settings.Mode; set { if (!IsRunning) Settings = Settings with { Mode = value }; } }
    public bool IsCompress => Mode == Mode.Compress;
    public bool IsConvert => Mode == Mode.Convert;

    public double Quality { get => Settings.Quality; set => Settings = Settings with { Quality = Math.Round(value, 2) } ; }
    public MaxSize MaxSize { get => Settings.MaxSize; set => Settings = Settings with { MaxSize = value }; }
    public VideoCodec VideoCodec { get => Settings.VideoCodec; set => Settings = Settings with { VideoCodec = value }; }
    public bool KeepMetadata { get => Settings.KeepMetadata; set => Settings = Settings with { KeepMetadata = value }; }

    public ImageTarget ConvertImage { get => Settings.Convert.Image; set => Settings = Settings with { Convert = Settings.Convert with { Image = value } }; }
    public bool CombineImages { get => Settings.Convert.CombineImages; set => Settings = Settings with { Convert = Settings.Convert with { CombineImages = value } }; }
    public bool ShowCombine => ConvertImage == ImageTarget.Pdf;
    public PageFormat Pages { get => Settings.Convert.Pages; set => Settings = Settings with { Convert = Settings.Convert with { Pages = value } }; }
    public int PageDpi { get => Settings.Convert.PageDpi; set => Settings = Settings with { Convert = Settings.Convert with { PageDpi = value } }; }
    public VideoCodec ConvertCodec { get => Settings.Convert.VideoCodec; set => Settings = Settings with { Convert = Settings.Convert with { VideoCodec = value } }; }
    public AudioFormat ConvertAudio { get => Settings.Convert.Audio; set => Settings = Settings with { Convert = Settings.Convert with { Audio = value } }; }
    public double ConvertQuality { get => Settings.Convert.Quality; set => Settings = Settings with { Convert = Settings.Convert with { Quality = Math.Round(value, 2) } }; }

    public string? DestinationLabel => Settings.Destination is { } d ? Path.GetFileName(d.TrimEnd('\\', '/')) : null;
    public bool HasDestination => Settings.Destination != null;

    public void ApplyPreset(Preset preset) => Settings = Settings.Applying(preset);

    public int Appearance { get => _appearance; set { if (Set(ref _appearance, value)) { Save(); Raise(nameof(AppearanceLabel)); } } }
    public string AppearanceLabel => _appearance switch { 1 => "LIGHT", 2 => "DARK", _ => "AUTO" };
    public bool ShowFineTune { get => _showFineTune; set { if (Set(ref _showFineTune, value)) { Save(); Raise(nameof(ShowFineTunePanel)); } } }
    public bool ShowFineTunePanel => IsCompress && ShowFineTune;

    void Save() => Prefs.Save(new Prefs { Settings = _settings, Appearance = _appearance, FineTune = _showFineTune });

    // MARK: Option lists

    public static IReadOnlyList<Choice> ModeChoices { get; } = Enum.GetValues<Mode>().Select(m => new Choice(m, m.Title())).ToList();
    public static IReadOnlyList<Choice> MaxSizeChoices { get; } =
        new[] { MaxSize.Original, MaxSize.P3840, MaxSize.P2560, MaxSize.P1920, MaxSize.P1280 }.Select(m => new Choice(m, m.Label())).ToList();
    public static IReadOnlyList<Choice> MetadataChoices { get; } = [new(false, "Strip"), new(true, "Keep")];
    public static IReadOnlyList<Choice> CombineChoices { get; } = [new(false, "One each"), new(true, "Combine")];
    public static IReadOnlyList<Choice> PageChoices { get; } = Enum.GetValues<PageFormat>().Select(f => new Choice(f, f.Label())).ToList();
    public static IReadOnlyList<Choice> DpiChoices { get; } = [new(150, "150 dpi"), new(300, "300 dpi")];
    public static IReadOnlyList<Choice> AudioChoices { get; } = Enum.GetValues<AudioFormat>().Select(f => new Choice(f, f.Label())).ToList();
    public static IReadOnlyList<Choice> ImageTargetChoices { get; } = Enum.GetValues<ImageTarget>()
        .Where(t => t != ImageTarget.Heic || Imaging.CanWriteHeic).Select(t => new Choice(t, t.Label())).ToList();

    IReadOnlyList<Choice> _codecChoices = [new(VideoCodec.H264, VideoCodec.H264.Label())];
    public IReadOnlyList<Choice> CodecChoices { get => _codecChoices; private set => Set(ref _codecChoices, value); }

    async Task DetectCodecs()
    {
        if (await MediaEngine.CanEncodeHevc())
            CodecChoices = Enum.GetValues<VideoCodec>().Select(c => new Choice(c, c.Label())).ToList();
    }

    // MARK: Derived state

    bool _isRunning;
    public bool IsRunning
    {
        get => _isRunning;
        private set { if (Set(ref _isRunning, value)) Raise(nameof(CanRun), nameof(IsIdle), nameof(CanClear)); }
    }
    public bool IsIdle => !IsRunning;
    public bool IsEmpty => Items.Count == 0;
    public bool HasItems => Items.Count > 0;
    public bool CanRun => !IsRunning && Items.Any(i => i.Status == ItemStatus.Ready);
    public bool CanClear => !IsRunning && Items.Count > 0;
    public string PrimaryLabel => Mode.Title();
    public string DropTitle => IsCompress ? "Drop files to compress" : "Drop files to convert";

    // Convert-panel rows for kinds that aren't queued are dimmed.
    public double ImagesOpacity => Presence(FileKind.Image);
    public double PdfOpacity => Presence(FileKind.Pdf);
    public double VideoOpacity => Presence(FileKind.Video);
    public double AudioOpacity => Presence(FileKind.Audio);
    double Presence(FileKind kind) => Items.Count == 0 || Items.Any(i => i.Kind == kind) ? 1 : 0.35;

    public double BatchProgress => _batch.Count == 0 ? 0 : _batch.Sum(i => i.Status switch
    {
        ItemStatus.Working => i.Progress ?? 0.5,
        ItemStatus.Ready => 0,
        _ => 1,
    }) / _batch.Count;

    /// Before/after across finished files. Images combined into one PDF
    /// share an output, which is only counted once.
    (long Before, long After)? Totals
    {
        get
        {
            var done = Items.Where(i => i.Status == ItemStatus.Done).ToList();
            if (done.Count == 0) return null;
            var seen = new HashSet<string>();
            long after = 0;
            foreach (var item in done)
                if (item.Output == null || seen.Add(item.Output)) after += item.OutputSize ?? item.Size;
            return (done.Sum(i => i.Size), after);
        }
    }

    // Footer: muted figures, then an ink phrase, then an accent percentage.
    string? _notice;
    public string FooterFigures => _notice != null ? "" : Totals is { } t ? $"{Formatting.Size(t.Before)} → {Formatting.Size(t.After)}"
        : Items.Count > 0 ? Formatting.Size(Items.Sum(i => i.Size)) : "";
    public string FooterText => _notice ?? (Totals is { } t
        ? (t.Before >= t.After ? $"{Formatting.Size(t.Before - t.After)} saved" : $"{Formatting.Size(t.After - t.Before)} larger")
        : Items.Count == 0 ? "No files yet" : Items.Count == 1 ? "1 file" : $"{Items.Count} files");
    public string FooterPercent => _notice == null && Totals is { } t && t.Before > 0 ? Formatting.Percent(1 - (double)t.After / t.Before) : "";
    public bool FooterSaves => Totals is { } t && t.Before > 0 && 1 - (double)t.After / t.Before >= 0.005;
    public bool FooterIsQuiet => _notice == null && Items.Count == 0;
    /// Totals read "52 MB → 8 MB  44 MB saved"; counts read "9 files  54 MB".
    public string FooterLeadFigures => Totals != null ? FooterFigures : "";
    public string FooterTrailFigures => Totals == null ? FooterFigures : "";

    void RaiseFooter() => Raise(nameof(FooterLeadFigures), nameof(FooterTrailFigures), nameof(FooterText), nameof(FooterPercent),
        nameof(FooterIsQuiet), nameof(FooterSaves), nameof(CanRun), nameof(CanClear), nameof(BatchProgress));

    void QueueChanged()
    {
        Raise(nameof(IsEmpty), nameof(HasItems), nameof(ImagesOpacity), nameof(PdfOpacity), nameof(VideoOpacity), nameof(AudioOpacity));
        foreach (var item in Items) item.Refresh(); // "one PDF" previews depend on the image count
        RaiseFooter();
        RefreshPredictions();
    }

    void Flash(string message)
    {
        _notice = message;
        RaiseFooter();
        _noticeTimer?.Cancel();
        var timer = _noticeTimer = new CancellationTokenSource();
        _ = Task.Delay(3500, timer.Token).ContinueWith(_ =>
        {
            _notice = null;
            RaiseFooter();
        }, timer.Token, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// What Convert mode will turn a file into ("JPEG", "MP4 · H.264"), and
    /// whether it's already in that format and will be left alone.
    (string Label, bool Already)? ConversionTarget(FileItem item)
    {
        if (Mode != Mode.Convert) return null;
        var options = Settings.Convert;
        var ext = Path.GetExtension(item.Path).TrimStart('.').ToLowerInvariant();
        return item.Kind switch
        {
            FileKind.Image when options.Image == ImageTarget.Pdf =>
                (options.CombineImages && Items.Count(i => i.Kind == FileKind.Image) > 1 ? "one PDF" : "PDF", false),
            FileKind.Image => (options.Image.Label(), options.Image switch
            {
                ImageTarget.Jpeg => ext is "jpg" or "jpeg" or "jpe" or "jfif",
                ImageTarget.Png => ext == "png",
                ImageTarget.Heic => ext is "heic" or "heif",
                ImageTarget.Tiff => ext is "tif" or "tiff",
                _ => false,
            }),
            FileKind.Pdf => (options.Pages.Label(), false),
            FileKind.Video => ($"MP4 · {options.VideoCodec.Label()}", false),
            _ => (options.Audio.Label(), ext == options.Audio.Ext()),
        };
    }

    // MARK: Adding files

    public void Add(IEnumerable<string> paths)
    {
        var known = Items.Select(i => i.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var added = new List<FileItem>();
        var skipped = 0;
        foreach (var path in Expand(paths))
        {
            if (!known.Add(path)) continue;
            if (FileKinds.Of(path) is not { } kind) { skipped++; continue; }
            added.Add(new FileItem(path, kind, new FileInfo(path).Length));
        }
        foreach (var item in added)
        {
            Items.Add(item);
            _ = Inspect(item);
        }
        if (added.Count > 0) ScheduleEstimates(100);
        if (skipped > 0) Flash(skipped == 1 ? "Skipped 1 unsupported file" : $"Skipped {skipped} unsupported files");
    }

    /// Folders are opened up recursively, up to a thousand files.
    static IEnumerable<string> Expand(IEnumerable<string> paths)
    {
        var count = 0;
        foreach (var path in paths)
        {
            if (File.Exists(path)) { count++; yield return Path.GetFullPath(path); }
            else if (Directory.Exists(path))
            {
                var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = System.IO.FileAttributes.Hidden | System.IO.FileAttributes.System };
                foreach (var file in Directory.EnumerateFiles(path, "*", options))
                {
                    if (++count > 1000) yield break;
                    yield return file;
                }
            }
        }
    }

    async Task Inspect(FileItem item)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(item.Path);
            using (var thumb = await file.GetThumbnailAsync(ThumbnailMode.SingleItem, 80, ThumbnailOptions.ResizeThumbnail))
            {
                if (thumb != null)
                {
                    var bytes = await Imaging.ReadAll(thumb);
                    var image = new BitmapImage();
                    image.BeginInit();
                    image.CacheOption = BitmapCacheOption.OnLoad;
                    image.StreamSource = new MemoryStream(bytes);
                    image.EndInit();
                    image.Freeze();
                    var mono = new FormatConvertedBitmap(image, PixelFormats.Gray8, null, 0);
                    mono.Freeze();
                    item.ThumbnailMono = mono;
                    item.Thumbnail = image;
                }
            }
            item.Info = await Describe(file, item.Kind);
        }
        catch (Exception) { /* thumbnails and details are nice-to-haves */ }
    }

    static async Task<string> Describe(StorageFile file, FileKind kind)
    {
        switch (kind)
        {
            case FileKind.Image:
                var image = await file.Properties.GetImagePropertiesAsync();
                var turned = image.Orientation is PhotoOrientation.Rotate90 or PhotoOrientation.Rotate270
                    or PhotoOrientation.Transpose or PhotoOrientation.Transverse;
                return turned ? Formatting.Dimensions((int)image.Height, (int)image.Width) : Formatting.Dimensions((int)image.Width, (int)image.Height);
            case FileKind.Pdf:
                var pdf = await Windows.Data.Pdf.PdfDocument.LoadFromFileAsync(file);
                return Formatting.Pages((int)pdf.PageCount);
            case FileKind.Video:
                var video = await file.Properties.GetVideoPropertiesAsync();
                var rotated = video.Orientation is VideoOrientation.Rotate90 or VideoOrientation.Rotate270;
                var size = rotated ? Formatting.Dimensions((int)video.Height, (int)video.Width) : Formatting.Dimensions((int)video.Width, (int)video.Height);
                return string.Join(" · ", new[] { video.Width > 0 ? size : "", Formatting.Duration(video.Duration.TotalSeconds) }.Where(s => s.Length > 0));
            default:
                return Formatting.Duration((await file.Properties.GetMusicPropertiesAsync()).Duration.TotalSeconds);
        }
    }

    // MARK: Queue actions

    public void Remove(FileItem item)
    {
        if (item.Status != ItemStatus.Working) Items.Remove(item);
    }

    public void Clear()
    {
        if (IsRunning) return;
        _estimates?.Cancel();
        Items.Clear();
    }

    public static void Reveal(FileItem item) =>
        System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{item.Output ?? item.Path}\"");

    public static void Open(FileItem item) =>
        System.Diagnostics.Process.Start(new ProcessStartInfo(item.Output ?? item.Path) { UseShellExecute = true });

    public void ChooseDestination()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Save results to" };
        if (dialog.ShowDialog() == true) Settings = Settings with { Destination = dialog.FolderName };
    }

    public void ClearDestination() => Settings = Settings with { Destination = null };

    // MARK: Running

    public async void Run()
    {
        if (!CanRun) return;
        _estimates?.Cancel(); // give the encoders the whole machine
        var settings = Settings.Effective;
        _batch.Clear();
        _batch.AddRange(Items.Where(i => i.Status == ItemStatus.Ready));
        IsRunning = true;
        var run = _run = new CancellationTokenSource();

        var stills = _batch.Where(i => !i.Kind.IsMedia()).ToList();
        var media = _batch.Where(i => i.Kind.IsMedia()).ToList();
        var combined = new List<FileItem>();
        if (ImageEngine.MakesPdf(settings) && settings.Convert.CombineImages)
        {
            combined = stills.Where(i => i.Kind == FileKind.Image).ToList();
            if (combined.Count > 1) stills.RemoveAll(i => i.Kind == FileKind.Image); else combined.Clear();
        }

        // Images and PDFs run a few at a time; media uses the hardware
        // encoder, so one at a time alongside them.
        var lanes = new List<Task> { Lane(stills, 3, settings, run.Token), Lane(media, 1, settings, run.Token) };
        if (combined.Count > 0) lanes.Add(Combine(combined, settings, run.Token));
        await Task.WhenAll(lanes);

        IsRunning = false;
        _batch.Clear();
        RaiseFooter();
        ScheduleEstimates(0);
    }

    public void Stop() => _run?.Cancel();

    async Task Lane(List<FileItem> queue, int width, Settings settings, CancellationToken cancel)
    {
        var next = 0;
        async Task Worker()
        {
            while (!cancel.IsCancellationRequested && next < queue.Count)
                await ProcessItem(queue[next++], settings, cancel);
        }
        await Task.WhenAll(Enumerable.Range(0, width).Select(_ => Worker()));
    }

    static string TempBase() => Path.Combine(Path.GetTempPath(), "squish-" + Guid.NewGuid().ToString("N"));

    async Task ProcessItem(FileItem item, Settings settings, CancellationToken cancel)
    {
        var exportsPages = item.Kind == FileKind.Pdf && settings.Mode == Mode.Convert;
        item.Message = "";
        item.Page = null;
        item.Progress = item.Kind.IsMedia() || exportsPages ? 0 : null;
        item.Status = ItemStatus.Working;
        RaiseFooter();

        var temp = TempBase();
        void Report(double p) => Application.Current.Dispatcher.BeginInvoke(() => { item.Progress = p; Raise(nameof(BatchProgress)); });
        EngineOutput? result = null;
        try
        {
            var input = item.Path;
            result = item.Kind switch
            {
                FileKind.Image => await Task.Run(() => ImageEngine.Run(input, temp, settings), cancel),
                FileKind.Pdf when exportsPages => await Task.Run(() => PdfEngine.ExportPages(input, temp, settings, Report), cancel),
                FileKind.Pdf => await Task.Run(() => PdfEngine.Run(input, temp, settings), cancel),
                _ => await Task.Run(() => MediaEngine.Run(input, temp, item.Kind, settings, Report, cancel), cancel),
            };
            cancel.ThrowIfCancellationRequested();

            var newSize = SizeOf(result.Path);
            ReplacePreviousOutput([item], result.Ext, settings.Mode);
            if (settings.Mode == Mode.Compress && KeepsOriginal(item, newSize, result.Ext))
            {
                item.Message = "Couldn't make this any smaller. Original kept.";
                item.Status = ItemStatus.Skipped;
                return;
            }
            var destination = Destination(item, result.Ext, settings);
            Move(result.Path, destination);
            Finish(item, destination, newSize, result, settings.Mode);
        }
        catch (OperationCanceledException) { item.Status = ItemStatus.Ready; }
        catch (AlreadyInFormatException already)
        {
            item.Message = $"Already {already.Format}. Nothing to convert.";
            item.Status = ItemStatus.Skipped;
        }
        catch (Exception error)
        {
            item.Message = Describe(error);
            item.Status = ItemStatus.Failed;
        }
        finally
        {
            if (result != null) Delete(result.Path);
            foreach (var leftover in new[] { temp }.Concat(Directory.GetFiles(Path.GetTempPath(), Path.GetFileName(temp) + ".*")))
                Delete(leftover);
            RaiseFooter();
        }
    }

    /// Images → one PDF, in queue order, named after the first image.
    async Task Combine(List<FileItem> images, Settings settings, CancellationToken cancel)
    {
        foreach (var item in images)
        {
            item.Message = "";
            item.Page = null;
            item.Progress = 0;
            item.Status = ItemStatus.Working;
        }
        var temp = TempBase() + ".pdf";
        try
        {
            var inputs = images.Select(i => i.Path).ToList();
            var result = await Task.Run(() => ImageEngine.MakePdf(inputs, temp, settings,
                index => Application.Current.Dispatcher.BeginInvoke(() => images[index].Progress = 1)), cancel);
            cancel.ThrowIfCancellationRequested();

            ReplacePreviousOutput(images, result.Ext, settings.Mode);
            var name = Path.GetFileNameWithoutExtension(images[0].Path) + "-combined";
            var destination = Destination(images[0], result.Ext, settings, [name]);
            Move(temp, destination);
            var size = SizeOf(destination);
            for (var i = 0; i < images.Count; i++)
            {
                images[i].Page = (i + 1, images.Count);
                Finish(images[i], destination, size, result with { Info = $"Page {i + 1} of {images.Count}" }, settings.Mode);
            }
        }
        catch (OperationCanceledException) { foreach (var item in images) item.Status = ItemStatus.Ready; }
        catch (Exception error)
        {
            foreach (var item in images) { item.Message = Describe(error); item.Status = ItemStatus.Failed; }
        }
        finally
        {
            Delete(temp);
            RaiseFooter();
        }
    }

    static void Finish(FileItem item, string output, long size, EngineOutput result, Mode mode)
    {
        item.Output = output;
        item.OutputFormat = result.FormatLabel ?? result.Ext.ToUpperInvariant();
        item.OutputMode = mode;
        item.OutputSize = size;
        item.OutputInfo = result.Info;
        item.Status = ItemStatus.Done;
    }

    /// Re-running a file with tweaked settings replaces its previous result
    /// (to the Recycle Bin), but only when it would make the same kind of
    /// file; converting to a new format keeps earlier results.
    static void ReplacePreviousOutput(IEnumerable<FileItem> items, string ext, Mode mode)
    {
        foreach (var item in items)
        {
            if (item.Output is not { } old || item.OutputMode != mode) continue;
            if (!Path.GetExtension(old).TrimStart('.').Equals(ext, StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                if (File.Exists(old)) RecycleBin.DeleteFile(old, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
                else if (Directory.Exists(old)) RecycleBin.DeleteDirectory(old, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
            }
            catch (Exception) { /* leave it */ }
            item.Output = null;
        }
    }

    /// Same format and under 1% smaller isn't worth a new file.
    static bool KeepsOriginal(FileItem item, long newSize, string ext) =>
        SameFormat(item.Path, ext) && newSize > item.Size * 0.99;

    static bool SameFormat(string path, string ext)
    {
        var source = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        string[] jpeg = ["jpg", "jpeg", "jpe", "jfif"], tiff = ["tif", "tiff"], heic = ["heic", "heif"];
        return source == ext || (jpeg.Contains(source) && jpeg.Contains(ext)) || (tiff.Contains(source) && tiff.Contains(ext))
            || (heic.Contains(source) && heic.Contains(ext));
    }

    /// Compressed files get "-squished"; converted ones keep their name with
    /// the new extension ("-converted" if that's taken). Page folders are
    /// "name-pages". Numbers are added until the name is free.
    static string Destination(FileItem item, string ext, Settings settings, string[]? names = null)
    {
        var folder = settings.Destination ?? Path.GetDirectoryName(item.Path)!;
        var stem = Path.GetFileNameWithoutExtension(item.Path);
        names ??= settings.Mode == Mode.Compress ? [stem + "-squished"]
            : ext.Length == 0 ? [stem + "-pages"] : [stem, stem + "-converted"];
        string At(string name) => Path.Combine(folder, ext.Length == 0 ? name : $"{name}.{ext}");
        bool Free(string path) => !File.Exists(path) && !Directory.Exists(path);
        foreach (var name in names) if (Free(At(name))) return At(name);
        var n = 2;
        while (!Free(At($"{names[^1]}-{n}"))) n++;
        return At($"{names[^1]}-{n}");
    }

    static void Move(string from, string to)
    {
        try
        {
            if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to);
        }
        catch (IOException) when (Directory.Exists(from))
        {
            // Different drive: copy the folder over.
            Directory.CreateDirectory(to);
            foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        }
        catch (UnauthorizedAccessException)
        {
            throw new EngineException("Can't save to this folder. Choose another under Save to.");
        }
    }

    static void Delete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
            else if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        }
        catch (Exception) { /* temp files are cleaned up by Windows eventually */ }
    }

    /// File size, or the total of a folder's files.
    static long SizeOf(string path) => Directory.Exists(path)
        ? Directory.EnumerateFiles(path, "*", System.IO.SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length)
        : File.Exists(path) ? new FileInfo(path).Length : 0;

    static string Describe(Exception error) => error switch
    {
        EngineException e => e.Message,
        UnauthorizedAccessException => "Squish doesn't have permission to read or save here",
        _ => error.Message,
    };

    // MARK: Size predictions

    /// Predicted queue total for a preset, or for the current settings.
    /// While files are still being estimated, the rest are extrapolated
    /// from the ones that are done, kind by kind.
    public Prediction? Prediction(Preset? preset)
    {
        var key = preset is { } p ? CompressSettings.Applying(p).SizeKey : Settings.SizeKey;
        long before = 0, after = 0;
        var byKind = new Dictionary<FileKind, (long Before, long After)>();
        var unknown = new List<FileItem>();
        foreach (var item in Items)
        {
            before += item.Size;
            if (item.Estimates.TryGetValue(key, out var estimate))
            {
                after += estimate;
                var k = byKind.GetValueOrDefault(item.Kind);
                byKind[item.Kind] = (k.Before + item.Size, k.After + estimate);
            }
            else unknown.Add(item);
        }
        if (unknown.Count == Items.Count) return null;

        var knownBefore = byKind.Values.Sum(v => v.Before);
        var overall = knownBefore > 0 ? (double)after / knownBefore : 1;
        foreach (var item in unknown)
        {
            var ratio = byKind.TryGetValue(item.Kind, out var k) && k.Before > 0 ? (double)k.After / k.Before : overall;
            after += (long)(item.Size * ratio);
        }
        return new Prediction(before, after, unknown.Count == 0);
    }

    Settings CompressSettings => Settings with { Mode = Mode.Compress };

    public bool IsCustom => IsCompress && Settings.Preset == null;
    public string CustomSummary => Items.Count > 0 && Prediction(null) is { } p ? $"CUSTOM · ≈ {Formatting.Size(p.After)}" : "CUSTOM";
    public bool ShowConvertSummary => IsConvert && Items.Count > 0;
    public string ConvertPredicted => Prediction(null) is { } p ? $"≈ {Formatting.Size(p.After)}" : "—";
    public string ConvertPercent => Prediction(null) is { } p ? Formatting.Percent(p.Saving) : "";
    public bool ConvertSaves => Prediction(null) is { Saving: >= 0.005 };
    public double ConvertOpacity => Prediction(null) is { Complete: false } ? 0.55 : 1;

    void RefreshPredictions()
    {
        var current = Settings.Preset;
        foreach (var cell in Presets)
        {
            cell.IsSelected = current == cell.Preset;
            cell.Update(Items.Count > 0 ? Prediction(cell.Preset) : null, Items.Count > 0);
        }
        Raise(nameof(IsCustom), nameof(CustomSummary), nameof(ShowConvertSummary), nameof(ConvertPredicted),
            nameof(ConvertPercent), nameof(ConvertSaves), nameof(ConvertOpacity));
    }

    /// The three presets plus custom settings in Compress mode; just the
    /// current targets in Convert mode.
    List<Settings> EstimateTargets(Mode mode)
    {
        if (mode == Mode.Convert) return [(Settings with { Mode = Mode.Convert }).SizeKey];
        var targets = Enum.GetValues<Preset>().Select(p => CompressSettings.Applying(p).SizeKey).ToList();
        if (!targets.Contains(CompressSettings.SizeKey)) targets.Add(CompressSettings.SizeKey);
        return targets;
    }

    /// Debounced, so dragging the quality slider doesn't queue up work.
    void ScheduleEstimates(int delay = 350)
    {
        _estimates?.Cancel();
        if (Items.Count == 0 || IsRunning) return;
        var cancel = (_estimates = new CancellationTokenSource()).Token;
        _ = RunEstimates(delay, cancel);
    }

    async Task RunEstimates(int delay, CancellationToken cancel)
    {
        try { await Task.Delay(delay, cancel); } catch (OperationCanceledException) { return; }
        var targets = EstimateTargets(Mode);
        // Keep both modes' estimates so switching back and forth is instant.
        var wanted = EstimateTargets(Mode.Compress).Concat(EstimateTargets(Mode.Convert)).ToHashSet();
        foreach (var item in Items)
            foreach (var key in item.Estimates.Keys.Where(k => !wanted.Contains(k)).ToList()) item.Estimates.Remove(key);

        var pending = Items.Where(i => targets.Any(t => !i.Estimates.ContainsKey(t))).ToList();
        var next = 0;
        async Task Worker()
        {
            while (!cancel.IsCancellationRequested && next < pending.Count)
            {
                await Estimate(pending[next++], targets, cancel);
                RefreshPredictions();
            }
        }
        await Task.WhenAll(Worker(), Worker());
    }

    async Task Estimate(FileItem item, List<Settings> targets, CancellationToken cancel)
    {
        var missing = targets.Where(t => !item.Estimates.ContainsKey(t)).ToList();
        if (missing.Count == 0 || cancel.IsCancellationRequested) return;
        var (path, kind, size) = (item.Path, item.Kind, item.Size);
        Dictionary<Settings, EngineEstimate> results;
        try
        {
            results = kind switch
            {
                FileKind.Image => await Task.Run(() => ImageEngine.Estimate(path, missing)),
                FileKind.Pdf => await Task.Run(() => PdfEngine.Estimate(path, size, missing)),
                _ => await Task.Run(() => MediaEngine.Estimate(path, kind, missing)),
            };
        }
        catch (Exception) { results = []; }

        // Anything that couldn't be estimated, or that would be left alone
        // (not smaller, or already in the target format), stays as it is.
        foreach (var target in missing)
        {
            if (!results.TryGetValue(target, out var result)) { item.Estimates[target] = size; continue; }
            var unchanged = target.Mode == Mode.Compress
                ? KeepsOriginal(item, result.Bytes, result.Ext)
                : kind is FileKind.Image or FileKind.Audio && SameFormat(path, result.Ext);
            item.Estimates[target] = unchanged ? size : result.Bytes;
        }
    }
}

/// Settings and window preferences, in %APPDATA%\Squish\settings.json.
public sealed record Prefs
{
    public Settings Settings { get; init; } = new();
    public int Appearance { get; init; }
    public bool FineTune { get; init; }

    static readonly string File = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Squish", "settings.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };

    public static Prefs Load()
    {
        try { return JsonSerializer.Deserialize<Prefs>(System.IO.File.ReadAllText(File), Json) ?? new(); }
        catch (Exception) { return new(); }
    }

    public static void Save(Prefs prefs)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(File)!);
            System.IO.File.WriteAllText(File, JsonSerializer.Serialize(prefs, Json));
        }
        catch (Exception) { /* preferences are best-effort */ }
    }
}
