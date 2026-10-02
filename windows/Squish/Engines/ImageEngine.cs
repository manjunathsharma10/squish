using PdfSharp.Drawing;
using PdfSharp.Pdf;
using WinDecoder = Windows.Graphics.Imaging.BitmapDecoder;

namespace Squish.Engines;

/// Resizes, recompresses and converts images; also images → PDF.
public static class ImageEngine
{
    public static async Task<EngineOutput> Run(string input, string tempBase, Settings settings)
    {
        if (MakesPdf(settings)) return await MakePdf([input], tempBase + ".pdf", settings);

        using var source = await Imaging.Source.Open(input);
        if (settings.Mode == Mode.Convert && SourceFormat(source.Codec) == settings.ImageFormat)
            throw new AlreadyInFormatException(settings.ImageFormat.Label());

        var pixels = await source.Decode(source.Edge(settings));
        var metadata = settings.KeepMetadata ? await Imaging.ReadMetadata(source.Decoder) : null;
        var (data, format) = await Encode(pixels, source, settings, metadata);
        var path = $"{tempBase}.{format.Ext()}";
        await File.WriteAllBytesAsync(path, data);
        return new EngineOutput(path, format.Ext(), Formatting.Dimensions(pixels.Width, pixels.Height));
    }

    public static bool MakesPdf(Settings settings) => settings.Mode == Mode.Convert && settings.Convert.Image == ImageTarget.Pdf;

    /// Exact sizes: each target is really encoded, in memory. Targets that
    /// share an output size share one decode.
    public static async Task<Dictionary<Settings, EngineEstimate>> Estimate(string input, IReadOnlyList<Settings> targets)
    {
        using var source = await Imaging.Source.Open(input);
        var estimates = new Dictionary<Settings, EngineEstimate>();
        foreach (var group in targets.GroupBy(source.Edge))
        {
            var pixels = await source.Decode(group.Key);
            foreach (var target in group)
            {
                if (MakesPdf(target))
                {
                    // The page's image data plus page and file overhead.
                    var page = await Imaging.Encode(pixels, pixels.HasAlpha ? ImageFormat.Png : ImageFormat.Jpeg, target.Quality);
                    estimates[target] = new EngineEstimate(page.Length + 3_000, "pdf");
                }
                else
                {
                    var (data, format) = await Encode(pixels, source, target, null);
                    estimates[target] = new EngineEstimate(data.Length, format.Ext());
                }
            }
        }
        return estimates;
    }

    static async Task<(byte[] Data, ImageFormat Format)> Encode(Pixels pixels, Imaging.Source source, Settings settings,
                                                                 List<KeyValuePair<string, Windows.Graphics.Imaging.BitmapTypedValue>>? metadata)
    {
        var format = Resolve(settings.ImageFormat, source.Codec, pixels.HasAlpha);
        // Lossy PNG: reduce to a 256-colour palette (like pngquant).
        // Conversions to PNG stay lossless.
        if (format == ImageFormat.Png && settings.Quality < 0.85 && settings.Mode == Mode.Compress)
            return (PaletteEncoder.Encode(pixels, settings.Quality < 0.45 ? 128 : 256), format);
        return (await Imaging.Encode(pixels, format, settings.Quality, metadata: metadata), format);
    }

    static ImageFormat? SourceFormat(Guid codec)
    {
        if (codec == WinDecoder.JpegDecoderId) return ImageFormat.Jpeg;
        if (codec == WinDecoder.PngDecoderId) return ImageFormat.Png;
        if (codec == WinDecoder.HeifDecoderId) return ImageFormat.Heic;
        if (codec == WinDecoder.TiffDecoderId) return ImageFormat.Tiff;
        return null;
    }

    /// "Auto" keeps the original format when Windows can write it, otherwise
    /// picks PNG for transparent images and JPEG for everything else.
    static ImageFormat Resolve(ImageFormat chosen, Guid codec, bool hasAlpha)
    {
        if (chosen != ImageFormat.Auto) return chosen;
        var source = SourceFormat(codec);
        if (source == ImageFormat.Heic && !Imaging.CanWriteHeic) source = null;
        return source ?? (hasAlpha ? ImageFormat.Png : ImageFormat.Jpeg);
    }

    // MARK: Images → PDF

    /// One page per image. Pages are capped at A4's long edge (842 pt) so
    /// they print sensibly; the image keeps its full resolution. Opaque
    /// images go in as JPEG at the chosen quality, transparent ones as PNG.
    public static async Task<EngineOutput> MakePdf(IReadOnlyList<string> inputs, string output, Settings settings,
                                                   Action<int>? pageDone = null)
    {
        using var document = new PdfDocument();
        for (var index = 0; index < inputs.Count; index++)
        {
            using (var source = await Imaging.Source.Open(inputs[index]))
            {
                var pixels = await source.Decode(source.Longest);
                var data = await Imaging.Encode(pixels, pixels.HasAlpha ? ImageFormat.Png : ImageFormat.Jpeg, settings.Quality);
                using var stream = new MemoryStream(data);
                using var image = XImage.FromStream(stream);
                var scale = Math.Min(1.0, 842.0 / Math.Max(pixels.Width, pixels.Height));
                var page = document.AddPage();
                page.Width = XUnit.FromPoint(pixels.Width * scale);
                page.Height = XUnit.FromPoint(pixels.Height * scale);
                using var gfx = XGraphics.FromPdfPage(page);
                gfx.DrawImage(image, 0, 0, page.Width.Point, page.Height.Point);
            }
            pageDone?.Invoke(index);
        }
        document.Save(output);
        return new EngineOutput(output, "pdf", Formatting.Pages(inputs.Count));
    }
}
