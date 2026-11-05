import Foundation

/// The month grid, meeting links and countdowns for the Calendar tool.
public enum CalendarRules {
    /// Six full weeks around the month, starting on the calendar's first
    /// weekday. Always six, so the grid keeps its height between months.
    public static func monthDays(containing date: Date, calendar: Calendar) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let weekday = calendar.component(.weekday, from: month.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -leading, to: month.start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// The grid without its last weeks when they hold only days of the next month.
    public static func trimmed(_ days: [Date], toMonthOf date: Date, calendar: Calendar) -> [Date] {
        var kept = days
        while kept.count > 7, !kept.suffix(7).contains(where: { calendar.isDate($0, equalTo: date, toGranularity: .month) }) {
            kept.removeLast(7)
        }
        return kept
    }

    /// Weekday letters in the order of the grid's columns.
    public static func weekdayLetters(calendar: Calendar) -> [String] {
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { letters[($0 + calendar.firstWeekday - 1) % 7] }
    }

    /// The first video call link in an event's URL, location or notes.
    public static func meetingLink(in texts: [String?]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com", "whereby.com", "meet.jit.si"]
        for text in texts.compactMap({ $0 }) {
            for match in text.matches(of: /https:\/\/[^\s<>"']+/) {
                guard let url = URL(string: String(match.output)), let host = url.host()?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    /// "now", "in 12 min", "in 2 h 5 min", for the next 24 hours. nil after
    /// that, or once it's over.
    public static func countdown(from now: Date, start: Date, end: Date) -> String? {
        if end <= now { return nil }
        if start <= now { return "now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes >= 24 * 60 { return nil }
        if minutes < 60 { return "in \(minutes) min" }
        return minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min"
    }
}
