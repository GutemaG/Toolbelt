import AppKit
import SwiftUI
import ToolbeltKit

/// Every global shortcut Toolbelt registers. Each belongs to a tool, has a
/// default, and can be changed or cleared in that tool's Settings page.
enum ShortcutID: Hashable, Identifiable {
    case launcher, clipboard, shotArea, shotScreen, shotText, record, color
    case window(WindowPosition)

    static var all: [ShortcutID] {
        [.launcher, .clipboard, .shotArea, .shotScreen, .shotText, .record, .color]
            + WindowPosition.allCases.map(ShortcutID.window)
    }

    var id: String { key }

    /// The UserDefaults key suffix and the name Hotkeys registers it under.
    var key: String {
        switch self {
        case .launcher: "launcher"
        case .clipboard: "clipboard"
        case .shotArea: "shot.area"
        case .shotScreen: "shot.screen"
        case .shotText: "shot.text"
        case .record: "record"
        case .color: "color"
        case .window(let position): "window." + position.rawValue
        }
    }

    var title: String {
        switch self {
        case .launcher: "Open Launcher"
        case .clipboard: "Open Clipboard"
        case .shotArea: "Capture an area or window"
        case .shotScreen: "Capture the whole screen"
        case .shotText: "Copy text from the screen"
        case .record: "Start or stop recording"
        case .color: "Pick a color"
        case .window(let position): position.title
        }
    }

    var tool: Tool {
        switch self {
        case .launcher: .launcher
        case .clipboard: .clipboard
        case .shotArea, .shotScreen, .shotText: .screenshots
        case .record: .recording
        case .color: .colors
        case .window: .windows
        }
    }

    var defaultCombo: KeyCombo? {
        let ctrlShift = KeyCombo.control | KeyCombo.shift
        switch self {
        case .launcher: return KeyCombo(keyCode: 49, modifiers: KeyCombo.option)
        case .clipboard: return KeyCombo(keyCode: 9, modifiers: KeyCombo.command | KeyCombo.shift)
        case .shotArea: return KeyCombo(keyCode: 21, modifiers: ctrlShift)
        case .shotScreen: return KeyCombo(keyCode: 20, modifiers: ctrlShift)
        case .shotText: return KeyCombo(keyCode: 19, modifiers: ctrlShift)
        case .record: return KeyCombo(keyCode: 23, modifiers: ctrlShift)
        case .color: return KeyCombo(keyCode: 8, modifiers: ctrlShift)
        case .window(let position): return KeyCombo(keyCode: position.shortcut.keyCode, modifiers: KeyCombo.control | KeyCombo.option)
        }
    }

    @MainActor
    func run() {
        switch self {
        case .launcher: PanelController.shared.toggle(.launcher)
        case .clipboard: PanelController.shared.toggle(.clipboard)
        case .shotArea: CaptureController.shared.screenshot(.area)
        case .shotScreen: CaptureController.shared.screenshot(.screen)
        case .shotText: TextGrabber.shared.grab()
        case .record: Recorder.shared.toggle()
        case .color: ColorPicker.shared.pick()
        case .window(let position): WindowSnapper.shared.snap(position)
        }
    }

    /// The current shortcut as shown on screen, or "no shortcut".
    @MainActor var label: String { ShortcutStore.shared.combo(for: self)?.label ?? "no shortcut" }
}

/// The shortcuts people chose. A missing key means the default; an empty
/// string means cleared. Test runs keep changes in memory.
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private var saved: [String: String] = [:]

    init() {
        guard !Store.isOverridden else { return }
        for id in ShortcutID.all {
            if let value = UserDefaults.standard.string(forKey: "shortcut." + id.key) { saved[id.key] = value }
        }
    }

    func combo(for id: ShortcutID) -> KeyCombo? {
        guard let value = saved[id.key] else { return id.defaultCombo }
        return KeyCombo(encoded: value)
    }

    func set(_ combo: KeyCombo?, for id: ShortcutID) {
        saved[id.key] = combo?.encoded ?? ""
        if !Store.isOverridden { UserDefaults.standard.set(saved[id.key], forKey: "shortcut." + id.key) }
        ToolPrefs.shared.onChange?()
    }

    func reset(_ id: ShortcutID) {
        saved[id.key] = nil
        if !Store.isOverridden { UserDefaults.standard.removeObject(forKey: "shortcut." + id.key) }
        ToolPrefs.shared.onChange?()
    }

    /// Another shortcut that uses the same keys, if any.
    func conflict(for id: ShortcutID) -> ShortcutID? {
        guard let combo = combo(for: id) else { return nil }
        return ShortcutID.all.first { $0 != id && self.combo(for: $0) == combo }
    }
}

/// A Settings row: the shortcut's name and a button that records new keys.
/// Click, press the keys; Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let id: ShortcutID
    @Bindable private var store = ShortcutStore.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refused = false

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.sm) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? "Type Shortcut…" : (store.combo(for: id)?.label ?? "None"))
                        .monospaced(!recording)
                        .frame(minWidth: 96)
                }
                .controlSize(.small)
                .help(recording ? "Press the new keys. Esc cancels, Delete clears." : "Click to change the shortcut")
                if store.combo(for: id) != id.defaultCombo, !recording {
                    Button("Reset", systemImage: "arrow.uturn.backward") { store.reset(id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Go back to \(id.defaultCombo?.label ?? "none")")
                }
            }
        } label: {
            Text(id.title)
            if let other = store.conflict(for: id) {
                Label("Also used by “\(other.title)”", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if Hotkeys.shared.failed.contains(id.key), store.combo(for: id) != nil {
                Label("Another app uses this shortcut", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if refused {
                Text("Add ⌘, ⌥ or ⌃, so typing still works.")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        // Toolbelt's own shortcuts would fire instead of being recorded.
        Hotkeys.shared.unregisterAll()
        recording = true
        refused = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isEmpty { stop(); return nil }
            if event.keyCode == 51, flags.isEmpty { store.set(nil, for: id); stop(); return nil }
            var modifiers = 0
            if flags.contains(.command) { modifiers |= KeyCombo.command }
            if flags.contains(.shift) { modifiers |= KeyCombo.shift }
            if flags.contains(.option) { modifiers |= KeyCombo.option }
            if flags.contains(.control) { modifiers |= KeyCombo.control }
            let combo = KeyCombo(keyCode: Int(event.keyCode), modifiers: modifiers)
            guard combo.isUsable else {
                refused = true
                NSSound.beep()
                return nil
            }
            store.set(combo, for: id)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            ToolPrefs.shared.onChange?()
        }
    }
}
