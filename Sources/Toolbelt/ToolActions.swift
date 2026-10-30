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
        case .launcher, .clipboard:
            return nil
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
            return ("Capture", modes + [text])
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
        case .screenshots: return "\(ShortcutID.shotArea.label) Area or Window   \(ShortcutID.shotScreen.label) Screen   \(ShortcutID.shotText.label) Text"
        case .recording: return model.isRecording ? "\(ShortcutID.record.label) Stop" : "\(ShortcutID.record.label) Start or Stop   ↩ Open"
        case .colors: return "\(ShortcutID.color.label) Pick   ↩ Copy as \(ColorPicker.format.rawValue.uppercased())"
        case .windows: return "↩ Move the front window   Shortcuts in Settings > Windows"
        case .timer: return "Type a length like 12, 90s or 1h30m, then ↩"
        case .keepAwake: return "↩ Start   Click Turn Off to let the Mac sleep"
        }
    }
}
