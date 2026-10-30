import AppKit
import SwiftData
import ToolbeltKit

/// One thing the user copied: text, a link, or an image.
@Model
final class ClipItem {
    var kindRaw: String = ClipKind.text.rawValue
    var text: String = ""
    @Attribute(.externalStorage) var imageData: Data?
    /// Text itself, or a hash of the image, so a repeat copy moves the old clip up.
    var fingerprint: String = ""
    var sourceBundleID: String?
    var copiedAt: Date = Date.now
    var isPinned: Bool = false
    var uuid: UUID = UUID()

    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .text }

    init(kind: ClipKind, text: String = "", imageData: Data? = nil, fingerprint: String, sourceBundleID: String?) {
        self.kindRaw = kind.rawValue
        self.text = text
        self.imageData = imageData
        self.fingerprint = fingerprint
        self.sourceBundleID = sourceBundleID
    }
}

enum ClipKind: String {
    case text, link, image
}

/// How often an app was opened from the launcher. Ranks results.
@Model
final class AppLaunch {
    var path: String = ""
    var count: Int = 0
    var lastLaunched: Date?
    /// Pinned apps show as a grid at the top of the Launcher, in pinOrder.
    var isPinned: Bool = false
    var pinOrder: Int = 0

    init(path: String) {
        self.path = path
    }
}

/// The tools in Toolbelt. Each one is a tab in the popover and the panel.
enum Tool: String, CaseIterable, Identifiable {
    case launcher, clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launcher: "Launcher"
        case .clipboard: "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .launcher: "magnifyingglass"
        case .clipboard: "doc.on.clipboard"
        }
    }

    var help: String {
        switch self {
        case .launcher: "Find and open apps (⌘1)"
        case .clipboard: "Search clipboard history (⌘2)"
        }
    }
}

/// App-wide state that the popover, the panel, and Settings share.
@Observable
final class AppModel {
    let container: ModelContainer
    let apps = AppIndex()
    @ObservationIgnored lazy var clipboard = ClipboardMonitor(model: self)
    /// The last used tool; the popover opens on it.
    var tool: Tool = Tool(rawValue: UserDefaults.standard.string(forKey: "tool") ?? "") ?? .launcher {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(tool.rawValue, forKey: "tool") } }
    }
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }
    /// Bumped each time a surface opens, so views reset their search and selection.
    var openCount = 0
    /// After Add…: the Launcher lists every app with a pin button, until Done.
    var pickingApps = false

    init(container: ModelContainer) {
        self.container = container
    }

    var context: ModelContext { container.mainContext }

    // MARK: Launcher

    func launchCandidates() -> [LaunchCandidate] {
        let launches = (try? context.fetch(FetchDescriptor<AppLaunch>())) ?? []
        let byPath = Dictionary(launches.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return apps.apps.map { app in
            let launch = byPath[app.path]
            return LaunchCandidate(name: app.name, path: app.path,
                                   launchCount: launch?.count ?? 0, lastLaunched: launch?.lastLaunched)
        }
    }

    /// Records the launch, then opens the app or brings it to the front.
    func open(_ app: LaunchCandidate) {
        recordLaunch(path: app.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: config)
    }

    func recordLaunch(path: String) {
        let launch = launchRecord(path: path)
        launch.count += 1
        launch.lastLaunched = .now
        try? context.save()
    }

    private func launchRecord(path: String) -> AppLaunch {
        var descriptor = FetchDescriptor<AppLaunch>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { return existing }
        let new = AppLaunch(path: path)
        context.insert(new)
        return new
    }

    // MARK: Pinned apps

    /// Pinned apps in grid order. Apps that were moved or deleted are left out.
    func pinnedApps() -> [LaunchCandidate] {
        let descriptor = FetchDescriptor<AppLaunch>(predicate: #Predicate { $0.isPinned },
                                                    sortBy: [SortDescriptor(\.pinOrder)])
        return ((try? context.fetch(descriptor)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { LaunchCandidate(name: AppIndex.name(atPath: $0.path), path: $0.path,
                                   launchCount: $0.count, lastLaunched: $0.lastLaunched) }
    }

    /// Pins an app at the end of the grid, or unpins it.
    func togglePin(appPath path: String) {
        let launch = launchRecord(path: path)
        if launch.isPinned {
            launch.isPinned = false
        } else {
            pin(launch)
        }
        try? context.save()
    }

    /// Pins apps chosen with Add…, keeping any that are already pinned.
    func pinApps(paths: [String]) {
        for path in paths {
            let launch = launchRecord(path: path)
            if !launch.isPinned { pin(launch) }
        }
        try? context.save()
    }

    /// Pins after the last pinned app. Unpinning leaves gaps, so counting would collide.
    private func pin(_ launch: AppLaunch) {
        let pinned = (try? context.fetch(FetchDescriptor<AppLaunch>(predicate: #Predicate { $0.isPinned }))) ?? []
        launch.pinOrder = (pinned.map(\.pinOrder).max() ?? -1) + 1
        launch.isPinned = true
    }

    /// Moves a pinned app left (-1) or right (+1) in the grid.
    func movePinned(path: String, by offset: Int) {
        var paths = pinnedApps().map(\.path)
        guard let from = paths.firstIndex(of: path) else { return }
        let to = min(max(from + offset, 0), paths.count - 1)
        paths.insert(paths.remove(at: from), at: to)
        for (order, path) in paths.enumerated() { launchRecord(path: path).pinOrder = order }
        try? context.save()
    }

    // MARK: Clipboard

    /// Saves a copy, or moves the clip with the same contents to the top.
    @discardableResult
    func record(kind: ClipKind, text: String = "", imageData: Data? = nil, fingerprint: String, source: String?) -> ClipItem {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.fingerprint == fingerprint })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.copiedAt = .now
            existing.sourceBundleID = source ?? existing.sourceBundleID
            try? context.save()
            return existing
        }
        let clip = ClipItem(kind: kind, text: text, imageData: imageData, fingerprint: fingerprint, sourceBundleID: source)
        context.insert(clip)
        prune()
        try? context.save()
        return clip
    }

    /// Puts a clip back on the clipboard and moves it to the top.
    func copy(_ clip: ClipItem, plainText: Bool = false) {
        clipboard.write(clip, plainText: plainText)
        clip.copiedAt = .now
        try? context.save()
    }

    func togglePin(_ clip: ClipItem) {
        clip.isPinned.toggle()
        prune()
        try? context.save()
    }

    func delete(_ clip: ClipItem) {
        context.delete(clip)
        try? context.save()
    }

    /// Keeps at most ClipRules.historyLimit unpinned clips.
    func prune() {
        let descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        let clips = (try? context.fetch(descriptor)) ?? []
        let doomed = Set(ClipRules.pruned(clips.map { (id: $0.persistentModelID, isPinned: $0.isPinned) }))
        for clip in clips where doomed.contains(clip.persistentModelID) { context.delete(clip) }
    }
}
