import AppKit
import ScreenCaptureKit
import SwiftUI
import ToolbeltKit

/// Scrolling capture: pick an area, scroll it by hand, and Toolbelt joins
/// what scrolls into view into one tall screenshot. Scrolling by hand works
/// in every app and needs no Accessibility.
@Observable
final class ScrollCapture {
    static let shared = ScrollCapture()
    /// Taller images get slow to save and to open.
    static let maxHeight = 30_000

    enum Status: Equatable {
        case waiting, capturing, tooFast, limit
    }

    private(set) var isRunning = false
    private(set) var status: Status = .waiting
    /// The joined image's height so far, in pixels.
    private(set) var height = 0

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var session: ScrollSession?
    @ObservationIgnored private var outline: NSWindow?
    @ObservationIgnored private var bar: NSPanel?

    /// The shortcut starts a capture, or finishes the one running.
    func toggle() {
        isRunning ? finish() : start()
    }

    func start() {
        guard !isRunning, CaptureController.ensurePermission() else { return }
        isRunning = true
        PanelController.shared.hide()
        StatusItems.shared?.closePopovers()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let selection = await SelectionOverlay().select(freeze: false,
                                                            hint: "Drag over the part that scrolls. Space: pick a window. Esc: cancel.")
            guard let selection, let target = await Self.target(for: selection) else {
                isRunning = false
                return
            }
            await begin(display: target.display, rect: target.rect)
        }
    }

    /// Saves what was captured, like any screenshot.
    func finish() {
        guard isRunning else { return }
        loop?.cancel()
        loop = nil
        let session = self.session
        close()
        Task {
            guard let image = await session?.compose() else { return }
            CaptureController.shared.save(image)
        }
    }

    func cancel() {
        loop?.cancel()
        loop = nil
        close()
    }

    // MARK: Capturing

    /// The area to capture, in points from the display's top left.
    private static func target(for selection: Selection) async -> (display: SCDisplay, rect: CGRect)? {
        switch selection {
        case .area(let display, let rect, _, _):
            return (display, rect)
        case .screen(let display):
            return (display, CGRect(x: 0, y: 0, width: display.width, height: display.height))
        case .window(let window):
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.max(by: { overlap($0.frame, window.frame) < overlap($1.frame, window.frame) }) else { return nil }
            let rect = window.frame.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            return rect.isEmpty ? nil : (display, rect)
        }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let both = a.intersection(b)
        return both.isNull ? 0 : both.width * both.height
    }

    private func begin(display: SCDisplay, rect: CGRect) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            isRunning = false
            return
        }
        // Toolbelt's own windows (the outline, the bar) never show in the image.
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let frameHeight = config.height
        let session = ScrollSession(frameHeight: frameHeight)
        self.session = session
        status = .waiting
        height = 0
        let screenRect = appKitRect(rect, display: display)
        showOutline(screenRect)
        showBar(near: screenRect)

        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    let result = await session.add(image)
                    guard !Task.isCancelled, let self else { return }
                    self.height = result.height
                    switch result.step {
                    case .first: self.status = .waiting
                    case .moved: self.status = .capturing
                    case .lost: self.status = .tooFast
                    case .same: if self.status == .tooFast { self.status = result.height > frameHeight ? .capturing : .waiting }
                    }
                    if result.height >= Self.maxHeight {
                        self.status = .limit
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func close() {
        outline?.orderOut(nil)
        outline = nil
        bar?.orderOut(nil)
        bar = nil
        session = nil
        isRunning = false
    }

    // MARK: Outline and bar

    /// A thin frame just outside the area, like the recorder's.
    private func showOutline(_ rect: CGRect) {
        let window = NSWindow(contentRect: rect.insetBy(dx: -2, dy: -2), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 2
        window.contentView = view
        window.orderFrontRegardless()
        outline = window
    }

    /// The bar sits under the area, above it when there is no room, or
    /// inside its bottom edge when the area fills the screen.
    private func showBar(near rect: CGRect) {
        let host = NSHostingView(rootView: ScrollCaptureBar(capture: self).themed())
        let size = host.fittingSize
        let panel = ScrollBarPanel(contentRect: CGRect(origin: .zero, size: size))
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) }?.visibleFrame ?? rect
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - Space.md - size.height)
        if origin.y < screen.minY { origin.y = rect.maxY + Space.md }
        if origin.y + size.height > screen.maxY { origin.y = rect.minY + Space.md }
        origin.x = min(max(origin.x, screen.minX + Space.sm), screen.maxX - size.width - Space.sm)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        // Return and Escape reach the bar; scrolling still goes to the window under the pointer.
        panel.makeKey()
        bar = panel
    }

    private func appKitRect(_ rect: CGRect, display: SCDisplay) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { return rect }
        return CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Takes key focus for Return and Escape without bringing Toolbelt forward.
