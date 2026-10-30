import AppKit
import ApplicationServices
import ToolbeltKit

/// Window snapping: moves and resizes the front window of the app you were
/// using, through the Accessibility API.
@MainActor
final class WindowSnapper {
    static let shared = WindowSnapper()
    /// The app in front before Toolbelt's popover took focus.
    var previousApp: NSRunningApplication?

    func snap(_ position: WindowPosition) {
        guard PanelController.canPaste(prompt: true) else {
            Toast.show("Allow Accessibility to move windows", symbol: "hand.raised")
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        guard let app = (front?.processIdentifier == me ? previousApp : front) ?? previousApp else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Toast.show("No window to move", symbol: "macwindow")
            return
        }
        let window = value as! AXUIElement
        guard let current = frame(of: window) else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // The screen that holds the middle of the window, in AppKit coordinates.
        let appKit = CGRect(x: current.minX, y: mainHeight - current.maxY, width: current.width, height: current.height)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: appKit.midX, y: appKit.midY)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let target = WindowPosition.axFrame(position.frame(in: visible, current: appKit), mainScreenHeight: mainHeight)
        // Size, then position, then size again: some apps clamp the size to the old screen.
        set(window, size: target.size)
        set(window, origin: target.origin)
        set(window, size: target.size)
        app.activate()
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private func set(_ window: AXUIElement, origin: CGPoint) {
        var point = origin
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    private func set(_ window: AXUIElement, size: CGSize) {
        var extent = size
        if let value = AXValueCreate(.cgSize, &extent) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }
}

extension WindowPosition {
    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .maximize: "Maximize"
        case .center: "Center"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .leftThird: "rectangle.leftthird.inset.filled"
        case .centerThird: "rectangle.split.3x1.fill"
        case .rightThird: "rectangle.rightthird.inset.filled"
        case .leftTwoThirds: "rectangle.split.2x1.fill"
        case .rightTwoThirds: "rectangle.split.2x1"
        case .maximize: "rectangle.fill"
        case .center: "rectangle.center.inset.filled"
        }
    }

    /// The shortcut as shown, and its Carbon key code. All use ⌃⌥.
    var shortcut: (label: String, keyCode: Int) {
        switch self {
        case .leftHalf: ("⌃⌥←", 123)
        case .rightHalf: ("⌃⌥→", 124)
        case .topHalf: ("⌃⌥↑", 126)
        case .bottomHalf: ("⌃⌥↓", 125)
        case .leftThird: ("⌃⌥D", 2)
        case .centerThird: ("⌃⌥F", 3)
        case .rightThird: ("⌃⌥G", 5)
        case .leftTwoThirds: ("⌃⌥E", 14)
        case .rightTwoThirds: ("⌃⌥T", 17)
        case .maximize: ("⌃⌥↩", 36)
        case .center: ("⌃⌥C", 8)
        }
    }
}
