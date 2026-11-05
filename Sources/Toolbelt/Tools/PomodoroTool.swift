import AppKit
import SwiftUI
import ToolbeltKit
import UserNotifications

/// Pomodoro: focus and break in turn, with a long break every few rounds. The
/// time left shows in the menu bar. When a part ends it chimes and asks, with a
/// banner, to start the next, unless Start the next part by itself is on.
@Observable
final class PomodoroTool {
    static let shared = PomodoroTool()

    private(set) var phase: PomodoroPhase = .focus
    private(set) var end: Date?
    private(set) var pausedLeft: TimeInterval?
    /// Finished focus sessions in this run of rounds.
    private(set) var completed = 0
    /// A part just ended and the next is waiting to start.
    private(set) var isRinging = false
    /// Bumped every second while running, so views redraw the time left.
    private(set) var tick = 0

    var plan: PomodoroPlan { didSet { save() } }
    var startsNextByItself: Bool { didSet { save() } }

    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private let chime = Chime()
    /// Without this, App Nap can hold back the tick of an app with no windows.
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults? = Store.isOverridden ? nil : .standard

    /// How many times a chime repeats while the next part waits.
    private static let chimeCount = 5

    private init() {
        let saved = Store.isOverridden ? nil : UserDefaults.standard
        let fresh = PomodoroPlan()
        func length(_ key: String, _ standard: TimeInterval) -> TimeInterval { saved?.object(forKey: key) as? TimeInterval ?? standard }
        plan = PomodoroPlan(focus: length("pomodoro.focus", fresh.focus), shortBreak: length("pomodoro.short", fresh.shortBreak),
                            longBreak: length("pomodoro.long", fresh.longBreak), rounds: saved?.object(forKey: "pomodoro.rounds") as? Int ?? fresh.rounds)
        startsNextByItself = saved?.bool(forKey: "pomodoro.auto") ?? false
    }

    private func save() {
        defaults?.set(plan.focus, forKey: "pomodoro.focus")
        defaults?.set(plan.shortBreak, forKey: "pomodoro.short")
        defaults?.set(plan.longBreak, forKey: "pomodoro.long")
        defaults?.set(plan.rounds, forKey: "pomodoro.rounds")
        defaults?.set(startsNextByItself, forKey: "pomodoro.auto")
    }

    var isRunning: Bool { end != nil }
    var isPaused: Bool { pausedLeft != nil }
    var isActive: Bool { isRunning || isPaused }
    var isChiming: Bool { chime.isPlaying }

    var length: TimeInterval { plan.length(of: phase) }

    /// Seconds left: running, paused, or the whole part before it starts.
    var remaining: TimeInterval {
        if let pausedLeft { return pausedLeft }
        guard let end else { return length }
        return max(0, end.timeIntervalSinceNow)
    }

    /// Focus sessions finished today, kept across restarts.
    var finishedToday: Int {
        get {
            guard let defaults else { return sessionsInMemory }
            return defaults.string(forKey: "pomodoro.day") == Self.today ? defaults.integer(forKey: "pomodoro.count") : 0
        }
        set {
            sessionsInMemory = newValue
            defaults?.set(Self.today, forKey: "pomodoro.day")
            defaults?.set(newValue, forKey: "pomodoro.count")
        }
    }
    private var sessionsInMemory = 0

    private static var today: String { Date.now.formatted(.iso8601.year().month().day()) }

    /// Start, Pause or Resume, whichever fits.
    func toggle() {
        if isPaused { resume() } else if isRunning { pause() } else { start() }
    }

    func start() {
        stopRinging()
        pausedLeft = nil
        end = Date.now.addingTimeInterval(length)
        startTicking()
    }

    func pause() {
        guard isRunning else { return }
        pausedLeft = remaining
        end = nil
        stopTicking()
        refresh()
    }

    func resume() {
        guard let left = pausedLeft else { return }
        pausedLeft = nil
        end = Date.now.addingTimeInterval(left)
        startTicking()
    }

    /// A focus session of a length typed into the search field, which it also
    /// makes the new length.
    func startFocus(length: TimeInterval) {
        plan.focus = length
        stopTicking()
        stopRinging()
        phase = .focus
        start()
    }

