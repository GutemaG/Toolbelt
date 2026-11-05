import SwiftUI
import ToolbeltKit

/// World Clock: the cities you chose, and the one whose time sits in the menu
/// bar. Saved in UserDefaults; test and snapshot runs keep it in memory.
/// The tick runs only while a city is in the menu bar.
@Observable
final class WorldClock {
    static let shared = WorldClock()

    private(set) var cities: [WorldCity]
    private(set) var menuBarCity: WorldCity?
    /// How the menu bar writes the city.
    var menuBarStyle: WorldClockMenuStyle { didSet { changed() } }
    /// How far the slider is from now, in seconds. The menu bar always shows
    /// the real time; this only moves the page, and resets when it opens.
    var travel: TimeInterval = 0
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var tick: Task<Void, Never>?

    init() {
        defaults = Store.isOverridden ? nil : .standard
        cities = (defaults?.stringArray(forKey: "worldClock.cities") ?? []).compactMap(WorldCity.init(id:))
        menuBarCity = defaults?.string(forKey: "worldClock.menuBar").flatMap(WorldCity.init(id:))
        menuBarStyle = defaults?.string(forKey: "worldClock.menuBarStyle").flatMap(WorldClockMenuStyle.init(rawValue:)) ?? .flagAndTime
    }

    /// Adds a city. The first one also goes in the menu bar, since that is what the tool is for.
    func add(_ city: WorldCity) {
        guard !cities.contains(city) else { return }
        let first = cities.isEmpty
        cities.append(city)
        if first { menuBarCity = city }
        changed()
    }

    func remove(_ city: WorldCity) {
        cities.removeAll { $0 == city }
        if menuBarCity == city { menuBarCity = nil }
        changed()
    }

    func setMenuBar(_ city: WorldCity?) {
        menuBarCity = city
        changed()
    }

    func toggleMenuBar(_ city: WorldCity) {
        setMenuBar(menuBarCity == city ? nil : city)
    }

    /// Dragging one city onto another puts it in that city's place.
    func move(_ city: WorldCity, onto target: WorldCity) {
        guard city != target, let from = cities.firstIndex(of: city), let to = cities.firstIndex(of: target) else { return }
        cities.insert(cities.remove(at: from), at: to)
        changed()
    }

    /// Moves a city up (-1) or down (+1). Returns whether it moved.
    @discardableResult
    func move(_ city: WorldCity, by offset: Int) -> Bool {
        guard let from = cities.firstIndex(of: city), cities.indices.contains(from + offset) else { return false }
        cities.insert(cities.remove(at: from), at: from + offset)
        changed()
        return true
    }

    /// One slider step with the arrow keys.
    func nudge(_ steps: Int) {
        let reach = WorldClockRules.travelReach
        travel = min(max(travel + Double(steps) * WorldClockRules.travelStep, -reach), reach)
    }

    /// The city as the menu bar writes it, nil when nothing should show.
    var menuBarText: String? {
        guard let menuBarCity, ToolPrefs.shared.enabled.contains(.worldClock) else { return nil }
        return menuBarStyle.text(menuBarCity, at: .now)
    }

    /// Starts or stops the tick to match what the menu bar shows.
    func updateTicking() {
        tick?.cancel()
        tick = nil
        guard menuBarText != nil else { return }
        tick = Task { [weak self] in
            while !Task.isCancelled {
                // A moment past the minute, so the new time is already true.
                try? await Task.sleep(for: .seconds(WorldClockRules.secondsToNextMinute(.now) + 0.05))
                guard self != nil, !Task.isCancelled else { return }
                StatusItems.shared?.refreshIcons()
            }
        }
    }

    private func changed() {
        defaults?.set(cities.map(\.id), forKey: "worldClock.cities")
        defaults?.set(menuBarCity?.id, forKey: "worldClock.menuBar")
        defaults?.set(menuBarStyle.rawValue, forKey: "worldClock.menuBarStyle")
        StatusItems.shared?.apply(ToolPrefs.shared)
    }
}

