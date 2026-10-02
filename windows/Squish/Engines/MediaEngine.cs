using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace Squish.Engines;

/// Re-encodes video and audio with Media Foundation's MediaTranscoder on the
/// hardware encoders, with resolution and bitrate planned the same way as on
/// macOS. Video goes to MP4; audio to M4A (AAC), MP3 or WAV.
public static class MediaEngine
{
    static readonly Lazy<Task<bool>> HevcEncoder = new(async () =>
    {
        try
        {
            var found = await new CodecQuery().FindAllAsync(CodecKind.Video, CodecCategory.Encoder, CodecSubtypes.VideoFormatHevc);
            return found.Count > 0;
        }
        catch (Exception) { return false; }
    });

    /// HEVC needs Microsoft's HEVC Video Extensions.
    public static Task<bool> CanEncodeHevc() => HevcEncoder.Value;

    public static async Task<EngineOutput> Run(string input, string tempBase, FileKind kind, Settings settings,
                                               Action<double> progress, CancellationToken cancel)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(input));
        var source = await Inspect(file, kind);
        if (source.Video == null && source.Audio == null) throw new EngineException("No audio or video found in this file");

        var ext = Extension(kind, settings);
        if (settings.Mode == Mode.Convert && AlreadyThere(input, kind, source, settings, ext) is { } format)
            throw new AlreadyInFormatException(format);

        var profile = Profile(kind, source, settings, out var info);
        var path = $"{tempBase}.{ext}";
        File.Create(path).Dispose();
        var output = await StorageFile.GetFileFromPathAsync(path);

        var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
        var prepared = await transcoder.PrepareFileTranscodeAsync(file, output, profile);
        if (!prepared.CanTranscode)
        {
            throw new EngineException(prepared.FailureReason switch
            {
                TranscodeFailureReason.CodecNotFound => "Windows is missing a codec for this file",
                TranscodeFailureReason.InvalidProfile => "These settings don't suit this file",
                _ => "This file can't be converted",
            });
        }
        await prepared.TranscodeAsync().AsTask(cancel, new Reporter(percent => progress(Math.Clamp(percent / 100, 0, 1))));

        if (kind == FileKind.Audio && source.Duration > 0) info.Add(Formatting.Duration(source.Duration));
        return new EngineOutput(path, ext, string.Join(" · ", info));
    }

    /// Bitrate × duration, from the same plans the encoder follows.
    public static async Task<Dictionary<Settings, EngineEstimate>> Estimate(string input, FileKind kind, IReadOnlyList<Settings> targets)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(input));
        var source = await Inspect(file, kind);
        var estimates = new Dictionary<Settings, EngineEstimate>();
        if (source.Duration <= 0) return estimates;
        foreach (var target in targets)
        {
            var ext = Extension(kind, target);
            // Files already in the target format are left as they are.
            if (target.Mode == Mode.Convert && AlreadyThere(input, kind, source, target, ext) != null)
            {
                estimates[target] = new EngineEstimate(new FileInfo(input).Length, ext);
                continue;
            }
            double bits = 0;
            if (source.Video != null) bits += VideoPlan(source, target).Bitrate;
            if (source.Audio != null) bits += AudioPlan(source.Audio, kind, target).Bitrate;
            var bytes = bits * source.Duration / 8 * 1.01 + 4_096; // container overhead
            estimates[target] = new EngineEstimate((long)bytes, ext);
        }
        return estimates;
    }

    sealed class Reporter(Action<double> report) : IProgress<double>
    {
        public void Report(double value) => report(value);
    }

    // MARK: Source

    sealed record Source(VideoEncodingProperties? Video, AudioEncodingProperties? Audio, double Duration, bool Rotated);

    static async Task<Source> Inspect(StorageFile file, FileKind kind)
    {
        MediaEncodingProfile profile;
        try { profile = await MediaEncodingProfile.CreateFromFileAsync(file); }
        catch (Exception) { throw new EngineException("Windows can't read this file. It may need a codec extension."); }

        double duration;
        var rotated = false;
        if (kind == FileKind.Video)
        {
            var video = await file.Properties.GetVideoPropertiesAsync();
            duration = video.Duration.TotalSeconds;
            rotated = video.Orientation is VideoOrientation.Rotate90 or VideoOrientation.Rotate270;
        }
        else
        {
            duration = (await file.Properties.GetMusicPropertiesAsync()).Duration.TotalSeconds;
        }
        var hasVideo = kind == FileKind.Video && profile.Video is { Width: > 0 };
        return new Source(hasVideo ? profile.Video : null, profile.Audio is { SampleRate: > 0 } ? profile.Audio : null, duration, rotated);
    }

    static string Extension(FileKind kind, Settings settings) => kind == FileKind.Audio ? settings.AudioFormat.Ext() : "mp4";

    /// In Convert mode, a file already in the target container and codec is
    /// left alone.
    static string? AlreadyThere(string input, FileKind kind, Source source, Settings settings, string ext)
    {
        var sameContainer = Path.GetExtension(input).TrimStart('.').Equals(ext, StringComparison.OrdinalIgnoreCase);
        if (!sameContainer) return null;
        if (kind == FileKind.Audio) return ext.ToUpperInvariant();
        var codec = source.Video?.Subtype ?? "";
        var same = settings.VideoCodec == VideoCodec.Hevc
            ? codec.Equals(MediaEncodingSubtypes.Hevc, StringComparison.OrdinalIgnoreCase)
            : codec.Equals(MediaEncodingSubtypes.H264, StringComparison.OrdinalIgnoreCase);
        return same ? $"MP4 · {settings.VideoCodec.Label()}" : null;
    }

    // MARK: Profiles

    static MediaEncodingProfile Profile(FileKind kind, Source source, Settings settings, out List<string> info)
    {
        info = [];
        MediaEncodingProfile profile;
        if (kind == FileKind.Audio)
        {
            var plan = AudioPlan(source.Audio!, kind, settings);
            profile = settings.AudioFormat switch
            {
                AudioFormat.Mp3 => MediaEncodingProfile.CreateMp3(AudioEncodingQuality.High),
                AudioFormat.Wav => MediaEncodingProfile.CreateWav(AudioEncodingQuality.High),
                _ => MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High),
            };
            profile.Audio = plan.Properties;
            info.Add(plan.Label);
            return profile;
        }

        var video = VideoPlan(source, settings);
        profile = settings.VideoCodec == VideoCodec.Hevc
            ? MediaEncodingProfile.CreateHevc(VideoEncodingQuality.HD1080p)
            : MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
        profile.Video.Width = (uint)video.Width;
        profile.Video.Height = (uint)video.Height;
        profile.Video.Bitrate = (uint)video.Bitrate;
        profile.Video.FrameRate.Numerator = video.FrameRate.Numerator;
        profile.Video.FrameRate.Denominator = video.FrameRate.Denominator;
        profile.Video.PixelAspectRatio.Numerator = 1;
        profile.Video.PixelAspectRatio.Denominator = 1;
        profile.Audio = source.Audio != null ? AudioPlan(source.Audio, kind, settings).Properties : null;

        var shown = source.Rotated ? Formatting.Dimensions(video.Height, video.Width) : Formatting.Dimensions(video.Width, video.Height);
        info.Add($"{shown} · {settings.VideoCodec.Label()}");
        return profile;
    }

    sealed record Video(int Width, int Height, double Bitrate, (uint Numerator, uint Denominator) FrameRate);

    /// Bits-per-pixel, damped above 30 fps. Compressing never goes above the
    /// source; converting HEVC → H.264 is allowed more, since H.264 needs it
    /// for the same picture.
    static Video VideoPlan(Source source, Settings settings)
    {
        var v = source.Video!;
        double srcW = v.Width, srcH = v.Height;
        var limit = settings.MaxSize.Pixels() is int px ? px : double.PositiveInfinity;
        var scale = Math.Min(1, limit / Math.Max(Math.Max(srcW, srcH), 1));
        static int Even(double value) => Math.Max(2, (int)Math.Round(value / 2) * 2);
        int width = Even(srcW * scale), height = Even(srcH * scale);

        var rate = v.FrameRate.Denominator > 0 && v.FrameRate.Numerator > 0
            ? ((uint)v.FrameRate.Numerator, (uint)v.FrameRate.Denominator)
            : (30u, 1u);
        var fps = rate.Item1 / (double)rate.Item2;
        var motion = Math.Min(fps, 30) + Math.Max(0, fps - 30) * 0.35;
        var bpp = 0.015 + 0.075 * settings.Quality;
        if (settings.VideoCodec == VideoCodec.H264) bpp *= 1.5;
        var bitrate = width * height * motion * bpp;

        var sourceIsHevc = v.Subtype.Equals(MediaEncodingSubtypes.Hevc, StringComparison.OrdinalIgnoreCase);
        var ceiling = settings.Mode == Mode.Compress ? 0.85 : settings.VideoCodec == VideoCodec.H264 && sourceIsHevc ? 1.6 : 1.0;
        if (v.Bitrate > 0) bitrate = Math.Min(bitrate, v.Bitrate * ceiling);
        return new Video(width, height, Math.Max(bitrate, 250_000), rate);
    }

    sealed record Audio(AudioEncodingProperties Properties, double Bitrate, string Label);

    static Audio AudioPlan(AudioEncodingProperties source, FileKind kind, Settings settings)
    {
        var channels = Math.Clamp(source.ChannelCount, 1u, 2u);
        // Windows' AAC and MP3 encoders take 44.1 or 48 kHz.
        var rate = source.SampleRate >= 48_000 ? 48_000u : 44_100u;
        var q = settings.Quality;
        var format = kind == FileKind.Audio ? settings.AudioFormat : AudioFormat.M4a;

        switch (format)
        {
            case AudioFormat.Wav:
                var pcmRate = source.SampleRate > 0 ? source.SampleRate : 44_100u;
                return new Audio(AudioEncodingProperties.CreatePcm(pcmRate, channels, 16), pcmRate * channels * 16.0, "PCM 16-bit");
            case AudioFormat.Mp3:
                var mp3 = q < 0.6 ? 128_000u : q < 0.8 ? 192_000u : q < 0.95 ? 256_000u : 320_000u;
                return new Audio(AudioEncodingProperties.CreateMp3(rate, channels, mp3), mp3, $"{mp3 / 1000} kbps");
            default:
                // The AAC encoder only accepts 96, 128, 160 or 192 kbps.
                var aac = q < 0.6 ? 96_000u : q < 0.8 ? 128_000u : q < 0.95 ? 160_000u : 192_000u;
                return new Audio(AudioEncodingProperties.CreateAac(rate, channels, aac), aac, $"AAC {aac / 1000} kbps");
        }
    }
}
