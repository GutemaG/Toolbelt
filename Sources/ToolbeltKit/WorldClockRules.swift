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

    /// The flag of the zone's country, "🇺🇸". Empty for a zone with no country.
    public var flag: String { WorldClockRules.flag(zone: zone) }
}

/// What a city's people are likely doing at some hour.
public enum DayPeriod: String, CaseIterable, Sendable {
    case work, edge, night

    public var title: String {
        switch self {
        case .work: "Work"
        case .edge: "Morning, Evening"
        case .night: "Night"
        }
    }

    public var symbol: String {
        switch self {
        case .work: "sun.max.fill"
        case .edge: "sunset.fill"
        case .night: "moon.fill"
        }
    }

    /// 9 to 5 is work, 7 to 9 and 5 to 10 are morning and evening, the rest is night.
    public static func at(hour: Int) -> DayPeriod {
        switch hour {
        case 9..<17: .work
        case 7..<9, 17..<22: .edge
        default: .night
        }
    }
}

/// How the city in the menu bar is written.
public enum WorldClockMenuStyle: String, CaseIterable, Identifiable, Sendable {
    case flagAndTime, flagCityAndTime, cityAndTime, timeOnly, cityAboveTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flagAndTime: "Flag and Time"
        case .flagCityAndTime: "Flag, City and Time"
        case .cityAndTime: "City and Time"
        case .timeOnly: "Time Only"
        case .cityAboveTime: "City Above Time"
        }
    }

    public func text(_ city: WorldCity, at date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let time = WorldClockRules.time(city, at: date, locale: locale)
        switch self {
        case .flagAndTime: return [city.flag, time].filter { !$0.isEmpty }.joined(separator: " ")
        case .flagCityAndTime: return [city.flag, city.name, time].filter { !$0.isEmpty }.joined(separator: " ")
        case .cityAndTime: return city.name + " " + time
        case .timeOnly: return time
        case .cityAboveTime: return city.name + "\n" + time
        }
    }
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

    /// The difference from here at that moment: "+3h", "-5h 30m", nil when the same.
    public static func difference(_ zone: TimeZone, at date: Date, here: TimeZone = .current) -> String? {
        let seconds = zone.secondsFromGMT(for: date) - here.secondsFromGMT(for: date)
        return seconds == 0 ? nil : signedLength(seconds)
    }

    /// "+5h 15m", "-30m". Minutes are left out on the hour.
    static func signedLength(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        let parts = [minutes >= 60 ? "\(minutes / 60)h" : nil, minutes % 60 != 0 ? "\(minutes % 60)m" : nil].compactMap { $0 }
        return (seconds < 0 ? "-" : "+") + parts.joined(separator: " ")
    }

    /// The day shown there at `date`, counted from today here: "Today", "Tomorrow".
    public static func day(_ zone: TimeZone, at date: Date, now: Date, here: TimeZone = .current) -> String {
        let days = dayNumber(date, in: zone) - dayNumber(now, in: here)
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return days > 0 ? "In \(days) days" : "\(-days) days ago"
        }
    }

    private static func dayNumber(_ date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        calendar.timeZone = .gmt
        return Int((calendar.date(from: parts)?.timeIntervalSince1970 ?? 0) / 86_400)
    }

    /// The line under a city: "Tomorrow, +9h", or "Today" with no difference.
    public static func detail(_ zone: TimeZone, at date: Date, now: Date, here: TimeZone = .current) -> String {
        [day(zone, at: date, now: now, here: here), difference(zone, at: date, here: here)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// "UTC-5", "UTC+5:30", "UTC".
    public static func utc(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "UTC" }
        let minutes = abs(seconds) / 60
        return "UTC" + (seconds < 0 ? "-" : "+") + "\(minutes / 60)" + (minutes % 60 == 0 ? "" : String(format: ":%02d", minutes % 60))
    }

    // MARK: Flags

    /// Old zone names macOS still lists, which its country file only has under their new names.
    private static let oldZones: [String: String] = [
        "America/Godthab": "GL", "America/Montreal": "CA", "America/Nipigon": "CA", "America/Pangnirtung": "CA",
        "America/Rainy_River": "CA", "America/Santa_Isabel": "MX", "America/Shiprock": "US", "America/Thunder_Bay": "CA",
        "America/Yellowknife": "CA", "Asia/Calcutta": "IN", "Asia/Choibalsan": "MN", "Asia/Chongqing": "CN",
        "Asia/Harbin": "CN", "Asia/Kashgar": "CN", "Asia/Katmandu": "NP", "Asia/Rangoon": "MM", "Australia/Currie": "AU",
        "Europe/Kiev": "UA", "Europe/Uzhgorod": "UA", "Europe/Zaporozhye": "UA", "Pacific/Enderbury": "KI",
        "Pacific/Johnston": "UM", "Pacific/Ponape": "FM", "Pacific/Truk": "FM",
    ]

    /// Zone to country code, from the list that ships with macOS.
    private static let countries: [String: String] = {
        let file = (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
        var result = oldZones
        for line in file.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t")
            if columns.count >= 3 { result[String(columns[2])] = String(columns[0]) }
        }
        return result
    }()

    static func flag(zone: String) -> String {
        guard let code = countries[zone] else { return "" }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
    }

    // MARK: Time travel

    /// How far the slider reaches each way, in seconds.
    public static let travelReach: TimeInterval = 24 * 3600
    /// One step of the slider or the arrow keys, in seconds.
    public static let travelStep: TimeInterval = 15 * 60

    /// The moment the slider points at. Off now, it lands on a quarter hour, so
    /// you read 3:00 PM and not 2:53 PM.
    public static func traveled(now: Date, by shift: TimeInterval) -> Date {
        guard shift != 0 else { return now }
        let seconds = now.timeIntervalSince1970 + shift
        return Date(timeIntervalSince1970: (seconds / travelStep).rounded() * travelStep)
    }

    /// "Now", or "+5h 15m from now".
    public static func travelLabel(_ shift: TimeInterval) -> String {
        shift == 0 ? "Now" : signedLength(Int(shift)) + " from now"
    }

    /// One stretch of the same period along the slider. Start and end run from 0 to 1.
    public struct DaySegment: Equatable, Sendable {
        public let period: DayPeriod
        public let start: Double
        public var end: Double
    }

    public static func period(_ zone: TimeZone, at date: Date) -> DayPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return .at(hour: calendar.component(.hour, from: date))
    }

    /// The periods in a zone across the slider's whole reach around `now`.
    public static func daySegments(now: Date, in zone: TimeZone) -> [DaySegment] {
        let steps = Int(travelReach * 2 / travelStep)
        var segments: [DaySegment] = []
        for step in 0..<steps {
            let date = now.addingTimeInterval(-travelReach + Double(step) * travelStep)
            let period = period(zone, at: date)
            let start = Double(step) / Double(steps), end = Double(step + 1) / Double(steps)
            if segments.last?.period == period {
                segments[segments.count - 1].end = end
            } else {
                segments.append(DaySegment(period: period, start: start, end: end))
            }
        }
        return segments
    }

    /// Seconds until the clock next changes.
    public static func secondsToNextMinute(_ date: Date) -> TimeInterval {
        60 - date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
    }
}
