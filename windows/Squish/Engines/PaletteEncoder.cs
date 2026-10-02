using System.Buffers.Binary;
using System.IO.Compression;

namespace Squish.Engines;

/// Lossy PNG compression: quantizes an image to an indexed palette
/// (median cut + k-means refinement + Floyd–Steinberg dithering) and writes
/// a palette PNG with alpha. Typically 60–80% smaller than a truecolour PNG,
/// the same idea as pngquant. Same algorithm as the macOS version.
///
/// Colours are premultiplied RGBA floats, stored flat in groups of four.
public static class PaletteEncoder
{
    const float Wr = 1.0f, Wg = 1.25f, Wb = 0.75f, Wa = 1.5f;
    static readonly float[] Weights = [Wr, Wg, Wb, Wa];

    public static byte[] Encode(Pixels image, int maxColors = 256)
    {
        int w = image.Width, h = image.Height;
        // BGRA → RGBA, still premultiplied.
        var px = new byte[w * h * 4];
        var src = image.Bgra;
        for (var i = 0; i < px.Length; i += 4)
        {
            px[i] = src[i + 2];
            px[i + 1] = src[i + 1];
            px[i + 2] = src[i];
            px[i + 3] = src[i + 3];
        }

        var (palette, hasClear) = BuildPalette(px, maxColors);
        var count = palette.Length / 4;
        var indices = Map(px, w, h, palette, hasClear ? 0 : -1);

        // Straight alpha, translucent entries first so tRNS stays short.
        var entries = Enumerable.Range(0, count).Select(i =>
        {
            var a = palette[i * 4 + 3];
            if (a <= 0.5f) return (Old: i, Rgba: new byte[] { 0, 0, 0, 0 });
            var k = 255f / a;
            byte Clamp(float v) => (byte)Math.Clamp(MathF.Round(v), 0, 255);
            return (Old: i, Rgba: new[] { Clamp(palette[i * 4] * k), Clamp(palette[i * 4 + 1] * k), Clamp(palette[i * 4 + 2] * k), Clamp(a) });
        }).OrderBy(e => e.Rgba[3] == 255 ? 1 : 0).ToArray();

        var remap = new byte[count];
        for (var n = 0; n < entries.Length; n++) remap[entries[n].Old] = (byte)n;
        for (var i = 0; i < indices.Length; i++) indices[i] = remap[indices[i]];

        return WritePng(w, h, entries.Select(e => e.Rgba).ToArray(), indices);
    }

    // MARK: Palette

    static (float[] Palette, bool HasClear) BuildPalette(byte[] px, int maxColors)
    {
        // Histogram of 5-5-5-4 bit buckets with running sums for exact means.
        const int buckets = 1 << 19;
        var n = new uint[buckets];
        var sums = new uint[buckets * 4];
        var hasClear = false;
        var pixels = px.Length / 4;
        var step = Math.Max(1, pixels / 4_000_000); // sample very large images

        for (var i = 0; i < pixels; i += step)
        {
            var o = i * 4;
            byte r = px[o], g = px[o + 1], b = px[o + 2], a = px[o + 3];
            if (a == 0) { hasClear = true; continue; }
            var key = (r >> 3) << 14 | (g >> 3) << 9 | (b >> 3) << 4 | (a >> 4);
            n[key]++;
            sums[key * 4] += r; sums[key * 4 + 1] += g; sums[key * 4 + 2] += b; sums[key * 4 + 3] += a;
        }

        var colors = new List<float>();
        var weight = new List<float>();
        for (var k = 0; k < buckets; k++)
        {
            if (n[k] == 0) continue;
            float c = n[k];
            for (var ch = 0; ch < 4; ch++) colors.Add(sums[k * 4 + ch] / c);
            weight.Add(c);
        }

        float[] clear = hasClear ? [0, 0, 0, 0] : [];
        var budget = maxColors - (hasClear ? 1 : 0);
        if (weight.Count <= budget) return ([.. clear, .. colors], hasClear);

        var colorArray = colors.ToArray();
        var weightArray = weight.ToArray();
        var palette = MedianCut(colorArray, weightArray, budget);
        Refine(palette, colorArray, weightArray, weightArray.Length > 200_000 ? 2 : 4);
        return ([.. clear, .. palette], hasClear);
    }

