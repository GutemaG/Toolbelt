import AppKit
import CoreLocation
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

    /// Tabs whose values change while you watch are read every time they show.
    var isLive: Bool { self == .battery || self == .network }
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

    /// Reads a tab. Live tabs read again each time; the others once, or on Refresh.
    func load(_ tab: InfoTab, force: Bool = false) {
        guard force || tab.isLive || sections[tab] == nil, !loading.contains(tab) else { return }
        loading.insert(tab)
        let options = InfoReader.Options(locationAllowed: LocationAccess.shared.isAllowed, lookUpPublicIP: true)
        Task {
            let result = await InfoReader.read(tab, options: options)
            sections[tab] = result
            loading.remove(tab)
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