extension DayPeriod {
    /// The same color on the slider's band, its legend and a city's symbol.
    var color: Color {
        switch self {
        case .work: .orange
        case .edge: .pink
        case .night: .indigo
        }
    }
}

/// One clock line: an icon, a name, the day and difference, the UTC offset, and the time.
private struct ClockLine<Icon: View, Accessory: View>: View {
    let name: String
    let zone: TimeZone
    let now: Date
    var selected = false
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessory: Accessory

    private var date: Date { WorldClockRules.traveled(now: now, by: WorldClock.shared.travel) }
    private var secondary: AnyShapeStyle { selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary) }

    var body: some View {
        let period = WorldClockRules.period(zone, at: date)
        HStack(spacing: Space.md) {
            icon
                .frame(width: Space.xxl)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                HStack(spacing: Space.sm) {
                    Text(WorldClockRules.detail(zone, at: date, now: now))
                        .font(.caption)
                        .foregroundStyle(secondary)
                    Text(WorldClockRules.utc(zone, at: date))
                        .font(.caption2)
                        .foregroundStyle(secondary)
                        .padding(.horizontal, Space.xs + 2)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
            }
            Spacer(minLength: Space.sm)
            accessory
            Image(systemName: period.symbol)
                .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(period.color))
                .help(period.title)
                .accessibilityLabel(period.title)
            Text(WorldClockRules.time(WorldCity(name: name, zone: zone.identifier), at: date))
                .font(.title3)
                .monospacedDigit()
                .fixedSize()
        }
    }
}

/// One city in the World Clock list.
struct WorldCityRow: View {
    let city: WorldCity
    let selected: Bool
    private var clock: WorldClock { .shared }

    var body: some View {
        TimelineView(.everyMinute) { context in
            ClockLine(name: city.name, zone: city.timeZone, now: context.date, selected: selected) {
                if city.flag.isEmpty {
                    Image(systemName: "globe")
                        .font(.title2)
                } else {
                    Text(city.flag)
                        .font(.title2)
                        .accessibilityHidden(true)
                }
            } accessory: {
                if clock.menuBarCity == city {
                    Image(systemName: "menubar.rectangle")
                        .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(Palette.accentText))
                        .help("Showing in the menu bar")
                        .accessibilityLabel("Showing in the menu bar")
                }
                if !clock.cities.contains(city) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.secondary))
                        .help("Add \(city.name)")
                        .accessibilityLabel("Not added yet")
                }
            }
        }
    }
}

/// Your own time, pinned above the cities, so the differences have a reference.
struct LocalTimeRow: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            ClockLine(name: "Local Time", zone: .autoupdatingCurrent, now: context.date) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.secondary)
            } accessory: {
                EmptyView()
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .accessibilityElement(children: .combine)
    }
}

