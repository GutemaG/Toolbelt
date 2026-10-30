import AppKit

/// Toggles: one-click system switches. Each says what it touches; Empty
/// Trash asks first because it cannot be undone.
@MainActor
enum QuickToggles {
    // MARK: State

    static var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var showsDesktopIcons: Bool { finderBool("CreateDesktop", fallback: true) }
    static var showsHiddenFiles: Bool { finderBool("AppleShowAllFiles", fallback: false) }

    // MARK: Actions

    /// Through System Events, so the whole Mac switches. macOS asks once for Automation.
    static func toggleDarkMode() {
        run(script: darkModeScript, failure: "Allow Toolbelt to control System Events to switch Dark Mode")
    }

    static let darkModeScript = """
    tell application "System Events" to tell appearance preferences to set dark mode to not dark mode
    """

    static func setDesktopIcons(_ show: Bool) {
        setFinder("CreateDesktop", show)
        Toast.show(show ? "Desktop icons shown" : "Desktop icons hidden", symbol: "menubar.dock.rectangle")
    }

    static func setHiddenFiles(_ show: Bool) {
        setFinder("AppleShowAllFiles", show)
        Toast.show(show ? "Hidden files shown in Finder" : "Hidden files hidden", symbol: "eye")
    }

    /// The system's own ⌃⌘Q. Needs Accessibility, like paste.
    static func lockScreen() {
        guard PanelController.canPaste(prompt: true) else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let q: CGKeyCode = 12
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: down)
            event?.flags = [.maskCommand, .maskControl]
            event?.post(tap: .cghidEventTap)
        }
    }

    static func sleepDisplay() {
        launch("/usr/bin/pmset", ["displaysleepnow"])
    }

    static func startScreenSaver() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }

    static func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "You can’t undo this."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(script: emptyTrashScript, failure: "Allow Toolbelt to control Finder to empty the Trash")
    }

    static let emptyTrashScript = """
    tell application "Finder" to empty trash
    """

    // MARK: Helpers

    private static func run(script source: String, failure: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            Toast.show(failure, symbol: "exclamationmark.triangle")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }

    private static func finderBool(_ key: String, fallback: Bool) -> Bool {
        let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.finder" as CFString)
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return ["1", "yes", "true"].contains(text.lowercased()) }
        return fallback
    }

    /// Writes Finder's setting, then restarts Finder so it takes effect.
    private static func setFinder(_ key: String, _ value: Bool) {
        launch("/usr/bin/defaults", ["write", "com.apple.finder", key, "-bool", value ? "true" : "false"])
        launch("/usr/bin/killall", ["Finder"])
    }

    private static func launch(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}
