import Foundation

/// A global shortcut: a Carbon key code plus Carbon modifier bits, as
/// RegisterEventHotKey takes them.
public struct KeyCombo: Equatable, Hashable, Sendable {
    public var keyCode: Int
    public var modifiers: Int

    // Carbon modifier bits (Events.h), so this library needs no Carbon import.
    public static let command = 256, shift = 512, option = 2048, control = 4096

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// "⌃⇧4", in Apple's modifier order.
    public var label: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// F1–F15 work alone; every other key needs ⌘, ⌥ or ⌃, or it would
    /// swallow normal typing.
    public var isUsable: Bool {
        Self.functionKeys.contains(keyCode) || modifiers & (Self.command | Self.option | Self.control) != 0
    }

    /// "21:4608", for UserDefaults.
    public var encoded: String { "\(keyCode):\(modifiers)" }

    public init?(encoded: String) {
        let parts = encoded.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], modifiers: parts[1])
    }

    static let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]

    static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
