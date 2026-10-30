import Carbon.HIToolbox

/// Global shortcuts through Carbon: no permission needed, and the key never
/// reaches the front app.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var names: [UInt32: String] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private var nextID: UInt32 = 0
    /// Shortcuts that failed to register, usually because another app owns them.
    private(set) var failed: [String] = []

    /// Registers keyCode + Carbon modifiers (optionKey, cmdKey, shiftKey, controlKey).
    func register(_ name: String, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandler()
        nextID += 1
        let id = nextID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: OSType(0x544F4F4C), id: id), // 'TOOL'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            failed.append(name)
            return
        }
        refs.append(ref)
        handlers[id] = action
        names[id] = name
    }

    func isRegistered(_ name: String) -> Bool { names.values.contains(name) }

    /// Removes every shortcut, so the enabled tools can register again.
    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        handlers = [:]
        names = [:]
        failed = []
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec, nil, nil)
    }
}

nonisolated private func hotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var hotkey = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
    let id = hotkey.id
    MainActor.assumeIsolated { Hotkeys.shared.fire(id) }
    return noErr
}
