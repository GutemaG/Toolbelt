import AppKit
import CoreLocation
import SwiftUI
import ToolbeltKit

/// Info: details about this Mac in five tabs. It opens on Battery.
enum InfoTab: String, CaseIterable, Identifiable {
    case battery, storage, hardware, network, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: "Battery"
        case .storage: "Storage"
        case .hardware: "Hardware"
        case .network: "Network"
        case .developer: "Developer"
        }
    }

    var symbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .storage: "internaldrive"
        case .hardware: "cpu"
        case .network: "network"
        case .developer: "hammer"
        }
    }

    /// A color per tab, like the tool tiles.
    var tint: Color {
        switch self {
        case .battery: .green
        case .storage: .purple
        case .hardware: .blue
        case .network: .teal
        case .developer: .orange
        }
    }

    /// Tabs whose values change while you watch are read every time they show.
    var isLive: Bool { self == .battery || self == .network }
}

/// How Info lays out its tabs. People choose in Settings > Info.
enum InfoLayout: String, CaseIterable, Identifiable {
    case overview, gauges, glance, list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview Grid"
        case .gauges: "Gauge Cards"
        case .glance: "Glance Tabs"
        case .list: "Simple List"
        }
    }

    var detail: String {
        switch self {
        case .overview: "A card for each area opens on its details."
        case .gauges: "A gauge and four cards for each tab, with the rest a click away."
        case .glance: "Tabs that show their own value, above the details."
        case .list: "Tabs above the details."
        }
    }

    /// Layouts that show a value from every tab read them all on opening.
    var readsEveryTab: Bool { self == .overview || self == .glance }
}

/// One line: a name and its value. Secret values (serial numbers, the
/// public IP, hardware addresses) stay hidden until shown, for screen sharing.
nonisolated struct InfoRow: Sendable {
    var label: String
    var value: String
    var secret = false
    /// The tooltip, like the path a tool runs from.
    var help: String?
    /// A bar beside the value, 0–1.
    var fraction: Double?
    /// Clicking does this instead of copying.
    var action: InfoAction?
}

nonisolated enum InfoAction: Sendable {
    case allowLocation
}

nonisolated struct InfoSection: Sendable, Identifiable {
    var title: String
    var rows: [InfoRow]
    var note: String?
    var id: String { title }
}

@Observable
final class MacInfo {
    static let shared = MacInfo()

    var tab: InfoTab = .battery {
        didSet { if tab != oldValue { load(tab) } }
    }
    private(set) var sections: [InfoTab: [InfoSection]] = [:]
    private(set) var loading: Set<InfoTab> = []

    var layout: InfoLayout = (Store.isOverridden ? nil : UserDefaults.standard.string(forKey: "info.layout")).flatMap(InfoLayout.init(rawValue:)) ?? .overview {
        didSet {
            if !Store.isOverridden { UserDefaults.standard.set(layout.rawValue, forKey: "info.layout") }
            detailOpen = false
            loadVisible()
        }
    }
    /// Overview Grid: a card's details are open instead of the grid.
    private(set) var detailOpen = false

    var showsGrid: Bool { layout == .overview && !detailOpen }

    /// The public IP takes a web request, so it waits until Network itself is
    /// open. Reading every tab for the cards doesn't count.
    var wantsPublicIP: Bool { tab == .network && !showsGrid }

    /// The self-test turns this off so it never contacts the internet.
    var mayLookUpPublicIP = true

    /// Reads a tab. Live tabs read again each time; the others once, or on Refresh.
    func load(_ tab: InfoTab, force: Bool = false) {
        guard force || tab.isLive || sections[tab] == nil, !loading.contains(tab) else { return }
        loading.insert(tab)
        let lookUp = tab == .network && wantsPublicIP
        let options = InfoReader.Options(locationAllowed: LocationAccess.shared.isAllowed, lookUpPublicIP: lookUp && mayLookUpPublicIP)
        Task {
            let result = await InfoReader.read(tab, options: options)
            sections[tab] = result
            loading.remove(tab)
            // Network opened during a read that left the public IP out.
            if tab == .network, wantsPublicIP, !lookUp { load(.network, force: true) }
        }
    }

    /// Every time Info opens it starts on Battery, and the grid if that's the layout.
    func opened() {
        detailOpen = false
        tab = .battery
        load(.battery, force: true)
        loadVisible()
    }

    private func loadVisible() {
        load(tab)
        if layout.readsEveryTab { InfoTab.allCases.forEach { load($0) } }
    }

    /// ⌘R and the Refresh button: the grid reads every card, the others this tab.
    func refresh() {
        if showsGrid {
            InfoTab.allCases.forEach { load($0, force: true) }
        } else {
            load(tab, force: true)
        }
    }

    /// Overview Grid: open a card.
    func open(_ tab: InfoTab) {
        detailOpen = true
        self.tab = tab
        load(tab)
    }

    /// Overview Grid: back to the cards. False when they're already showing.
    func closeDetail() -> Bool {
        guard detailOpen else { return false }
        detailOpen = false
        return true
    }

    /// Sections with the rows that match the search. A matching section title keeps all its rows.
    func filtered(_ tab: InfoTab, query: String) -> [InfoSection] {
        let all = sections[tab] ?? []
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.compactMap { section in
            if ClipRules.matches(query, text: section.title) { return section }
            var copy = section
            copy.rows = section.rows.filter { ClipRules.matches(query, text: $0.label) || (!$0.secret && ClipRules.matches(query, text: $0.value)) }
            return copy.rows.isEmpty ? nil : copy
        }
    }

    func step(_ offset: Int) {
        let all = InfoTab.allCases
        let index = all.firstIndex(of: tab) ?? 0
        tab = all[(index + offset + all.count) % all.count]
    }

    /// The tab as plain text, for Copy All.
    func report(_ tab: InfoTab) -> String {
        let body = (sections[tab] ?? []).map { section in
            ([section.title] + section.rows.map { "  \($0.label): \($0.value)" }).joined(separator: "\n")
        }
        return (["\(tab.title) – \(Host.current().localizedName ?? "Mac")"] + body).joined(separator: "\n\n")
    }
}

// MARK: Running commands

/// Runs a command with a time limit, stdout and stderr together, no input.
nonisolated enum Shell {
    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 5) async -> (output: String, status: Int32)? {
        await withCheckedContinuation { continuation in
            // Blocking reads stay off Swift's small thread pool.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stop.cancel()
                continuation.resume(returning: (String(decoding: data, as: UTF8.self), process.terminationStatus))
            }
        }
    }

    /// system_profiler's JSON for some data types.
    static func profile(_ types: [String]) async -> [String: Any] {
        guard let result = await run("/usr/sbin/system_profiler", types + ["-json"], timeout: 15),
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return [:] }
        return json
    }

    /// A property list printed by a command, like `diskutil info -plist /`.
    static func plist(_ path: String, _ arguments: [String]) async -> [String: Any] {
        guard let result = await run(path, arguments),
              let value = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any] else { return [:] }
        return value
    }
}

// MARK: Location, for the Wi-Fi name

/// macOS treats a Wi-Fi network's name as location, so showing it needs
/// Location Services. Asked only when the person clicks to show it.
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAllowed: Bool {
        [.authorizedAlways, .authorized].contains(manager.authorizationStatus)
    }

    func request() {
        if manager.authorizationStatus == .notDetermined {
            NSApp.activate()
            manager.requestWhenInUseAuthorization()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in MacInfo.shared.load(.network, force: true) }
    }
}
