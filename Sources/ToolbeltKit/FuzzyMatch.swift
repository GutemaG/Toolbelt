import Foundation

/// How well a typed query matches a name. Logic lives in this library so
/// tests can run it without the app.
public struct FuzzyMatch: Comparable, Sendable {
    /// 4 name starts with the query, 3 a word starts with it, 2 the name
    /// contains it, 1 the letters appear in order. Higher is better.
    public let tier: Int
    /// Ranks matches inside one tier: word starts hit, fewer gaps, shorter names.
    public let points: Int

    public static func < (lhs: FuzzyMatch, rhs: FuzzyMatch) -> Bool {
        (lhs.tier, lhs.points) < (rhs.tier, rhs.points)
    }

    /// nil when the query's letters do not all appear in order in the name.
    /// Case, accents, and spaces in the query are ignored.
    public static func match(_ query: String, in name: String) -> FuzzyMatch? {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        let n = Array(fold(name))
        guard !q.isEmpty else { return FuzzyMatch(tier: 0, points: 0) }
        let shortness = max(0, 100 - n.count)

        let qs = String(q), ns = String(n)
        if ns.hasPrefix(qs) { return FuzzyMatch(tier: 4, points: shortness) }
        let words = ns.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(qs) }) { return FuzzyMatch(tier: 3, points: shortness) }
        if ns.contains(qs) { return FuzzyMatch(tier: 2, points: shortness) }

        // Letters in order. Prefer letters that start a word ("vsc" -> Visual Studio Code).
        var points = 0, qi = 0, last = -1
        for (i, ch) in n.enumerated() where qi < q.count && ch == q[qi] {
            let wordStart = i == 0 || !(n[i - 1].isLetter || n[i - 1].isNumber)
            points += wordStart ? 30 : 10
            if last >= 0 { points -= min(i - last - 1, 10) }
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return FuzzyMatch(tier: 1, points: points * 100 + shortness)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// One app the launcher can open, with how often it was opened from Toolbelt.
public struct LaunchCandidate: Sendable, Equatable {
    public var name: String
    public var path: String
    public var launchCount: Int
    public var lastLaunched: Date?

    public init(name: String, path: String, launchCount: Int = 0, lastLaunched: Date? = nil) {
        self.name = name
        self.path = path
        self.launchCount = launchCount
        self.lastLaunched = lastLaunched
    }
}

public enum LauncherRanking {
    /// Matching apps, best first: match quality, then how often and how
    /// recently they were opened, then the finer match points, then name.
    /// An empty query returns the most used apps ("Frequent").
    public static func rank(_ apps: [LaunchCandidate], query: String, frequentLimit: Int = 8) -> [LaunchCandidate] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return apps.filter { $0.launchCount > 0 }
                .sorted(by: usageFirst)
                .prefix(frequentLimit)
                .map { $0 }
        }
        return apps.compactMap { app in FuzzyMatch.match(query, in: app.name).map { (app, $0) } }
            .sorted { a, b in
                if a.1.tier != b.1.tier { return a.1.tier > b.1.tier }
                if a.0.launchCount != b.0.launchCount || a.0.lastLaunched != b.0.lastLaunched {
                    return usageFirst(a.0, b.0)
                }
                if a.1.points != b.1.points { return a.1.points > b.1.points }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    static func usageFirst(_ a: LaunchCandidate, _ b: LaunchCandidate) -> Bool {
        if a.launchCount != b.launchCount { return a.launchCount > b.launchCount }
        let da = a.lastLaunched ?? .distantPast, db = b.lastLaunched ?? .distantPast
        if da != db { return da > db }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
