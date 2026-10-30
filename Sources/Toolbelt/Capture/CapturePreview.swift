import AppKit
import AVFoundation
import SwiftUI

/// The small card in the corner after a capture: drag it out, copy it, show
/// it in Finder, or move it to the Trash. Hides after 6 seconds unless hovered.
@MainActor
final class CapturePreview {
    static let shared = CapturePreview()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private(set) var hovering = false

    func show(_ capture: Capture) {
        hide()
        let size = NSSize(width: 240, height: 200)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CapturePreviewView(capture: capture, onHover: { [weak self] in
            self?.hovering = $0
            if !$0 { self?.scheduleHide() }
        }, onClose: { [weak self] in self?.hide() }).themed())
        host.sizingOptions = []
        panel.contentView = host
        if let screen = NSScreen.screenWithMouse ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - Space.xl, y: frame.minY + Space.xl))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleHide()
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        hovering = false
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, !self.hovering else { return }
            self.hide()
        }
    }
}

private struct CapturePreviewView: View {
    let capture: Capture
    let onHover: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            ZStack(alignment: .topTrailing) {
                CaptureThumbnail(capture: capture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .draggable(capture.url)
                    .help("Drag into another app or a folder")
                Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .help("Close the preview")
            }
            HStack(spacing: Space.sm) {
                Button("Copy", systemImage: "doc.on.doc") {
                    CaptureController.shared.copy(capture)
                    onClose()
                }
                .help("Copy to the clipboard")
                if capture.kind == .screenshot {
                    Button("Pin to Screen", systemImage: "pin") {
                        PinnedImage.pin(capture.url)
                        onClose()
                    }
                    .help("Keep it floating above other windows")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([capture.url])
                    onClose()
                }
                .help("Show the file in Finder")
                Button("Open", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(capture.url)
                    onClose()
                }
                .help("Open in the default app")
                Button("Move to Trash", systemImage: "trash") {
                    CaptureController.shared.delete(capture)
                    onClose()
                }
                .help("Move the file to the Trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(Space.md)
        .frame(width: 240, height: 200)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onHover(perform: onHover)
    }
}

/// A capture's first frame or image, loaded once from the file.
struct CaptureThumbnail: View {
    let capture: Capture
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: capture.kind == .recording ? "video" : "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            if capture.kind == .recording {
                Label(CaptureRulesText.duration(capture.duration), systemImage: "play.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.xs + 2)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: .capsule)
                    .padding(Space.xs)
            }
        }
        .task(id: capture.path) { image = await CaptureThumbnails.image(for: capture) }
    }
}

enum CaptureRulesText {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Thumbnails for captures: Quick Look makes them for images and movies alike.
@MainActor
enum CaptureThumbnails {
    private static var cache: [String: NSImage] = [:]

    static func image(for capture: Capture) async -> NSImage? {
        if let image = cache[capture.path] { return image }
        let url = capture.url
        let isMovie = capture.kind == .recording
        let image: NSImage? = await Task.detached(priority: .utility) {
            if isMovie {
                let generator = AVAssetImageGeneratorBox(url: url)
                return await generator.firstFrame()
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 480,
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        }.value
        if let image { cache[capture.path] = image }
        return image
    }
}

/// Reads the first frame of a movie for its thumbnail.
nonisolated struct AVAssetImageGeneratorBox: Sendable {
    let url: URL

    func firstFrame() async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
