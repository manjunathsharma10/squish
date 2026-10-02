import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("fineTune") private var showFineTune = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Header()
            Hairline()
            // Settings are locked mid-batch so results always match what's shown.
            Group {
                ControlBar(showFineTune: $showFineTune)
                if model.settings.mode == .compress, showFineTune {
                    Hairline()
                    FineTunePanel()
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .disabled(model.isRunning)
            .opacity(model.isRunning ? 0.45 : 1)
            .animation(.easeOut(duration: 0.2), value: model.isRunning)
            Hairline()

            Group {
                if model.items.isEmpty {
                    DropZone(targeted: dropTargeted, mode: model.settings.mode) { model.isImporting = true }
                        .padding(Theme.gutter)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        DropStrip(targeted: dropTargeted) { model.isImporting = true }
                        Hairline()
                        FileList()
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)

            Hairline()
            Footer()
        }
        .background(Theme.background.ignoresSafeArea())
        .frame(minWidth: 580, minHeight: 640)
        .animation(.snappy(duration: 0.3), value: showFineTune)
        .animation(.snappy(duration: 0.3), value: model.settings.mode)
        .animation(.snappy(duration: 0.3), value: model.items.isEmpty)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $model.isImporting,
                      allowedContentTypes: [.image, .pdf, .movie, .audio, .folder],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { model.add(urls) }
        }
    }
}

// MARK: - Header

private struct Header: View {
    @AppStorage("appearance") private var appearance = 0 // 0 system, 1 light, 2 dark

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                (Text("Squish") + Text(".").foregroundColor(Theme.accent))
                    .font(.system(size: 30, weight: .semibold))
                    .kerning(-1)
                    .foregroundStyle(Theme.ink)
                Text("Make files lighter. Everything stays on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button {
                appearance = (appearance + 1) % 3
            } label: {
                HStack(spacing: 7) {
                    Caps(["Auto", "Light", "Dark"][appearance], color: Theme.faint)
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 13, weight: .light))
                }
            }
            .buttonStyle(QuietButtonStyle())
            .help("Appearance")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 22)
        .onChange(of: appearance, initial: true) { _, value in
            NSApp.appearance = [nil, NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)][value]
        }
    }
}

// MARK: - Mode, presets and conversion targets

private struct ControlBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showFineTune: Bool
    @Namespace private var marker

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SegmentedSwitch(options: Mode.allCases, selection: $model.settings.mode) { $0.title }
                Spacer()
                if model.settings.mode == .compress {
                    if model.settings.preset == nil { Caps(customSummary).padding(.trailing, 14) }
                    Button { showFineTune.toggle() } label: {
                        HStack(spacing: 6) {
                            Caps("Fine-tune", color: showFineTune ? Theme.ink : Theme.muted)
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                                .rotationEffect(.degrees(showFineTune ? 45 : 0))
                        }
                    }
                    .buttonStyle(QuietButtonStyle(active: showFineTune))
                } else if !model.items.isEmpty {
                    ConvertSummary(prediction: model.prediction(for: nil))
                }
            }

            if model.settings.mode == .compress {
                presets.transition(.opacity)
            } else {
                ConvertPanel().transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 18)
    }

    private var presets: some View {
        let current = model.settings.preset
        return HStack(alignment: .top, spacing: 18) {
            ForEach(Preset.allCases) { preset in
                let selected = current == preset
                let prediction = model.items.isEmpty ? nil : model.prediction(for: preset)
                Button {
                    withAnimation(.snappy(duration: 0.3)) { self.model.settings.apply(preset) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.line).frame(height: 1)
                            if selected {
                                Rectangle().fill(Theme.accent).frame(height: 2)
                                    .matchedGeometryEffect(id: "marker", in: marker)
                            }
                        }
                        .frame(height: 2)
                        .padding(.bottom, 8)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(preset.title)
                                .font(.system(size: 15, weight: .medium))
                                .kerning(-0.2)
                                .foregroundStyle(selected ? Theme.ink : Theme.muted)
                            Spacer(minLength: 0)
                            if !model.items.isEmpty {
                                PredictedSize(prediction: prediction, selected: selected)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(preset.caption)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.faint)
                            Spacer(minLength: 0)
                            if let prediction {
                                Text(Format.percent(prediction.saving))
                                    .font(.system(size: 11.5).monospacedDigit())
                                    .foregroundStyle(selected ? Theme.accent : Theme.faint)
                                    .contentTransition(.numericText())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .animation(.snappy(duration: 0.35), value: prediction?.after)
                }
                .buttonStyle(QuietButtonStyle(active: selected))
                .help(helpText(preset, prediction))
            }
        }
    }

    private var customSummary: String {
        guard !model.items.isEmpty, let prediction = model.prediction(for: nil) else { return "Custom" }
        return "Custom · ≈ \(Format.size(prediction.after))"
    }

    private func helpText(_ preset: Preset, _ prediction: Prediction?) -> String {
        guard let prediction else { return "\(preset.title): quality \(Int(preset.quality * 100)), up to \(preset.maxSize.label) px" }
        let files = model.items.count == 1 ? "1 file" : "\(model.items.count) files"
        let state = prediction.complete ? "" : " (still estimating)"
        return "About \(Format.size(prediction.after)) for \(files) with \(preset.title)\(state)"
    }
}

