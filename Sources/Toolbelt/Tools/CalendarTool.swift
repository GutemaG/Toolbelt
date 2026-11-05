import AppKit
import EventKit
import SwiftUI
import ToolbeltKit

/// One event, read from the Calendar database. Toolbelt never changes events.
struct CalendarEvent: Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: Color
    var location: String?
    var link: URL?
    /// Opens the event in Calendar.
    var itemID: String?

    var time: String {
        if isAllDay { return "All day" }
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// Calendar: the month and your events. The month works without permission;
/// events are asked for only when you click to allow them. Test and snapshot
/// runs use sample events and never touch the real calendars.
@Observable
final class CalendarTool {
    static let shared = CalendarTool()

    enum Access { case allowed, notAsked, denied }

    private(set) var month = Date.now
    private(set) var selected = Calendar.current.startOfDay(for: .now)
    private(set) var events: [CalendarEvent] = []
    /// The coming year, for the next event and for search.
    private(set) var upcoming: [CalendarEvent] = []
    var access: Access = .notAsked

    @ObservationIgnored private lazy var store = EKEventStore()
    @ObservationIgnored private var changes: NSObjectProtocol?
    private var calendar: Calendar { .current }

    var days: [Date] { CalendarRules.monthDays(containing: month, calendar: calendar) }

    /// Every time Calendar opens it starts on today.
    func opened() {
        goToToday()
        if !Store.isOverridden, changes == nil {
            changes = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarTool.shared.reload() }
            }
        }
        reload()
    }

    func reload() {
        if Store.isOverridden {
            if usesSamples { access = .allowed }
            let all = Self.samples()
            events = all
            upcoming = all.filter { $0.end > .now }
            return
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .allowed
        case .notDetermined: access = .notAsked
        default: access = .denied
        }
        guard access == .allowed, let first = days.first, let last = days.last,
              let gridEnd = calendar.date(byAdding: .day, value: 1, to: last),
              let yearEnd = calendar.date(byAdding: .year, value: 1, to: .now) else {
            events = []
            upcoming = []
            return
        }
        events = fetch(from: first, to: gridEnd)
        upcoming = fetch(from: .now, to: yearEnd)
    }

    /// Snapshots turn this off to show the screen that asks for access.
    @ObservationIgnored var usesSamples = true

    private func fetch(from start: Date, to end: Date) -> [CalendarEvent] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.compareStartDate(with: $1) == .orderedAscending }
            .map { event in
                CalendarEvent(id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                              title: event.title ?? "Untitled", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                              color: event.calendar.cgColor.map(Color.init(cgColor:)) ?? .secondary,
                              location: event.location?.isEmpty == false ? event.location : nil,
                              link: CalendarRules.meetingLink(in: [event.url?.absoluteString, event.location, event.notes]),
                              itemID: event.calendarItemIdentifier)
            }
    }

    /// Asks for access, or opens System Settings when it was turned down.
    func allow() {
        if access == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return
        }
        NSApp.activate()
        Task {
            _ = try? await store.requestFullAccessToEvents()
            reload()
        }
    }

    func select(_ day: Date) {
        selected = calendar.startOfDay(for: day)
        if !calendar.isDate(day, equalTo: month, toGranularity: .month) {
            month = day
            reload()
        }
    }

    func move(days count: Int) {
        if let day = calendar.date(byAdding: .day, value: count, to: selected) { select(day) }
    }

    func moveMonth(by count: Int) {
        guard let day = calendar.date(byAdding: .month, value: count, to: selected) else { return }
        selected = calendar.startOfDay(for: day)
        month = day
        reload()
    }

    func goToToday() {
        month = .now
        selected = calendar.startOfDay(for: .now)
        reload()
    }

    func events(on day: Date) -> [CalendarEvent] {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return [] }
        let start = calendar.startOfDay(for: day)
        return events.filter { $0.start < next && $0.end > start }
    }

    /// The next timed event in the coming day, or the one going on now.
    func nextEvent(at now: Date) -> CalendarEvent? {
        upcoming.first { !$0.isAllDay && CalendarRules.countdown(from: now, start: $0.start, end: $0.end) != nil }
    }

    func search(_ query: String) -> [CalendarEvent] {
        upcoming.filter { ClipRules.matches(query, text: $0.title) || ClipRules.matches(query, text: $0.location ?? "") }
    }

    func open(_ event: CalendarEvent) {
        guard !Store.isOverridden else { return }
        if let id = event.itemID?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    private static func samples() -> [CalendarEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func event(_ title: String, day: Int, hour: Int, minutes: Int = 30, color: Color, location: String? = nil, link: String? = nil, allDay: Bool = false) -> CalendarEvent {
            let base = calendar.date(byAdding: .day, value: day, to: today)!
            let start = allDay ? base : calendar.date(byAdding: .hour, value: hour, to: base)!
            let end = allDay ? calendar.date(byAdding: .day, value: 1, to: base)! : calendar.date(byAdding: .minute, value: minutes, to: start)!
            return CalendarEvent(id: "\(title)-\(day)", title: title, start: start, end: end, isAllDay: allDay, color: color,
                                 location: location, link: link.flatMap(URL.init(string:)))
        }
        let soon = Date.now.addingTimeInterval(40 * 60)
        let next = CalendarEvent(id: "next", title: "Design Review", start: soon, end: soon.addingTimeInterval(30 * 60), isAllDay: false, color: .blue,
                                 link: URL(string: "https://meet.google.com/abc-defg-hij"))
        return [
            event("Team Offsite Planning", day: 0, hour: 0, color: .purple, allDay: true),
            event("Morning Standup", day: 0, hour: 9, minutes: 15, color: .blue),
            next,
            event("Lunch with Sam", day: 1, hour: 12, minutes: 60, color: .green, location: "Corner Cafe"),
            event("Dentist", day: 3, hour: 15, minutes: 45, color: .red),
            event("Sprint Planning", day: 4, hour: 10, minutes: 60, color: .blue),
            event("Flight to Lisbon", day: -2, hour: 8, minutes: 180, color: .orange),
        ].sorted { $0.start < $1.start }
    }
}

