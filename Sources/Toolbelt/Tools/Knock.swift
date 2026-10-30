import AppKit
import Carbon.HIToolbox
import SwiftUI
import ToolbeltKit

/// What a group of knocks does. Toolbelt's own actions run directly; Edit
/// and app actions press keys in the front app.
enum KnockAction: String, CaseIterable, Identifiable {
    case nothing
    case copy, paste, cut, undo, redo, selectAll, save
    case accept, dismiss, newTab, closeTab, hideApp
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
    case screenshotArea, screenshotScreen, copyText, record, pickColor
    case leftHalf, rightHalf, maximize, missionControl
    case launcher, clipboard, lockScreen, sleepDisplay, darkMode

    enum Group: String, CaseIterable {
        case edit = "Edit", app = "In the App", media = "Music and Sound", capture = "Capture",
             windows = "Windows", system = "Toolbelt and System"
    }

    var id: String { rawValue }

    var group: Group? {
        switch self {
        case .nothing: nil
        case .copy, .paste, .cut, .undo, .redo, .selectAll, .save: .edit
        case .accept, .dismiss, .newTab, .closeTab, .hideApp: .app
        case .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute: .media
        case .screenshotArea, .screenshotScreen, .copyText, .record, .pickColor: .capture
        case .leftHalf, .rightHalf, .maximize, .missionControl: .windows
        case .launcher, .clipboard, .lockScreen, .sleepDisplay, .darkMode: .system
        }
    }

    var title: String {
        switch self {
        case .nothing: "Do Nothing"
        case .copy: "Copy"
        case .paste: "Paste"
        case .cut: "Cut"
        case .undo: "Undo"
        case .redo: "Redo"
        case .selectAll: "Select All"
        case .save: "Save"
        case .accept: "Accept (Return)"
        case .dismiss: "Dismiss (Escape)"
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .hideApp: "Hide the App"
        case .playPause: "Play or Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .mute: "Mute or Unmute"
        case .screenshotArea: "Screenshot of an Area"
        case .screenshotScreen: "Screenshot of the Screen"
        case .copyText: "Copy Text from the Screen"
        case .record: "Start or Stop Recording"
        case .pickColor: "Pick a Color"
        case .leftHalf: "Window to Left Half"
        case .rightHalf: "Window to Right Half"
        case .maximize: "Fill the Screen"
        case .missionControl: "Mission Control"
        case .launcher: "Open Launcher"
        case .clipboard: "Open Clipboard"
        case .lockScreen: "Lock Screen"
        case .sleepDisplay: "Sleep the Display"
        case .darkMode: "Dark Mode On or Off"
        }
    }

    var symbol: String {
        switch self {
        case .nothing: "circle.dashed"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .cut: "scissors"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .selectAll: "selection.pin.in.out"
        case .save: "square.and.arrow.down"
        case .accept: "return"
        case .dismiss: "escape"
        case .newTab: "plus.square.on.square"
        case .closeTab: "xmark.square"
        case .hideApp: "eye.slash"
        case .playPause: "playpause"
        case .nextTrack: "forward"
        case .previousTrack: "backward"
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        case .mute: "speaker.slash"
        case .screenshotArea: "rectangle.dashed"
        case .screenshotScreen: "desktopcomputer"
        case .copyText: "text.viewfinder"
        case .record: "record.circle"
        case .pickColor: "eyedropper"
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .maximize: "rectangle.fill"
        case .missionControl: "squares.below.rectangle"
        case .launcher: "magnifyingglass"
        case .clipboard: "doc.on.clipboard"
        case .lockScreen: "lock"
        case .sleepDisplay: "moon.zzz"
        case .darkMode: "circle.lefthalf.filled"
        }
    }

    /// Key presses sent to the front app, as key code and modifiers.
    private var keys: (code: Int, modifiers: CGEventFlags)? {
        switch self {
        case .copy: (kVK_ANSI_C, .maskCommand)
        case .paste: (kVK_ANSI_V, .maskCommand)
        case .cut: (kVK_ANSI_X, .maskCommand)
        case .undo: (kVK_ANSI_Z, .maskCommand)
        case .redo: (kVK_ANSI_Z, [.maskCommand, .maskShift])
        case .selectAll: (kVK_ANSI_A, .maskCommand)
        case .save: (kVK_ANSI_S, .maskCommand)
        case .accept: (kVK_Return, [])
        case .dismiss: (kVK_Escape, [])
        case .newTab: (kVK_ANSI_T, .maskCommand)
        case .closeTab: (kVK_ANSI_W, .maskCommand)
        default: nil
        }
    }

