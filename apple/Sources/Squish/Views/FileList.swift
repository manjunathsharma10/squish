import SwiftUI

struct FileList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    FileRow(item: item)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    Hairline().padding(.leading, Theme.gutter + 36 + 14)
                }
            }
            .animation(.snappy(duration: 0.3), value: model.items.map(\.id))
        }
        .scrollIndicators(.never)
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: FileItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(item: item, vivid: hovering || item.status == .done)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isFailed ? Theme.accent : Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail)
            }

            Spacer(minLength: 12)

            // Swap instantly, then fade the new state in, so old and new
            // text never overlap mid-transition.
            trailing
                .id(stateKey)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.25)), removal: .identity))

            actions
        }
        .padding(.leading, Theme.gutter)
        .padding(.trailing, Theme.gutter - 8)
        .frame(height: 58)
        .background(hovering ? Theme.wash : .clear)
        .overlay(alignment: .bottom) { progressLine }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.3), value: item.status)
        .onTapGesture(count: 2) { model.open(item) }
        .contextMenu {
            Button(item.output == nil ? "Show Original in Finder" : "Show in Finder") { model.reveal(item) }
            Button("Open") { model.open(item) }
            Divider()
            Button("Remove") { model.remove(item) }.disabled(item.status == .working)
        }
    }

    private var stateKey: String {
        switch item.status {
        case .ready: "ready"
        case .working: item.progress == nil ? "working" : "progress"
        case .done: "done"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var detail: String {
        switch item.status {
        case .failed(let message):
            return message
        case .skipped(let message):
            return message
        case .done:
            let formats = item.format == item.outputFormat || (item.format == "JPEG" && item.outputFormat == "JPG")
                ? item.outputFormat : "\(item.format) → \(item.outputFormat)"
            return [formats, item.outputInfo].filter { !$0.isEmpty }.joined(separator: " · ")
        case .ready, .working:
            // In Convert mode, preview what the file will become.
            let formats = model.conversionTarget(for: item).map { target in
                target.already ? "\(item.format) · already \(target.label)" : "\(item.format) → \(target.label)"
            } ?? item.format
            return [formats, item.info].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .ready, .failed:
            Text(Format.size(item.size)).font(.figures).foregroundStyle(Theme.muted)
        case .working:
            if let p = item.progress {
                Text("\(Int(p * 100))%").font(.figures).foregroundStyle(Theme.ink)
            } else {
                Text("Working").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
        case .skipped:
            Text(Format.size(item.size)).font(.figures).foregroundStyle(Theme.faint)
        case .done where item.page != nil:
            // One page of a combined PDF: the PDF's size is in the footer.
            Text("\(Format.size(item.size)) → page \(item.page?.number ?? 0)")
                .font(.figures)
                .foregroundStyle(Theme.muted)
        case .done:
            HStack(spacing: 12) {
                Text("\(Format.size(item.size)) → \(Format.size(item.outputSize ?? 0))")
                    .font(.figures)
                    .foregroundStyle(Theme.muted)
                Text(Format.percent(item.saving ?? 0))
                    .font(.figures.weight(.semibold))
                    .foregroundStyle((item.saving ?? 0) >= 0.005 ? Theme.accent : Theme.muted)
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if item.status == .done {
                iconButton("arrow.up.forward", help: "Show in Finder") { model.reveal(item) }
            }
            if item.status != .working {
                iconButton("xmark", help: "Remove") { model.remove(item) }
            }
        }
        .frame(width: 44, alignment: .trailing)
        .opacity(hovering ? 1 : 0)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(QuietButtonStyle())
        .help(help)
    }

    @ViewBuilder private var progressLine: some View {
        if item.status == .working {
            Group {
                if let p = item.progress {
                    GeometryReader { geo in
                        Rectangle().fill(Theme.accent)
                            .frame(width: geo.size.width * p)
                            .animation(.linear(duration: 0.2), value: p)
                    }
                } else {
                    SweepBar()
                }
            }
            .frame(height: 1.5)
            .transition(.opacity)
        }
    }
}

/// Greyscale until hovered or finished, in keeping with the monochrome UI.
private struct Thumbnail: View {
    let item: FileItem
    let vivid: Bool

    var body: some View {
        ZStack {
            if let image = item.thumbnail {
                picture(item.thumbnailMono ?? image)
                picture(image).opacity(vivid ? 1 : 0)
            } else {
                Theme.wash
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 36, height: 36)
        .clipped()
        .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 0.5))
        .animation(.easeOut(duration: 0.4), value: vivid)
    }

    private func picture(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: 36, height: 36)
    }
}