/// "≈ 4.2 MB": the predicted total for the queue. Dimmed while some files
/// are still being estimated; a dash until the first estimate lands.
private struct PredictedSize: View {
    let prediction: Prediction?
    let selected: Bool

    var body: some View {
        Group {
            if let prediction {
                Text("≈ \(Format.size(prediction.after))")
                    .foregroundStyle(selected ? Theme.ink : Theme.muted)
                    .opacity(prediction.complete ? 1 : 0.55)
                    .contentTransition(.numericText())
            } else {
                Text("—").foregroundStyle(Theme.faint)
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Fine-tune

private struct FineTunePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 12) {
            Row("Quality") {
                HairSlider(value: $model.settings.quality, range: 0.2...1, ticks: Preset.allCases.map(\.quality))
                Text("\(Int((model.settings.quality * 100).rounded()))")
                    .font(.figures)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 30, alignment: .trailing)
            }
            Row("Max size") {
                ChoiceRow(options: MaxSize.allCases, selection: $model.settings.maxSize) { $0.label }
            }
            Row("Video") {
                ChoiceRow(options: VideoCodec.allCases, selection: $model.settings.videoCodec) { $0.label }
            }
            Row("Metadata") {
                ChoiceRow(options: [false, true], selection: $model.settings.keepMetadata) { $0 ? "Keep" : "Strip" }
            }
            Row("Save to") {
                SaveToChoice()
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 16)
    }
}

// MARK: - Convert

/// One row per kind of file. Kinds that aren't in the queue are dimmed.
private struct ConvertPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let options = model.settings.convert

        VStack(alignment: .leading, spacing: 12) {
            Row("Images") {
                ChoiceRow(options: ImageTarget.available, selection: $model.settings.convert.image) { $0.label }
                if options.image == .pdf {
                    Divider()
                    ChoiceRow(options: [false, true], selection: $model.settings.convert.combineImages) {
                        $0 ? "Combine" : "One each"
                    }
                }
            }
            .opacity(dim(.image))
            Row("PDF") {
                ChoiceRow(options: PageFormat.allCases, selection: $model.settings.convert.pages) { $0.label }
                Divider()
                ChoiceRow(options: [150, 300], selection: $model.settings.convert.pageDPI) { "\($0) dpi" }
            }
            .opacity(dim(.pdf))
            Row("Video") {
                ChoiceRow(options: [VideoFormat.mp4, .mov], selection: $model.settings.convert.video) { $0.label }
                Divider()
                ChoiceRow(options: VideoCodec.allCases, selection: $model.settings.convert.videoCodec) { $0.label }
            }
            .opacity(dim(.video))
            Row("Audio") {
                ChoiceRow(options: AudioFormat.allCases, selection: $model.settings.convert.audio) { $0.label }
            }
            .opacity(dim(.audio))
            Row("Quality") {
                HairSlider(value: $model.settings.convert.quality, range: 0.2...1)
                Text("\(Int((options.quality * 100).rounded()))")
                    .font(.figures)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 30, alignment: .trailing)
            }
            Row("Save to") {
                SaveToChoice()
            }
        }
        .animation(.snappy(duration: 0.25), value: options.image)
    }

    private func dim(_ kind: FileKind) -> Double {
        model.items.isEmpty || model.items.contains { $0.kind == kind } ? 1 : 0.35
    }

    private struct Divider: View {
        var body: some View {
            Rectangle().fill(Theme.line).frame(width: 1, height: 12).padding(.horizontal, 4)
        }
    }
}

/// "≈ 12.3 MB · −40%" for the whole queue in Convert mode.
private struct ConvertSummary: View {
    let prediction: Prediction?

    var body: some View {
        HStack(spacing: 8) {
            if let prediction {
                Text("≈ \(Format.size(prediction.after))")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(Format.percent(prediction.saving))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(prediction.saving >= 0.005 ? Theme.accent : Theme.faint)
            } else {
                Text("—").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.faint)
            }
        }
        .opacity(prediction?.complete == false ? 0.55 : 1)
        .animation(.snappy(duration: 0.35), value: prediction?.after)
        .help("Predicted total after converting")
    }
}

private struct Row<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Caps(title).frame(width: 92, alignment: .leading)
            HStack(spacing: 10) { content }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }
}