/// The slider that moves every clock on the page together, with a band above
/// it showing work, morning and evening, and night here.
struct TimeTravelBar: View {
    private var clock: WorldClock { .shared }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: Space.xs) {
                HStack(spacing: Space.md) {
                    Text(WorldClockRules.travelLabel(clock.travel))
                        .font(.callout)
                        .monospacedDigit()
                        .fixedSize()
                    Spacer(minLength: Space.sm)
                    ViewThatFits(in: .horizontal) {
                        legend
                        EmptyView()
                    }
                    if clock.travel != 0 {
                        Button("Reset") { clock.travel = 0 }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Back to the time now (esc)")
                    }
                }
                .frame(minHeight: Space.xl)
                DayBandSlider(value: Binding(get: { clock.travel }, set: { clock.travel = $0 }),
                              segments: WorldClockRules.daySegments(now: context.date, in: .autoupdatingCurrent))
                    .help("Drag to see every clock earlier or later")
                    .accessibilityLabel("Time from now")
                    .accessibilityValue(WorldClockRules.travelLabel(clock.travel))
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
        }
    }

    private var legend: some View {
        HStack(spacing: Space.md) {
            ForEach(DayPeriod.allCases, id: \.self) { period in
                Label {
                    Text(period.title)
                } icon: {
                    Image(systemName: period.symbol)
                        .foregroundStyle(period.color)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

/// The system slider and knob, with the day's periods drawn as its track.
/// SwiftUI's Slider cannot hide its own track, so this one is AppKit's.
private struct DayBandSlider: NSViewRepresentable {
    @Binding var value: TimeInterval
    let segments: [WorldClockRules.DaySegment]

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = DayBandSliderCell()
        slider.minValue = -WorldClockRules.travelReach
        slider.maxValue = WorldClockRules.travelReach
        slider.isContinuous = true
        // The search field keeps the focus; the arrow keys reach the slider through it.
        slider.refusesFirstResponder = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.moved)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        (slider.cell as? DayBandSliderCell)?.segments = segments
        if slider.doubleValue != value { slider.doubleValue = value }
        slider.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: DayBandSlider

        init(parent: DayBandSlider) { self.parent = parent }

        @objc func moved(_ slider: NSSlider) {
            let step = WorldClockRules.travelStep
            parent.value = (slider.doubleValue / step).rounded() * step
        }
    }
}

/// Draws the periods in place of the slider's bar. The colors line up with
/// where the knob's center travels, so the knob points at the right hour.
final class DayBandSliderCell: NSSliderCell {
    var segments: [WorldClockRules.DaySegment] = []

    /// How far the knob's center reaches at each end.
    var knobTravel: ClosedRange<CGFloat> {
        let bounds = controlView?.bounds ?? .zero
        let half = knobThickness / 2
        return (bounds.minX + half)...max(bounds.minX + half, bounds.maxX - half)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bounds = controlView?.bounds ?? rect
        let bar = NSRect(x: bounds.minX, y: rect.midY - Space.xs, width: bounds.width, height: Space.sm)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).addClip()
        let travel = knobTravel, length = travel.upperBound - travel.lowerBound
        for (index, segment) in segments.enumerated() {
            // The first and last colors run on past the knob's reach to the ends of the bar.
            let start = index == 0 ? bar.minX : travel.lowerBound + length * segment.start
            let end = index == segments.count - 1 ? bar.maxX : travel.lowerBound + length * segment.end
            NSColor(segment.period.color).setFill()
            NSRect(x: start, y: bar.minY, width: end - start, height: bar.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Dragging a saved city onto another to change the order.
struct CityReordering: ViewModifier {
    let city: WorldCity
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .draggable(city.id) {
                Text(city.flag + " " + city.name)
                    .padding(Space.sm)
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let moved = ids.first.flatMap(WorldCity.init(id:)) else { return false }
                WorldClock.shared.move(moved, onto: city)
                return true
            } isTargeted: { targeted = $0 }
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 8).stroke(.tint) }
            }
            // The panel moves when dragged by its background; over a city, a drag moves the city.
            .onHover { PanelController.shared.panel.isMovableByWindowBackground = !$0 }
            .onDisappear { PanelController.shared.panel.isMovableByWindowBackground = true }
    }
}

/// Settings > World Clock: which city sits in the menu bar, and how it is written.
struct WorldClockOptions: View {
    @Bindable private var clock = WorldClock.shared

    var body: some View {
        Section {
            Picker("City in the menu bar", selection: Binding(get: { clock.menuBarCity }, set: { clock.setMenuBar($0) })) {
                Text("None").tag(WorldCity?.none)
                ForEach(clock.cities) { Text($0.flag + " " + $0.name).tag(WorldCity?.some($0)) }
            }
            .disabled(clock.cities.isEmpty)
            Picker("Show it as", selection: $clock.menuBarStyle) {
                ForEach(WorldClockMenuStyle.allCases) { Text($0.title).tag($0) }
            }
            .disabled(clock.menuBarCity == nil)
        } footer: {
            Text("Add cities on the World Clock page. The time shows on the World Clock icon, or beside the Toolbelt icon when World Clock has no icon of its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
