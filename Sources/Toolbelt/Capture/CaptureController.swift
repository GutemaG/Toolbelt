import AppKit
import ScreenCaptureKit
import SwiftData
import ToolbeltKit

/// Screenshots: checks permission, runs the selection overlay, crops or
/// captures, saves the file, copies it, and shows the preview.
@MainActor
final class CaptureController {
    static var shared: CaptureController!
    private let model: AppModel
    private var busy = false

    init(model: AppModel) {
        self.model = model
    }

    /// True when Screen Recording is allowed. Otherwise asks once and opens
    /// the right pane of System Settings.
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    func screenshot(_ mode: CaptureMode) {
        guard !busy, Self.ensurePermission() else { return }
        busy = true
        PanelController.shared.hide()
        StatusItems.shared?.closePopovers()
        Task {
            defer { busy = false }
            // Let the panel and popover leave the screen before freezing it.
            try? await Task.sleep(for: .milliseconds(150))
            let selection: Selection?
            if mode == .screen {
                selection = await Self.displayUnderPointer().map(Selection.screen)
            } else {
                selection = await SelectionOverlay().select(startInWindowMode: mode == .window, freeze: true,
                                                            hint: "Drag to select. Space: pick a window. Return: whole screen. Esc: cancel.")
            }
            guard let selection, let image = await image(for: selection) else { return }
            save(image)
        }
    }

    func image(for selection: Selection) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        switch selection {
        case .area(let display, let rect, let frozen, let scale):
            let frozenImage: CGImage?
            if let frozen { frozenImage = frozen } else { frozenImage = await SelectionOverlay.captureDisplay(display, content: content)?.image }
            let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
            return frozenImage?.cropping(to: pixels)
        case .screen(let display):
            return await SelectionOverlay.captureDisplay(display, content: content)?.image
        case .window(let window):
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.ignoreShadowsSingleWindow = !CapturePrefs.windowShadow
            config.showsCursor = false
            config.captureResolution = .best
            return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    func save(_ image: CGImage, kind: String = "Screenshot") {
        let format = CapturePrefs.format
        let name = CaptureRules.fileName(kind: kind, date: .now, ext: format.ext)
        let folder = CapturePrefs.folder
        let url = CaptureRules.uniqueURL(in: folder, name: name) { FileManager.default.fileExists(atPath: $0.path) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            NSSound.beep()
            return
        }
        if CapturePrefs.copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
        }
        let capture = Capture(kind: .screenshot, url: url, width: image.width, height: image.height)
        model.context.insert(capture)
        try? model.context.save()
        NSSound(named: "Grab")?.play()
        if CapturePrefs.showPreview { CapturePreview.shared.show(capture) }
    }

    /// The display the pointer is on.
    static func displayUnderPointer() async -> SCDisplay? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let id = NSScreen.screenWithMouse?.displayID
        return content.displays.first { $0.displayID == id } ?? content.displays.first
    }

    // MARK: Recent captures

    func markup(_ capture: Capture) {
        MarkupWindow.open(capture, model: model)
    }

    func delete(_ capture: Capture) {
        try? FileManager.default.trashItem(at: capture.url, resultingItemURL: nil)
        model.context.delete(capture)
        try? model.context.save()
    }

    func copy(_ capture: Capture) {
        NSPasteboard.general.clearContents()
        if capture.kind == .screenshot, let image = NSImage(contentsOf: capture.url) {
            NSPasteboard.general.writeObjects([image])
        } else {
            NSPasteboard.general.writeObjects([capture.url as NSURL])
        }
    }
}