    /// Moves to the next part without counting this one as finished.
    func skip() {
        stopTicking()
        stopRinging()
        end = nil
        pausedLeft = nil
        phase = phase == .focus ? .shortBreak : .focus
        refresh()
    }

    /// Back to the first focus session of a new run of rounds.
    func reset() {
        stopTicking()
        stopRinging()
        end = nil
        pausedLeft = nil
        phase = .focus
        completed = 0
        refresh()
    }

    /// Stops the chime and the banner. The next part stays ready to start.
    func later() {
        stopRinging()
        refresh()
    }

    /// The part ran out. Internal so the self-test needn't wait for one.
    func finish() {
        let ended = phase
        stopTicking()
        end = nil
        pausedLeft = nil
        if ended == .focus {
            completed += 1
            finishedToday += 1
        }
        phase = PomodoroRules.next(after: ended, completed: completed, rounds: plan.rounds)
        notify(ended: ended)
        if startsNextByItself {
            chime.play(times: 1)
            end = Date.now.addingTimeInterval(length)
            startTicking()
        } else {
            isRinging = true
            chime.play(times: Self.chimeCount)
            PomodoroAlert.show(ended: ended, next: phase, length: length)
            refresh()
        }
    }

    private func stopRinging() {
        isRinging = false
        chime.stop()
        PomodoroAlert.hide()
    }

    private func startTicking() {
        ticking?.cancel()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "A Pomodoro is running")
        }
        refresh()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.remaining <= 0 { return self.finish() }
                self.refresh()
            }
        }
    }

    private func stopTicking() {
        ticking?.cancel()
        ticking = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func refresh() {
        tick &+= 1
        StatusItems.shared?.refreshIcons()
    }

    private func notify(ended: PomodoroPhase) {
        guard !Store.isOverridden else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = ended == .focus ? "Focus Done" : "Break Over"
        content.body = "Next: \(phase.title), \(TimerRules.title(length))."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pomodoro", content: content, trigger: nil))
    }

    /// "Focus 24:10" for the menu bar, "Break 4:10", nil when nothing is going on.
    var menuBarText: String? {
        if isRinging { return phase == .focus ? "Break over" : "Focus done" }
        guard isActive else { return nil }
        let word = phase.isBreak ? "Break" : "Focus"
        return (isPaused ? "⏸ " : "") + "\(word) " + CaptureRules.elapsed(Int(remaining.rounded(.up)))
    }
}

extension PomodoroPhase {
    var tint: Color {
        switch self {
        case .focus: .orange
        case .shortBreak: .green
        case .longBreak: .teal
        }
    }

    var startTitle: String { isBreak ? "Start Break" : "Start Focus" }
}

// MARK: The banner

/// Asks to start the next part. It stays until answered and leaves the keyboard
/// with the app in front, like Timer's.
@MainActor
enum PomodoroAlert {
    private(set) static var panel: NSPanel?

    static func show(ended: PomodoroPhase, next: PomodoroPhase, length: TimeInterval) {
        hide()
        panel = TimerAlert.present(PomodoroAlertView(ended: ended, next: next, length: length, isMuted: AudioOutput.isMuted).themed(),
                                   below: TimerAlert.panel)
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct PomodoroAlertView: View {
    let ended: PomodoroPhase
    let next: PomodoroPhase
    let length: TimeInterval
    let isMuted: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: ended == .focus ? "checkmark.circle.fill" : "bell.fill")
                .font(.title2)
                .foregroundStyle(next.tint)
                .frame(width: Space.xxl)
            VStack(alignment: .leading, spacing: 2) {
                Text(ended == .focus ? "Focus Done" : "Break Over")
                    .font(.headline)
                Text(isMuted ? "Your Mac is muted, so you can’t hear the chime." : "Next: \(next.title), \(TimerRules.title(length)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            // The app stays inactive here, which would fade system secondary buttons.
            Button("Later") { PomodoroTool.shared.later() }
                .buttonStyle(QuickActionStyle())
                .help("Stop the chime; start the next part when you’re ready")
            Button(next.startTitle) { PomodoroTool.shared.start() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(TintedActionStyle(tint: next.tint))
                .help("Start the next part now")
        }
        .fixedSize()
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ended == .focus ? "Focus done" : "Break over")
    }
}

// MARK: The tool

struct PomodoroView: View {
    private var pomodoro: PomodoroTool { .shared }

