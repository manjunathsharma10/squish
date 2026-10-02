import AVFoundation
import UniformTypeIdentifiers
import VideoToolbox

/// Re-encodes video and audio with AVAssetReader → AVAssetWriter, which
/// gives direct control over resolution and bitrate (export presets don't).
/// Encoding runs on the hardware HEVC / H.264 encoders. In Convert mode,
/// tracks already in the target codec are copied without re-encoding.
enum MediaEngine {
    static func run(input: URL, output: URL, kind: FileKind, settings: Settings,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> EngineOutput {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        let source = try await Tracks(asset, kind: kind)
        guard source.video != nil || source.audio != nil else { throw EngineError("No audio or video found in this file") }

        let (fileType, ext) = container(kind: kind, input: input, settings: settings)
        let copyVideo = source.video.map { copies($0, settings) } ?? false
        let copyAudio = source.audio.map { copies($0, kind: kind, settings) } ?? false
        if settings.mode == .convert, UTType(filenameExtension: ext) == UTType(filenameExtension: input.pathExtension),
           kind == .audio || (copyVideo && (source.audio == nil || copyAudio)) {
            throw AlreadyInFormat(format: kind == .video ? "\(ext.uppercased()) · \(settings.videoCodec.label)" : ext.uppercased())
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        if settings.keepMetadata { writer.metadata = (try? await asset.load(.metadata)) ?? [] }

        var lanes: [Lane] = []
        var info: [String] = []

        if let video = source.video {
            let (lane, summary) = try videoLane(video, reader: reader, writer: writer, settings: settings, copy: copyVideo)
            lanes.append(lane)
            info.append(summary)
        }
        if let audio = source.audio {
            let (lane, summary) = try audioLane(audio, reader: reader, writer: writer, quality: settings.quality,
                                                pcm: usesPCM(kind, settings), bigEndian: settings.audioFormat == .aiff,
                                                copy: copyAudio)
            lanes.append(lane)
            if kind == .audio { info.append(summary) }
        }
        if kind == .audio, duration > 0 { info.append(Format.duration(duration)) }
        lanes[0].reportsProgress = true

        guard writer.startWriting() else { throw writer.error ?? EngineError("Couldn't start writing") }
        guard reader.startReading() else { throw reader.error ?? EngineError("Couldn't read this file") }
        writer.startSession(atSourceTime: .zero)

        try await pump(lanes, reader: reader, writer: writer, duration: duration, progress: progress)
        return EngineOutput(ext: ext, info: info.joined(separator: " · "))
    }

    // MARK: Estimate

    /// Bitrate × duration, from the same plans the encoder follows. The
    /// hardware encoders land within a few percent of their target; copied
    /// tracks keep their own bitrate.
    static func estimate(input: URL, kind: FileKind, targets: [Settings]) async throws -> [Settings: EngineEstimate] {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [:] }
        let source = try await Tracks(asset, kind: kind)

        var estimates: [Settings: EngineEstimate] = [:]
        for target in targets {
            var bitsPerSecond = 0.0
            if let video = source.video {
                bitsPerSecond += copies(video, target)
                    ? Double(video.rate)
                    : Double(VideoPlan(video, settings: target).bitrate)
            }
            if let audio = source.audio {
                bitsPerSecond += copies(audio, kind: kind, target)
                    ? Double(audio.rate)
                    : Double(AudioPlan(audio.description, quality: target.quality, pcm: usesPCM(kind, target)).bitrate)
            }
            let bytes = bitsPerSecond * duration / 8 * 1.01 + 4_096 // container overhead
            estimates[target] = EngineEstimate(bytes: Int64(bytes), ext: container(kind: kind, input: input, settings: target).1)
        }
        return estimates
    }

    // MARK: Source tracks

    private struct VideoTrack {
        let track: AVAssetTrack
        let natural: CGSize
        let transform: CGAffineTransform
        let fps: Float
        let rate: Float
        let format: CMFormatDescription?
        var codec: FourCharCode? { format.map(CMFormatDescriptionGetMediaSubType) }
    }

    private struct AudioTrack {
        let track: AVAssetTrack
        let rate: Float
        let format: CMFormatDescription?
        var description: AudioStreamBasicDescription? {
            format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        }
    }

    private struct Tracks {
        var video: VideoTrack?
        var audio: AudioTrack?

        init(_ asset: AVURLAsset, kind: FileKind) async throws {
            if kind == .video, let track = try await asset.loadTracks(withMediaType: .video).first {
                let (natural, transform, fps, rate, formats) = try await track.load(
                    .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
                video = VideoTrack(track: track, natural: natural, transform: transform, fps: fps, rate: rate, format: formats.first)
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let (rate, formats) = try await track.load(.estimatedDataRate, .formatDescriptions)
                audio = AudioTrack(track: track, rate: rate, format: formats.first)
            }
        }
    }

    /// Convert mode copies video that's already in the target codec.
    private static func copies(_ video: VideoTrack, _ settings: Settings) -> Bool {
        guard settings.mode == .convert, settings.maxSize == .original, let codec = video.codec else { return false }
        return settings.videoCodec == .hevc ? codec == kCMVideoCodecType_HEVC : codec == kCMVideoCodecType_H264
    }

    /// ...and AAC audio going into an AAC container.
    private static func copies(_ audio: AudioTrack, kind: FileKind, _ settings: Settings) -> Bool {
        guard settings.mode == .convert, !usesPCM(kind, settings) else { return false }
        return audio.description?.mFormatID == kAudioFormatMPEG4AAC
    }

    // MARK: Container

    private static func usesPCM(_ kind: FileKind, _ settings: Settings) -> Bool {
        kind == .audio && settings.audioFormat != .m4a
    }

    private static func container(kind: FileKind, input: URL, settings: Settings) -> (AVFileType, String) {
        if kind == .audio {
            switch settings.audioFormat {
            case .m4a: return (.m4a, "m4a")
            case .wav: return (.wav, "wav")
            case .aiff: return (.aiff, "aiff")
            }
        }
        switch settings.videoFormat {
        case .mov: return (.mov, "mov")
        case .mp4: return (.mp4, "mp4")
        case .auto: return input.pathExtension.lowercased() == "mov" ? (.mov, "mov") : (.mp4, "mp4")
        }
    }

    // MARK: Video

    private static func videoLane(_ video: VideoTrack, reader: AVAssetReader, writer: AVAssetWriter,
                                  settings: Settings, copy: Bool) throws -> (Lane, String) {
        let transform = video.transform
        func shown(_ w: Int, _ h: Int) -> String {
            let rotated = abs(transform.b) == 1 && abs(transform.c) == 1
            return rotated ? Format.dimensions(h, w) : Format.dimensions(w, h)
        }

        if copy {
            let readerOutput = AVAssetReaderTrackOutput(track: video.track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: video.format)
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(readerOutput), writer.canAdd(input) else { throw EngineError("Couldn't copy the video track") }
            reader.add(readerOutput)
            writer.add(input)
            let size = shown(Int(abs(video.natural.width)), Int(abs(video.natural.height)))
            return (Lane(output: readerOutput, input: input), "\(size) · \(settings.videoCodec.label) · lossless copy")
        }

        let plan = VideoPlan(video, settings: settings)
        let width = plan.width, height = plan.height, codec = plan.codec

        // Colour: carry over the source tags so HDR (HLG / PQ) stays correct.
        func tag(_ key: CFString) -> String? {
            video.format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? String }
        }
        let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries)
        let transfer = tag(kCMFormatDescriptionExtension_TransferFunction)
        let matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix)
        let hdr = transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
            || transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        let tenBit = hdr && codec == .hevc

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(plan.frameRate.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoProfileLevelKey: codec == .h264
                ? AVVideoProfileLevelH264HighAutoLevel
                : (tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String,
        ]
        var output: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let primaries, let transfer, let matrix {
            output[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix,
            ]
        }

        // AVFoundation throws uncatchable exceptions on bad settings,
        // so validate first and relax optional keys one at a time.
        for relax in [nil, AVVideoColorPropertiesKey, AVVideoScalingModeKey, AVVideoProfileLevelKey] {
            if let relax {
                if relax == AVVideoProfileLevelKey {
                    compression.removeValue(forKey: relax)
                    output[AVVideoCompressionPropertiesKey] = compression
                } else {
                    output.removeValue(forKey: relax)
                }
            }
            if writer.canApply(outputSettings: output, forMediaType: .video) { break }
        }
        guard writer.canApply(outputSettings: output, forMediaType: .video) else {
            throw EngineError("This Mac can't encode \(settings.videoCodec.label) at \(width) × \(height)")
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let readerOutput = AVAssetReaderTrackOutput(track: video.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput), writer.canAdd(input) else { throw EngineError("Couldn't set up video encoding") }
        reader.add(readerOutput)
        writer.add(input)
        return (Lane(output: readerOutput, input: input), "\(shown(width, height)) · \(settings.videoCodec.label)")
    }

    /// Output size and bitrate for a video track under some settings.
    private struct VideoPlan {
        let width: Int
        let height: Int
        let codec: AVVideoCodecType
        let frameRate: Double
        let bitrate: Int

        init(_ video: VideoTrack, settings: Settings) {
            let srcW = abs(video.natural.width), srcH = abs(video.natural.height)
            let limit = settings.maxSize.pixels.map(Double.init) ?? .infinity
            let scale = min(1, limit / max(srcW, srcH, 1))
            width = Self.even(srcW * scale)
            height = Self.even(srcH * scale)
            codec = settings.videoCodec == .hevc ? .hevc : .h264
            frameRate = Double(video.fps > 0 ? video.fps : 30)

            // Bits-per-pixel, damped above 30 fps. Compressing never goes
            // above the source; converting HEVC → H.264 is allowed more,
            // since H.264 needs it for the same picture.
            let motion = min(frameRate, 30) + max(0, frameRate - 30) * 0.35
            var bpp = 0.015 + 0.075 * settings.quality
            if codec == .h264 { bpp *= 1.5 }
            var rate = Double(width * height) * motion * bpp
            let ceiling: Double = switch settings.mode {
            case .compress: 0.85
            case .convert: codec == .h264 && video.codec == kCMVideoCodecType_HEVC ? 1.6 : 1.0
            }
            if video.rate > 0 { rate = min(rate, Double(video.rate) * ceiling) }
            bitrate = Int(max(rate, 250_000))
        }

        private static func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
    }

    // MARK: Audio

    private static func audioLane(_ audio: AudioTrack, reader: AVAssetReader, writer: AVAssetWriter,
                                  quality: Double, pcm: Bool, bigEndian: Bool, copy: Bool) throws -> (Lane, String) {
        if copy {
            let readerOutput = AVAssetReaderTrackOutput(track: audio.track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audio.format)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(readerOutput), writer.canAdd(input) else { throw EngineError("Couldn't copy the audio track") }
            reader.add(readerOutput)
            writer.add(input)
            return (Lane(output: readerOutput, input: input), "AAC · lossless copy")
        }

        let plan = AudioPlan(audio.description, quality: quality, pcm: pcm)
        let channels = plan.channels, rate = plan.rate

        let linear: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: pcm && bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]

        var output: [String: Any] = linear
        if !pcm {
            output = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: plan.bitrate,
            ]
            if !writer.canApply(outputSettings: output, forMediaType: .audio) {
                output.removeValue(forKey: AVEncoderBitRateKey)
            }
        }
        guard writer.canApply(outputSettings: output, forMediaType: .audio) else {
            throw EngineError("Couldn't set up audio encoding")
        }

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: output)
        input.expectsMediaDataInRealTime = false
        let readerOutput = AVAssetReaderTrackOutput(track: audio.track, outputSettings: linear)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput), writer.canAdd(input) else { throw EngineError("Couldn't set up audio encoding") }
        reader.add(readerOutput)
        writer.add(input)

        let summary = pcm ? "PCM 16-bit" : "AAC \(plan.bitrate / 1000) kbps"
        return (Lane(output: readerOutput, input: input), summary)
    }

    /// Channels, sample rate and bitrate for an audio track.
    private struct AudioPlan {
        let channels: Int
        let rate: Double
        /// AAC target, or the raw PCM rate.
        let bitrate: Int

        init(_ source: AudioStreamBasicDescription?, quality: Double, pcm: Bool) {
            channels = max(1, min(Int(source?.mChannelsPerFrame ?? 2), 2))
            var rate = source?.mSampleRate ?? 44_100
            if rate <= 0 { rate = 44_100 }
            if !pcm { rate = min(rate, 48_000) } // AAC tops out at 48 kHz
            self.rate = rate
            let perChannel = quality < 0.6 ? 48_000 : quality < 0.8 ? 64_000 : quality < 0.95 ? 96_000 : 128_000
            bitrate = pcm ? Int(rate) * channels * 16 : perChannel * channels
        }
    }

    // MARK: Pump

    private final class Lane: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        var reportsProgress = false
        var finished = false
        var lastReported = -1.0

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
            self.output = output
            self.input = input
        }
    }

    /// Reader and writer are only touched from the lane queues and the
    /// final notify block, never concurrently.
    private final class Session: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        init(_ reader: AVAssetReader, _ writer: AVAssetWriter) {
            self.reader = reader
            self.writer = writer
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Moves samples from reader to writer, one serial queue per track.
    private static func pump(_ lanes: [Lane], reader: AVAssetReader, writer: AVAssetWriter, duration: Double,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let cancelled = CancelFlag()
        let session = Session(reader, writer)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                let group = DispatchGroup()
                for (i, lane) in lanes.enumerated() {
                    group.enter()
                    let queue = DispatchQueue(label: "squish.media.\(i)", qos: .userInitiated)
                    lane.input.requestMediaDataWhenReady(on: queue) {
                        guard !lane.finished else { return }
                        func finish() {
                            lane.finished = true
                            lane.input.markAsFinished()
                            group.leave()
                        }
                        while lane.input.isReadyForMoreMediaData {
                            guard !cancelled.isSet, let sample = lane.output.copyNextSampleBuffer() else { return finish() }
                            if lane.reportsProgress, duration > 0 {
                                let p = min(1, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                                if p - lane.lastReported >= 0.005 {
                                    lane.lastReported = p
                                    progress(p)
                                }
                            }
                            guard lane.input.append(sample) else { return finish() }
                        }
                    }
                }
                group.notify(queue: .global(qos: .userInitiated)) {
                    let reader = session.reader, writer = session.writer
                    if cancelled.isSet {
                        reader.cancelReading()
                        writer.cancelWriting()
                        return done.resume(throwing: CancellationError())
                    }
                    if reader.status == .failed {
                        writer.cancelWriting()
                        return done.resume(throwing: reader.error ?? EngineError("Couldn't read this file"))
                    }
                    if writer.status == .failed {
                        reader.cancelReading()
                        return done.resume(throwing: writer.error ?? EngineError("Couldn't encode this file"))
                    }
                    writer.finishWriting {
                        if session.writer.status == .completed {
                            done.resume()
                        } else {
                            done.resume(throwing: session.writer.error ?? EngineError("Couldn't finish writing"))
                        }
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }
}