    sealed class Box(int[] items)
    {
        public int[] Items = items;
        public float Score;
        public int Axis;
    }

    static float[] MedianCut(float[] colors, float[] weight, int target)
    {
        Box Measure(int[] items)
        {
            var box = new Box(items);
            if (items.Length < 2) return box;
            var best = -1f;
            for (var ch = 0; ch < 4; ch++)
            {
                float sum = 0, sq = 0, wt = 0;
                foreach (var i in items)
                {
                    var v = colors[i * 4 + ch];
                    var ww = weight[i];
                    sum += v * ww; sq += v * v * ww; wt += ww;
                }
                var variance = (sq - sum * sum / wt) * Weights[ch];
                if (variance > best) { best = variance; box.Axis = ch; }
            }
            box.Score = Math.Max(0, best);
            return box;
        }

        var boxes = new List<Box> { Measure(Enumerable.Range(0, weight.Length).ToArray()) };
        while (boxes.Count < target)
        {
            var pick = 0;
            for (var i = 1; i < boxes.Count; i++) if (boxes[i].Score > boxes[pick].Score) pick = i;
            if (boxes[pick].Score <= 0) break;

            var box = boxes[pick];
            boxes.RemoveAt(pick);
            var axis = box.Axis;
            var sorted = box.Items.OrderBy(i => colors[i * 4 + axis]).ToArray();
            var half = sorted.Sum(i => weight[i]) / 2;
            float acc = 0;
            var cut = 1;
            for (var j = 0; j < sorted.Length; j++)
            {
                acc += weight[sorted[j]];
                if (acc >= half) { cut = Math.Clamp(j + 1, 1, sorted.Length - 1); break; }
            }
            boxes.Add(Measure(sorted[..cut]));
            boxes.Add(Measure(sorted[cut..]));
        }

        var palette = new float[boxes.Count * 4];
        for (var b = 0; b < boxes.Count; b++)
        {
            float wt = 0;
            var mean = new float[4];
            foreach (var i in boxes[b].Items)
            {
                for (var ch = 0; ch < 4; ch++) mean[ch] += colors[i * 4 + ch] * weight[i];
                wt += weight[i];
            }
            for (var ch = 0; ch < 4; ch++) palette[b * 4 + ch] = mean[ch] / wt;
        }
        return palette;
    }

    static void Refine(float[] palette, float[] colors, float[] weight, int iterations)
    {
        var k = palette.Length / 4;
        for (var iteration = 0; iteration < iterations; iteration++)
        {
            var sums = new float[k * 4];
            var wts = new float[k];
            for (var i = 0; i < weight.Length; i++)
            {
                var o = i * 4;
                var best = Nearest(colors[o], colors[o + 1], colors[o + 2], colors[o + 3], palette);
                for (var ch = 0; ch < 4; ch++) sums[best * 4 + ch] += colors[o + ch] * weight[i];
                wts[best] += weight[i];
            }
            for (var j = 0; j < k; j++)
            {
                if (wts[j] <= 0) continue;
                for (var ch = 0; ch < 4; ch++) palette[j * 4 + ch] = sums[j * 4 + ch] / wts[j];
            }
        }
    }

    static int Nearest(float r, float g, float b, float a, float[] palette)
    {
        int best = 0, k = 0;
        var bestD = float.MaxValue;
        for (var o = 0; o < palette.Length; o += 4, k++)
        {
            float dr = r - palette[o], dg = g - palette[o + 1], db = b - palette[o + 2], da = a - palette[o + 3];
            var d = dr * dr * Wr + dg * dg * Wg + db * db * Wb + da * da * Wa;
            if (d < bestD) { bestD = d; best = k; }
        }
        return best;
    }

    // MARK: Mapping

