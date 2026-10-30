import AppKit

/// Pin a screenshot: the image floats above other windows as a reference.
/// Drag to move, drag an edge to resize (keeps the shape), Escape or the
/// right-click menu to close.
@MainActor
enum PinnedImage {
    private static var windows: [NSWindow] = []

    static func pin(_ url: URL) {
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first else { return }
        // Show at point size (pixels / 2 on Retina), at most half the screen.
        var size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        let screen = NSScreen.screenWithMouse ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let scale = min(1, visible.width / 2 / size.width, visible.height / 2 / size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        let window = PinnedWindow(image: image, size: size)
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        window.orderFrontRegardless()
        windows.append(window)
    }

    static func close(_ window: NSWindow) {
        window.orderOut(nil)
        windows.removeAll { $0 === window }
    }
}

private final class PinnedWindow: NSPanel {
    init(image: NSImage, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.menu = makeMenu()
        view.toolTip = "Drag to move. Right-click to copy or close."
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { PinnedImage.close(self) }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePinned), keyEquivalent: "w").target = self
        return menu
    }

    @objc private func copyImage() {
        guard let image = (contentView as? NSImageView)?.image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func closePinned() { PinnedImage.close(self) }
}