// MARK: The tool

struct CalendarView: View {
    let surface: Surface
    let query: String
    @Environment(AppModel.self) private var model
    private var tool: CalendarTool { .shared }

    var body: some View {
        Group {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else if surface == .popover {
                VStack(spacing: 0) {
                    CalendarMonth(compact: true)
                    Divider()
                    agenda
                }
            } else {
                HStack(spacing: 0) {
                    CalendarMonth(compact: false)
                        .frame(width: Space.section * 9)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Divider()
                    agenda
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear { tool.opened() }
        .onChange(of: model.openCount) { tool.opened() }
    }

    private var agenda: some View {
        Group {
            if tool.access != .allowed {
                CalendarAccessPrompt(access: tool.access) { tool.allow() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        // The popover has room for the events only; their rows count down instead.
                        if surface == .panel {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                if let next = tool.nextEvent(at: context.date), let countdown = CalendarRules.countdown(from: context.date, start: next.start, end: next.end) {
                                    nextBanner(next, countdown: countdown)
                                }
                            }
                        }
                        Text(tool.selected.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        let today = tool.events(on: tool.selected)
                        if today.isEmpty {
                            Text("No Events")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(today) { CalendarEventRow(event: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
                }
                .defaultScrollAnchor(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func nextBanner(_ event: CalendarEvent, countdown: String) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "bell.fill")
                .foregroundStyle(event.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(countdown == "now" ? "Going on now" : "Starts \(countdown)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let link = event.link { JoinButton(link: link) }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(event.color.opacity(0.16), in: .rect(cornerRadius: 8))
    }

    private var searchResults: some View {
        let found = tool.search(query)
        return Group {
            if tool.access != .allowed {
                CalendarAccessPrompt(access: tool.access) { tool.allow() }
            } else if found.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(found) { event in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                CalendarEventRow(event: event)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
                }
                .defaultScrollAnchor(.top)
            }
        }
    }
}

/// The month: its name, the days, and a dot per event. Compact leaves out
/// weeks of only the next month, and sits tighter, to leave room for events.
private struct CalendarMonth: View {
    let compact: Bool
    private var tool: CalendarTool { .shared }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Text(tool.month.formatted(.dateTime.month(.wide).year()))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Button("Today") { tool.goToToday() }
                    .buttonStyle(QuickActionStyle())
                    .controlSize(.small)
                    .help("Go to today (↩)")
                arrow("chevron.left", label: "Previous Month") { tool.moveMonth(by: -1) }
                arrow("chevron.right", label: "Next Month") { tool.moveMonth(by: 1) }
            }
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(CalendarRules.weekdayLetters(calendar: .current).enumerated()), id: \.offset) { _, letter in
                    Text(letter)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: Space.lg)
                }
                ForEach(compact ? CalendarRules.trimmed(tool.days, toMonthOf: tool.month, calendar: .current) : tool.days, id: \.self) { day in
                    CalendarDayCell(day: day, height: compact ? Space.xxl : Space.xxl + Space.xs)
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .frame(width: Space.xxl, height: Space.xxl)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(label) (⌘\(symbol == "chevron.left" ? "←" : "→"))")
        .accessibilityLabel(label)
    }
}

private struct CalendarDayCell: View {
    let day: Date
    let height: CGFloat
    @State private var hovering = false
    private var tool: CalendarTool { .shared }

    var body: some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: tool.selected)
        let inMonth = calendar.isDate(day, equalTo: tool.month, toGranularity: .month)
        let dots = tool.events(on: day).prefix(3)
        Button {
            tool.select(day)
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.weight(isToday || isSelected ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? AnyShapeStyle(Tool.calendar.tint) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                HStack(spacing: 2) {
                    ForEach(dots) { event in
                        Circle().fill(event.color).frame(width: Space.xs, height: Space.xs)
                    }
                }
                .frame(height: Space.xs)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8).fill(Tool.calendar.tint.opacity(isToday ? 0.25 : 0.14))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(dots.isEmpty ? "No events" : "Has events")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Capsule()
                .fill(event.color)
                .frame(width: Space.xs, height: Space.xxl)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.callout)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let countdown = event.isAllDay ? nil : CalendarRules.countdown(from: context.date, start: event.start, end: event.end)
                    Text([event.time, countdown, event.location].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let link = event.link { JoinButton(link: link) }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quinary))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { CalendarTool.shared.open(event) }
        .help("Open in Calendar")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct JoinButton: View {
    let link: URL

    var body: some View {
        Button("Join") { NSWorkspace.shared.open(link) }
            .buttonStyle(QuickActionStyle())
            .help("Join the call: \(link.host() ?? "")")
    }
}

private struct CalendarAccessPrompt: View {
    let access: CalendarTool.Access
    let allow: () -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "calendar")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("See Your Events Here")
                .font(.callout.weight(.semibold))
            Text(access == .denied ? "Calendar access is off. Turn on Toolbelt in System Settings." : "Toolbelt only reads your calendars, and nothing leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(access == .denied ? "Open System Settings" : "Allow Calendar Access", action: allow)
                .buttonStyle(TintedActionStyle(tint: Tool.calendar.tint))
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
