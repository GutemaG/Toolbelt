import Foundation

/// How speeds are written. People choose in Settings > Network Speed.
public enum SpeedUnit: String, Sendable, CaseIterable, Identifiable {
    case bytes, bits

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bytes: "MB/s"
        case .bits: "Mbps"
        }
    }
}

/// What `networkQuality -c` reports.
public struct SpeedTestResult: Sendable, Equatable {
    public var downloadBitsPerSecond: Double
    public var uploadBitsPerSecond: Double
    /// Round trip with the line idle.
    public var latencyMilliseconds: Double?
    /// Round trip with the line busy, from its "round trips per minute".
    public var loadedLatencyMilliseconds: Double?

    public init(downloadBitsPerSecond: Double, uploadBitsPerSecond: Double, latencyMilliseconds: Double? = nil, loadedLatencyMilliseconds: Double? = nil) {
        self.downloadBitsPerSecond = downloadBitsPerSecond
        self.uploadBitsPerSecond = uploadBitsPerSecond
        self.latencyMilliseconds = latencyMilliseconds
        self.loadedLatencyMilliseconds = loadedLatencyMilliseconds
    }
}

/// Which interfaces count, speeds from byte counters, the words for them, and
/// reading the speed test.
public enum NetworkRules {
    /// Wi-Fi, Ethernet and cellular. Loopback stays on this Mac; VPN tunnels
    /// and bridges carry traffic that a real interface already counted.
    public static func countsTraffic(interface name: String) -> Bool {
        for prefix in ["en", "pdp_ip"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// Bytes per second between two readings. nil when the counter went back:
    /// it wrapped, or an interface went away, and that says nothing about the speed.
    public static func rate(from before: UInt64, to after: UInt64, seconds: TimeInterval) -> Double? {
        guard seconds > 0, after >= before else { return nil }
        return Double(after - before) / seconds
    }

    /// "340 KB/s", "12.4 MB/s", "312 Mbps". Decimal units, like network speeds elsewhere.
    public static func speed(_ bytesPerSecond: Double, unit: SpeedUnit) -> String {
        let names = unit == .bytes ? ["KB/s", "MB/s", "GB/s"] : ["Kbps", "Mbps", "Gbps"]
        var scaled = max(bytesPerSecond, 0) * (unit == .bits ? 8 : 1) / 1000
        var index = 0
        while scaled >= 999.5, index < names.count - 1 {
            scaled /= 1000
            index += 1
        }
        let digits = index > 0 && scaled < 99.95 ? 1 : 0
        return String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), scaled) + " " + names[index]
    }

    /// Two lines for the menu bar, padded so its width holds still.
    public static func menuBarText(down: Double, up: Double, unit: SpeedUnit) -> String {
        func line(_ arrow: String, _ rate: Double) -> String {
            let text = speed(rate, unit: unit)
            return arrow + " " + String(repeating: "\u{2007}", count: max(9 - text.count, 0)) + text
        }
        return line("↑", up) + "\n" + line("↓", down)
    }

    /// "372 ms", "1.3 s".
    public static func latency(_ milliseconds: Double) -> String {
        if milliseconds >= 999.5 { return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), milliseconds / 1000) }
        return "\(Int(milliseconds.rounded())) ms"
    }

    /// nil when the output has no speeds, as when the test could not run.
    public static func parseSpeedTest(_ output: String) -> SpeedTestResult? {
        // Warnings can come before the JSON.
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any],
              let download = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let upload = (json["ul_throughput"] as? NSNumber)?.doubleValue,
              download > 0 || upload > 0 else { return nil }
        let perMinute = (json["responsiveness"] as? NSNumber)?.doubleValue ?? 0
        return SpeedTestResult(downloadBitsPerSecond: download, uploadBitsPerSecond: upload,
                               latencyMilliseconds: (json["base_rtt"] as? NSNumber)?.doubleValue,
                               loadedLatencyMilliseconds: perMinute > 0 ? 60_000 / perMinute : nil)
    }
}
