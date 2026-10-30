import AppKit
import SwiftUI

/// Keyboard handling and the capture row, split from ToolbeltView to keep it readable.
extension ToolbeltView {
    /// A thin row of capture buttons under the search field in the Launcher,
    /// so screenshots and recording are one click from the menu bar.
    @ViewBuilder
    var quickActions: some View {
        let prefs = ToolPrefs.shared
        let shots = prefs.enabled.contains(.screenshots), record = prefs.enabled.contains(.recording)
        if tool == .launcher, !model.pickingApps, shots || record {
            HStack(spacing: Space.sm) {
                if shots {
                    ForEach(CaptureMode.allCases) { mode in
                        quickButton(mode.title, symbol: mode.symbol,
                                    help: mode == .screen ? "Screenshot of the whole screen (\(ShortcutID.shotScreen.label))"
                                        : "Screenshot of \(mode == .area ? "an area" : "a window") (\(ShortcutID.shotArea.label))") {
                            close()
                            CaptureController.shared.screenshot(mode)
                        }
                    }
                }
                if shots && record {
                    Divider().frame(height: Space.lg)
                }
                if record {
                    quickButton(isRecording ? "Stop" : "Record", symbol: isRecording ? "stop.circle.fill" : "record.circle",
                                help: isRecording ? "Stop recording (\(ShortcutID.record.label))" : "Record an area, a window or the screen (\(ShortcutID.record.label))") {
                        close()
                        isRecording ? Recorder.shared?.stop() : Recorder.shared?.start(.area)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            Divider()
        }
    }

    func quickButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(QuickActionStyle())
        .help(help)
    }

    // MARK: Keyboard

    /// Arrow keys, Return, Escape, and Command shortcuts while the search
    /// field has focus. A local monitor sees them before the field editor.
    func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window === window else { return event }
            return handle(event) ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Key codes of 1 to 9 on the top row.
    static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let entries = flatEntries
        let current = entries.indices.contains(selected) ? entries[selected] : nil
        switch (event.keyCode, flags.contains(.command)) {
        case (123, false) where tool == .info && query.isEmpty: MacInfo.shared.step(-1) // Left: previous Info tab
        case (124, false) where tool == .info && query.isEmpty: MacInfo.shared.step(1)  // Right: next Info tab
        case (15, true) where tool == .info: MacInfo.shared.load(MacInfo.shared.tab, force: true) // Command-R
        case (36, _) where tool == .camera, (76, _) where tool == .camera: model.photoCount += 1 // Return takes a photo
        case (46, false) where tool == .camera: Camera.toggleMirror() // M
        case (125, false): // Down: one row, or one grid row inside the pinned grid
            let step = selected < gridCount ? min(gridColumns, max(gridCount - selected, 1)) : 1
            selected = min(selected + step, max(entries.count - 1, 0))
        case (126, false): // Up
            if selected < gridCount { selected = max(selected - gridColumns, 0) }
            else if selected == gridCount { selected = max(gridCount - 1, 0) }
            else { selected = max(selected - 1, 0) }
        case (124, false) where selected < gridCount && query.isEmpty: // Right, inside the grid
            selected = min(selected + 1, gridCount - 1)
        case (123, false) where selected < gridCount && query.isEmpty: // Left, inside the grid
            selected = max(selected - 1, 0)
        case (36, _), (76, _): // Return, Enter
            if let current { activate(current, plainText: flags.contains(.option)) }
        case (53, _): // Escape
            if !query.isEmpty { query = "" } else if model.pickingApps { stopPicking() } else { close() }
        case (48, false) where fixedTool == nil && panelTools.count > 1: // Tab switches tool
            let index = panelTools.firstIndex(of: model.tool) ?? 0
            model.tool = panelTools[(index + 1) % panelTools.count]
        case (let key, true) where fixedTool == nil && Self.digitKeys.firstIndex(of: key).map({ $0 < panelTools.count }) == true:
            model.tool = panelTools[Self.digitKeys.firstIndex(of: key)!] // Command-1 to Command-9
        case (43, true): openSettings()            // Command-,
        case (12, true): NSApp.terminate(nil)      // Command-Q
        case (35, true): // Command-P pins a clip or an app
            switch current {
            case .clip(let clip)?: model.togglePin(clip)
            case .app(let app)?: model.togglePin(appPath: app.path)
            default: return false
            }
        case (51, true): // Command-Delete
            guard case .clip(let clip)? = current else { return false }
            model.delete(clip)
            selected = min(selected, max(entries.count - 2, 0))
        default:
            return false
        }
        if [123, 124, 125, 126].contains(event.keyCode) { keyboardMoves += 1 }
        return true
    }}
