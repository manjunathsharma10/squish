import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// Shrinks PDFs by recompressing and downsampling their embedded images
/// with a Quartz filter. Text and vector graphics are left untouched.
enum PDFEngine {
    static func run(input: URL, output: URL, settings: Settings) throws -> EngineOutput {
        let document = try open(input)
        try write(document, to: output, settings: settings)
        let pages = document.pageCount
        return EngineOutput(ext: "pdf", info: pages == 1 ? "1 page" : "\(pages) pages")
    }

    /// Exact sizes from real filter runs into a temporary file. Very large
    /// PDFs are skipped (left unestimated) to keep this cheap.
    static func estimate(input: URL, size: Int64, targets: [Settings]) throws -> [Settings: EngineEstimate] {
        if targets.allSatisfy({ $0.mode == .convert }) { return try estimatePages(input: input, targets: targets) }
        guard size <= 150_000_000 else { return [:] }
        let document = try open(input)
        var estimates: [Settings: EngineEstimate] = [:]
        for target in targets {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("squish-estimate-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temp) }
            try write(document, to: temp, settings: target)
            let bytes = (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int(size)
            estimates[target] = EngineEstimate(bytes: Int64(bytes), ext: "pdf")
        }
        return estimates
    }

    // MARK: PDF → images

    /// Renders every page at the chosen DPI. A one-page PDF becomes a single
    /// image; longer ones become a folder of numbered images.
    static func exportPages(input: URL, output: URL, settings: Settings,
                            progress: @escaping (Double) -> Void) throws -> EngineOutput {
        let document = try pages(of: input)
        let count = document.numberOfPages
        let format = settings.convert.pages.imageFormat
        let dpi = settings.convert.pageDPI
        let base = input.deletingPathExtension().lastPathComponent
        let digits = String(count).count

        if count > 1 { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for number in 1...count {
            try autoreleasepool {
                guard let page = document.page(at: number) else { return }
                let data = try encode(render(page, dpi: dpi), as: format, quality: settings.quality, dpi: dpi)
                let name = "\(base)-\(String(format: "%0\(digits)d", number)).\(format.ext)"
                try data.write(to: count > 1 ? output.appendingPathComponent(name) : output)
            }
            progress(Double(number) / Double(count))
        }
        let pages = count == 1 ? "1 page" : "\(count) pages"
        return EngineOutput(ext: count > 1 ? "" : format.ext, info: "\(pages) · \(dpi) dpi", format: format.label)
    }

    /// Renders up to three pages spread through the document and scales by
    /// the page count.
    private static func estimatePages(input: URL, targets: [Settings]) throws -> [Settings: EngineEstimate] {
        let document = try pages(of: input)
        let count = document.numberOfPages
        let samples = Array(Set([1, (count + 1) / 2, count])).sorted()
        var estimates: [Settings: EngineEstimate] = [:]
        for target in targets {
            let format = target.convert.pages.imageFormat
            var bytes = 0
            for number in samples {
                guard let page = document.page(at: number) else { continue }
                bytes += try autoreleasepool {
                    try encode(render(page, dpi: target.convert.pageDPI), as: format, quality: target.quality,
                               dpi: target.convert.pageDPI).count
                }
            }
            let total = Double(bytes) / Double(samples.count) * Double(count)
            estimates[target] = EngineEstimate(bytes: Int64(total), ext: count > 1 ? "" : format.ext)
        }
        return estimates
    }

    private static func pages(of url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            throw EngineError("This PDF can't be opened")
        }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            throw EngineError("This PDF is password-protected")
        }
        return document
    }

    /// Draws a page on white at `dpi`, honouring its rotation. Huge pages
    /// are capped at 40 megapixels.
    private static func render(_ page: CGPDFPage, dpi: Int) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        var scale = CGFloat(dpi) / 72
        let area = size.width * size.height
        if area * scale * scale > 40_000_000 { scale = (40_000_000 / area).squareRoot() }

        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw EngineError("This page is too large to render") }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // getDrawingTransform never scales up, so it's given the page at 1:1
        // and only handles rotation and the crop box origin.
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw EngineError("Couldn't render this page") }
        return image
    }

    private static func encode(_ image: CGImage, as format: ImageFormat, quality: Double, dpi: Int) throws -> Data {
        let data = NSMutableData()
        guard let type = format.type,
              let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { throw EngineError("Couldn't encode the page") }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError("Couldn't encode the page") }
        return data as Data
    }

    // MARK: Helpers

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw EngineError("This PDF can't be opened") }
        if document.isLocked { throw EngineError("This PDF is password-protected") }
        return document
    }

    private static func write(_ document: PDFDocument, to output: URL, settings: Settings) throws {
        let filterURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("squish-\(UUID().uuidString).qfilter")
        defer { try? FileManager.default.removeItem(at: filterURL) }
        try filter(for: settings).write(to: filterURL)

        var saved = false
        if let filter = QuartzFilter(url: filterURL) {
            saved = document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        }
        if !saved {
            saved = document.write(to: output, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        }
        guard saved else { throw EngineError("Couldn't save the PDF") }
    }

    /// Same structure as macOS's built-in "Reduce File Size" filter,
    /// with quality and resolution driven by the current settings.
    private static func filter(for settings: Settings) throws -> Data {
        let dpi: Int = switch settings.maxSize {
        case .original: 300
        case .p3840: 200
        case .p2560: 170
        case .p1920: 150
        case .p1280: 110
        }
        // Above roughly 3500 px the filter silently stores images
        // uncompressed, so never ask for more than 3000.
        let longest = min(settings.maxSize.pixels ?? 3000, 3000)
        let plist: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": settings.quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": dpi,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": longest,
                            "ImageSizeMin": 0,
                        ],
                    ],
                ],
            ],
            "FilterType": 1,
            "Name": "Squish",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
