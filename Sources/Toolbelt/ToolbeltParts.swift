import AppKit
import SwiftUI
import ToolbeltKit

/// One clip: source app icon, a one-line preview or thumbnail, and its age.
struct ClipRow: View {
    let clip: ClipItem
    let icon: NSImage?
    let selected: Bool

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "doc.on.clipboard").frame(width: 20, height: 20)
            }
            switch clip.kind {
            case .image:
                if let thumb = Thumbnails.shared.image(for: clip) {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 48)
                        .clipShape(.rect(cornerRadius: 4))
                }
                Text("Image")
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
            case .link:
                Image(systemName: "link").font(.caption)
                Text(ClipRules.preview(clip.text))
                    .lineLimit(1)
                    .help(String(clip.text.prefix(500)))
            case .text:
                Text(ClipRules.preview(clip.text))
                    .lineLimit(1)
                    .help(String(clip.text.prefix(500)))
            }
            Spacer(minLength: Space.sm)
            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .accessibilityLabel("Pinned")
            }
            Text(clip.copiedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption)
                .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                .fixedSize()
        }
    }
}

/// Small images for clip rows, made once per clip.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [UUID: NSImage] = [:]

    func image(for clip: ClipItem) -> NSImage? {
        if let image = cache[clip.uuid] { return image }
        guard let data = clip.imageData, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache[clip.uuid] = image
        return image
    }
}

/// The panel gets Liquid Glass with rounded corners; the popover draws its own.
struct SurfaceBackground: ViewModifier {
    let surface: Surface

    func body(content: Content) -> some View {
        switch surface {
        case .panel:
            content
                .frame(width: PanelController.size.width, height: PanelController.size.height)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
        case .popover:
            content.frame(width: 440, height: 480)
        }
    }
}

/// Reports the NSWindow a view sits in.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.found = found
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [found] in found?(window) }
        }
    }
}

/// The capture buttons under the Launcher search: full-contrast text on a
/// tinted fill. The system bordered style washes out on the glass panel and
/// in the popover, so these draw their own fill and hover state.
struct QuickActionStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs + 2)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering || configuration.isPressed ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.fill.secondary))
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A tool in the picker row: its icon, an accent fill when selected, and its
/// name in a small label right under it while the pointer is over it.
struct ToolPickerButton: View {
    /// A button and the gap after it, for working out how many fit on a line.
    static let width: CGFloat = 30

    let tool: Tool
    let number: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
                .background {
                    Capsule().fill(selected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(hovering ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear)))
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .top) {
            if hovering {
                Text(tool.title)
                    .font(.caption.weight(.medium))
                    .fixedSize()
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(radius: 2, y: 1)
                    .alignmentGuide(.top) { _ in -32 }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .help("\(tool.title): \(tool.help) (⌘\(number))")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Lays its views out in a row and wraps onto more rows when they do not fit
/// the width offered. Rows are balanced (17 tools make 9 and 8, not 13 and 4),
/// and every view gets the size it asks for.
struct WrappingRow: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: proposal.width, subviews: subviews)
        let height = rows.map { row in row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0 }
        return CGSize(width: rows.map { width(of: $0, subviews) }.max() ?? 0,
                      height: height.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let height = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }

    /// Indices per row: as few rows as fit, then the same count on each.
    private func rows(for available: CGFloat?, subviews: Subviews) -> [[Int]] {
        let all = Array(subviews.indices)
        guard let available, !all.isEmpty else { return [all] }
        var fit = 0, used: CGFloat = 0
        for index in all {
            let next = used + (fit > 0 ? spacing : 0) + subviews[index].sizeThatFits(.unspecified).width
            if next > available { break }
            used = next
            fit += 1
        }
        let rowCount = Int((Double(all.count) / Double(max(fit, 1))).rounded(.up))
        let perRow = Int((Double(all.count) / Double(rowCount)).rounded(.up))
        return stride(from: 0, to: all.count, by: perRow).map { Array(all[$0..<min($0 + perRow, all.count)]) }
    }

    private func width(of row: [Int], _ subviews: Subviews) -> CGFloat {
        row.reduce(0) { $0 + subviews[$1].sizeThatFits(.unspecified).width } + spacing * CGFloat(max(row.count - 1, 0))
    }
}
