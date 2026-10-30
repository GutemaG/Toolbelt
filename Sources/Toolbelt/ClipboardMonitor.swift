import AppKit
import CryptoKit
import ToolbeltKit

/// Watches the general pasteboard and saves each new copy as a clip.
/// There is no change notification, so it polls changeCount twice a second.
@MainActor
final class ClipboardMonitor {
    private unowned let model: AppModel
    private let pasteboard = NSPasteboard.general
    private var lastChange: Int
    private var task: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        lastChange = NSPasteboard.general.changeCount
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.check()
            }
        }
    }

    func check() {
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !ClipRules.shouldSkip(types: types, sourceApp: source) else { return }
        // Copied Finder files are not in version one.
        if pasteboard.types?.contains(.fileURL) == true { return }

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kind: ClipKind = ClipRules.isLink(text) ? .link : .text
            model.record(kind: kind, text: text, fingerprint: "t:" + text, source: source)
        } else if let data = pngData(), data.count <= ClipRules.maxImageBytes {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            model.record(kind: .image, imageData: data, fingerprint: "i:" + hash, source: source)
        }
    }

    /// Writes a clip to the pasteboard without saving it again as a new copy.
    func write(_ clip: ClipItem, plainText: Bool = false) {
        pasteboard.clearContents()
        switch clip.kind {
        case .text, .link:
            pasteboard.setString(clip.text, forType: .string)
            if clip.kind == .link, !plainText, let url = URL(string: clip.text) {
                pasteboard.writeObjects([url as NSURL])
                pasteboard.setString(clip.text, forType: .string)
            }
        case .image:
            if let data = clip.imageData, let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
                pasteboard.setData(data, forType: .png)
            }
        }
        lastChange = pasteboard.changeCount
    }

    private func pngData() -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
