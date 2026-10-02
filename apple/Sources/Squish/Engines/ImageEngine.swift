import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Resizes, recompresses and converts images with ImageIO.
enum ImageEngine {
    static func run(input: URL, output: URL, settings: Settings) throws -> EngineOutput {
        if makesPDF(settings) { return try makePDF(from: [input], output: output, settings: settings) }
        let source = try Source(input)
        if settings.mode == .convert, let target = settings.imageFormat.type, source.type == target.identifier {
            throw AlreadyInFormat(format: settings.imageFormat.label)
        }
        let (data, format, image) = try encode(source.decode(edge: source.edge(for: settings)), from: source, settings: settings)
        try data.write(to: output)
        return EngineOutput(ext: format.ext, info: Format.dimensions(image.width, image.height))
    }

    static func makesPDF(_ settings: Settings) -> Bool {
        settings.mode == .convert && settings.convert.image == .pdf
    }

    // MARK: Images → PDF

    /// One page per image. Pages are capped at A4's long edge (842 pt) so
    /// they print sensibly; the image keeps its full resolution.
    static func makePDF(from inputs: [URL], output: URL, settings: Settings,
                        pageDone: ((Int) -> Void)? = nil) throws -> EngineOutput {
        guard let pdf = CGContext(output as CFURL, mediaBox: nil, nil) else { throw EngineError("Couldn't create the PDF") }
        for (index, url) in inputs.enumerated() {
            try autoreleasepool {
                let source = try Source(url)
                let decoded = try source.decode(edge: source.longest)
                let image = try pageImage(decoded, alpha: source.hasAlpha(decoded), quality: settings.quality).image
                let scale = min(1, 842 / CGFloat(max(image.width, image.height)))
                var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                pdf.beginPDFPage(info)
                pdf.interpolationQuality = .high
                pdf.draw(image, in: box)
                pdf.endPDFPage()
            }
            pageDone?(index)
        }
        pdf.closePDF()
        return EngineOutput(ext: "pdf", info: inputs.count == 1 ? "1 page" : "\(inputs.count) pages")
    }

    /// Opaque images are stored as JPEG at the chosen quality: decoding the
    /// encoded bytes back through ImageIO lets Quartz embed them as-is.
    /// Transparent images go in losslessly.
    private static func pageImage(_ image: CGImage, alpha: Bool, quality: Double) throws -> (image: CGImage, bytes: Int) {
        let type = alpha ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw EngineError("Couldn't encode the page")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError("Couldn't encode the page") }
        guard !alpha,
              let src = CGImageSourceCreateWithData(data, nil),
              let embedded = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return (image, data.length) }
        return (embedded, data.length)
    }

    /// Exact sizes: each target is really encoded, in memory. Targets that
    /// share an output size share one decode.
    static func estimate(input: URL, targets: [Settings]) throws -> [Settings: EngineEstimate] {
        let source = try Source(input)
        var estimates: [Settings: EngineEstimate] = [:]
        for (edge, group) in Dictionary(grouping: targets, by: source.edge(for:)) {
            let image = try source.decode(edge: edge)
            for target in group {
                if makesPDF(target) {
                    // The page's image data plus page, profile and file overhead.
                    let bytes = try pageImage(image, alpha: source.hasAlpha(image), quality: target.quality).bytes + 3_000
                    estimates[target] = EngineEstimate(bytes: Int64(bytes), ext: "pdf")
                } else {
                    let (data, format, _) = try encode(image, from: source, settings: target)
                    estimates[target] = EngineEstimate(bytes: Int64(data.count), ext: format.ext)
                }
            }
        }
        return estimates
    }

    // MARK: Decode

    private struct Source {
        let image: CGImageSource
        let props: [CFString: Any]
        let longest: Int
        let type: String?
        /// Whether the image really has transparency. Decoders often hand
        /// back an alpha channel even for opaque images.
        let hasAlpha: Bool

        init(_ url: URL) throws {
            guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(image) > 0
            else { throw EngineError("This image can't be read") }
            self.image = image
            props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] ?? [:]
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            longest = max(width, height, 1)
            type = CGImageSourceGetType(image) as String?
            hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? Self.probeAlpha(image)
        }

        func hasAlpha(_ decoded: CGImage) -> Bool { hasAlpha && decoded.hasAlpha }

        /// For files that don't say (HEIC doesn't): look for any
        /// non-opaque pixel in a small thumbnail.
        private static func probeAlpha(_ source: CGImageSource) -> Bool {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), thumb.hasAlpha,
                  let srgb = CGColorSpace(name: CGColorSpace.sRGB)
            else { return false }
            let w = thumb.width, h = thumb.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = px.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return drawn && stride(from: 3, to: px.count, by: 4).contains { px[$0] < 250 }
        }

        func edge(for settings: Settings) -> Int { min(settings.maxSize.pixels ?? longest, longest) }

        /// The thumbnail API resizes in one high-quality pass and bakes in
        /// the EXIF orientation.
        func decode(edge: Int) throws -> CGImage {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else {
                throw EngineError("This image can't be decoded")
            }
            return decoded
        }
    }

    // MARK: Encode

    private static func encode(_ decoded: CGImage, from source: Source, settings: Settings) throws -> (Data, ImageFormat, CGImage) {
        var image = decoded
        let alpha = source.hasAlpha(decoded)
        let format = resolveFormat(settings.imageFormat, sourceType: source.type, hasAlpha: alpha)
        let q = settings.quality

        if format == .jpeg, alpha, let flat = image.flattened() { image = flat }

        if format == .png, q < 0.85, settings.mode == .compress {
            // Lossy PNG: reduce to a 256-colour palette (like pngquant).
            // Conversions to PNG stay lossless.
            guard let data = PaletteEncoder.encode(image, maxColors: q < 0.45 ? 128 : 256) else {
                throw EngineError("Couldn't encode PNG")
            }
            return (data, format, image)
        }

        let data = NSMutableData()
        guard let type = format.type,
              let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { throw EngineError("Can't write \(format.label) on this Mac") }

        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q,
            kCGImagePropertyOrientation: 1,
        ]
        if format == .tiff {
            options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] // LZW
        }
        if settings.keepMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = source.props[key] { options[key] = value }
            }
            if var tiff = source.props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                if format == .tiff { tiff[kCGImagePropertyTIFFCompression] = 5 }
                options[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError("Couldn't save the image") }
        return (data as Data, format, image)
    }

    /// "Auto" keeps the original format when it can be written, otherwise
    /// picks PNG for transparent images and JPEG for everything else.
    private static func resolveFormat(_ chosen: ImageFormat, sourceType: String?, hasAlpha: Bool) -> ImageFormat {
        if chosen != .auto { return chosen }
        let fallback: ImageFormat = hasAlpha ? .png : .jpeg
        guard let id = sourceType, let type = UTType(id) else { return fallback }
        if let exact = ImageFormat.available.first(where: { $0.type == type }) { return exact }
        if type.conforms(to: .heif), ImageFormat.available.contains(.heic) { return .heic }
        return fallback
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Composites onto white, for formats without transparency.
    func flattened() -> CGImage? {
        let space = colorSpace?.model == .rgb ? colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(self, in: rect)
        return ctx.makeImage()
    }
}
