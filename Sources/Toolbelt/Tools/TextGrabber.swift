import AppKit
import Vision

/// Text from the screen: select an area, and its text is copied. A QR code
/// or barcode in the area is copied instead, since that is almost always
/// what people want from one. Runs on the device with Vision.
@MainActor
final class TextGrabber {
    static let shared = TextGrabber()
    private var busy = false

    func grab() {
        guard !busy, CaptureController.ensurePermission() else { return }
        busy = true
        PanelController.shared.hide()
        StatusItems.shared?.closePopovers()
        Task {
            defer { busy = false }
            try? await Task.sleep(for: .milliseconds(150))
            guard let selection = await SelectionOverlay().select(freeze: true, hint: "Drag over text or a QR code. Esc: cancel."),
                  let image = await CaptureController.shared.image(for: selection) else { return }
            let result = await Self.read(image)
            guard let text = result.text, !text.isEmpty else {
                Toast.show("No text found", symbol: "text.viewfinder")
                return
            }
            if !Store.isOverridden {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Toast.show(result.isCode ? "Copied the QR code" : "Copied \(text.split(whereSeparator: \.isWhitespace).count) words",
                       symbol: result.isCode ? "qrcode" : "text.viewfinder")
        }
    }

    /// A barcode's text when there is one, otherwise every line of text, top to bottom.
    nonisolated static func read(_ image: CGImage) async -> (text: String?, isCode: Bool) {
        if let codes = try? await DetectBarcodesRequest().perform(on: image),
           let payload = codes.compactMap(\.payloadString).first, !payload.isEmpty {
            return (payload, true)
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let lines = try? await request.perform(on: image) else { return (nil, false) }
        let text = lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return (text, false)
    }
}
