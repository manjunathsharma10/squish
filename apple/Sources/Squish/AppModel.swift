import AppKit
import AVFoundation
import CoreImage
import ImageIO
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var items: [FileItem] = []
    var isRunning = false
    var isImporting = false
    var notice: String?

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            // Finished files no longer reflect the settings; let them run again.
            if !isRunning {
                for item in items where item.status != .ready { item.status = .ready }
            }
            scheduleEstimates()
        }
    }

    private var batch: [FileItem] = []
    private var runTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?

    private init() {
        settings = UserDefaults.standard.data(forKey: "settings")
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
    }

    // MARK: Derived state

    var canCompress: Bool { !isRunning && items.contains { $0.status == .ready } }

    var batchProgress: Double {
        guard !batch.isEmpty else { return 0 }
        let total = batch.reduce(0.0) { sum, item in
            switch item.status {
            case .working: sum + (item.progress ?? 0.5)
            case .ready: sum
            default: sum + 1
            }
        }
        return total / Double(batch.count)
    }

    /// Total before/after across finished files. Images combined into one
    /// PDF share an output, which is only counted once.
    var totals: (before: Int64, after: Int64)? {
        let done = items.filter { $0.status == .done }
        guard !done.isEmpty else { return nil }
        var seen = Set<URL>(), after: Int64 = 0
        for item in done where item.output.map({ seen.insert($0).inserted }) ?? true {
            after += item.outputSize ?? item.size
        }
        return (done.reduce(0) { $0 + $1.size }, after)
    }

    /// What Convert mode will turn a file into ("JPEG", "MP4 · H.264"), and
    /// whether it's already in that format and will be left alone.
    func conversionTarget(for item: FileItem) -> (label: String, already: Bool)? {
        guard settings.mode == .convert else { return nil }
        let options = settings.convert
        let source = UTType(filenameExtension: item.url.pathExtension)
        switch item.kind {
        case .image:
            guard options.image == .pdf else { return (options.image.label, source == options.image.imageFormat?.type) }
            return (options.combineImages && items.filter({ $0.kind == .image }).count > 1 ? "one PDF" : "PDF", false)
        case .pdf:
            return (options.pages.label, false)
        case .video:
            return ("\(options.video.label) · \(options.videoCodec.label)", false)
        case .audio:
            return (options.audio.label, source == UTType(filenameExtension: options.audio.rawValue))
        }
    }

    // MARK: Adding files

    func add(_ urls: [URL]) {
        var skipped = 0
        let known = Set(items.map(\.url.standardizedFileURL))
        var added: [FileItem] = []

        for url in expand(urls) {
            let url = url.standardizedFileURL
            guard !known.contains(url), !added.contains(where: { $0.url == url }) else { continue }
            guard let kind = FileKind.of(url) else { skipped += 1; continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            added.append(FileItem(url: url, kind: kind, size: Int64(size)))
        }

        items.append(contentsOf: added)
        for item in added { Task { await inspect(item) } }
        if !added.isEmpty { scheduleEstimates(after: .milliseconds(100)) }
        if skipped > 0 { flash(skipped == 1 ? "Skipped 1 unsupported file" : "Skipped \(skipped) unsupported files") }
    }

    /// Folders are opened up, one level of files at a time, recursively.
    private func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else { files.append(url); continue }
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = walker?.nextObject() as? URL, files.count < 1000 {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(file) }
            }
        }
        return files
    }

    private func inspect(_ item: FileItem) async {
        let url = item.url
        async let info = Self.describe(url, kind: item.kind)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 40, height: 40),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            item.thumbnailMono = Self.monochrome(rep.cgImage)
            item.thumbnail = rep.nsImage
        }
        item.info = await info
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private static func monochrome(_ image: CGImage) -> NSImage? {
        let mono = CIImage(cgImage: image).applyingFilter("CIPhotoEffectMono")
        guard let cg = ciContext.createCGImage(mono, from: mono.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: image.width, height: image.height))
    }

    nonisolated private static func describe(_ url: URL, kind: FileKind) async -> String {
        switch kind {
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
            else { return "" }
            let turned = (p[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            return turned ? Format.dimensions(h, w) : Format.dimensions(w, h)
        case .pdf:
            let pages = CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
            return pages == 1 ? "1 page" : "\(pages) pages"
        case .video:
            let asset = AVURLAsset(url: url)
            var parts: [String] = []
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let geometry = try? await track.load(.naturalSize, .preferredTransform) {
                let r = geometry.0.applying(geometry.1)
                parts.append(Format.dimensions(Int(abs(r.width)), Int(abs(r.height))))
            }
            if let d = try? await asset.load(.duration).seconds { parts.append(Format.duration(d)) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        case .audio:
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            return Format.duration(d)
        }
    }

    // MARK: Queue actions

    func remove(_ item: FileItem) {
        guard item.status != .working else { return }
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        guard !isRunning else { return }
        estimateTask?.cancel()
        items.removeAll()
    }

    func reveal(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.output ?? item.url])
    }

    func open(_ item: FileItem) {
        NSWorkspace.shared.open(item.output ?? item.url)
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { settings.destination = url }
    }

    private func flash(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { notice = nil }
        }
    }

    // MARK: Compressing

    func compress() {
        guard canCompress else { return }
        estimateTask?.cancel() // give the encoders the whole machine
        let snapshot = settings.effective
        batch = items.filter { $0.status == .ready }
        isRunning = true

        var stills = batch.filter { !$0.kind.isMedia }
        let media = batch.filter { $0.kind.isMedia }
        var combined: [FileItem] = []
        if ImageEngine.makesPDF(snapshot), snapshot.convert.combineImages {
            combined = stills.filter { $0.kind == .image }
            if combined.count > 1 { stills.removeAll { $0.kind == .image } } else { combined = [] }
        }
        runTask = Task {
            // Images and PDFs run a few at a time; media uses the hardware
            // encoder, so one at a time alongside them.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.run(stills, width: 3, settings: snapshot) }
                group.addTask { await self.run(media, width: 1, settings: snapshot) }
                if !combined.isEmpty { group.addTask { await self.combine(combined, settings: snapshot) } }
            }
            isRunning = false
            batch = []
            scheduleEstimates(after: .zero)
        }
    }

    func stop() { runTask?.cancel() }

    private func run(_ queue: [FileItem], width: Int, settings: Settings) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = queue.makeIterator()
            for _ in 0..<width {
                if let item = pending.next() { group.addTask { await self.process(item, settings: settings) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { continue }
                if let item = pending.next() { group.addTask { await self.process(item, settings: settings) } }
            }
        }
    }

    private func process(_ item: FileItem, settings: Settings) async {
        guard !Task.isCancelled else { return }
        let exportsPages = item.kind == .pdf && settings.mode == .convert
        item.status = .working
        item.progress = item.kind.isMedia || exportsPages ? 0 : nil
        item.page = nil

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("squish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            let input = item.url, kind = item.kind
            let result: EngineOutput
            switch kind {
            case .image:
                result = try await Task.detached(priority: .userInitiated) {
                    try ImageEngine.run(input: input, output: temp, settings: settings)
                }.value
            case .pdf where exportsPages:
                result = try await Task.detached(priority: .userInitiated) {
                    try PDFEngine.exportPages(input: input, output: temp, settings: settings) { p in
                        Task { @MainActor in item.progress = p }
                    }
                }.value
            case .pdf:
                result = try await Task.detached(priority: .userInitiated) {
                    try PDFEngine.run(input: input, output: temp, settings: settings)
                }.value
            case .video, .audio:
                result = try await MediaEngine.run(input: input, output: temp, kind: kind, settings: settings) { p in
                    Task { @MainActor in item.progress = p }
                }
            }
            try Task.checkCancellation()

            let newSize = Self.size(of: temp)
            replacePreviousOutput(of: [item], ext: result.ext, mode: settings.mode)

            if settings.mode == .compress, Self.keepsOriginal(item, newSize: newSize, ext: result.ext) {
                item.status = .skipped("Couldn't make this any smaller. Original kept.")
                return
            }

            let destination = try destination(for: item, ext: result.ext, settings: settings)
            try FileManager.default.moveItem(at: temp, to: destination)
            finish(item, output: destination, size: newSize, result: result, mode: settings.mode)
        } catch is CancellationError {
            item.status = .ready
        } catch let already as AlreadyInFormat {
            item.status = .skipped("Already \(already.format). Nothing to convert.")
        } catch {
            item.status = .failed(Self.describe(error))
        }
    }

    /// Images → one PDF, in queue order, named after the first image.
    private func combine(_ images: [FileItem], settings: Settings) async {
        guard !Task.isCancelled, let first = images.first else { return }
        for item in images {
            item.status = .working
            item.progress = 0
            item.page = nil
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("squish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            let inputs = images.map(\.url)
            let result = try await Task.detached(priority: .userInitiated) {
                try ImageEngine.makePDF(from: inputs, output: temp, settings: settings) { index in
                    Task { @MainActor in images[index].progress = 1 }
                }
            }.value
            try Task.checkCancellation()

            replacePreviousOutput(of: images, ext: result.ext, mode: settings.mode)
            let stem = first.url.deletingPathExtension().lastPathComponent + "-combined"
            let destination = try destination(for: first, ext: result.ext, settings: settings, names: [stem])
            try FileManager.default.moveItem(at: temp, to: destination)
            let size = Self.size(of: destination)
            for (index, item) in images.enumerated() {
                item.page = (index + 1, images.count)
                finish(item, output: destination, size: size,
                       result: EngineOutput(ext: "pdf", info: "Page \(index + 1) of \(images.count)"), mode: settings.mode)
            }
        } catch is CancellationError {
            for item in images { item.status = .ready }
        } catch {
            for item in images { item.status = .failed(Self.describe(error)) }
        }
    }

    private func finish(_ item: FileItem, output: URL, size: Int64, result: EngineOutput, mode: Mode) {
        item.output = output
        item.outputFormat = result.format ?? result.ext.uppercased()
        item.outputMode = mode
        item.outputSize = size
        item.outputInfo = result.info
        item.status = .done
    }

    /// Re-running a file with tweaked settings replaces its previous result
    /// (to the Trash), but only when it would make the same kind of file;
    /// converting to a new format keeps earlier results.
    private func replacePreviousOutput(of items: [FileItem], ext: String, mode: Mode) {
        for item in items {
            guard let old = item.output, item.outputMode == mode, old.pathExtension == ext else { continue }
            if FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
            }
            item.output = nil
        }
    }

    /// File size, or the total of a folder's files.
    nonisolated private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys))?.fileSize ?? 0)
        }
        return total
    }

    /// Same format and under 1% smaller isn't worth a new file.
    private static func keepsOriginal(_ item: FileItem, newSize: Int64, ext: String) -> Bool {
        UTType(filenameExtension: ext) == UTType(filenameExtension: item.url.pathExtension)
            && Double(newSize) > Double(item.size) * 0.99
    }

    // MARK: Size predictions

    /// Predicted queue total for a preset, or for the current settings.
    /// While files are still being estimated, the rest are extrapolated
    /// from the ones that are done, kind by kind.
    func prediction(for preset: Preset?) -> Prediction? {
        let key = preset.map { compressSettings.applying($0).sizeKey } ?? settings.sizeKey
        var before: Int64 = 0, after: Int64 = 0
        var byKind: [FileKind: (before: Int64, after: Int64)] = [:]
        var unknown: [FileItem] = []

        for item in items {
            before += item.size
            if let estimate = item.estimates[key] {
                after += estimate
                byKind[item.kind, default: (0, 0)].before += item.size
                byKind[item.kind, default: (0, 0)].after += estimate
            } else {
                unknown.append(item)
            }
        }
        guard unknown.count < items.count else { return nil }

        let knownBefore = byKind.values.reduce(0) { $0 + $1.before }
        let overall = knownBefore > 0 ? Double(after) / Double(knownBefore) : 1
        for item in unknown {
            let ratio = byKind[item.kind].map { $0.before > 0 ? Double($0.after) / Double($0.before) : 1 } ?? overall
            after += Int64(Double(item.size) * ratio)
        }
        return Prediction(before: before, after: after, complete: unknown.isEmpty)
    }

    private var compressSettings: Settings {
        var copy = settings
        copy.mode = .compress
        return copy
    }

    /// The three presets plus custom settings in Compress mode; just the
    /// current targets in Convert mode.
    private func estimateTargets(for mode: Mode) -> [Settings] {
        guard mode == .compress else {
            var convert = settings
            convert.mode = .convert
            return [convert.sizeKey]
        }
        var targets = Preset.allCases.map { compressSettings.applying($0).sizeKey }
        if !targets.contains(compressSettings.sizeKey) { targets.append(compressSettings.sizeKey) }
        return targets
    }

    /// Debounced, so dragging the quality slider doesn't queue up work.
    private func scheduleEstimates(after delay: Duration = .milliseconds(350)) {
        estimateTask?.cancel()
        guard !items.isEmpty, !isRunning else { return }
        estimateTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await runEstimates()
        }
    }

    private func runEstimates() async {
        let targets = estimateTargets(for: settings.mode)
        // Keep both modes' estimates so switching back and forth is instant.
        let wanted = Set(estimateTargets(for: .compress) + estimateTargets(for: .convert))
        for item in items { item.estimates = item.estimates.filter { wanted.contains($0.key) } }
        let pending = items.filter { item in targets.contains { item.estimates[$0] == nil } }

        await withTaskGroup(of: Void.self) { group in
            var queue = pending.makeIterator()
            for _ in 0..<2 {
                if let item = queue.next() { group.addTask { await self.estimate(item, targets: targets) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { continue }
                if let item = queue.next() { group.addTask { await self.estimate(item, targets: targets) } }
            }
        }
    }

    private func estimate(_ item: FileItem, targets: [Settings]) async {
        let missing = targets.filter { item.estimates[$0] == nil }
        guard !missing.isEmpty, !Task.isCancelled else { return }
        let url = item.url, kind = item.kind, size = item.size

        let results: [Settings: EngineEstimate]
        switch kind {
        case .image:
            results = (try? await Task.detached(priority: .utility) {
                try ImageEngine.estimate(input: url, targets: missing)
            }.value) ?? [:]
        case .pdf:
            results = (try? await Task.detached(priority: .utility) {
                try PDFEngine.estimate(input: url, size: size, targets: missing)
            }.value) ?? [:]
        case .video, .audio:
            results = (try? await MediaEngine.estimate(input: url, kind: kind, targets: missing)) ?? [:]
        }

        // Anything that couldn't be estimated, or that would be left alone
        // (not smaller, or already in the target format), stays as it is.
        for target in missing {
            guard let result = results[target] else { item.estimates[target] = size; continue }
            let unchanged = target.mode == .compress
                ? Self.keepsOriginal(item, newSize: result.bytes, ext: result.ext)
                : kind == .image && UTType(filenameExtension: result.ext) == UTType(filenameExtension: url.pathExtension)
            item.estimates[target] = unchanged ? size : result.bytes
        }
    }

    // MARK: Output

    /// Compressed files get "-squished"; converted ones keep their name with
    /// the new extension ("-converted" if that's taken). Page folders are
    /// "name-pages". Numbers are added until the name is free.
    private func destination(for item: FileItem, ext: String, settings: Settings, names: [String]? = nil) throws -> URL {
        let folder = settings.destination ?? item.url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw EngineError("Can't save to this folder. Choose another under Save to.")
        }
        let stem = item.url.deletingPathExtension().lastPathComponent
        let defaults: [String] = switch settings.mode {
        case .compress: [stem + "-squished"]
        case .convert: ext.isEmpty ? [stem + "-pages"] : [stem, stem + "-converted"]
        }
        let names = names ?? defaults
        func url(_ name: String) -> URL {
            ext.isEmpty ? folder.appendingPathComponent(name, isDirectory: true)
                : folder.appendingPathComponent(name).appendingPathExtension(ext)
        }
        if let free = names.map(url).first(where: { !FileManager.default.fileExists(atPath: $0.path) }) { return free }
        var n = 2
        while FileManager.default.fileExists(atPath: url("\(names[names.count - 1])-\(n)").path) { n += 1 }
        return url("\(names[names.count - 1])-\(n)")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? EngineError { return error.message }
        let ns = error as NSError
        if ns.domain == AVFoundationErrorDomain {
            return ns.localizedFailureReason ?? ns.localizedDescription
        }
        return ns.localizedDescription
    }
}
