import CoreGraphics
import Foundation
import zlib

/// Lossy PNG compression: quantizes an image to an indexed palette
/// (median cut + k-means refinement + Floyd–Steinberg dithering) and
/// writes a palette PNG with alpha. Typically 60–80% smaller than a
/// truecolour PNG, the same idea as pngquant.
///
/// Colours are stored flat as RGBA quadruplets of premultiplied Floats.
enum PaletteEncoder {
    static func encode(_ image: CGImage, maxColors: Int = 256) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        // Premultiplied RGBA, row 0 = top.
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let (palette, hasClear) = buildPalette(px, maxColors: maxColors)
        let count = palette.count / 4
        guard count > 0 else { return nil }
        var indices = map(px, width: w, height: h, palette: palette, clearIndex: hasClear ? 0 : nil)

        // Straight alpha, translucent entries first so tRNS stays short.
        var entries: [(old: Int, rgba: [UInt8])] = (0..<count).map { i in
            let a = palette[i * 4 + 3]
            guard a > 0.5 else { return (i, [0, 0, 0, 0]) }
            let k = 255 / a
            let rgba = [palette[i * 4] * k, palette[i * 4 + 1] * k, palette[i * 4 + 2] * k, a]
            return (i, rgba.map { UInt8(max(0, min(255, $0.rounded()))) })
        }
        entries.sort { ($0.rgba[3] == 255 ? 1 : 0) < ($1.rgba[3] == 255 ? 1 : 0) }
        var remap = [UInt8](repeating: 0, count: count)
        for (new, e) in entries.enumerated() { remap[e.old] = UInt8(new) }
        for i in indices.indices { indices[i] = remap[Int(indices[i])] }