private final class ScrollBarPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
}

/// What the bar says, and Cancel and Done.
struct ScrollCaptureBar: View {
    let capture: ScrollCapture

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(capture.status == .tooFast ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                .frame(width: Space.xxl)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 240, alignment: .leading)
            Button("Cancel") { capture.cancel() }
                .keyboardShortcut(.cancelAction)
                .help("Stop without saving (esc)")
            Button("Done") { capture.finish() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .help("Save the tall screenshot (↩)")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scrolling capture")
    }

    private var symbol: String {
        switch capture.status {
        case .waiting, .capturing: "scroll"
        case .tooFast: "exclamationmark.triangle.fill"
        case .limit: "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch capture.status {
        case .waiting: "Scroll down slowly"
        case .capturing: "\(capture.height.formatted()) px captured"
        case .tooFast: "Scroll back up a little"
        case .limit: "Reached \(ScrollCapture.maxHeight.formatted()) px"
        }
    }

    private var detail: String {
        switch capture.status {
        case .waiting: "Each new part is added as it scrolls in."
        case .capturing: "Keep scrolling, or press Return to save."
        case .tooFast: "That was too fast to join. Scroll slower."
        case .limit: "Press Return to save."
        }
    }
}

// MARK: Joining

/// Keeps the new rows of each frame and joins them at the end, off the main thread.
actor ScrollSession {
    private var stitcher: ScrollStitcher
    /// The kept rows of each kept frame, and the frame row they start at.
    private var parts: [(image: CGImage, start: Int)] = []

    init(frameHeight: Int) {
        stitcher = ScrollStitcher(frameHeight: frameHeight)
    }

    func add(_ image: CGImage) -> (step: ScrollStitcher.Step, height: Int) {
        let step = stitcher.add(Self.signature(image))
        switch step {
        case .first:
            parts.append((image, 0))
        case .moved(_, let keep):
            // Copied, so the rest of the frame is freed.
            if let rows = image.cropping(to: CGRect(x: 0, y: keep.lowerBound, width: image.width, height: keep.count)),
               let copy = Self.copy(rows) {
                parts.append((copy, keep.lowerBound))
            }
        case .same, .lost:
            break
        }
        return (step, stitcher.height)
    }

    func compose() -> CGImage? {
        guard let width = parts.first?.image.width, stitcher.pieces.count <= parts.count else { return nil }
        let height = stitcher.height
        guard height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: parts[0].image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = 0
        for piece in stitcher.pieces {
            let part = parts[piece.frame]
            let rect = CGRect(x: 0, y: piece.rows.lowerBound - part.start, width: width, height: piece.rows.count)
            guard let rows = part.image.cropping(to: rect) else { continue }
            // Core Graphics counts from the bottom.
            context.draw(rows, in: CGRect(x: 0, y: height - top - piece.rows.count, width: width, height: piece.rows.count))
            top += piece.rows.count
        }
        return context.makeImage()
    }

    /// One row of gray samples per pixel row, top first, for matching.
    nonisolated static func signature(_ image: CGImage, samples: Int = 96) -> [[UInt8]] {
        let height = image.height
        var data = [UInt8](repeating: 0, count: samples * height)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: samples, height: height, bitsPerComponent: 8, bytesPerRow: samples,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.interpolationQuality = .medium
            context?.draw(image, in: CGRect(x: 0, y: 0, width: samples, height: height))
        }
        return (0..<height).map { Array(data[($0 * samples)..<(($0 + 1) * samples)]) }
    }

    nonisolated private static func copy(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
