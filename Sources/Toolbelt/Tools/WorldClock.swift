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
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var tick: Task<Void, Never>?

    init() {
        defaults = Store.isOverridden ? nil : .standard
        cities = (defaults?.stringArray(forKey: "worldClock.cities") ?? []).compactMap(WorldCity.init(id:))
        menuBarCity = defaults?.string(forKey: "worldClock.menuBar").flatMap(WorldCity.init(id:))
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

    /// "New York 2:32 PM" for the menu bar, nil when nothing should show.
    var menuBarText: String? {
        guard let menuBarCity, ToolPrefs.shared.enabled.contains(.worldClock) else { return nil }
        return menuBarCity.name + " " + WorldClockRules.time(menuBarCity, at: .now)
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
        StatusItems.shared?.apply(ToolPrefs.shared)
    }
}

/// One city in the World Clock list: its name, how it differs from here, and its time.
struct WorldCityRow: View {
    let city: WorldCity
    let selected: Bool
    private var clock: WorldClock { .shared }

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(city.name)
                        .lineLimit(1)
                    Text(WorldClockRules.detail(city, at: context.date))
                        .font(.caption)
                        .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: Space.sm)
                if clock.menuBarCity == city {
                    Image(systemName: "menubar.rectangle")
                        .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(Palette.accentText))
                        .help("Showing in the menu bar")
                        .accessibilityLabel("Showing in the menu bar")
                }
                Text(WorldClockRules.time(city, at: context.date))
                    .font(.title3)
                    .monospacedDigit()
                    .fixedSize()
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

/// Settings > World Clock: which city sits in the menu bar.
struct WorldClockOptions: View {
    private var clock: WorldClock { .shared }

    var body: some View {
        Section {
            Picker("City in the menu bar", selection: Binding(get: { clock.menuBarCity }, set: { clock.setMenuBar($0) })) {
                Text("None").tag(WorldCity?.none)
                ForEach(clock.cities) { Text($0.name).tag(WorldCity?.some($0)) }
            }
            .disabled(clock.cities.isEmpty)
        } footer: {
            Text("Add cities on the World Clock page. Its time shows on the World Clock icon, or beside the Toolbelt icon when World Clock has no icon of its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
