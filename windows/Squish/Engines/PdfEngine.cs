using System.Runtime.InteropServices.WindowsRuntime;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.Filters;
using PdfSharp.Pdf.IO;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using SharpDocument = PdfSharp.Pdf.PdfDocument;
using WinPdfDocument = Windows.Data.Pdf.PdfDocument;

namespace Squish.Engines;

/// PDF compression rewrites the document's images directly with PDFsharp:
/// photos (JPEG) and plain RGB/grey bitmaps are downsampled and re-encoded
/// as JPEG. Text and vector graphics are untouched. Unlike a print filter,
/// this also reaches images nested inside form objects.
///
/// PDF → images uses Windows' built-in PDF renderer.
public static class PdfEngine
{
    public static async Task<EngineOutput> Run(string input, string tempBase, Settings settings)
    {
        var (data, pages) = await Compress(input, settings);
        var path = tempBase + ".pdf";
        await File.WriteAllBytesAsync(path, data);
        return new EngineOutput(path, "pdf", Formatting.Pages(pages));
    }

    /// Exact sizes from real runs in memory. Very large PDFs are skipped
    /// (left unestimated) to keep this cheap.
    public static async Task<Dictionary<Settings, EngineEstimate>> Estimate(string input, long size, IReadOnlyList<Settings> targets)
    {
        if (targets.All(t => t.Mode == Mode.Convert)) return await EstimatePages(input, targets);
        var estimates = new Dictionary<Settings, EngineEstimate>();
        if (size > 150_000_000) return estimates;
        foreach (var target in targets)
        {
            var (data, _) = await Compress(input, target);
            estimates[target] = new EngineEstimate(data.Length, "pdf");
        }
        return estimates;
    }

    // MARK: Compress

    static async Task<(byte[] Data, int Pages)> Compress(string input, Settings settings)
    {
        SharpDocument document;
        try
        {
            document = PdfReader.Open(input, PdfDocumentOpenMode.Modify);
        }
        catch (PdfReaderException e) when (e.Message.Contains("password", StringComparison.OrdinalIgnoreCase))
        {
            throw new EngineException("This PDF is password-protected");
        }
        catch (Exception)
        {
            throw new EngineException("This PDF can't be opened");
        }

        using (document)
        {
            foreach (var item in document.Internals.GetAllObjects())
            {
                if (item is PdfDictionary dict && dict.Stream != null && dict.Elements.GetName("/Subtype") == "/Image")
                {
                    try { await Recompress(dict, document, settings); }
                    catch (Exception) { /* leave this image as it was */ }
                }
            }
            document.Options.CompressContentStreams = true;
            document.Options.NoCompression = false;
            using var buffer = new MemoryStream();
            document.Save(buffer);
            return (buffer.ToArray(), document.PageCount);
        }
    }

    static async Task Recompress(PdfDictionary image, SharpDocument document, Settings settings)
    {
        var e = image.Elements;
        if (e.GetBoolean("/ImageMask") || e.ContainsKey("/Decode") || e.GetInteger("/BitsPerComponent") != 8) return;
        var width = e.GetInteger("/Width");
        var height = e.GetInteger("/Height");
        if (width < 64 || height < 64) return;

        var channels = Channels(e["/ColorSpace"]);
        if (channels is not (1 or 3)) return; // CMYK, indexed and spot colours are left alone

        var stored = image.Stream.Value;
        if (stored.Length < 20_000) return;

        var filter = FilterName(e["/Filter"]);
        var longest = Math.Max(width, height);
        var edge = Math.Min(settings.MaxSize.Pixels() ?? longest, longest);
        Pixels pixels;
        if (filter == "/DCTDecode")
        {
            using var source = await Imaging.Source.Open(stored);
            pixels = await source.Decode(edge, raw: true);
        }
        else if (filter == "/FlateDecode")
        {
            // Decoded without touching the document, in case it's kept as is.
            var raw = Filtering.Decode(stored, e["/Filter"]!, e["/DecodeParms"]);
            if (raw == null || raw.Length != width * height * channels) return;
            pixels = await Resize(ToBgra(raw, channels, width, height), edge);
        }
        else return;

        var jpeg = channels == 1
            ? await EncodeGray(pixels, settings.Quality)
            : await Imaging.Encode(pixels, ImageFormat.Jpeg, settings.Quality);
        if (jpeg.Length >= stored.Length * 0.9) return;

        image.Stream.Value = jpeg;
        e.SetName("/Filter", "/DCTDecode");
        e.Remove("/DecodeParms");
        e.SetInteger("/Width", pixels.Width);
        e.SetInteger("/Height", pixels.Height);
        e.SetInteger("/Length", jpeg.Length);
    }

    static string? FilterName(PdfItem? filter) => Resolve(filter) switch
    {
        PdfName name => name.Value,
        PdfArray { Elements.Count: 1 } array => (Resolve(array.Elements[0]) as PdfName)?.Value,
        _ => null,
    };

    /// RGB or grey, directly or through an ICC profile.
    static int Channels(PdfItem? colorSpace)
    {
        switch (Resolve(colorSpace))
        {
            case PdfName { Value: "/DeviceRGB" }: return 3;
            case PdfName { Value: "/DeviceGray" }: return 1;
            case PdfArray array when array.Elements.Count == 2 && (Resolve(array.Elements[0]) as PdfName)?.Value == "/ICCBased":
                return Resolve(array.Elements[1]) is PdfDictionary profile ? profile.Elements.GetInteger("/N") : 0;
            default: return 0;
        }
    }

    static PdfItem? Resolve(PdfItem? item) => item is PdfReference reference ? reference.Value : item;

