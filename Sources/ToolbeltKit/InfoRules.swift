import Foundation

/// A command-line tool Info looks for, and how to read its version.
public struct DevTool: Sendable, Equatable {
    public enum Group: String, Sendable, CaseIterable {
        case languages = "Languages"
        case packages = "Package Managers"
        case tools = "Tools"
    }

    public var name: String
    public var executable: String
    public var arguments: [String]
    public var group: Group
    /// Read the version after this text, when the output names another version first.
    public var marker: String?

    public init(_ name: String, _ executable: String, _ arguments: [String] = ["--version"], group: Group, marker: String? = nil) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.group = group
        self.marker = marker
    }

    /// Every tool Info checks. Only the installed ones are shown.
    public static let all: [DevTool] = [
        DevTool("Node.js", "node", group: .languages),
        DevTool("Python", "python3", group: .languages),
        DevTool("Go", "go", ["version"], group: .languages),
        DevTool("Rust", "rustc", group: .languages),
        DevTool("Java", "java", ["-version"], group: .languages),
        DevTool(".NET SDK", "dotnet", group: .languages),
        DevTool("Swift", "swift", group: .languages, marker: "Swift version"),
        DevTool("Ruby", "ruby", group: .languages),
        DevTool("PHP", "php", group: .languages),
        DevTool("Dart", "dart", group: .languages),
        DevTool("Bun", "bun", group: .languages),
        DevTool("Deno", "deno", group: .languages),
        DevTool("Kotlin", "kotlin", ["-version"], group: .languages),
        DevTool("npm", "npm", group: .packages),
        DevTool("pnpm", "pnpm", group: .packages),
        DevTool("Yarn", "yarn", group: .packages),
        DevTool("pip", "pip3", group: .packages),
        DevTool("uv", "uv", group: .packages),
        DevTool("Cargo", "cargo", group: .packages),
        DevTool("Homebrew", "brew", group: .packages),
        DevTool("CocoaPods", "pod", group: .packages),
        DevTool("Composer", "composer", group: .packages),
        DevTool("Git", "git", group: .tools),
        DevTool("GitHub CLI", "gh", group: .tools),
        DevTool("Docker", "docker", group: .tools),
        DevTool("kubectl", "kubectl", ["version", "--client"], group: .tools),
        DevTool("Terraform", "terraform", ["-version"], group: .tools),
        DevTool("CMake", "cmake", group: .tools),
        DevTool("Claude Code", "claude", group: .tools),
    ]

    /// Commands in /usr/bin that only stand in for Apple's developer tools:
    /// running one without them installed opens an install dialog.
    public static let appleStubs: Set<String> = ["git", "python3", "pip3", "swift", "ruby", "java"]
}

/// Formatting and reading rules for the Info tool.
public enum InfoRules {
    /// The first version number in a tool's output, after `marker` when given.
    /// "go version go1.22.1 darwin/arm64" gives "1.22.1".
    public static func version(in output: String, after marker: String? = nil) -> String? {
        var text = Substring(output)
        if let marker, let range = output.range(of: marker) { text = output[range.upperBound...] }
        guard let match = text.firstMatch(of: /\d+(\.\d+)+(-[0-9A-Za-z.]+)?|\d+/) else { return nil }
        return String(match.output.0)
    }

    /// "macOS Tahoe" for 26; later versions Apple has not named here show the number only.
    public static func macOSName(major: Int) -> String {
        let names = [11: "Big Sur", 12: "Monterey", 13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe"]
        return names[major].map { "macOS \($0)" } ?? "macOS \(major)"
    }

    /// "3 days, 4 hours", "5 hours, 12 minutes", "8 minutes".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let (days, hours, mins) = (minutes / 1440, minutes / 60 % 24, minutes % 60)
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if days > 0 { return hours > 0 ? "\(unit(days, "day")), \(unit(hours, "hour"))" : unit(days, "day") }
        if hours > 0 { return mins > 0 ? "\(unit(hours, "hour")), \(unit(mins, "minute"))" : unit(hours, "hour") }
        return unit(mins, "minute")
    }

    /// Minutes from the battery as "2:05"; nil while macOS is still estimating (65535).
    public static func clock(minutes: Int) -> String? {
        guard minutes > 0, minutes < 65535 else { return nil }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// Maximum capacity as System Settings shows it: full charge over design, at most 100%.
    public static func maximumCapacity(fullCharge: Int, design: Int) -> Int? {
        guard design > 0, fullCharge > 0 else { return nil }
        return min(Int((Double(fullCharge) / Double(design) * 100).rounded()), 100)
    }

    /// The condition System Settings shows, from the system's health word.
    public static func batteryCondition(_ health: String?, maximumCapacity: Int?) -> String {
        switch health?.lowercased() {
        case "good": return "Normal"
        case "fair", "poor", "check battery": return "Service Recommended"
        default: return (maximumCapacity ?? 100) < 80 ? "Service Recommended" : "Normal"
        }
    }

    /// Wi-Fi signal in words, from its strength in dBm.
    public static func signal(rssi: Int) -> String {
        switch rssi {
        case -50...0: "Excellent"
        case -60 ..< -50: "Good"
        case -70 ..< -60: "Fair"
        default: "Weak"
        }
    }

    /// "1 TB" the way Finder counts (1000 bytes to a KB).
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
