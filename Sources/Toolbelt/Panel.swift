import AppKit
import ApplicationServices
import SwiftUI

/// A Spotlight-style panel: it takes typing but leaves the other app in
/// front, so a paste lands there.
final class FloatingPanel: NSPanel {
    init(size: NSSize, content: some View) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// Shows and hides the panel, and pastes into the app that was in front.
@MainActor
final class PanelController {
    static var shared: PanelController!
    private let model: AppModel
    private(set) var panel: FloatingPanel!
    static let size = NSSize(width: 640, height: 440)

    init(model: AppModel) {
        self.model = model
        panel = FloatingPanel(size: Self.size, content:
            ToolbeltView(surface: .panel)
                .environment(model)
                .modelContainer(model.container)
                .themed()
        )
    }

    var isVisible: Bool { panel.isVisible }

    /// The shortcut for a tool: opens the panel on it, or closes the panel
    /// when it already shows that tool.
    func toggle(_ tool: Tool) {
        if panel.isVisible, model.tool == tool {
            hide()
            return
        }
        show(tool)
    }

    func show(_ tool: Tool) {
        model.tool = tool
        model.openCount += 1
        if !panel.isVisible, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                         y: frame.minY + frame.height * 0.62 - Self.size.height / 2))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Copies the clip, closes the panel, and presses Command-V in the app
    /// that was in front. Without Accessibility it only copies, and asks once.
    func paste(_ clip: ClipItem, plainText: Bool) {
        model.copy(clip, plainText: plainText)
        hide()
        guard Self.canPaste(prompt: true) else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            Self.pressCommandV()
        }
    }

    static func canPaste(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