private struct SaveToChoice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let folder = model.settings.destination
        HStack(spacing: 16) {
            Button { model.settings.destination = nil } label: {
                choice("Next to original", selected: folder == nil)
            }
            .buttonStyle(QuietButtonStyle(active: folder == nil))

            Button { model.chooseDestination() } label: {
                choice(folder.map { "\($0.lastPathComponent)" } ?? "Choose folder…", selected: folder != nil)
            }
            .buttonStyle(QuietButtonStyle(active: folder != nil))
            .help(folder?.path(percentEncoded: false) ?? "Save to a folder of your choice")
        }
    }

    private func choice(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .lineLimit(1)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(Theme.accent).frame(height: 1.5) }
            }
    }
}

// MARK: - Drop targets

private struct DropZone: View {
    var targeted: Bool
    var mode: Mode
    var choose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(targeted ? Theme.accent.opacity(0.045) : .clear)
            Rectangle()
                .strokeBorder(targeted ? Theme.accent : Theme.faint,
                              style: StrokeStyle(lineWidth: 1, dash: targeted ? [] : [3, 4]))

            VStack(spacing: 22) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(targeted ? Theme.accent : Theme.ink)
                    .offset(y: targeted ? 5 : 0)

                VStack(spacing: 7) {
                    Text(targeted ? "Release to add" : mode == .compress ? "Drop files to compress" : "Drop files to convert")
                        .font(.system(size: 21, weight: .medium))
                        .kerning(-0.5)
                        .foregroundStyle(Theme.ink)
                    Text("Images, PDFs, video and audio. Folders work too.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                }

                Button(action: choose) {
                    Text("Choose files")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.vertical, 3)
                        .overlay(alignment: .bottom) { Rectangle().frame(height: 1) }
                }
                .buttonStyle(QuietButtonStyle(active: true))
            }

            VStack {
                Spacer()
                Caps("JPG  PNG  HEIC  WEBP  AVIF  PDF  MP4  MOV  MP3  M4A  WAV", color: Theme.faint)
                    .padding(.bottom, 20)
            }
        }
        .animation(.snappy(duration: 0.25), value: targeted)
    }
}

private struct DropStrip: View {
    var targeted: Bool
    var choose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: targeted ? "arrow.down" : "plus")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(targeted ? Theme.accent : Theme.muted)
                .frame(width: 14)
            Text(targeted ? "Release to add" : "Drop more files, or")
                .font(.system(size: 12.5))
                .foregroundStyle(targeted ? Theme.accent : Theme.muted)
            if !targeted {
                Button("browse", action: choose)
                    .font(.system(size: 12.5, weight: .medium))
                    .buttonStyle(QuietButtonStyle(active: true))
            }
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .frame(height: 44)
        .background(targeted ? Theme.accent.opacity(0.045) : .clear)
        .animation(.snappy(duration: 0.2), value: targeted)
    }
}

// MARK: - Footer

private struct Footer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            summary
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            if !model.items.isEmpty, !model.isRunning {
                Button("Clear") { withAnimation(.snappy) { model.clear() } }
                    .font(.system(size: 12.5))
                    .buttonStyle(QuietButtonStyle())
            }

            if model.isRunning {
                Button { model.stop() } label: {
                    Text("Stop")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button { model.compress() } label: {
                    HStack(spacing: 10) {
                        Text(model.settings.mode.title)
                        Text("⌘↩").font(.system(size: 11)).opacity(0.45)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canCompress)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .frame(height: 64)
        .overlay(alignment: .top) {
            if model.isRunning {
                GeometryReader { geo in
                    Rectangle().fill(Theme.accent)
                        .frame(width: geo.size.width * model.batchProgress, height: 1.5)
                        .animation(.easeOut(duration: 0.3), value: model.batchProgress)
                }
                .frame(height: 1.5)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        if let notice = model.notice {
            Text(notice).foregroundStyle(Theme.ink)
        } else if let totals = model.totals {
            let saved = totals.before - totals.after
            let fraction = totals.before > 0 ? Double(saved) / Double(totals.before) : 0
            HStack(spacing: 8) {
                Text("\(Format.size(totals.before)) → \(Format.size(totals.after))")
                    .font(.figures)
                    .foregroundStyle(Theme.muted)
                Text(saved >= 0 ? "\(Format.size(saved)) saved" : "\(Format.size(-saved)) larger")
                    .foregroundStyle(Theme.ink)
                // Orange only marks a real saving.
                Text(Format.percent(fraction))
                    .font(.figures.weight(.semibold))
                    .foregroundStyle(fraction >= 0.005 ? Theme.accent : Theme.muted)
            }
        } else if model.items.isEmpty {
            Text("No files yet").foregroundStyle(Theme.faint)
        } else {
            let count = model.items.count
            let total = model.items.reduce(0) { $0 + $1.size }
            HStack(spacing: 8) {
                Text(count == 1 ? "1 file" : "\(count) files").foregroundStyle(Theme.ink)
                Text(Format.size(total)).font(.figures).foregroundStyle(Theme.muted)
            }
        }
    }
}
