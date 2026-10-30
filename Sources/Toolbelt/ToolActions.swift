import AppKit
import ToolbeltKit

/// One tile in a tool's grid: something the tool can do right now.
struct ToolAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let help: String
    /// Drawn as active, like the running Keep Awake length.
    var isOn = false
    /// Close the popover or panel first (anything that needs the screen).
    var closes = true
    let run: @MainActor () -> Void
}

/// The tiles and the footer hint for each tool. ToolbeltView draws them;
/// a new tool adds its case here and in `Tool`.
@MainActor
enum ToolActions {
    /// The grid title and tiles, or nil for tools with their own list (Launcher, Clipboard).
    static func grid(for tool: Tool, model: AppModel, query: String = "") -> (title: String, actions: [ToolAction])? {
        switch tool {
        case .launcher, .clipboard, .system, .info, .camera, .mixer, .knock:
            return nil
        case .snippets:
            guard query.isEmpty else { return nil }
            return ("Snippets", [ToolAction(id: "snippet.new", title: "New Snippet", symbol: "plus",
                                            help: "Write a new snippet in Settings") {
                model.editSnippet(model.addSnippet())
            }])
        case .screenshots:
            let modes = CaptureMode.allCases.map { mode in
                ToolAction(id: "shot." + mode.rawValue, title: mode.title, symbol: mode.symbol,
                           help: mode == .screen ? "Capture the whole screen (\(ShortcutID.shotScreen.label))"
                               : "Capture \(mode == .area ? "an area" : "a window") (\(ShortcutID.shotArea.label))") {
                    CaptureController.shared.screenshot(mode)
                }
            }
            let text = ToolAction(id: "shot.text", title: "Text", symbol: "text.viewfinder",
                                  help: "Copy the text or QR code in an area (\(ShortcutID.shotText.label))") { TextGrabber.shared.grab() }
            let scroll = ToolAction(id: "shot.scroll", title: "Scrolling", symbol: "scroll",
                                    help: "Capture an area as you scroll it (\(ShortcutID.shotScroll.label))") { ScrollCapture.shared.start() }
            return ("Capture", modes + [scroll, text])
        case .recording:
            if model.isRecording {
                return ("Recording", [ToolAction(id: "rec.stop", title: "Stop", symbol: "stop.circle.fill",
                                                 help: "Stop recording (\(ShortcutID.record.label))", isOn: true) { Recorder.shared?.stop() }])
            }
            return ("Record", CaptureMode.allCases.map { mode in
                ToolAction(id: "rec." + mode.rawValue, title: mode.title, symbol: mode.symbol,
                           help: "Record \(mode == .area ? "an area" : mode == .window ? "a window" : "the whole screen") (\(ShortcutID.record.label))") {
                    Recorder.shared?.start(mode)
                }
            })
        case .colors:
            return ("Pick", [ToolAction(id: "color.pick", title: "Pick Color", symbol: "eyedropper",
                                        help: "Pick a color from the screen (\(ShortcutID.color.label))") { ColorPicker.shared.pick() }])
        case .windows:
            return ("Move the front window", WindowPosition.allCases.map { position in
                ToolAction(id: "win." + position.rawValue, title: position.title, symbol: position.symbol,
                           help: "\(position.title) (\(position.shortcut.label))") {
                    WindowSnapper.shared.snap(position)
                }
            })
        case .timer:
            let timer = TimerTool.shared!
            // Reading the tick makes the view redraw the time left every second.
            _ = model.timerTick
            if timer.isRunning {
                let left = (timer.isPaused ? "Paused, " : "") + CaptureRules.elapsed(Int(timer.remaining.rounded(.up))) + " left"
                return (left, [
                    timer.isPaused
                        ? ToolAction(id: "timer.resume", title: "Resume", symbol: "play.fill", help: "Keep counting down", closes: false) { timer.resume() }
                        : ToolAction(id: "timer.pause", title: "Pause", symbol: "pause.fill", help: "Pause the timer", closes: false) { timer.pause() },
                    ToolAction(id: "timer.add1", title: "+1 min", symbol: "plus.circle", help: "Add a minute", closes: false) { timer.add(60) },
                    ToolAction(id: "timer.add5", title: "+5 min", symbol: "goforward.5", help: "Add five minutes", closes: false) { timer.add(300) },
                    ToolAction(id: "timer.stop", title: "Stop", symbol: "stop.fill", help: "Stop the timer", closes: false) { timer.stop() },
                ])
            }
            var lengths: [TimeInterval] = [60, 300, 600, 900, 1500, 2700, 3600]
            // A length typed in the search field ("12", "90s", "1h30m") comes first.
            if let typed = TimerRules.parse(query) { lengths = [typed] }
            return ("Start a timer", lengths.map { length in
                ToolAction(id: "timer.\(Int(length))", title: TimerRules.title(length),
                           symbol: length == 1500 ? "brain.head.profile" : "timer",
                           help: length == 1500 ? "A 25-minute focus session" : "Count down \(TimerRules.title(length))",
                           closes: false) {
                    timer.start(length)
                }
            })
        case .sound:
            _ = model.soundTick
            let current = AudioOutput.current
            var actions = AudioOutput.devices().map { device in
                ToolAction(id: "sound.\(device.id)", title: device.name, symbol: device.symbol,
                           help: "Play sound through \(device.name)", isOn: device.id == current, closes: false) {
                    AudioOutput.select(device)
                    model.soundTick &+= 1
                }
            }
            let muted = AudioOutput.isMuted
            actions.append(ToolAction(id: "sound.mute", title: muted ? "Unmute" : "Mute",
                                      symbol: muted ? "speaker.slash.fill" : "speaker.slash",
                                      help: muted ? "Turn the sound back on" : "Mute the sound", isOn: muted, closes: false) {
                AudioOutput.setMuted(!muted)
                model.soundTick &+= 1
            })
            return ("Play sound through", actions)
        case .toggles:
            _ = model.soundTick
            let refresh = { model.soundTick &+= 1 }
            let dark = QuickToggles.isDarkMode, icons = QuickToggles.showsDesktopIcons, hidden = QuickToggles.showsHiddenFiles
            return ("System", [
                ToolAction(id: "t.dark", title: "Dark Mode", symbol: dark ? "moon.fill" : "moon",
                           help: "Switch the Mac between light and dark", isOn: dark, closes: false) {
                    QuickToggles.toggleDarkMode(); refresh()
                },
                ToolAction(id: "t.icons", title: "Desktop Icons", symbol: icons ? "menubar.dock.rectangle" : "rectangle.dashed",
                           help: icons ? "Hide the icons on the desktop (restarts Finder)" : "Show the icons on the desktop (restarts Finder)",
                           isOn: icons, closes: false) {
                    QuickToggles.setDesktopIcons(!icons); refresh()
                },
                ToolAction(id: "t.hidden", title: "Hidden Files", symbol: hidden ? "eye.fill" : "eye.slash",
                           help: hidden ? "Hide hidden files in Finder (restarts Finder)" : "Show hidden files in Finder (restarts Finder)",
                           isOn: hidden, closes: false) {
                    QuickToggles.setHiddenFiles(!hidden); refresh()
                },
                ToolAction(id: "t.lock", title: "Lock Screen", symbol: "lock.fill", help: "Lock the Mac (⌃⌘Q)") { QuickToggles.lockScreen() },
                ToolAction(id: "t.sleep", title: "Sleep Display", symbol: "display", help: "Turn the display off now") { QuickToggles.sleepDisplay() },
                ToolAction(id: "t.saver", title: "Screen Saver", symbol: "sparkles.tv", help: "Start the screen saver") { QuickToggles.startScreenSaver() },
                ToolAction(id: "t.trash", title: "Empty Trash", symbol: "trash", help: "Empty the Trash, after asking") { QuickToggles.emptyTrash() },
            ])
        case .keepAwake:
            let on = model.awakeUntil != nil
            let lengths: [(String, String, TimeInterval?)] = [
                ("Until Off", "infinity", nil), ("15 Minutes", "15.circle", 900),
                ("1 Hour", "1.circle", 3600), ("2 Hours", "2.circle", 7200), ("4 Hours", "4.circle", 14400),
            ]
            var actions = lengths.map { title, symbol, length in
                ToolAction(id: "awake.\(title)", title: title, symbol: symbol,
                           help: length == nil ? "Keep the Mac awake until you turn it off" : "Keep the Mac awake for \(title.lowercased())",
                           isOn: on && model.awakeLength == length, closes: false) {
                    model.awakeLength = length
                    KeepAwake.shared.start(for: length)
                }
            }
            if on {
                actions.append(ToolAction(id: "awake.off", title: "Turn Off", symbol: "moon.zzz",
                                          help: "Let the Mac sleep again", closes: false) { KeepAwake.shared.stop() })
            }
            return (KeepAwake.status(model.awakeUntil), actions)
        }
    }

