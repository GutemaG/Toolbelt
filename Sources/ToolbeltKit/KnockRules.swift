import Foundation

/// Where knocks are told apart: anywhere on the Mac (three slots), or by the
/// edge they hit (six slots).
public enum KnockLayout: String, CaseIterable, Sendable {
    case anywhere, sides

    public var title: String {
        switch self {
        case .anywhere: "Anywhere"
        case .sides: "Left and Right"
        }
    }

    /// The slots this layout has, in display order.
    public var slots: [KnockSlot] {
        switch self {
        case .anywhere: (1...3).map { KnockSlot(count: $0, side: nil) }
        case .sides: (1...3).flatMap { count in KnockSide.allCases.map { KnockSlot(count: count, side: $0) } }
        }
    }
}

/// One to three knocks, on one edge or anywhere. Saved by its key.
public struct KnockSlot: Hashable, Sendable {
    public let count: Int
    /// nil for the Anywhere layout.
    public let side: KnockSide?

    public init(count: Int, side: KnockSide?) {
        self.count = count
        self.side = side
    }

    /// "any.2", "left.1".
    public var key: String { "\(side?.rawValue ?? "any").\(count)" }

    public var title: String {
        let knocks = count == 1 ? "1 knock" : "\(count) knocks"
        guard let side else { return knocks }
        return "\(knocks), \(side.rawValue)"
    }
}

/// A ready set of actions for all six slots; Anywhere uses the left column,
/// like mactap's presets this follows.
public struct KnockPreset: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    /// Action ids for one, two and three knocks.
    public let left: [String]
    public let right: [String]

    public func slots(for layout: KnockLayout) -> [String: String] {
        var result: [String: String] = [:]
        for count in 1...3 {
            switch layout {
            case .anywhere:
                result[KnockSlot(count: count, side: nil).key] = left[count - 1]
            case .sides:
                result[KnockSlot(count: count, side: .left).key] = left[count - 1]
                result[KnockSlot(count: count, side: .right).key] = right[count - 1]
            }
        }
        return result
    }

    public static let all: [KnockPreset] = [
        KnockPreset(id: "daily", title: "Daily", subtitle: "Copy, paste and undo on the left; music, screenshots and lock on the right",
                    symbol: "star", left: ["copy", "paste", "undo"], right: ["playPause", "screenshotArea", "lockScreen"]),
        KnockPreset(id: "coding", title: "Coding", subtitle: "Accept, dismiss and save on the left; copy, paste and undo on the right",
                    symbol: "chevron.left.forwardslash.chevron.right", left: ["accept", "dismiss", "save"], right: ["copy", "paste", "undo"]),
        KnockPreset(id: "capture", title: "Capture", subtitle: "Screenshots and text on the left; recording, colors and clips on the right",
                    symbol: "camera.viewfinder", left: ["screenshotArea", "screenshotScreen", "copyText"], right: ["record", "pickColor", "clipboard"]),
        KnockPreset(id: "media", title: "Media", subtitle: "Back and quieter on the left; play, skip and louder on the right",
                    symbol: "playpause", left: ["previousTrack", "volumeDown", "mute"], right: ["playPause", "nextTrack", "volumeUp"]),
        KnockPreset(id: "focus", title: "Focus", subtitle: "Hide, tile left and lock on the left; Mission Control, tile right and sleep on the right",
                    symbol: "moon", left: ["hideApp", "leftHalf", "lockScreen"], right: ["missionControl", "rightHalf", "sleepDisplay"]),
    ]
}

/// Settings for knocks in one app, over the ones used everywhere else.
public struct KnockAppRule: Codable, Identifiable, Equatable, Sendable {
    /// The app's bundle id.
    public let id: String
    public var name: String
    /// Slot key to action id; a slot left out does what it does everywhere.
    public var slots: [String: String]

    public init(id: String, name: String, slots: [String: String]) {
        self.id = id
        self.name = name
        self.slots = slots
    }

    /// Rules worth offering when the app is installed. Accept is Return and
    /// Dismiss is Escape: they answer AI suggestions in Cursor and Claude, and
    /// Claude Code's questions in a terminal.
    public static let suggested: [(rule: KnockAppRule, why: String)] = {
        let coding = ["any.1": "accept", "any.2": "dismiss", "left.1": "accept", "left.2": "dismiss"]
        let editor = coding.merging(["any.3": "save", "left.3": "save"]) { $1 }
        let music = ["any.1": "playPause", "any.2": "nextTrack", "any.3": "previousTrack",
                     "left.1": "previousTrack", "right.1": "playPause", "right.2": "nextTrack"]
        let browser = ["any.2": "newTab", "any.3": "closeTab", "left.2": "newTab", "left.3": "closeTab"]
        func rule(_ id: String, _ name: String, _ slots: [String: String], _ why: String) -> (KnockAppRule, String) {
            (KnockAppRule(id: id, name: name, slots: slots), why)
        }
        return [
            rule("com.todesktop.230313mzl4w4u92", "Cursor", editor, "Accept or dismiss a suggestion, and save"),
            rule("com.anthropic.claudefordesktop", "Claude", coding, "Accept or dismiss"),
            rule("com.mitchellh.ghostty", "Ghostty", coding, "Answer Claude Code: Return to accept, Escape to stop"),
            rule("com.apple.Terminal", "Terminal", coding, "Answer Claude Code: Return to accept, Escape to stop"),
            rule("com.googlecode.iterm2", "iTerm", coding, "Answer Claude Code: Return to accept, Escape to stop"),
            rule("com.microsoft.VSCode", "Visual Studio Code", editor, "Accept or dismiss, and save"),
            rule("com.apple.dt.Xcode", "Xcode", editor, "Accept or dismiss a completion, and save"),
            rule("com.spotify.client", "Spotify", music, "Play, skip and go back"),
            rule("com.apple.Music", "Music", music, "Play, skip and go back"),
            rule("com.apple.Safari", "Safari", browser, "Open and close tabs"),
            rule("com.google.Chrome", "Google Chrome", browser, "Open and close tabs"),
            rule("com.microsoft.edgemac", "Microsoft Edge", browser, "Open and close tabs"),
        ]
    }()
}

public enum KnockRules {
    /// The action for a knock: the front app's rule first, then the slot used everywhere.
    public static func action(for slot: KnockSlot, slots: [String: String], rule: KnockAppRule?) -> String? {
        rule?.slots[slot.key] ?? slots[slot.key]
    }

    /// The slot a detected knock fills in a layout.
    public static func slot(count: Int, side: KnockSide, layout: KnockLayout) -> KnockSlot {
        KnockSlot(count: min(max(count, 1), 3), side: layout == .sides ? side : nil)
    }
}