    /// Maps pixels to palette indices with serpentine Floyd–Steinberg dithering.
    static byte[] Map(byte[] px, int w, int h, float[] palette, int clearIndex)
    {
        var output = new byte[w * h];
        var cache = new short[1 << 22]; // 6-6-6-4 bit lookup
        Array.Fill(cache, (short)-1);
        var err = new float[(w + 2) * 4];
        var next = new float[(w + 2) * 4];
        const float strength = 0.8f;

        for (var y = 0; y < h; y++)
        {
            var ltr = y % 2 == 0;
            var dir = ltr ? 4 : -4;
            Array.Clear(next);
            for (var step = 0; step < w; step++)
            {
                var x = ltr ? step : w - 1 - step;
                var o = (y * w + x) * 4;
                if (px[o + 3] == 0 && clearIndex >= 0)
                {
                    output[y * w + x] = (byte)clearIndex;
                    continue;
                }
                var e = (x + 1) * 4;
                var r = Math.Clamp(px[o] + err[e], 0, 255);
                var g = Math.Clamp(px[o + 1] + err[e + 1], 0, 255);
                var b = Math.Clamp(px[o + 2] + err[e + 2], 0, 255);
                var a = Math.Clamp(px[o + 3] + err[e + 3], 0, 255);

                var key = ((int)r >> 2) << 16 | ((int)g >> 2) << 10 | ((int)b >> 2) << 4 | ((int)a >> 4);
                int k = cache[key];
                if (k < 0) { k = Nearest(r, g, b, a, palette); cache[key] = (short)k; }
                output[y * w + x] = (byte)k;

                var q = k * 4;
                float d0 = (r - palette[q]) * strength, d1 = (g - palette[q + 1]) * strength;
                float d2 = (b - palette[q + 2]) * strength, d3 = (a - palette[q + 3]) * strength;
                int ahead = e + dir, behind = e - dir;
                err[ahead] += d0 * 0.4375f; err[ahead + 1] += d1 * 0.4375f; err[ahead + 2] += d2 * 0.4375f; err[ahead + 3] += d3 * 0.4375f;
                next[behind] += d0 * 0.1875f; next[behind + 1] += d1 * 0.1875f; next[behind + 2] += d2 * 0.1875f; next[behind + 3] += d3 * 0.1875f;
                next[e] += d0 * 0.3125f; next[e + 1] += d1 * 0.3125f; next[e + 2] += d2 * 0.3125f; next[e + 3] += d3 * 0.3125f;
                next[ahead] += d0 * 0.0625f; next[ahead + 1] += d1 * 0.0625f; next[ahead + 2] += d2 * 0.0625f; next[ahead + 3] += d3 * 0.0625f;
            }
            (err, next) = (next, err);
        }
        return output;
    }

    // MARK: PNG writer

    static byte[] WritePng(int w, int h, byte[][] palette, byte[] indices)
    {
        var depth = palette.Length <= 2 ? 1 : palette.Length <= 4 ? 2 : palette.Length <= 16 ? 4 : 8;
        var perByte = 8 / depth;
        var rowBytes = (w + perByte - 1) / perByte;

        // Filter type 0 (None) on every row suits palette images best.
        var raw = new byte[(rowBytes + 1) * h];
        for (var y = 0; y < h; y++)
        {
            var row = y * (rowBytes + 1) + 1;
            for (var x = 0; x < w; x++)
            {
                var shift = 8 - depth * (x % perByte + 1);
                raw[row + x / perByte] |= (byte)(indices[y * w + x] << shift);
            }
        }

        byte[] deflated;
        using (var buffer = new MemoryStream())
        {
            using (var z = new ZLibStream(buffer, CompressionLevel.SmallestSize, leaveOpen: true)) z.Write(raw);
            deflated = buffer.ToArray();
        }

        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        void Chunk(string type, byte[] body)
        {
            var tagged = new byte[4 + body.Length];
            System.Text.Encoding.ASCII.GetBytes(type, tagged);
            body.CopyTo(tagged, 4);
            png.Write(Be32((uint)body.Length));
            png.Write(tagged);
            png.Write(Be32(Crc32(tagged)));
        }

        var header = new byte[13];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)w);
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(4), (uint)h);
        header[8] = (byte)depth;
        header[9] = 3; // indexed colour
        Chunk("IHDR", header);
        Chunk("sRGB", [0]);
        Chunk("PLTE", palette.SelectMany(c => c.Take(3)).ToArray());
        var translucent = palette.TakeWhile(c => c[3] < 255).Select(c => c[3]).ToArray();
        if (translucent.Length > 0) Chunk("tRNS", translucent);
        Chunk("IDAT", deflated);
        Chunk("IEND", []);
        return png.ToArray();
    }

    static byte[] Be32(uint v)
    {
        var b = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(b, v);
        return b;
    }

    static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    static uint Crc32(byte[] data)
    {
        var c = 0xFFFFFFFFu;
        foreach (var b in data) c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }
}
