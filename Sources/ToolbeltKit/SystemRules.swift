import Foundation

/// One process's use over a sampling interval, already turned into rates.
public struct ProcessUse: Sendable, Equatable {
    /// The executable of the process macOS holds responsible, so helpers
    /// and web content processes count toward the app that started them.
    public var path: String
    public var watts: Double
    /// Percent of one core, like Activity Monitor (can pass 100).
    public var cpu: Double

    public init(path: String, watts: Double, cpu: Double) {
        self.path = path
        self.watts = watts
        self.cpu = cpu
    }
}

/// One app's total use: all its processes added up.
public struct AppUse: Sendable, Equatable, Identifiable {
    /// The .app bundle, or the executable for a process outside one.
    public var path: String
    public var watts: Double
    public var cpu: Double
    public var id: String { path }

    public init(path: String, watts: Double, cpu: Double) {
        self.path = path
        self.watts = watts
        self.cpu = cpu
    }

    public var isApp: Bool { path.hasSuffix(".app") }
}

/// The math behind the System tool: CPU load, memory, temperature, and
/// which apps use the most energy.
public enum SystemRules {
    /// The outermost .app bundle in a path, so "Chrome.app/…/Helper.app/…"
    /// counts as Chrome. nil for an executable outside any app.
    public static func appBundle(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Adds up processes per app, most energy first, then most CPU.
    public static func group(_ processes: [ProcessUse]) -> [AppUse] {
        var totals: [String: AppUse] = [:]
        for process in processes {
            let key = appBundle(forExecutable: process.path) ?? process.path
            totals[key, default: AppUse(path: key, watts: 0, cpu: 0)].watts += process.watts
            totals[key, default: AppUse(path: key, watts: 0, cpu: 0)].cpu += process.cpu
        }
        return totals.values.sorted { a, b in
            if a.watts != b.watts { return a.watts > b.watts }
            if a.cpu != b.cpu { return a.cpu > b.cpu }
            return a.path < b.path
        }
    }

    /// The average of several samples per app, so the list does not jump
    /// every two seconds. An app missing from a sample counts as zero there.
    public static func average(_ samples: [[AppUse]]) -> [AppUse] {
        guard !samples.isEmpty else { return [] }
        let all = samples.flatMap { $0 }.map { ProcessUse(path: $0.path, watts: $0.watts, cpu: $0.cpu) }
        let count = Double(samples.count)
        return group(all).map { AppUse(path: $0.path, watts: $0.watts / count, cpu: $0.cpu / count) }
    }

    /// Busy share of all cores between two readings of the tick counters.
    public static func cpuLoad(busyBefore: UInt64, totalBefore: UInt64, busyAfter: UInt64, totalAfter: UInt64) -> Double? {
        guard totalAfter > totalBefore, busyAfter >= busyBefore else { return nil }
        return min(Double(busyAfter - busyBefore) / Double(totalAfter - totalBefore), 1)
    }

    /// Memory in use the way Activity Monitor counts it: app memory
    /// (internal minus purgeable), wired, and compressed.
    public static func memoryUsed(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                                  compressedPages: UInt64, pageSize: UInt64) -> UInt64 {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (app + wiredPages + compressedPages) * pageSize
    }

    /// The chip temperature: the mean of the die sensors ("tdie"), leaving
    /// out readings no sensor can give (some report large negative values).
    public static func chipTemperature(_ readings: [(name: String, celsius: Double)]) -> Double? {
        let valid = readings.filter { $0.celsius > 0 && $0.celsius < 130 }
        let die = valid.filter { $0.name.localizedCaseInsensitiveContains("tdie") }
        let use = die.isEmpty ? valid.filter { $0.name.localizedCaseInsensitiveContains("cpu") } : die
        guard !use.isEmpty else { return nil }
        return use.map(\.celsius).reduce(0, +) / Double(use.count)
    }

    /// "0 mW", "32 mW", "1.4 W".
    public static func powerText(_ watts: Double) -> String {
        let watts = max(watts, 0)
        if watts < 1 { return "\(Int((watts * 1000).rounded())) mW" }
        return String(format: "%.1f W", watts)
    }

    /// "9%", rounded, never below 0.
    public static func percentText(_ fraction: Double) -> String {
        "\(Int((max(fraction, 0) * 100).rounded()))%"
    }

    /// "12.3 of 24 GB".
    public static func memoryText(used: UInt64, total: UInt64) -> String {
        let gb = 1_073_741_824.0
        return String(format: "%.1f of %.0f GB", Double(used) / gb, Double(total) / gb)
    }
}
