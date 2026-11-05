import Foundation

/// A city the World Clock can show: its name and its time zone.
public struct WorldCity: Hashable, Identifiable, Sendable {
    public let name: String
    /// A time zone identifier, like "America/New_York".
    public let zone: String

    public init(name: String, zone: String) {
        self.name = name
        self.zone = zone
    }

    /// The saved form, "America/New_York|New York".
    public var id: String { zone + "|" + name }

    /// nil for text that is not a saved city, or a zone this Mac does not know.
    public init?(id: String) {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, TimeZone(identifier: parts[0]) != nil else { return nil }
        self.init(name: parts[1], zone: parts[0])
    }

    public var timeZone: TimeZone { TimeZone(identifier: zone) ?? .current }
}

/// Finding cities and writing their time.
public enum WorldClockRules {
    /// Big cities that share a time zone named after another city.
    private static let aliases: [(String, String)] = [
        ("San Francisco", "America/Los_Angeles"), ("Seattle", "America/Los_Angeles"), ("Las Vegas", "America/Los_Angeles"),
        ("Dallas", "America/Chicago"), ("Houston", "America/Chicago"), ("Atlanta", "America/New_York"),
        ("Boston", "America/New_York"), ("Miami", "America/New_York"), ("Washington DC", "America/New_York"),
        ("Montreal", "America/Toronto"), ("Rio de Janeiro", "America/Sao_Paulo"),
        ("Barcelona", "Europe/Madrid"), ("Frankfurt", "Europe/Berlin"), ("Munich", "Europe/Berlin"), ("Milan", "Europe/Rome"),
        ("Cape Town", "Africa/Johannesburg"), ("Abu Dhabi", "Asia/Dubai"), ("Tel Aviv", "Asia/Jerusalem"),
        ("Bengaluru", "Asia/Kolkata"), ("Delhi", "Asia/Kolkata"), ("Kolkata", "Asia/Kolkata"), ("Mumbai", "Asia/Kolkata"),
        ("Beijing", "Asia/Shanghai"), ("Shenzhen", "Asia/Shanghai"), ("Osaka", "Asia/Tokyo"),
    ]

    private static let regions: Set<String> = ["Africa", "America", "Asia", "Atlantic", "Australia", "Europe", "Indian", "Pacific"]

    /// Every city, A to Z: one per time zone on this Mac, plus the aliases.
    public static let catalog: [WorldCity] = {
        let named = TimeZone.knownTimeZoneIdentifiers.compactMap { zone -> WorldCity? in
            let parts = zone.split(separator: "/")
            guard parts.count >= 2, regions.contains(String(parts[0])), let last = parts.last else { return nil }
            return WorldCity(name: last.replacingOccurrences(of: "_", with: " "), zone: zone)
        }
        // Not checked against the list above: it can hold only a zone's old name, like Asia/Calcutta.
        let shared = aliases.filter { TimeZone(identifier: $0.1) != nil }.map { WorldCity(name: $0.0, zone: $0.1) }
        let byName = Dictionary((shared + named).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    public static func city(named name: String) -> WorldCity? {
        catalog.first { $0.name == name }
    }

    /// Offered before anything is typed.
    public static let suggested: [WorldCity] = [
        "New York", "San Francisco", "London", "Paris", "Berlin", "Dubai", "Mumbai", "Singapore", "Tokyo", "Sydney",
    ].compactMap(city(named:))

    /// Cities to add, best match first. An empty query gives the suggestions.
    public static func search(_ query: String, excluding saved: [WorldCity] = [], limit: Int = 30) -> [WorldCity] {
        let candidates = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? suggested
            : catalog.compactMap { city in FuzzyMatch.match(query, in: city.name).map { (city, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        return Array(candidates.filter { !saved.contains($0) }.prefix(limit))
    }

    /// The time there, the way this Mac writes times: "2:32 PM" or "14:32".
    public static func time(_ city: WorldCity, at date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = city.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// How the city differs from here: "3 h ahead", "Tomorrow, 9 h ahead".
    public static func detail(_ city: WorldCity, at date: Date, here: TimeZone = .current) -> String {
        let seconds = city.timeZone.secondsFromGMT(for: date) - here.secondsFromGMT(for: date)
        guard seconds != 0 else { return "Same time as here" }
        let minutes = abs(seconds) / 60
        let length = minutes % 60 == 0 ? "\(minutes / 60) h" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
        let offset = length + (seconds > 0 ? " ahead" : " behind")
        guard !sameDay(date, city.timeZone, here) else { return offset }
        return (seconds > 0 ? "Tomorrow, " : "Yesterday, ") + offset
    }

    private static func sameDay(_ date: Date, _ a: TimeZone, _ b: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        let parts: Set<Calendar.Component> = [.year, .month, .day]
        calendar.timeZone = a
        let first = calendar.dateComponents(parts, from: date)
        calendar.timeZone = b
        let second = calendar.dateComponents(parts, from: date)
        return first.year == second.year && first.month == second.month && first.day == second.day
    }

    /// Seconds until the clock next changes.
    public static func secondsToNextMinute(_ date: Date) -> TimeInterval {
        60 - date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
    }
}
