import AppKit
import SwiftUI

/// A short message near the bottom of the screen ("Copied #FF8000") that
/// fades after 1.5 seconds. Never takes focus or clicks.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, symbol: String) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        let host = NSHostingView(rootView: ToastView(message: message, symbol: symbol).themed())
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        if let screen = NSScreen.screenWithMouse ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .glassEffect(.regular, in: .capsule)
            .padding(Space.sm)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
