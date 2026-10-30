import AppKit
import SwiftData

/// Sample data for snapshots: APP_SEED=1 with APP_STORE in /tmp fills an empty
/// store with realistic clips and launch counts.
/// Seed only what a person can create in the app, or the snapshots show
/// features no one can use.
@MainActor
enum SeedData {
    static func insertIfRequested(into model: AppModel) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1" else { return }
        guard Store.isOverridden else {
            print("APP_SEED ignored: APP_STORE must be a file in /tmp")
            return
        }
        let context = model.container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<ClipItem>())) ?? 0) == 0 else { return }
        let samples: [(String, String, Bool)] = [
            ("https://developer.apple.com/documentation/swiftui", "com.apple.Safari", false),
            ("let panel = FloatingPanel(size: size, content: view)", "com.apple.dt.Xcode", false),
            ("Meet at the café on Friday at 10?", "com.apple.MobileSMS", false),
            ("git log --oneline --graph --decorate --all", "com.mitchellh.ghostty", true),
            ("Shipping address: 1 Infinite Loop, Cupertino, CA 95014", "com.apple.Notes", true),
            ("https://github.com/daveebbelaar/bama", "com.apple.Safari", false),
            ("The quick brown fox jumps over the lazy dog, then keeps running across the whole field until the line is far too long for one row", "com.apple.Notes", false),
            ("swift test --scratch-path ~/Library/Developer/Toolbelt/test-build", "com.mitchellh.ghostty", false),
            ("Order #48213", "com.apple.mail", false),
        ]
        for (index, sample) in samples.enumerated() {
            let clip = ClipItem(kind: sample.0.hasPrefix("https://") ? .link : .text, text: sample.0,
                                fingerprint: "t:" + sample.0, sourceBundleID: sample.1)
            clip.isPinned = sample.2
            clip.copiedAt = Date.now.addingTimeInterval(Double(-index) * 1_900 - 30)
            context.insert(clip)
        }
        if let image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil),
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let clip = ClipItem(kind: .image, imageData: png, fingerprint: "i:seed", sourceBundleID: "com.apple.Preview")
            clip.copiedAt = Date.now.addingTimeInterval(-600)
            context.insert(clip)
        }
        let launches: [(String, Int)] = [
            ("/Applications/Safari.app", 40),
            ("/Applications/Xcode.app", 25),
            ("/Applications/Ghostty.app", 18),
            ("/System/Applications/Notes.app", 6),
        ]
        for (path, count) in launches {
            let launch = AppLaunch(path: path)
            launch.count = count
            launch.lastLaunched = .now
            context.insert(launch)
        }
        let pinned = ["/Applications/Claude.app", "/Applications/Ghostty.app", "/Applications/Visual Studio Code.app",
                      "/Applications/Telegram.app", "/System/Applications/Calendar.app"]
        model.pinApps(paths: pinned.filter { FileManager.default.fileExists(atPath: $0) })
        try? context.save()
    }
}
