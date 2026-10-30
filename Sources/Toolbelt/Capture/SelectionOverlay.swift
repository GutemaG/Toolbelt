import AppKit
import ScreenCaptureKit
import ToolbeltKit

/// What the person picked on the overlay.
enum Selection {
    /// An area on one display, in points with a top-left origin, plus the
    /// frozen image of that display (nil when the overlay was not frozen).
    case area(display: SCDisplay, rect: CGRect, frozen: CGImage?, scale: CGFloat)
    case window(SCWindow)
    case screen(SCDisplay)
}

/// The full-screen selection overlay: the screen freezes (for screenshots),
/// dims, and the person drags an area. Space switches to picking a window;
/// Escape cancels. One borderless window per display.
@MainActor
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var content: SCShareableContent?
    private var displays: [CGDirectDisplayID: SCDisplay] = [:]
    private var frozen: [CGDirectDisplayID: (image: CGImage, scale: CGFloat)] = [:]
    /// Windows under the overlay, front to back, in AppKit coordinates.
    private var windowFrames: [(id: CGWindowID, frame: CGRect)] = []
    private var keyMonitor: Any?
    var windowMode = false {
        didSet { views.forEach { $0.windowMode = windowMode } }
    }
    private var views: [SelectionView] { windows.compactMap { $0.contentView as? SelectionView } }

    /// Shows the overlay and waits for a choice. `freeze` captures each display
    /// first so the screen holds still (screenshots); recording selects live.
    func select(startInWindowMode: Bool = false, freeze: Bool, hint: String) async -> Selection? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        self.content = content
        displays = Dictionary(content.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { a, _ in a })
        if freeze {
            for display in content.displays {
                if let shot = await Self.captureDisplay(display, content: content) { frozen[display.displayID] = shot }
            }
        }
        windowFrames = Self.onScreenWindows()

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let id = screen.displayID
                let window = OverlayWindow(screen: screen)
                let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.frozen = frozen[id].map { NSImage(cgImage: $0.image, size: screen.frame.size) }
                view.hint = hint
                view.onDone = { [weak self] rect in self?.finishArea(rect, screen: screen) }
                view.onHover = { [weak self] point in self?.hover(at: point, on: screen) }
                view.onPickWindow = { [weak self] in self?.finishWindow() }
                window.contentView = view
                window.orderFrontRegardless()
                windows.append(window)
            }
            NSApp.activate()
            if let window = windows.first(where: { $0.screen == NSScreen.screenWithMouse }) ?? windows.first {
                window.makeKey()
                window.makeFirstResponder(window.contentView)
            }
            NSCursor.crosshair.push()
            windowMode = startInWindowMode
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 53: self.finish(nil)                // Escape
                case 49: self.windowMode.toggle()          // Space
                case 36, 76:                               // Return: the whole screen under the pointer
                    if let screen = NSScreen.screenWithMouse, let display = self.displays[screen.displayID] {
                        self.finish(.screen(display))
                    }
                default: return event
                }
                return nil
            }
        }
    }

    private func finishArea(_ rect: CGRect, screen: NSScreen) {
        guard let display = displays[screen.displayID] else { return finish(nil) }
        // A click without a drag picks the whole screen.
        if rect.width < 4 || rect.height < 4 { return finish(.screen(display)) }
        let topLeft = CaptureRules.topLeftRect(selection: rect, screenHeight: screen.frame.height)
        let shot = frozen[screen.displayID]
        finish(.area(display: display, rect: topLeft, frozen: shot?.image, scale: shot?.scale ?? screen.backingScaleFactor))
    }

    private var hovered: CGWindowID?

    private func hover(at point: CGPoint, on screen: NSScreen) {
        guard windowMode else { return }
        let global = CGPoint(x: point.x + screen.frame.minX, y: point.y + screen.frame.minY)
        let match = windowFrames.first { $0.frame.contains(global) }
        hovered = match?.id
        for view in views {
            let origin = view.window?.screen?.frame.origin ?? .zero
            view.highlight = match.map { $0.frame.offsetBy(dx: -origin.x, dy: -origin.y) }
        }
    }

    private func finishWindow() {
        guard let id = hovered, let window = content?.windows.first(where: { $0.windowID == id }) else { return }
        finish(.window(window))
    }

    private func finish(_ selection: Selection?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        continuation?.resume(returning: selection)
        continuation = nil
    }

    /// The whole display as it is now, without Toolbelt's own windows.
    static func captureDisplay(_ display: SCDisplay, content: SCShareableContent) async -> (image: CGImage, scale: CGFloat)? {
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = CapturePrefs.includeCursor
        config.captureResolution = .best
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return (image, scale)
    }

    /// Normal app windows on screen, front to back, in AppKit coordinates.
    private static func onScreenWindows() -> [(id: CGWindowID, frame: CGRect)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != me,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w > 40, h > 40 else { return nil }
            // Quartz puts the origin at the top left of the main display; AppKit at the bottom left.
            return (id, CGRect(x: x, y: mainHeight - y - h, width: w, height: h))
        }
    }
}