        return writePNG(width: w, height: h, palette: entries.map(\.rgba), indices: indices)
    }

    private static let wr: Float = 1.0, wg: Float = 1.25, wb: Float = 0.75, wa: Float = 1.5
    private static let weights: [Float] = [wr, wg, wb, wa]

    // MARK: Palette

    private static func buildPalette(_ px: [UInt8], maxColors: Int) -> (palette: [Float], hasClear: Bool) {
        // Histogram of 5-5-5-4 bit buckets with running sums for exact means.
        let buckets = 1 << 19
        var n = [UInt32](repeating: 0, count: buckets)
        var sums = [UInt32](repeating: 0, count: buckets * 4)
        var hasClear = false
        let pixels = px.count / 4
        let step = max(1, pixels / 4_000_000) // sample very large images

        px.withUnsafeBufferPointer { p in
            n.withUnsafeMutableBufferPointer { n in
                sums.withUnsafeMutableBufferPointer { s in
                    var i = 0
                    while i < pixels {
                        let o = i * 4
                        let r = p[o], g = p[o + 1], b = p[o + 2], a = p[o + 3]
                        if a == 0 {
                            hasClear = true
                        } else {
                            let key = Int(r >> 3) << 14 | Int(g >> 3) << 9 | Int(b >> 3) << 4 | Int(a >> 4)
                            n[key] += 1
                            s[key * 4] += UInt32(r); s[key * 4 + 1] += UInt32(g)
                            s[key * 4 + 2] += UInt32(b); s[key * 4 + 3] += UInt32(a)
                        }
                        i += step
                    }
                }
            }
        }

        var colors: [Float] = [], weight: [Float] = []
        for k in 0..<buckets where n[k] > 0 {
            let c = Float(n[k])
            for ch in 0..<4 { colors.append(Float(sums[k * 4 + ch]) / c) }
            weight.append(c)
        }

        let clear: [Float] = hasClear ? [0, 0, 0, 0] : []
        let budget = maxColors - (hasClear ? 1 : 0)
        if weight.count <= budget { return (clear + colors, hasClear) }

        var palette = medianCut(colors, weight, budget)
        refine(&palette, colors, weight, iterations: weight.count > 200_000 ? 2 : 4)
        return (clear + palette, hasClear)
    }

    private struct Box {
        var items: [Int]
        var score: Float = 0
        var axis = 0
    }

    private static func medianCut(_ colors: [Float], _ weight: [Float], _ target: Int) -> [Float] {
        func measure(_ items: [Int]) -> Box {
            var box = Box(items: items)
            guard items.count > 1 else { return box }
            var best: Float = -1
            for ch in 0..<4 {
                var sum: Float = 0, sq: Float = 0, wt: Float = 0
                for i in items {
                    let v = colors[i * 4 + ch], ww = weight[i]
                    sum += v * ww; sq += v * v * ww; wt += ww
                }
                let variance = (sq - sum * sum / wt) * weights[ch]
                if variance > best { best = variance; box.axis = ch }
            }
            box.score = max(0, best)
            return box
        }

        var boxes = [measure(Array(weight.indices))]
        while boxes.count < target {
            guard let pick = boxes.indices.max(by: { boxes[$0].score < boxes[$1].score }),
                  boxes[pick].score > 0
            else { break }
            let box = boxes.remove(at: pick)
            let axis = box.axis
            let sorted = box.items.sorted { colors[$0 * 4 + axis] < colors[$1 * 4 + axis] }
            let half = sorted.reduce(Float(0)) { $0 + weight[$1] } / 2
            var acc: Float = 0, cut = 1
            for (j, i) in sorted.enumerated() {
                acc += weight[i]
                if acc >= half { cut = max(1, min(sorted.count - 1, j + 1)); break }
            }
            boxes.append(measure(Array(sorted[..<cut])))
            boxes.append(measure(Array(sorted[cut...])))
        }

        var palette: [Float] = []
        palette.reserveCapacity(boxes.count * 4)
        for box in boxes {
            var mean: [Float] = [0, 0, 0, 0], wt: Float = 0
            for i in box.items {
                for ch in 0..<4 { mean[ch] += colors[i * 4 + ch] * weight[i] }
                wt += weight[i]
            }
            palette += mean.map { $0 / wt }
        }
        return palette
    }

    private static func refine(_ palette: inout [Float], _ colors: [Float], _ weight: [Float], iterations: Int) {
        let k = palette.count / 4
        for _ in 0..<iterations {
            var sums = [Float](repeating: 0, count: k * 4)
            var wts = [Float](repeating: 0, count: k)
            palette.withUnsafeBufferPointer { pal in
                colors.withUnsafeBufferPointer { c in
                    for i in 0..<weight.count {
                        let o = i * 4
                        let best = nearest(c[o], c[o + 1], c[o + 2], c[o + 3], pal)
                        for ch in 0..<4 { sums[best * 4 + ch] += c[o + ch] * weight[i] }
                        wts[best] += weight[i]
                    }
                }
            }
            for j in 0..<k where wts[j] > 0 {
                for ch in 0..<4 { palette[j * 4 + ch] = sums[j * 4 + ch] / wts[j] }
            }
        }
    }

    @inline(__always)
    private static func nearest(_ r: Float, _ g: Float, _ b: Float, _ a: Float, _ pal: UnsafeBufferPointer<Float>) -> Int {
        var best = 0, bestD = Float.greatestFiniteMagnitude
        var o = 0, k = 0
        while o < pal.count {
            let dr = r - pal[o], dg = g - pal[o + 1], db = b - pal[o + 2], da = a - pal[o + 3]
            let d = dr * dr * wr + dg * dg * wg + db * db * wb + da * da * wa
            if d < bestD { bestD = d; best = k }
            o += 4; k += 1
        }
        return best
    }

    // MARK: Mapping

    /// Maps pixels to palette indices with serpentine Floyd–Steinberg dithering.
    private static func map(_ px: [UInt8], width w: Int, height h: Int, palette: [Float], clearIndex: Int?) -> [UInt8] {
        // Plain pointers rather than nested withUnsafe… closures, which older
        // Swift compilers can't type-check in reasonable time.
        let count = w * h, rowFloats = (w + 2) * 4, cacheSize = 1 << 22
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        out.initialize(repeating: 0, count: count)
        let cache = UnsafeMutablePointer<Int16>.allocate(capacity: cacheSize) // 6-6-6-4 bit lookup
        cache.initialize(repeating: -1, count: cacheSize)
        var cur = UnsafeMutablePointer<Float>.allocate(capacity: rowFloats)
        cur.initialize(repeating: 0, count: rowFloats)
        var nxt = UnsafeMutablePointer<Float>.allocate(capacity: rowFloats)
        nxt.initialize(repeating: 0, count: rowFloats)
        let palStorage = UnsafeMutablePointer<Float>.allocate(capacity: palette.count)
        palStorage.initialize(from: palette, count: palette.count)
        let pal = UnsafeBufferPointer(start: palStorage, count: palette.count)
        defer {
            out.deallocate(); cache.deallocate(); cur.deallocate(); nxt.deallocate(); palStorage.deallocate()
        }
        let strength: Float = 0.8

        px.withUnsafeBufferPointer { (p: UnsafeBufferPointer<UInt8>) -> Void in
            for y in 0..<h {
                let ltr = y % 2 == 0
                let dir = ltr ? 4 : -4
                nxt.update(repeating: 0, count: rowFloats)
                for step in 0..<w {
                    let x = ltr ? step : w - 1 - step
                    let o = (y * w + x) * 4
                    if p[o + 3] == 0, let clear = clearIndex {
                        out[y * w + x] = UInt8(clear)
                        continue
                    }
                    let e = (x + 1) * 4
                    let r: Float = max(0, min(255, Float(p[o]) + cur[e]))
                    let g: Float = max(0, min(255, Float(p[o + 1]) + cur[e + 1]))
                    let b: Float = max(0, min(255, Float(p[o + 2]) + cur[e + 2]))
                    let a: Float = max(0, min(255, Float(p[o + 3]) + cur[e + 3]))

                    let kr: Int = (Int(r) >> 2) << 16, kg: Int = (Int(g) >> 2) << 10
                    let kb: Int = (Int(b) >> 2) << 4, ka: Int = Int(a) >> 4
                    let key: Int = kr | kg | kb | ka
                    var k = Int(cache[key])
                    if k < 0 {
                        k = nearest(r, g, b, a, pal)
                        cache[key] = Int16(k)
                    }
                    out[y * w + x] = UInt8(k)

                    let q = k * 4
                    let d0: Float = (r - pal[q]) * strength, d1: Float = (g - pal[q + 1]) * strength
                    let d2: Float = (b - pal[q + 2]) * strength, d3: Float = (a - pal[q + 3]) * strength
                    let ahead = e + dir, behind = e - dir
                    cur[ahead] += d0 * 0.4375; cur[ahead + 1] += d1 * 0.4375
                    cur[ahead + 2] += d2 * 0.4375; cur[ahead + 3] += d3 * 0.4375
                    nxt[behind] += d0 * 0.1875; nxt[behind + 1] += d1 * 0.1875
                    nxt[behind + 2] += d2 * 0.1875; nxt[behind + 3] += d3 * 0.1875
                    nxt[e] += d0 * 0.3125; nxt[e + 1] += d1 * 0.3125
                    nxt[e + 2] += d2 * 0.3125; nxt[e + 3] += d3 * 0.3125
                    nxt[ahead] += d0 * 0.0625; nxt[ahead + 1] += d1 * 0.0625
                    nxt[ahead + 2] += d2 * 0.0625; nxt[ahead + 3] += d3 * 0.0625
                }
                swap(&cur, &nxt)
            }
        }
        return Array(UnsafeBufferPointer(start: out, count: count))
    }

    // MARK: PNG writer

    private static func writePNG(width w: Int, height h: Int, palette: [[UInt8]], indices: [UInt8]) -> Data? {
        let depth = palette.count <= 2 ? 1 : palette.count <= 4 ? 2 : palette.count <= 16 ? 4 : 8
        let perByte = 8 / depth
        let rowBytes = (w + perByte - 1) / perByte

        // Filter type 0 (None) on every row suits palette images best.
        var raw = [UInt8](repeating: 0, count: (rowBytes + 1) * h)
        for y in 0..<h {
            let base = y * (rowBytes + 1) + 1
            for x in 0..<w {
                let shift = 8 - depth * (x % perByte + 1)
                raw[base + x / perByte] |= indices[y * w + x] << shift
            }
        }

        var size = compressBound(uLong(raw.count))
        var deflated = [UInt8](repeating: 0, count: Int(size))
        guard compress2(&deflated, &size, raw, uLong(raw.count), 9) == Z_OK else { return nil }
        deflated.removeSubrange(Int(size)...)

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func be32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).bigEndian, Array.init) }
        func chunk(_ type: String, _ body: [UInt8]) {
            let tagged = Array(type.utf8) + body
            png.append(contentsOf: be32(body.count))
            png.append(contentsOf: tagged)
            png.append(contentsOf: be32(Int(crc32(0, tagged, uInt(tagged.count)))))
        }

        chunk("IHDR", be32(w) + be32(h) + [UInt8(depth), 3, 0, 0, 0])
        chunk("sRGB", [0])
        chunk("PLTE", palette.flatMap { $0.prefix(3) })
        let translucent = palette.prefix { $0[3] < 255 }.map { $0[3] }
        if !translucent.isEmpty { chunk("tRNS", translucent) }
        chunk("IDAT", deflated)
        chunk("IEND", [])
        return png
    }
}
