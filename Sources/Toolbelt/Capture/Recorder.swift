import AppKit
import AVFoundation
import ScreenCaptureKit
import ToolbeltKit

/// Screen recording with ScreenCaptureKit: SCStream + SCRecordingOutput
/// writes the movie file itself. While it runs, a menu bar item shows the
/// time and stops it on click.
@MainActor
final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    static var shared: Recorder!
    private let model: AppModel
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var url: URL?
    private var size: CGSize = .zero
    private var startedAt: Date?
    private var timer: Task<Void, Never>?
    private var indicator: NSStatusItem?
    private var outline: NSWindow?
    private var selecting = false

    var isRecording: Bool { stream != nil }

    init(model: AppModel) {
        self.model = model
    }

    /// The Recording shortcut: start when idle, stop while recording.
    func toggle(_ mode: CaptureMode = .area) {
        if isRecording { stop() } else { start(mode) }
    }

    func start(_ mode: CaptureMode) {
        guard !isRecording, !selecting, CaptureController.ensurePermission() else { return }
        selecting = true
        PanelController.shared.hide()
        StatusItems.shared?.closePopovers()
        Task {
            defer { selecting = false }
            try? await Task.sleep(for: .milliseconds(150))
            let selection: Selection?
            if mode == .screen {
                selection = await CaptureController.displayUnderPointer().map(Selection.screen)
            } else {
                selection = await SelectionOverlay().select(startInWindowMode: mode == .window, freeze: false,
                                                            hint: "Drag to choose what to record. Space: a window. Return: whole screen. Esc: cancel.")
            }
            guard let selection else { return }
            if CapturePrefs.microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            await begin(selection)
        }
    }

    func begin(_ selection: Selection) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        var outlineRect: CGRect?
        switch selection {
        case .area(let display, let rect, _, _):
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            config.sourceRect = rect
            config.width = Int(rect.width * scale) / 2 * 2
            config.height = Int(rect.height * scale) / 2 * 2
            outlineRect = appKitRect(rect, display: display)
        case .screen(let display):
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(CGFloat(display.width) * scale) / 2 * 2
            config.height = Int(CGFloat(display.height) * scale) / 2 * 2
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale) / 2 * 2
            config.height = Int(filter.contentRect.height * scale) / 2 * 2
            config.ignoreShadowsSingleWindow = true
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = CapturePrefs.recordCursor
        config.showMouseClicks = CapturePrefs.showClicks
        config.capturesAudio = CapturePrefs.systemAudio
        config.captureMicrophone = CapturePrefs.microphone
        config.excludesCurrentProcessAudio = true

        let name = CaptureRules.fileName(kind: "Recording", date: .now, ext: "mp4")
        let url = CaptureRules.uniqueURL(in: CapturePrefs.folder, name: name) { FileManager.default.fileExists(atPath: $0.path) }
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            showError("Unable to start recording: \(error.localizedDescription)")
            return
        }
        self.stream = stream
        model.isRecording = true
        self.output = output
        self.url = url
        size = CGSize(width: config.width, height: config.height)
        startedAt = .now
        showIndicator()
        if let outlineRect { showOutline(outlineRect) }
    }

    func stop() {
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
            // The recording output finishes the file; the delegate saves it.
        }
        self.stream = nil
        model.isRecording = false
        timer?.cancel()
        timer = nil
        if let indicator { NSStatusBar.system.removeStatusItem(indicator) }
        indicator = nil
        outline?.orderOut(nil)
        outline = nil
    }

    // MARK: SCRecordingOutputDelegate

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.stop()
            self.showError("Recording stopped: \(message)")
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in self.stop() }
    }

    private func finished() {
        guard let url else { return }
        let duration = Date.now.timeIntervalSince(startedAt ?? .now)
        let capture = Capture(kind: .recording, url: url, width: Int(size.width), height: Int(size.height), duration: duration)
        model.context.insert(capture)
        try? model.context.save()
        output = nil
        self.url = nil
        if CapturePrefs.showPreview { CapturePreview.shared.show(capture) }
    }

    // MARK: Menu bar timer and outline

    private func showIndicator() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
        item.button?.imagePosition = .imageLeading
        item.button?.contentTintColor = .systemRed
        item.button?.title = " 0:00"
        item.button?.toolTip = "Stop recording (\(ShortcutID.record.label))"
        item.button?.target = self
        item.button?.action = #selector(stopClicked)
        indicator = item
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let startedAt = self.startedAt else { return }
                self.indicator?.button?.title = " " + CaptureRules.elapsed(Int(Date.now.timeIntervalSince(startedAt)))
            }
        }
    }

    @objc private func stopClicked() { stop() }

    /// A thin red frame around the recorded area. Toolbelt's windows are
    /// excluded from the capture, so it never shows in the movie.
    private func showOutline(_ rect: CGRect) {
        let window = NSWindow(contentRect: rect.insetBy(dx: -2, dy: -2), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor
        view.layer?.borderWidth = 2
        window.contentView = view
        window.orderFrontRegardless()
        outline = window
    }

    /// A display-local, top-left rect in AppKit's global coordinates.
    private func appKitRect(_ rect: CGRect, display: SCDisplay) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { return rect }
        return CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Unable to Record"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
