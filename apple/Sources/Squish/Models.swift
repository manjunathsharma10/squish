import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - File kinds

enum FileKind: String {
    case image, pdf, video, audio

    var symbol: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.text"
        case .video: "film"
        case .audio: "waveform"
        }
    }

    var isMedia: Bool { self == .video || self == .audio }

    /// Decides whether Squish can handle a file, and how.
    static func of(_ url: URL) -> FileKind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }

        if type.conforms(to: .pdf) { return .pdf }
        // Animated GIFs would lose their animation, so they're left alone.
        if type.conforms(to: .gif) { return nil }
        if type.conforms(to: .image), readableImageTypes.contains(type.identifier) { return .image }

        let playable = avTypes.contains(type.identifier)
        if type.conforms(to: .movie) || type.conforms(to: .video) { return playable ? .video : nil }
        if type.conforms(to: .audio) { return playable ? .audio : nil }
        return nil
    }

    private static let readableImageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    private static let avTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
}

// MARK: - Settings

enum Preset: String, CaseIterable, Identifiable {
    case small, balanced, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .balanced: "Balanced"
        case .high: "High"
        }
    }

    var caption: String {
        switch self {
        case .small: "Smallest files"
        case .balanced: "Best for most"
        case .high: "Near original"
        }
    }

    var quality: Double {
        switch self {
        case .small: 0.50
        case .balanced: 0.72
        case .high: 0.88
        }
    }

    var maxSize: MaxSize {
        switch self {
        case .small: .p1920
        case .balanced: .p3840
        case .high: .original
        }
    }
}

enum MaxSize: Int, CaseIterable, Codable, Identifiable {
    case original = 0, p3840 = 3840, p2560 = 2560, p1920 = 1920, p1280 = 1280
    var id: Int { rawValue }
    var pixels: Int? { self == .original ? nil : rawValue }
    var label: String { self == .original ? "Original" : "\(rawValue)" }
}

enum ImageFormat: String, CaseIterable, Codable, Identifiable {
    case auto, jpeg, png, heic, avif, tiff
    var id: String { rawValue }

    var label: String { self == .auto ? "Auto" : rawValue.uppercased() }

    var type: UTType? {
        switch self {
        case .auto: nil
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .avif: UTType("public.avif")
        case .tiff: .tiff
        }
    }

    var ext: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    /// Formats this Mac can actually encode (AVIF needs a recent macOS).
    static let available: [ImageFormat] = {
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        return allCases.filter { $0 == .auto || writable.contains($0.type?.identifier ?? "") }
    }()
}

enum VideoFormat: String, CaseIterable, Codable, Identifiable {
    case auto, mp4, mov
    var id: String { rawValue }
    var label: String { self == .auto ? "Auto" : rawValue.uppercased() }
}

enum VideoCodec: String, CaseIterable, Codable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
}

enum AudioFormat: String, CaseIterable, Codable, Identifiable {
    case m4a, wav, aiff
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

// MARK: - Convert mode

enum Mode: String, CaseIterable, Codable, Identifiable {
    case compress, convert
    var id: String { rawValue }
    var title: String { self == .compress ? "Compress" : "Convert" }
}

/// What images become in Convert mode. PDF wraps each image in a page.
enum ImageTarget: String, CaseIterable, Codable, Identifiable {
    case jpeg, png, heic, avif, tiff, pdf
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var imageFormat: ImageFormat? { ImageFormat(rawValue: rawValue) }

    static let available: [ImageTarget] = allCases.filter { target in
        target.imageFormat.map(ImageFormat.available.contains) ?? true
    }
}

/// What each PDF page becomes in Convert mode.
enum PageFormat: String, CaseIterable, Codable, Identifiable {
    case jpeg, png
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var imageFormat: ImageFormat { self == .jpeg ? .jpeg : .png }
}

struct ConvertOptions: Codable, Hashable {
    var image = ImageTarget.jpeg
    /// Images → PDF: one PDF holding every image, instead of one each.
    var combineImages = false
    var pages = PageFormat.jpeg
    var pageDPI = 150
    var video = VideoFormat.mp4
    var videoCodec = VideoCodec.h264
    var audio = AudioFormat.m4a
    var quality = 0.85

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConvertOptions()
        image = try c.decodeIfPresent(ImageTarget.self, forKey: .image) ?? d.image
        combineImages = try c.decodeIfPresent(Bool.self, forKey: .combineImages) ?? d.combineImages
        pages = try c.decodeIfPresent(PageFormat.self, forKey: .pages) ?? d.pages
        pageDPI = try c.decodeIfPresent(Int.self, forKey: .pageDPI) ?? d.pageDPI
        video = try c.decodeIfPresent(VideoFormat.self, forKey: .video) ?? d.video
        videoCodec = try c.decodeIfPresent(VideoCodec.self, forKey: .videoCodec) ?? d.videoCodec
        audio = try c.decodeIfPresent(AudioFormat.self, forKey: .audio) ?? d.audio
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality
    }
}

