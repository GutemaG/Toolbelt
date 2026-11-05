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

/// A tool's main button where the window stays inactive. The system prominent
/// style turns gray there, and a tinted one blooms past legible on the dark
/// glass panel, so this keeps full-contrast text on a fill of the tool's color.
struct TintedActionStyle: ButtonStyle {
    let tint: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs + 2)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(hovering || configuration.isPressed ? 0.5 : 0.35))
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
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