    func run() {
        if let keys {
            Keystroke.press(keys.code, keys.modifiers)
            return
        }
        switch self {
        case .playPause: Self.mediaKey(16) // NX_KEYTYPE_PLAY
        case .nextTrack: Self.mediaKey(17) // NX_KEYTYPE_NEXT
        case .previousTrack: Self.mediaKey(18) // NX_KEYTYPE_PREVIOUS
        case .volumeUp, .volumeDown:
            guard let volume = AudioOutput.volume else { return NSSound.beep() }
            AudioOutput.setVolume(volume + (self == .volumeUp ? 1 : -1) / 16)
        case .mute: AudioOutput.setMuted(!AudioOutput.isMuted)
        case .hideApp: NSWorkspace.shared.frontmostApplication?.hide()
        case .screenshotArea: ShortcutID.shotArea.run()
        case .screenshotScreen: ShortcutID.shotScreen.run()
        case .copyText: ShortcutID.shotText.run()
        case .record: ShortcutID.record.run()
        case .pickColor: ShortcutID.color.run()
        case .leftHalf: WindowSnapper.shared.snap(.leftHalf)
        case .rightHalf: WindowSnapper.shared.snap(.rightHalf)
        case .maximize: WindowSnapper.shared.snap(.maximize)
        case .missionControl: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .launcher: ShortcutID.launcher.run()
        case .clipboard: ShortcutID.clipboard.run()
        case .lockScreen: QuickToggles.lockScreen()
        case .sleepDisplay: QuickToggles.sleepDisplay()
        case .darkMode: QuickToggles.toggleDarkMode()
        default: break
        }
    }

    /// Presses a media key, so whichever app is playing answers, as with the keyboard's own keys.
    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: key << 16 | state << 8, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Presses keys in the front app. On macOS 26, key presses with ⌘ posted by
/// an ad hoc signed app are often dropped, so this asks System Events first
/// (Automation, asked once) and posts the keys itself only if that fails.
enum Keystroke {
    static func press(_ code: Int, _ modifiers: CGEventFlags) {
        var names: [String] = []
        if modifiers.contains(.maskCommand) { names.append("command down") }
        if modifiers.contains(.maskShift) { names.append("shift down") }
        if modifiers.contains(.maskAlternate) { names.append("option down") }
        if modifiers.contains(.maskControl) { names.append("control down") }
        let using = names.isEmpty ? "" : " using {\(names.joined(separator: ", "))}"
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to key code \(code)\(using)")?.executeAndReturnError(&error)
        guard error != nil else { return }
        guard PanelController.canPaste(prompt: true) else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            event?.flags = modifiers
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// Knock: one, two or three knocks on the MacBook, anywhere or on the left
/// or right edge, run an action, with rules per app. Listens only while the
/// tool is on and the screen is awake.
@Observable
final class Knock {
    static let shared = Knock()
    static let sensitivityKey = "knock.sensitivity"
    static let messageKey = "knock.message"
    private static let layoutKey = "knock.layout"
    private static let slotsKey = "knock.slots"
    private static let rulesKey = "knock.apps"
    private static let invertKey = "knock.invertSides"

    enum State: Equatable {
        case off, listening, unavailable
    }

    /// The last knock or ignored jolt, for the tool page and tuning.
    struct Heard: Equatable {
        let event: KnockDetector.Event
        let action: KnockAction?
        /// The app whose rule chose the action.
        let app: String?
        let at: Date
    }

    private(set) var state: State = .off
    private(set) var heard: Heard?
    private(set) var slots: [String: String]
    private(set) var rules: [KnockAppRule]
    var layout: KnockLayout {
        didSet {
            sensor?.findsSide = layout == .sides
            save(layout.rawValue, Self.layoutKey)
        }
    }
    var sensitivity: Double {
        didSet {
            sensor?.sensitivity = sensitivity
            save(sensitivity, Self.sensitivityKey)
        }
    }
    var invertSides: Bool {
        didSet {
            sensor?.invertSides = invertSides
            save(invertSides, Self.invertKey)
        }
    }
    /// Test and snapshot runs never read the sensor or save.
    let isSimulated = Store.isOverridden

    @ObservationIgnored private var sensor: KnockSensor?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let defaults: UserDefaults? = Store.isOverridden ? nil : .standard
        sensitivity = defaults?.object(forKey: Self.sensitivityKey) as? Double ?? 0.6
        layout = defaults?.string(forKey: Self.layoutKey).flatMap(KnockLayout.init(rawValue:)) ?? .anywhere
        invertSides = defaults?.bool(forKey: Self.invertKey) ?? false
        var saved = defaults?.dictionary(forKey: Self.slotsKey) as? [String: String]
        if saved == nil {
            // The first version kept three slots as knock.1 to knock.3.
            var anywhere = ["any.1": "nothing", "any.2": "playPause", "any.3": "screenshotArea"]
            for count in 1...3 { if let old = defaults?.string(forKey: "knock.\(count)") { anywhere["any.\(count)"] = old } }
            saved = anywhere.merging(KnockPreset.all[0].slots(for: .sides)) { old, _ in old }
        }
        slots = saved ?? [:]
        rules = (defaults?.data(forKey: Self.rulesKey)).flatMap { try? JSONDecoder().decode([KnockAppRule].self, from: $0) } ?? []

        // A sleeping screen means nobody is knocking: stop reading to save power.
        let center = NSWorkspace.shared.notificationCenter
        for (name, awake) in [(NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
                              (NSWorkspace.willSleepNotification, false), (NSWorkspace.didWakeNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { awake ? self?.resume() : self?.pause() }
            })
        }
    }

    // MARK: Slots and rules

    func action(for slot: KnockSlot, rule: KnockAppRule? = nil) -> KnockAction {
        KnockRules.action(for: slot, slots: slots, rule: rule).flatMap(KnockAction.init(rawValue:)) ?? .nothing
    }

    func setAction(_ action: KnockAction, for slot: KnockSlot) {
        slots[slot.key] = action.rawValue
        save(slots, Self.slotsKey)
    }

    func apply(_ preset: KnockPreset) {
        slots.merge(preset.slots(for: layout)) { $1 }
        save(slots, Self.slotsKey)
        Toast.show("Knocks set to \(preset.title)", symbol: preset.symbol)
    }

    /// The preset the current layout's slots match, if any.
    var currentPreset: KnockPreset? {
        KnockPreset.all.first { preset in preset.slots(for: layout).allSatisfy { slots[$0.key] == $0.value } }
    }

    /// nil means the slot does what it does everywhere.
    func ruleAction(_ rule: KnockAppRule, _ slot: KnockSlot) -> KnockAction? {
        rule.slots[slot.key].flatMap(KnockAction.init(rawValue:))
    }

    func setRuleAction(_ action: KnockAction?, for slot: KnockSlot, in rule: KnockAppRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].slots[slot.key] = action?.rawValue
        saveRules()
    }

