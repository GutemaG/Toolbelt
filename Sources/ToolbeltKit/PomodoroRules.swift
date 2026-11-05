import Foundation

/// One part of a Pomodoro cycle.
public enum PomodoroPhase: String, Sendable, CaseIterable {
    case focus, shortBreak, longBreak

    public var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }

    public var isBreak: Bool { self != .focus }
}

/// The lengths people choose in Settings.
public struct PomodoroPlan: Sendable, Equatable {
    public var focus: TimeInterval
    public var shortBreak: TimeInterval
    public var longBreak: TimeInterval
    public var rounds: Int

    public init(focus: TimeInterval = 25 * 60, shortBreak: TimeInterval = 5 * 60, longBreak: TimeInterval = 15 * 60, rounds: Int = 4) {
        self.focus = focus
        self.shortBreak = shortBreak
        self.longBreak = longBreak
        self.rounds = rounds
    }

    public func length(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}

public enum PomodoroRules {
    /// What follows a phase. `completed` counts finished focus sessions,
    /// including the one that just ended: every `rounds`th earns the long break.
    public static func next(after phase: PomodoroPhase, completed: Int, rounds: Int) -> PomodoroPhase {
        guard phase == .focus else { return .focus }
        return completed > 0 && completed % max(rounds, 1) == 0 ? .longBreak : .shortBreak
    }

    /// How many dots to fill in a row of `rounds`. A long break shows the full row.
    public static func filledDots(completed: Int, rounds: Int, phase: PomodoroPhase) -> Int {
        let rounds = max(rounds, 1)
        if phase == .longBreak, completed > 0 { return rounds }
        return completed % rounds
    }

    /// 0–1 of the phase gone by, for the ring.
    public static func progress(remaining: TimeInterval, length: TimeInterval) -> Double {
        guard length > 0 else { return 0 }
        return min(max(1 - remaining / length, 0), 1)
    }
}