    var body: some View {
        // Reading the tick makes the view redraw the time left every second.
        let _ = pomodoro.tick
        VStack(spacing: Space.lg) {
            ring
                .frame(width: Space.section * 5, height: Space.section * 5)
            dots
            buttons
            Text(pomodoro.finishedToday == 1 ? "1 focus session today" : "\(pomodoro.finishedToday) focus sessions today")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ring: some View {
        let tint = pomodoro.phase.tint
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: Space.md)
            Circle()
                .trim(from: 0, to: PomodoroRules.progress(remaining: pomodoro.remaining, length: pomodoro.length))
                .stroke(tint, style: StrokeStyle(lineWidth: Space.md, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: Space.xs) {
                Text(CaptureRules.elapsed(Int(pomodoro.remaining.rounded(.up))))
                    .font(.system(.largeTitle, weight: .bold))
                    .monospacedDigit()
                Text(pomodoro.isPaused ? "Paused" : pomodoro.phase.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pomodoro.phase.title)
        .accessibilityValue(CaptureRules.elapsed(Int(pomodoro.remaining.rounded(.up))) + " left")
    }

    private var dots: some View {
        let filled = PomodoroRules.filledDots(completed: pomodoro.completed, rounds: pomodoro.plan.rounds, phase: pomodoro.phase)
        return HStack(spacing: Space.sm) {
            ForEach(0..<max(pomodoro.plan.rounds, 1), id: \.self) { index in
                Circle()
                    .fill(index < filled ? AnyShapeStyle(PomodoroPhase.focus.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: Space.sm, height: Space.sm)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(filled) of \(pomodoro.plan.rounds) rounds done")
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            Button("Reset", systemImage: "arrow.counterclockwise") { pomodoro.reset() }
                .buttonStyle(QuickActionStyle())
                .help("Back to the first round (⌘R)")
            Button(primaryTitle, systemImage: primarySymbol) { pomodoro.toggle() }
                .buttonStyle(TintedActionStyle(tint: pomodoro.phase.tint))
                .help("Start or pause (↩)")
            Button("Skip", systemImage: "forward.end") { pomodoro.skip() }
                .buttonStyle(QuickActionStyle())
                .help("Go to the next part, without counting this one (⌘→)")
        }
    }

    private var primaryTitle: String {
        if pomodoro.isPaused { return "Resume" }
        return pomodoro.isRunning ? "Pause" : pomodoro.phase.startTitle
    }

    private var primarySymbol: String { pomodoro.isRunning ? "pause.fill" : "play.fill" }
}

/// Settings > Pomodoro.
struct PomodoroOptions: View {
    @Bindable private var pomodoro = PomodoroTool.shared

    var body: some View {
        Section {
            minutes("Focus", \.focus, in: 1...180)
            minutes("Short break", \.shortBreak, in: 1...60)
            minutes("Long break", \.longBreak, in: 1...120)
            Stepper(value: $pomodoro.plan.rounds, in: 1...12) {
                LabeledContent("Rounds before a long break", value: "\(pomodoro.plan.rounds)")
            }
            Toggle(isOn: $pomodoro.startsNextByItself) {
                Text("Start the next part by itself")
                Text("Chimes once and keeps going, without asking.")
            }
        } footer: {
            Text("When a part ends, a chime repeats a few times and a banner stays until you answer. A new length applies from the next time a part starts. Type a length in the search field, like 25 or 1h, to start a focus session of that length.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func minutes(_ title: String, _ path: WritableKeyPath<PomodoroPlan, TimeInterval>, in range: ClosedRange<Int>) -> some View {
        let value = Binding<Int>(get: { Int(pomodoro.plan[keyPath: path] / 60) },
                                 set: { pomodoro.plan[keyPath: path] = TimeInterval($0) * 60 })
        return Stepper(value: value, in: range) {
            LabeledContent(title, value: "\(value.wrappedValue) min")
        }
    }
}