    func addRule(_ rule: KnockAppRule) {
        guard !rules.contains(where: { $0.id == rule.id }) else { return }
        rules.append(rule)
        rules.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveRules()
    }

    func removeRule(_ rule: KnockAppRule) {
        rules.removeAll { $0.id == rule.id }
        saveRules()
    }

    /// Suggested rules for apps on this Mac that have none yet.
    var suggestions: [(rule: KnockAppRule, why: String)] {
        KnockAppRule.suggested.filter { suggestion in
            !rules.contains { $0.id == suggestion.rule.id }
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: suggestion.rule.id) != nil
        }
    }

    private func saveRules() {
        if !isSimulated, let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: Self.rulesKey) }
    }

    private func save(_ value: Any, _ key: String) {
        if !isSimulated { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: Listening

    /// Turned on or off in Settings.
    func setEnabled(_ on: Bool) {
        wanted = on
        on ? resume() : pause()
        if !on { state = .off }
    }

    func reading() -> KnockSensor.Reading { sensor?.take() ?? KnockSensor.Reading() }

    private func resume() {
        guard wanted, sensor == nil, !isSimulated else { return }
        let sensor = KnockSensor(sensitivity: sensitivity) { event in
            Task { @MainActor in Knock.shared.handle(event) }
        }
        sensor.findsSide = layout == .sides
        sensor.invertSides = invertSides
        guard sensor.begin() else {
            state = .unavailable
            return
        }
        self.sensor = sensor
        state = .listening
    }

    private func pause() {
        sensor?.end()
        sensor = nil
    }

    private func handle(_ event: KnockDetector.Event) {
        guard state == .listening else { return }
        var action: KnockAction?
        var app: String?
        if case .knocks(let count, let side) = event {
            let slot = KnockRules.slot(count: count, side: side, layout: layout)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let rule = rules.first { $0.id == front && $0.slots[slot.key] != nil }
            action = self.action(for: slot, rule: rule)
            app = rule?.name
            action?.run()
            if UserDefaults.standard.object(forKey: Self.messageKey) as? Bool ?? true {
                Toast.show(describe(event, action: action, app: app), symbol: action?.symbol ?? "hand.tap")
            }
        }
        heard = Heard(event: event, action: action, app: app, at: .now)
    }

    func describe(_ event: KnockDetector.Event, action: KnockAction?, app: String?) -> String {
        switch event {
        case .knocks(let count, let side):
            let knocks = KnockRules.slot(count: count, side: side, layout: layout).title
            guard let action, action != .nothing else { return knocks }
            return "\(knocks): \(action.title)" + (app.map { " in \($0)" } ?? "")
        case .ignored(let reason):
            return "Ignored: \(reason.rawValue)"
        }
    }
}
