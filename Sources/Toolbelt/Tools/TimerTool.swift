import AppKit
import SwiftUI
import ToolbeltKit
import UserNotifications

/// Timer: one countdown at a time. The time left shows in the menu bar; at
/// zero it chimes again and again, shows a banner until dismissed, and posts
/// a notification when allowed. The tick runs only while a timer runs.
@MainActor
final class TimerTool {
    static var shared: TimerTool!
    private let model: AppModel
    private var tick: Task<Void, Never>?
    private var chimes: Task<Void, Never>?
    private var sound: NSSound?
    /// Without this, App Nap can hold back the tick of an app with no windows.
    private var activity: NSObjectProtocol?
    private let defaults: UserDefaults? = Store.isOverridden ? nil : .standard

    /// How often the chime repeats, and how many times before it goes quiet.
    /// The banner stays after that.
    private static let chimeGap: Duration = .seconds(3)
    private static let chimeCount = 20

    init(model: AppModel) {
        self.model = model
    }

    var isRunning: Bool { model.timerEnd != nil }
    var isPaused: Bool { model.timerPausedLeft != nil }
    /// Time is up and nobody has dismissed it yet.
    var isRinging: Bool { model.timerDone != nil }
    /// The chime is playing or due again.
    var isChiming: Bool { chimes != nil }

    /// The length last started from the Custom row.
    var customLength: TimeInterval {
        get { defaults?.object(forKey: "timer.custom") as? TimeInterval ?? 600 }
        set { defaults?.set(newValue, forKey: "timer.custom") }
    }

    /// Seconds left, running or paused.
    var remaining: TimeInterval {
        if let left = model.timerPausedLeft { return left }
        guard let end = model.timerEnd else { return 0 }
        return max(0, end.timeIntervalSinceNow)
    }

    func start(_ seconds: TimeInterval) {
        dismiss()
        model.timerPausedLeft = nil
        model.timerLength = seconds
        model.timerEnd = Date.now.addingTimeInterval(seconds)
        askForNotifications()
        startTicking()
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        model.timerPausedLeft = remaining
        tick?.cancel()
        endActivity()
        refresh()
    }

    func resume() {
        guard let left = model.timerPausedLeft else { return }
        model.timerPausedLeft = nil
        model.timerEnd = Date.now.addingTimeInterval(left)
        startTicking()
    }

    /// Adds to the time left; after time is up, it counts down that much again.
    func add(_ seconds: TimeInterval) {
        if isRinging { return start(seconds) }
        if let left = model.timerPausedLeft {
            model.timerPausedLeft = left + seconds
        } else if let end = model.timerEnd {
            model.timerEnd = end.addingTimeInterval(seconds)
        }
        model.timerLength += seconds
        refresh()
    }

    func stop() {
        tick?.cancel()
        tick = nil
        model.timerEnd = nil
        model.timerPausedLeft = nil
        dismiss()
    }

    /// Stops the chime and closes the banner.
    func dismiss() {
        chimes?.cancel()
        chimes = nil
        sound?.stop()
        sound = nil
        model.timerDone = nil
        TimerAlert.hide()
        endActivity()
        refresh()
    }

    private func startTicking() {
        tick?.cancel()
        beginActivity()
        refresh()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.remaining <= 0 { return self.finish() }
                self.refresh()
            }
        }
    }

    private func finish() {
        let length = model.timerLength
        stop()
        model.timerDone = length
        ring()
        TimerAlert.show(length: length)
        refresh()
        guard !Store.isOverridden else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time’s up"
        content.body = "Your \(TimerRules.title(length)) timer is done."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "timer", content: content, trigger: nil))
    }

    private func ring() {
        beginActivity()
        let sound = NSSound(named: "Glass")
        self.sound = sound
        chimes = Task { [weak self] in
            for _ in 0..<Self.chimeCount {
                sound?.stop()
                if sound?.play() != true { NSSound.beep() }
                try? await Task.sleep(for: Self.chimeGap)
                if Task.isCancelled { return }
            }
            self?.chimes = nil
            self?.endActivity()
        }
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "A timer is running")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Asks once, the first time a timer starts. The chime and banner work without it.
    private func askForNotifications() {
        guard !Store.isOverridden else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func refresh() {
        model.timerTick &+= 1
        StatusItems.shared?.refreshIcons()
    }

    /// "12:34" for the menu bar, "Time’s up" until dismissed, nil otherwise.
    var menuBarText: String? {
        if isRinging { return "Time’s up" }
        guard isRunning else { return nil }
        return (isPaused ? "⏸ " : "") + CaptureRules.elapsed(Int(remaining.rounded(.up)))
    }
}

/// The banner at the top of the screen when time is up. It stays until
/// dismissed and leaves the keyboard with the app in front.
@MainActor
enum TimerAlert {
    private(set) static var panel: NSPanel?

    static func show(length: TimeInterval) {
        hide()
        let host = NSHostingView(rootView: TimerAlertView(length: length, isMuted: AudioOutput.isMuted).themed())
        let size = host.fittingSize
        let panel = TimerAlertPanel(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        if let screen = NSScreen.screenWithMouse ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - Space.md))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class TimerAlertPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
}

struct TimerAlertView: View {
    let length: TimeInterval
    let isMuted: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "bell.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .repeating)
                .frame(width: Space.xxl)
            VStack(alignment: .leading, spacing: 2) {
                Text("Time’s Up")
                    .font(.headline)
                Text(isMuted ? "Your Mac is muted, so you can’t hear the chime." : "Your \(TimerRules.title(length)) timer is done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            // The app stays inactive here, which would fade system secondary buttons.
            Button("+1 min") { TimerTool.shared.add(60) }
                .buttonStyle(QuickActionStyle())
                .help("Count down one more minute")
            Button("+5 min") { TimerTool.shared.add(300) }
                .buttonStyle(QuickActionStyle())
                .help("Count down five more minutes")
            Button("Done") { TimerTool.shared.dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .help("Stop the chime and close this")
        }
        .fixedSize()
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time’s up")
    }
}

/// Picks any length with menus, under the preset tiles.
struct TimerCustomRow: View {
    @State private var hours: Int
    @State private var minutes: Int
    @State private var seconds: Int

    init() {
        let parts = TimerRules.parts(TimerTool.shared.customLength)
        _hours = State(initialValue: parts.hours)
        _minutes = State(initialValue: parts.minutes)
        _seconds = State(initialValue: parts.seconds)
    }

    private var length: TimeInterval { TimeInterval(hours * 3600 + minutes * 60 + seconds) }

    var body: some View {
        HStack(spacing: Space.sm) {
            Text("Custom")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.sm)
            picker("Hours", unit: "h", in: 0..<24, selection: $hours)
            picker("Minutes", unit: "min", in: 0..<60, selection: $minutes)
            picker("Seconds", unit: "s", in: 0..<60, selection: $seconds)
            Button("Start") {
                TimerTool.shared.customLength = length
                TimerTool.shared.start(length)
            }
            .buttonStyle(.borderedProminent)
            .disabled(length == 0)
            .help("Count down this length")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }

    private func picker(_ title: String, unit: String, in range: Range<Int>, selection: Binding<Int>) -> some View {
        // A plain Picker fades like a disabled one while the app is inactive.
        Menu {
            Picker(title, selection: selection) {
                ForEach(range, id: \.self) { Text("\($0) \(unit)").tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Space.xs) {
                Text("\(selection.wrappedValue) \(unit)")
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(QuickActionStyle())
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }
}
