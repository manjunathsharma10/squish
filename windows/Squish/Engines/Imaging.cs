using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using WinDecoder = Windows.Graphics.Imaging.BitmapDecoder;
using WinEncoder = Windows.Graphics.Imaging.BitmapEncoder;

namespace Squish.Engines;

/// Decoded pixels: BGRA, premultiplied, top row first.
public sealed record Pixels(byte[] Bgra, int Width, int Height, bool HasAlpha);

/// Thin wrapper over Windows.Graphics.Imaging (WIC), which decodes every
/// format Windows has a codec for and applies EXIF orientation and colour
/// management in one pass.
public static class Imaging
{
    public static readonly bool CanWriteHeic =
        WinEncoder.GetEncoderInformationEnumerator().Any(e => e.CodecId == WinEncoder.HeifEncoderId);

    public sealed class Source : IDisposable
    {
        readonly IRandomAccessStream _stream;
        public WinDecoder Decoder { get; }
        public int Longest { get; }
        public Guid Codec => Decoder.DecoderInformation.CodecId;

        Source(IRandomAccessStream stream, WinDecoder decoder)
        {
            _stream = stream;
            Decoder = decoder;
            Longest = (int)Math.Max(Math.Max(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight), 1);
        }

        public static async Task<Source> Open(string path) => await Open(await File.ReadAllBytesAsync(path));

        public static async Task<Source> Open(byte[] bytes)
        {
            var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            try
            {
                return new Source(stream, await WinDecoder.CreateAsync(stream));
            }
            catch (Exception)
            {
                stream.Dispose();
                throw new EngineException("This image can't be read. Windows may need a codec extension for it.");
            }
        }

        public int Edge(Settings settings) => Math.Min(settings.MaxSize.Pixels() ?? Longest, Longest);

        /// Decodes with the longest edge at `edge` pixels. Photos are
        /// colour-managed to sRGB; `raw` keeps the stored values (for PDFs,
        /// where the colour space is declared separately).
        public async Task<Pixels> Decode(int edge, bool raw = false)
        {
            var scale = Math.Min(1.0, edge / (double)Longest);
            // WIC scales before it rotates, so scaled sizes are unrotated.
            var transform = new BitmapTransform
            {
                ScaledWidth = (uint)Math.Max(1, Math.Round(Decoder.PixelWidth * scale)),
                ScaledHeight = (uint)Math.Max(1, Math.Round(Decoder.PixelHeight * scale)),
                InterpolationMode = BitmapInterpolationMode.Fant,
            };
            var data = await Decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
                raw ? ExifOrientationMode.IgnoreExifOrientation : ExifOrientationMode.RespectExifOrientation,
                raw ? ColorManagementMode.DoNotColorManage : ColorManagementMode.ColorManageToSRgb);
            var bytes = data.DetachPixelData();
            var turned = !raw && Decoder.OrientedPixelWidth != Decoder.PixelWidth;
            var (w, h) = turned ? (transform.ScaledHeight, transform.ScaledWidth) : (transform.ScaledWidth, transform.ScaledHeight);
            return new Pixels(bytes, (int)w, (int)h, HasTransparency(bytes));
        }

        public void Dispose() => _stream.Dispose();
    }

    /// Decoders hand back an alpha channel even for opaque images, so look
    /// at the pixels themselves.
    static bool HasTransparency(byte[] bgra)
    {
        for (var i = 3; i < bgra.Length; i += 4)
            if (bgra[i] < 255) return true;
        return false;
    }

    public static Guid EncoderId(ImageFormat format) => format switch
    {
        ImageFormat.Png => WinEncoder.PngEncoderId,
        ImageFormat.Heic => WinEncoder.HeifEncoderId,
        ImageFormat.Tiff => WinEncoder.TiffEncoderId,
        _ => WinEncoder.JpegEncoderId,
    };

    /// Formats without transparency are composited onto white.
    public static async Task<byte[]> Encode(Pixels pixels, ImageFormat format, double quality, double dpi = 96,
                                            IEnumerable<KeyValuePair<string, BitmapTypedValue>>? metadata = null)
    {
        var options = new BitmapPropertySet();
        if (format is ImageFormat.Jpeg or ImageFormat.Heic)
            options.Add("ImageQuality", new BitmapTypedValue((float)Math.Clamp(quality, 0, 1), Windows.Foundation.PropertyType.Single));
        if (format == ImageFormat.Tiff)
            options.Add("TiffCompressionMethod", new BitmapTypedValue((byte)6, Windows.Foundation.PropertyType.UInt8)); // ZIP

        using var stream = new InMemoryRandomAccessStream();
        var encoder = await WinEncoder.CreateAsync(EncoderId(format), stream, options);
        var keepAlpha = pixels.HasAlpha && format != ImageFormat.Jpeg;
        var bytes = pixels.HasAlpha && !keepAlpha ? OnWhite(pixels.Bgra) : pixels.Bgra;
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, keepAlpha ? BitmapAlphaMode.Premultiplied : BitmapAlphaMode.Ignore,
            (uint)pixels.Width, (uint)pixels.Height, dpi, dpi, bytes);

        if (metadata != null)
        {
            foreach (var property in metadata)
            {
                try { await encoder.BitmapProperties.SetPropertiesAsync([property]); }
                catch (Exception) { /* not every format stores every field */ }
            }
        }
        await encoder.FlushAsync();
        return await ReadAll(stream);
    }

    /// Premultiplied BGRA over white: c + (255 − a).
    static byte[] OnWhite(byte[] bgra)
    {
        var copy = (byte[])bgra.Clone();
        for (var i = 0; i < copy.Length; i += 4)
        {
            var add = 255 - copy[i + 3];
            copy[i] = (byte)Math.Min(255, copy[i] + add);
            copy[i + 1] = (byte)Math.Min(255, copy[i + 1] + add);
            copy[i + 2] = (byte)Math.Min(255, copy[i + 2] + add);
            copy[i + 3] = 255;
        }
        return copy;
    }

    public static async Task<byte[]> ReadAll(IRandomAccessStream stream)
    {
        stream.Seek(0);
        var buffer = new byte[stream.Size];
        await stream.ReadAsync(buffer.AsBuffer(), (uint)stream.Size, InputStreamOptions.None);
        return buffer;
    }

    /// Camera, date and location, for "Keep metadata".
    public static async Task<List<KeyValuePair<string, BitmapTypedValue>>> ReadMetadata(WinDecoder decoder)
    {
        string[] keys =
        [
            "System.Photo.DateTaken", "System.Photo.CameraManufacturer", "System.Photo.CameraModel",
            "System.GPS.Latitude", "System.GPS.LatitudeRef", "System.GPS.Longitude", "System.GPS.LongitudeRef",
        ];
        var found = new List<KeyValuePair<string, BitmapTypedValue>>();
        foreach (var key in keys)
        {
            try
            {
                var values = await decoder.BitmapProperties.GetPropertiesAsync([key]);
                if (values.TryGetValue(key, out var value)) found.Add(new(key, value));
            }
            catch (Exception) { /* not present in this format */ }
        }
        return found;
    }
}
