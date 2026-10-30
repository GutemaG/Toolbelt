import Foundation

/// Reading a timer length typed into the search field.
public enum TimerRules {
    /// "12" or "12m" → 12 minutes, "90s", "1h", "1h30m", "1:30" (minutes:seconds).
    /// nil for anything else, or for zero.
    public static func parse(_ text: String) -> TimeInterval? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return nil }
        if let minutes = Double(t) { return minutes > 0 ? minutes * 60 : nil }
        let clock = t.split(separator: ":")
        if clock.count == 2, let m = Int(clock[0]), let s = Int(clock[1]), s < 60 {
            let total = TimeInterval(m * 60 + s)
            return total > 0 ? total : nil
        }
        var total: TimeInterval = 0, number = "", sawUnit = false
        for ch in t {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else {
                guard let value = Double(number) else { return nil }
                switch ch {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                default: return nil
                }
                number = ""
                sawUnit = true
            }
        }
        guard sawUnit, number.isEmpty, total > 0 else { return nil }
        return total
    }

    /// "25 min", "1 h 30 min", "45 s" for tile titles.
    public static func title(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 { parts.append("\(s) s") }
        return parts.isEmpty ? "0 s" : parts.joined(separator: " ")
    }
}
