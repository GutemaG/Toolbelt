import Foundation
import ToolbeltKit

/// The few facts a card shows for a tab, picked from the tab's rows. Rows a Mac
/// doesn't have (a desktop's battery, Wi-Fi on Ethernet) just drop out.
struct InfoSummary {
    /// The big value on a card: "80%", "422 GB", "M4 Pro".
    var stat: String
    /// The words beside it: "Not charging", "free of 1 TB".
    var caption: String
    /// A bar or ring, 0–1.
    var fraction: Double?
    /// Gauge Cards' title and the line under it.
    var headline: String
    var subtitle: String
    /// Gauge Cards' four small cards.
    var highlights: [InfoRow]

    static func make(_ tab: InfoTab, sections: [InfoSection]) -> InfoSummary? {
        let rows = sections.flatMap(\.rows)
        guard !rows.isEmpty else { return nil }
        func row(_ label: String) -> InfoRow? { rows.first { $0.label == label } }
        func value(_ label: String) -> String? { row(label)?.value }
        func joined(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

        /// These rows in order, then any other short ones up to four.
        func highlights(_ labels: [String], skipping: Set<String> = []) -> [InfoRow] {
            let named = labels.compactMap(row)
            let taken = skipping.union(labels)
            let others = rows.filter { !taken.contains($0.label) && !$0.secret && $0.value.count <= 18 }
            return Array((named + others).prefix(4))
        }

        switch tab {
        case .battery:
            let status = value("Status") ?? "Unknown"
            let time = (value("Time to full") ?? value("Time remaining")).map { "\($0) left" }
            let lowPower = value("Low Power Mode").map { "Low Power Mode \($0.lowercased())" }
            return InfoSummary(stat: value("Charge") ?? "–", caption: words(status), fraction: row("Charge")?.fraction,
                               headline: words(status), subtitle: joined(inBrackets(status)?.sentenceCased, time, lowPower),
                               highlights: highlights(["Condition", "Maximum capacity", "Cycle count", "Full charge capacity"],
                                                      skipping: ["Charge", "Status", "Low Power Mode"]))
        case .storage:
            let used = value("Used")
            let parts = used?.components(separatedBy: " of ") ?? []
            let free = value("Available").map(roundedSize) ?? "–"
            let volume = sections.first { $0.rows.contains { $0.label == "Used" } }?.title
            return InfoSummary(stat: free, caption: parts.count == 2 ? "free of \(roundedSize(parts[1]))" : "free", fraction: row("Used")?.fraction,
                               headline: "\(free) free", subtitle: joined(volume, used.map { "\($0) used" }),
                               highlights: highlights(["File system", "FileVault", "Health", "Location"], skipping: ["Used", "Available"]))
        case .hardware:
            let chip = value("Chip") ?? "Mac"
            let shortChip = chip.hasPrefix("Apple ") ? String(chip.dropFirst(6)) : chip
            var cards = highlights(["CPU cores", "GPU cores", "Memory", "Uptime"], skipping: ["Model", "Chip"])
            for index in cards.indices where cards[index].label == "CPU cores" { cards[index].value = words(cards[index].value) }
            // A macOS name without a word yet is "macOS 27"; its version says that already.
            let name = value("Name").map { $0.last?.isNumber == true ? "macOS" : $0 }
            let system = [name, value("Version")].compactMap { $0 }.joined(separator: " ")
            return InfoSummary(stat: shortChip, caption: value("Memory") ?? "", fraction: nil,
                               headline: value("Model") ?? "Mac", subtitle: joined(chip, system.isEmpty ? nil : system),
                               highlights: cards)
        case .network:
            let through = value("Connected through")
            let signal = row("Signal")
            let vpn = value("VPN").map { $0.hasPrefix("Connected") ? "VPN on" : "VPN off" }
            return InfoSummary(stat: through.map(words) ?? "Offline",
                               caption: through == nil ? "Not connected" : signal.flatMap { inBrackets($0.value) }.map { "Signal \($0.lowercased())" } ?? "Connected",
                               fraction: signal?.fraction,
                               headline: through == nil ? "Not connected" : "Connected",
                               subtitle: joined(through.map { "Through \($0)" }, vpn),
                               highlights: highlights(["Signal", "Link speed", "Local IP", "Public IP"], skipping: ["Status", "Connected through", "VPN"]))
        case .developer:
            // Command-line tools only, not the Xcode details or the apps.
            let groups = Set(DevTool.Group.allCases.map(\.rawValue))
            let tools = sections.filter { groups.contains($0.title) }.flatMap(\.rows).count
            let count = tools == 1 ? "1 tool" : "\(tools) tools"
            let top = highlights(["Node.js", "Python", "Swift", "Git"])
            return InfoSummary(stat: count, caption: top.prefix(3).map { "\($0.label) \($0.value)" }.joined(separator: " · "), fraction: nil,
                               headline: "\(count) found", subtitle: "Installed on this Mac", highlights: top)
        }
    }

    /// Cards have room for "656 GB", not "655.69 GB". "1.2 TB" keeps its decimal.
    private static func roundedSize(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let number = Double(parts[0]), number >= 100 else { return text }
        return "\(Int(number.rounded())) \(parts[1])"
    }

    /// "Not charging (on power)" gives "Not charging".
    private static func words(_ text: String) -> String {
        guard let open = text.range(of: " (") else { return text }
        return String(text[..<open.lowerBound])
    }

    /// "Not charging (on power)" gives "on power".
    private static func inBrackets(_ text: String) -> String? {
        guard let open = text.range(of: " ("), text.hasSuffix(")") else { return nil }
        return String(text[open.upperBound...].dropLast())
    }
}

private extension String {
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}