struct Settings: Codable, Hashable {
    var mode = Mode.compress
    var quality = Preset.balanced.quality
    var maxSize = Preset.balanced.maxSize
    var imageFormat = ImageFormat.auto
    var videoFormat = VideoFormat.auto
    var videoCodec = VideoCodec.hevc
    var audioFormat = AudioFormat.m4a
    var keepMetadata = false
    var destination: URL?
    var convert = ConvertOptions()

    init() {}

    /// Tolerates settings saved by older versions (missing keys keep defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality
        maxSize = try c.decodeIfPresent(MaxSize.self, forKey: .maxSize) ?? d.maxSize
        imageFormat = try c.decodeIfPresent(ImageFormat.self, forKey: .imageFormat) ?? d.imageFormat
        videoFormat = try c.decodeIfPresent(VideoFormat.self, forKey: .videoFormat) ?? d.videoFormat
        videoCodec = try c.decodeIfPresent(VideoCodec.self, forKey: .videoCodec) ?? d.videoCodec
        audioFormat = try c.decodeIfPresent(AudioFormat.self, forKey: .audioFormat) ?? d.audioFormat
        keepMetadata = try c.decodeIfPresent(Bool.self, forKey: .keepMetadata) ?? d.keepMetadata
        destination = try c.decodeIfPresent(URL.self, forKey: .destination)
        convert = try c.decodeIfPresent(ConvertOptions.self, forKey: .convert) ?? d.convert
    }

    /// What the engines run with. Compress keeps each file's format (audio
    /// becomes AAC). Convert takes its targets from `convert`, at full size.
    var effective: Settings {
        var s = self
        switch mode {
        case .compress:
            s.imageFormat = .auto
            s.videoFormat = .auto
            s.audioFormat = .m4a
            s.convert = ConvertOptions()
        case .convert:
            s.quality = convert.quality
            s.maxSize = .original
            s.imageFormat = convert.image.imageFormat ?? .auto
            s.videoFormat = convert.video
            s.videoCodec = convert.videoCodec
            s.audioFormat = convert.audio
        }
        return s
    }

    var preset: Preset? {
        Preset.allCases.first { abs($0.quality - quality) < 0.005 && $0.maxSize == maxSize }
    }

    mutating func apply(_ preset: Preset) {
        quality = preset.quality
        maxSize = preset.maxSize
    }

    func applying(_ preset: Preset) -> Settings {
        var copy = self
        copy.apply(preset)
        return copy
    }

    /// Everything that affects output size; where files are saved doesn't.
    var sizeKey: Settings {
        var copy = effective
        copy.destination = nil
        return copy
    }
}

// MARK: - Queue item

@MainActor @Observable
final class FileItem: Identifiable {
    enum Status: Equatable {
        case ready, working, done, skipped(String), failed(String)
    }

    let id = UUID()
    let url: URL
    let kind: FileKind
    let size: Int64

    var info = ""
    var thumbnail: NSImage?
    var thumbnailMono: NSImage?
    var status = Status.ready
    /// nil while working means the engine can't report progress.
    var progress: Double?
    var output: URL?
    var outputFormat = ""
    var outputMode: Mode?
    var outputSize: Int64?
    var outputInfo = ""
    /// Predicted size after compressing, keyed by `Settings.sizeKey`.
    var estimates: [Settings: Int64] = [:]
    /// Set when this image became one page of a combined PDF.
    var page: (number: Int, of: Int)?

    init(url: URL, kind: FileKind, size: Int64) {
        self.url = url
        self.kind = kind
        self.size = size
    }

    var name: String { url.lastPathComponent }
    var format: String { url.pathExtension.uppercased() }

    /// Fraction saved, negative if the file grew (possible when converting).
    var saving: Double? {
        guard status == .done, let outputSize, size > 0 else { return nil }
        return 1 - Double(outputSize) / Double(size)
    }
}

/// What an engine produced, for the row's detail line.
struct EngineOutput {
    var ext: String
    var info: String
    /// For outputs without an extension of their own (a folder of pages).
    var format: String?
}

/// A predicted output size, before the "keep the original if it isn't
/// smaller" rule is applied.
struct EngineEstimate {
    var bytes: Int64
    var ext: String
}

/// Predicted total for the whole queue under one set of settings.
struct Prediction {
    var before: Int64
    var after: Int64
    /// False while some files are still being estimated (and extrapolated).
    var complete: Bool

    var saving: Double { before > 0 ? 1 - Double(after) / Double(before) : 0 }
}

/// Thrown in Convert mode when a file is already in the target format.
struct AlreadyInFormat: Error {
    var format: String
}

struct EngineError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Formatting

enum Format {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ value: Int64) -> String { bytes.string(fromByteCount: value) }

    static func percent(_ saving: Double) -> String {
        // Never round a real file down to "−100%".
        let value = min(Int((abs(saving) * 100).rounded()), saving > 0 ? 99 : .max)
        if value == 0 { return "0%" }
        return saving >= 0 ? "−\(value)%" : "+\(value)%"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func dimensions(_ w: Int, _ h: Int) -> String { "\(w) × \(h)" }
}
