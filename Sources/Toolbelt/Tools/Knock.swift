import AppKit
import SwiftUI
import ToolbeltKit

/// What a group of knocks does. Each runs a Toolbelt action directly, so no
/// keystrokes are faked into other apps.
enum KnockAction: String, CaseIterable, Identifiable {
    case nothing, playPause, nextTrack, mute, screenshotArea, screenshotScreen, copyText, record, pickColor, launcher, clipboard, lockScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: "Do Nothing"
        case .playPause: "Play or Pause"
        case .nextTrack: "Next Track"
        case .mute: "Mute or Unmute"
        case .screenshotArea: "Screenshot of an Area"
        case .screenshotScreen: "Screenshot of the Screen"
        case .copyText: "Copy Text from the Screen"
        case .record: "Start or Stop Recording"
        case .pickColor: "Pick a Color"
        case .launcher: "Open Launcher"
        case .clipboard: "Open Clipboard"
        case .lockScreen: "Lock Screen"
        }
    }

    var symbol: String {
        switch self {
        case .nothing: "circle.dashed"
        case .playPause: "playpause"
        case .nextTrack: "forward"
        case .mute: "speaker.slash"
        case .screenshotArea: "rectangle.dashed"
        case .screenshotScreen: "desktopcomputer"
        case .copyText: "text.viewfinder"
        case .record: "record.circle"
        case .pickColor: "eyedropper"
        case .launcher: "magnifyingglass"
        case .clipboard: "doc.on.clipboard"
        case .lockScreen: "lock"
        }
    }

    func run() {
        switch self {
        case .nothing: break
        case .playPause: Self.mediaKey(16) // NX_KEYTYPE_PLAY
        case .nextTrack: Self.mediaKey(17) // NX_KEYTYPE_NEXT
        case .mute: AudioOutput.setMuted(!AudioOutput.isMuted)
        case .screenshotArea: ShortcutID.shotArea.run()
        case .screenshotScreen: ShortcutID.shotScreen.run()
        case .copyText: ShortcutID.shotText.run()
        case .record: ShortcutID.record.run()
        case .pickColor: ShortcutID.color.run()
        case .launcher: ShortcutID.launcher.run()
        case .clipboard: ShortcutID.clipboard.run()
        case .lockScreen: QuickToggles.lockScreen()
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

/// Knock: one, two or three knocks on the MacBook run an action. Listens
/// only while the tool is on and the screen is awake.
@Observable
final class Knock {
    static let shared = Knock()
    static let sensitivityKey = "knock.sensitivity"
    static let messageKey = "knock.message"

    enum State: Equatable {
        case off, listening, unavailable
    }

    /// The last knock or ignored jolt, for the tool page and tuning.
    struct Heard: Equatable {
        let event: KnockDetector.Event
        let action: KnockAction?
        let at: Date
    }

    private(set) var state: State = .off
    private(set) var heard: Heard?
    private(set) var actions: [KnockAction]
    var sensitivity: Double {
        didSet {
            sensor?.sensitivity = sensitivity
            if !isSimulated { UserDefaults.standard.set(sensitivity, forKey: Self.sensitivityKey) }
        }
    }
    /// Test and snapshot runs never read the sensor.
    let isSimulated = Store.isOverridden

    @ObservationIgnored private var sensor: KnockSensor?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        sensitivity = Store.isOverridden ? 0.6 : defaults.object(forKey: Self.sensitivityKey) as? Double ?? 0.6
        let fallback: [KnockAction] = [.nothing, .playPause, .screenshotArea]
        actions = (1...3).map { count in
            Store.isOverridden ? fallback[count - 1]
                : defaults.string(forKey: "knock.\(count)").flatMap(KnockAction.init(rawValue:)) ?? fallback[count - 1]
        }
        // A sleeping screen means nobody is knocking: stop reading to save power.
        let center = NSWorkspace.shared.notificationCenter
        for (name, awake) in [(NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
                              (NSWorkspace.willSleepNotification, false), (NSWorkspace.didWakeNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { awake ? self?.resume() : self?.pause() }
            })
        }
    }

    func action(for count: Int) -> KnockAction { actions[count - 1] }

    func setAction(_ action: KnockAction, for count: Int) {
        actions[count - 1] = action
        if !isSimulated { UserDefaults.standard.set(action.rawValue, forKey: "knock.\(count)") }
    }

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
        if case .knocks(let count) = event {
            action = self.action(for: count)
            action?.run()
            if UserDefaults.standard.object(forKey: Self.messageKey) as? Bool ?? true {
                Toast.show(Self.describe(event, action: action), symbol: action?.symbol ?? "hand.tap")
            }
        }
        heard = Heard(event: event, action: action, at: .now)
    }

    static func describe(_ event: KnockDetector.Event, action: KnockAction?) -> String {
        switch event {
        case .knocks(let count):
            let knocks = count == 1 ? "1 knock" : "\(count) knocks"
            guard let action, action != .nothing else { return knocks }
            return "\(knocks): \(action.title)"
        case .ignored(let reason):
            return "Ignored: \(reason.rawValue)"
        }
    }
}
