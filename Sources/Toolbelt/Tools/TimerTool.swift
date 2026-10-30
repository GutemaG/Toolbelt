import AppKit
import ToolbeltKit
import UserNotifications

/// Timer: one countdown at a time. The time left shows in the menu bar; at
/// zero it chimes, shows a toast, and posts a notification when allowed.
/// The tick runs only while a timer runs.
@MainActor
final class TimerTool {
    static var shared: TimerTool!
    private let model: AppModel
    private var tick: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    var isRunning: Bool { model.timerEnd != nil }
    var isPaused: Bool { model.timerPausedLeft != nil }

    /// Seconds left, running or paused.
    var remaining: TimeInterval {
        if let left = model.timerPausedLeft { return left }
        guard let end = model.timerEnd else { return 0 }
        return max(0, end.timeIntervalSinceNow)
    }

    func start(_ seconds: TimeInterval) {
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
        refresh()
    }

    func resume() {
        guard let left = model.timerPausedLeft else { return }
        model.timerPausedLeft = nil
        model.timerEnd = Date.now.addingTimeInterval(left)
        startTicking()
    }

    func add(_ seconds: TimeInterval) {
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
        refresh()
    }

    private func startTicking() {
        tick?.cancel()
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
        let length = TimerRules.title(model.timerLength)
        stop()
        NSSound(named: "Glass")?.play()
        Toast.show("Time’s up: \(length)", symbol: "timer")
        guard !Store.isOverridden else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time’s up"
        content.body = "Your \(length) timer is done."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "timer", content: content, trigger: nil))
    }

    /// Asks once, the first time a timer starts. The chime and toast work without it.
    private func askForNotifications() {
        guard !Store.isOverridden else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func refresh() {
        model.timerTick &+= 1
        StatusItems.shared?.refreshIcons()
    }

    /// "12:34" for the menu bar, nil when no timer runs.
    var menuBarText: String? {
        guard isRunning else { return nil }
        return (isPaused ? "⏸ " : "") + CaptureRules.elapsed(Int(remaining.rounded(.up)))
    }
}
