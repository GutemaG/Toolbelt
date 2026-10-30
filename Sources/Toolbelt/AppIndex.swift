import AppKit

/// The apps the launcher can open, read from the Applications folders.
/// Rescanned every time the launcher shows, so new apps appear without a restart.
@Observable
final class AppIndex {
    nonisolated struct App: Hashable, Sendable {
        var name: String
        var path: String
    }

    private(set) var apps: [App] = []
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    nonisolated static let folders: [String] = [
        "/Applications",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
    ]
    nonisolated static let extras = ["/System/Library/CoreServices/Finder.app"]

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let found = Self.scan()
            await MainActor.run { if found != self.apps { self.apps = found } }
        }
    }

    nonisolated static func scan() -> [App] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [App] = []
        let paths = folders.flatMap { folder in
            ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { folder + "/" + $0 }
        } + extras
        for path in paths where fm.fileExists(atPath: path) {
            let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            // The same app can sit in two folders; keep the first.
            guard seen.insert(name.lowercased()).inserted else { continue }
            result.append(App(name: name, path: path))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        // Resolve links (Safari in /Applications is one), or the icon gets an alias arrow.
        let icon = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        icons[path] = icon
        return icon
    }

    /// The icon of the app with this bundle id, for clip rows.
    func icon(bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return icon(for: url.path)
    }
}
