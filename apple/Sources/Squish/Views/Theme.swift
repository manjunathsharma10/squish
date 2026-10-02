import AppKit
import SwiftUI

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Monochrome palette with a single signal-orange accent.
enum Theme {
    private static let lightInk = NSColor(white: 0.04, alpha: 1)
    private static let darkInk = NSColor(white: 0.95, alpha: 1)

    private static func ink(_ alpha: CGFloat) -> Color {
        Color(light: lightInk.withAlphaComponent(alpha), dark: darkInk.withAlphaComponent(alpha))
    }

    static let background = Color(light: .white, dark: NSColor(white: 0.055, alpha: 1))
    static let ink = ink(1)
    static let muted = ink(0.5)
    static let faint = ink(0.28)
    static let line = ink(0.1)
    static let wash = ink(0.035)
    static let accent = Color(light: NSColor(srgbRed: 1, green: 0.30, blue: 0, alpha: 1),
                              dark: NSColor(srgbRed: 1, green: 0.40, blue: 0.12, alpha: 1))

    static let gutter: CGFloat = 28
}

/// Small uppercase label with wide tracking.
struct Caps: View {
    var text: String
    var color: Color = Theme.muted

    init(_ text: String, color: Color = Theme.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(1.4)
            .foregroundStyle(color)
    }
}

/// One physical pixel tall.
struct Hairline: View {
    @Environment(\.displayScale) private var scale
    var color: Color = Theme.line

    var body: some View {
        Rectangle().fill(color).frame(height: 1 / scale)
    }
}

extension Font {
    /// Tabular figures so sizes and percentages line up.
    static let figures = Font.system(size: 12).monospacedDigit()
}

// MARK: Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.background : Theme.faint)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(isEnabled ? Theme.ink.opacity(configuration.isPressed ? 0.78 : 1) : Theme.wash)
            .overlay { if !isEnabled { Rectangle().strokeBorder(Theme.line, lineWidth: 1) } }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Plain text that darkens on hover.
struct QuietButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration, active: active)
    }

    private struct QuietLabel: View {
        let configuration: Configuration
        let active: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(active || hovering ? Theme.ink : Theme.muted)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// A row of text options; the selected one is ink with an accent underline.
struct ChoiceRow<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @Namespace private var underline

    var body: some View {
        HStack(spacing: 16) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .padding(.vertical, 4)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Rectangle().fill(Theme.accent).frame(height: 1.5)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                }
                .buttonStyle(QuietButtonStyle(active: selected))
            }
        }
    }
}

/// A one-pixel slider with tick marks at the preset positions.
struct HairSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var ticks: [Double] = []

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = range.upperBound - range.lowerBound
            let x = CGFloat((value - range.lowerBound) / span) * width

            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.line).frame(height: 1)
                ForEach(ticks, id: \.self) { tick in
                    Rectangle().fill(Theme.faint).frame(width: 1, height: 5)
                        .offset(x: CGFloat((tick - range.lowerBound) / span) * width)
                }
                Rectangle().fill(Theme.ink).frame(width: max(0, x), height: 1)
                Circle()
                    .fill(Theme.ink)
                    .frame(width: dragging ? 13 : 11, height: dragging ? 13 : 11)
                    .offset(x: x - (dragging ? 6.5 : 5.5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let t = min(1, max(0, g.location.x / width))
                        value = ((range.lowerBound + Double(t) * span) * 100).rounded() / 100
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 22)
    }
}

/// A short accent segment sweeping across, for work with no known progress.
struct SweepBar: View {
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Theme.accent)
                .frame(width: geo.size.width * 0.3)
                .offset(x: geo.size.width * phase)
        }
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Two or more segments in a hairline frame; the selected one is solid ink
/// and slides between options.
struct SegmentedSwitch<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @Namespace private var fill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Segment(title: label(option), selected: option == selection, fill: fill) {
                    withAnimation(.snappy(duration: 0.3)) { selection = option }
                }
            }
        }
        .padding(2)
        .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
    }

    private struct Segment: View {
        let title: String
        let selected: Bool
        let fill: Namespace.ID
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? Theme.background : hovering ? Theme.ink : Theme.muted)
                    .padding(.horizontal, 16)
                    .frame(height: 26)
                    .background {
                        if selected {
                            Rectangle().fill(Theme.ink).matchedGeometryEffect(id: "fill", in: fill)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}