/// A borderless window over one display, above everything, including full-screen apps.
private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

/// Draws the frozen screen, dims it, and tracks the drag. AppKit view, because
/// it needs exact mouse tracking and redraws on every mouse move.
private final class SelectionView: NSView {
    var frozen: NSImage?
    var hint = ""
    var windowMode = false { didSet { highlight = nil; needsDisplay = true } }
    var highlight: CGRect? { didSet { needsDisplay = true } }
    var onDone: ((CGRect) -> Void)?
    var onHover: ((CGPoint) -> Void)?
    var onPickWindow: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private var pointer: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self))
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CaptureRules.dragRect(from: start, to: current, in: bounds)
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        onHover?(pointer!)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if windowMode { return }
        start = convert(event.locationInWindow, from: nil)
        current = start
    }

    override func mouseDragged(with event: NSEvent) {
        guard !windowMode else { return }
        current = convert(event.locationInWindow, from: nil)
        pointer = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if windowMode { return onPickWindow?() ?? () }
        current = convert(event.locationInWindow, from: nil)
        onDone?(selection ?? .zero)
    }

    override func draw(_ dirtyRect: NSRect) {
        frozen?.draw(in: bounds)
        let dim = NSColor.black.withAlphaComponent(0.35)
        if let cut = windowMode ? highlight : selection, cut.width > 0 {
            // Dim everything except the selection.
            let path = NSBezierPath(rect: bounds)
            path.appendRect(cut)
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: cut.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            if !windowMode { label("\(Int(cut.width)) × \(Int(cut.height))", near: CGPoint(x: cut.maxX, y: cut.minY)) }
        } else {
            dim.setFill()
            bounds.fill()
            if let pointer, !windowMode {
                // Crosshair lines through the pointer.
                NSColor.white.withAlphaComponent(0.5).setStroke()
                let lines = NSBezierPath()
                lines.move(to: CGPoint(x: pointer.x, y: 0)); lines.line(to: CGPoint(x: pointer.x, y: bounds.maxY))
                lines.move(to: CGPoint(x: 0, y: pointer.y)); lines.line(to: CGPoint(x: bounds.maxX, y: pointer.y))
                lines.lineWidth = 0.5
                lines.stroke()
            }
        }
        label(windowMode ? "Click a window. Space: select an area. Esc: cancel."
                         : hint, near: CGPoint(x: bounds.midX, y: bounds.maxY - 60), centered: true)
    }

    /// White text on a dark capsule, readable over any screen content.
    private func label(_ text: String, near point: CGPoint, centered: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var box = CGRect(x: point.x + 8, y: point.y - size.height - 12, width: size.width + 16, height: size.height + 8)
        if centered { box.origin = CGPoint(x: point.x - box.width / 2, y: point.y) }
        box.origin.x = min(max(box.minX, 4), bounds.maxX - box.width - 4)
        box.origin.y = min(max(box.minY, 4), bounds.maxY - box.height - 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static var screenWithMouse: NSScreen? {
        screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }
}
