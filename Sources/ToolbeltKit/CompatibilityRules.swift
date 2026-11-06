import Foundation

/// The hardware some tools depend on, read from the Mac the app runs on.
public struct MacFacts: Sendable, Equatable {
    public var hasMotionSensor: Bool
    public var hasCamera: Bool
    public var hasBattery: Bool
    public var hasFans: Bool

    public init(hasMotionSensor: Bool, hasCamera: Bool, hasBattery: Bool, hasFans: Bool) {
        self.hasMotionSensor = hasMotionSensor
        self.hasCamera = hasCamera
        self.hasBattery = hasBattery
        self.hasFans = hasFans
    }
}

/// How well a tool works on a Mac.
public enum ToolSupport: Sendable, Equatable {
    case ready
    /// Works, with something missing. The note says what.
    case limited(String)
    /// Can't work on this Mac. The note says why.
    case unavailable(String)

    public var note: String? {
        switch self {
        case .ready: nil
        case .limited(let note), .unavailable(let note): note
        }
    }

    public var isUnavailable: Bool {
        if case .unavailable = self { true } else { false }
    }
}

/// What each tool needs, and what that means on a given Mac. Tools are named by
/// their raw value, like "knock". Permissions don't count: people grant those
/// when they use a tool, so every requirement here is only hardware.
public enum CompatibilityRules {
    public static func support(forTool tool: String, on mac: MacFacts) -> ToolSupport {
        switch tool {
        case "knock":
            return mac.hasMotionSensor ? .ready : .unavailable("This Mac has no motion sensor to feel a knock.")
        case "camera":
            return mac.hasCamera ? .ready : .limited("No camera found. Connect one, or use an iPhone with Continuity Camera.")
        case "system":
            let missing = [mac.hasFans ? nil : "fan", mac.hasBattery ? nil : "battery"].compactMap(\.self)
            return missing.isEmpty ? .ready : .limited("This Mac has no \(missing.joined(separator: " or ")) to show.")
        case "info":
            return mac.hasBattery ? .ready : .limited("This Mac has no battery, so Info skips that section.")
        default:
            return .ready
        }
    }

    /// One line on what the tool needs, on any Mac.
    public static func requirement(forTool tool: String) -> String {
        switch tool {
        case "clipboard", "snippets": "Any Mac. Pasting for you needs Accessibility."
        case "screenshots": "Any Mac. Needs Screen Recording."
        case "recording": "Any Mac. Needs Screen Recording, and Microphone to record your voice."
        case "camera": "A built-in or connected camera. Needs Camera."
        case "windows": "Any Mac. Needs Accessibility."
        case "calendar": "Any Mac. Needs Calendars."
        case "nowPlaying": "Music or Spotify. Needs Automation."
        case "mixer": "Any Mac. Needs System Audio Recording."
        case "toggles": "Any Mac. Dark Mode and Empty Trash need Automation."
        case "knock": "A MacBook with M2 or later, M1 Pro or M1 Max."
        case "system": "Any Mac. Fans and battery show when your Mac has them."
        case "info": "Any Mac. The Wi-Fi name needs Location."
        case "networkSpeed": "Any Mac. The speed test needs internet."
        default: "Any Mac."
        }
    }
}