    static Pixels ToBgra(byte[] raw, int channels, int width, int height)
    {
        var bgra = new byte[width * height * 4];
        for (int i = 0, o = 0; o < bgra.Length; i += channels, o += 4)
        {
            if (channels == 3) { bgra[o] = raw[i + 2]; bgra[o + 1] = raw[i + 1]; bgra[o + 2] = raw[i]; }
            else { bgra[o] = bgra[o + 1] = bgra[o + 2] = raw[i]; }
            bgra[o + 3] = 255;
        }
        return new Pixels(bgra, width, height, false);
    }

    /// Lossless round trip through PNG lets WIC do the high-quality resize.
    static async Task<Pixels> Resize(Pixels pixels, int edge)
    {
        if (Math.Max(pixels.Width, pixels.Height) <= edge) return pixels;
        using var source = await Imaging.Source.Open(await Imaging.Encode(pixels, ImageFormat.Png, 1));
        return await source.Decode(edge, raw: true);
    }

    /// Grey images stay single-channel, matching their declared colour space.
    static async Task<byte[]> EncodeGray(Pixels pixels, double quality)
    {
        var gray = new byte[pixels.Width * pixels.Height];
        for (int i = 0, o = 0; i < gray.Length; i++, o += 4) gray[i] = pixels.Bgra[o + 1];
        var options = new BitmapPropertySet
        {
            ["ImageQuality"] = new BitmapTypedValue((float)quality, Windows.Foundation.PropertyType.Single),
        };
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream, options);
        var bitmap = new SoftwareBitmap(BitmapPixelFormat.Gray8, pixels.Width, pixels.Height, BitmapAlphaMode.Ignore);
        bitmap.CopyFromBuffer(gray.AsBuffer());
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync();
        return await Imaging.ReadAll(stream);
    }

    // MARK: PDF → images

    /// Renders every page at the chosen DPI. A one-page PDF becomes a single
    /// image; longer ones become a folder of numbered images.
    public static async Task<EngineOutput> ExportPages(string input, string tempBase, Settings settings, Action<double>? progress = null)
    {
        var pdf = await Load(input);
        var count = (int)pdf.PageCount;
        var format = settings.Convert.Pages.AsImageFormat();
        var dpi = settings.Convert.PageDpi;
        var name = Path.GetFileNameWithoutExtension(input);
        var digits = count.ToString().Length;

        var output = count > 1 ? tempBase : $"{tempBase}.{format.Ext()}";
        if (count > 1) Directory.CreateDirectory(output);
        for (var index = 0; index < count; index++)
        {
            var data = await RenderPage(pdf, index, dpi, format, settings.Quality);
            var file = count > 1 ? Path.Combine(output, $"{name}-{(index + 1).ToString().PadLeft(digits, '0')}.{format.Ext()}") : output;
            await File.WriteAllBytesAsync(file, data);
            progress?.Invoke((index + 1) / (double)count);
        }
        return new EngineOutput(output, count > 1 ? "" : format.Ext(), $"{Formatting.Pages(count)} · {dpi} dpi", format.Label());
    }

    /// Renders up to three pages spread through the document and scales by
    /// the page count.
    static async Task<Dictionary<Settings, EngineEstimate>> EstimatePages(string input, IReadOnlyList<Settings> targets)
    {
        var pdf = await Load(input);
        var count = (int)pdf.PageCount;
        var samples = new[] { 0, count / 2, count - 1 }.Distinct().ToArray();
        var estimates = new Dictionary<Settings, EngineEstimate>();
        foreach (var target in targets)
        {
            var format = target.Convert.Pages.AsImageFormat();
            long bytes = 0;
            foreach (var index in samples)
                bytes += (await RenderPage(pdf, index, target.Convert.PageDpi, format, target.Quality)).Length;
            estimates[target] = new EngineEstimate(bytes / samples.Length * count, count > 1 ? "" : format.Ext());
        }
        return estimates;
    }

    static async Task<WinPdfDocument> Load(string input)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(input));
            var pdf = await WinPdfDocument.LoadFromFileAsync(file);
            if (pdf.IsPasswordProtected) throw new EngineException("This PDF is password-protected");
            if (pdf.PageCount == 0) throw new EngineException("This PDF has no pages");
            return pdf;
        }
        catch (EngineException) { throw; }
        catch (Exception) { throw new EngineException("This PDF can't be opened. It may be password-protected."); }
    }

    /// Draws a page on white at `dpi`. Page sizes are in 96-per-inch units;
    /// huge pages are capped at 40 megapixels.
    static async Task<byte[]> RenderPage(WinPdfDocument pdf, int index, int dpi, ImageFormat format, double quality)
    {
        using var page = pdf.GetPage((uint)index);
        var size = page.Size;
        var scale = dpi / 96.0;
        var area = size.Width * size.Height;
        if (area * scale * scale > 40_000_000) scale = Math.Sqrt(40_000_000 / area);

        using var stream = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(stream, new PdfPageRenderOptions
        {
            DestinationWidth = (uint)Math.Max(1, Math.Round(size.Width * scale)),
            DestinationHeight = (uint)Math.Max(1, Math.Round(size.Height * scale)),
            BackgroundColor = new Windows.UI.Color { A = 255, R = 255, G = 255, B = 255 },
            BitmapEncoderId = BitmapEncoder.BmpEncoderId,
        });
        using var source = await Imaging.Source.Open(await Imaging.ReadAll(stream));
        var pixels = await source.Decode(source.Longest);
        return await Imaging.Encode(pixels with { HasAlpha = false }, format, quality, dpi);
    }
}