    static func hint(for tool: Tool, model: AppModel, surface: Surface) -> String {
        switch tool {
        case .launcher: return model.pickingApps ? "↩ Pin or Unpin   esc Done" : "↩ Open   ⌘P Pin"
        case .clipboard:
            let main = surface == .panel ? "↩ Paste   ⌥↩ Paste as Plain Text" : "↩ Copy"
            return main + "   ⌘P Pin   ⌘⌫ Delete"
        case .snippets: return (surface == .panel ? "↩ Paste" : "↩ Copy") + "   Type a keyword like ;addr   Right-click to edit"
        case .screenshots: return "\(ShortcutID.shotArea.label) Area or Window   \(ShortcutID.shotScreen.label) Screen   \(ShortcutID.shotScroll.label) Scrolling   \(ShortcutID.shotText.label) Text"
        case .recording: return model.isRecording ? "\(ShortcutID.record.label) Stop" : "\(ShortcutID.record.label) Start or Stop   ↩ Open"
        case .colors: return "\(ShortcutID.color.label) Pick   ↩ Copy as \(ColorPicker.format.rawValue.uppercased())"
        case .windows: return "↩ Move the front window   Shortcuts in Settings > Windows"
        case .toggles: return "↩ Flip the switch   Highlighted ones are on"
        case .knock: return "Knock on the palm rest, lid or desk   Typing is ignored"
        case .mixer: return "↑↓ Choose   ←→ Volume   ↩ Mute   Right-click to reset"
        case .camera: return "↩ Take Photo   M Mirror   The camera turns off when this closes"
        case .info: return "←→ Switch Tabs   Click a value to copy it   ⌘R Refresh"
        case .system: return "↩ Bring to Front   Right-click to quit   Energy over the last 6 seconds"
        case .sound: return "↩ Switch output   The highlighted one is playing now"
        case .timer: return "Type a length like 12, 90s or 1h30m, then ↩"
        case .keepAwake: return "↩ Start   Click Turn Off to let the Mac sleep"
        }
    }
}
