import SwiftUI
import ToolbeltKit

/// The Knock page: whether it listens, the layout and what each knock does,
/// a live meter for tuning, and the last knock heard.
struct KnockView: View {
    let surface: Surface
    let window: NSWindow?
    @State private var reading = KnockSensor.Reading()
    @Bindable private var knock = Knock.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                status
                if knock.state == .listening || knock.isSimulated {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.sm) {
                            Picker("Layout", selection: $knock.layout) {
                                ForEach(KnockLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help("Anywhere: three knocks. Left and Right: each edge has its own three.")
                            Spacer(minLength: 0)
                            KnockPresetMenu()
                        }
                        .controlSize(.small)
                        .padding(.horizontal, Space.sm)
                        card {
                            ForEach(Array(knock.layout.slots.enumerated()), id: \.element) { index, slot in
                                if index > 0 { Divider().padding(.leading, Space.md) }
                                row(slot.title) { KnockActionPicker(slot: slot) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Tuning")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.sm)
                            .accessibilityAddTraits(.isHeader)
                        card {
                            meter
                            Divider().padding(.leading, Space.md)
                            row("Sensitivity") {
                                KnockSensitivitySlider()
                                    .frame(width: 200)
                            }
                            if knock.layout == .sides {
                                Divider().padding(.leading, Space.md)
                                row("Swap left and right") {
                                    Toggle("Swap left and right", isOn: $knock.invertSides)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .help("Turn on if knocks on the left read as right")
                                }
                            }
                        }
                    }
                }
            }
            .padding(Space.md)
        }
        .defaultScrollAnchor(.top)
        .task(id: window) {
            // Only while the page shows: the sensor thread never wakes the main thread for the meter.
            while !Task.isCancelled {
                if window?.isVisible == true { reading = knock.reading() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch knock.state {
        case .unavailable:
            ContentUnavailableView("No Motion Sensor", systemImage: "hand.tap",
                                   description: Text("Toolbelt could not read a motion sensor on this Mac. Knock needs a MacBook with M2 or later, or M1 Pro or Max."))
        case .off where !knock.isSimulated:
            ContentUnavailableView("Knock Is Off", systemImage: "hand.tap",
                                   description: Text("Turn it on in Settings > Knock."))
        default:
            HStack(spacing: Space.md) {
                Image(systemName: "hand.tap.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(knock.isSimulated ? "Test runs never read the motion sensor" : "Listening for knocks")
                        .font(.headline)
                    Text(lastHeard)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if reading.rate > 0 {
                    Text("\(Int(reading.rate.rounded())) Hz")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Readings a second from the motion sensor")
                }
            }
            .padding(.horizontal, Space.sm)
        }
    }

    private var lastHeard: String {
        guard let heard = knock.heard else {
            return knock.layout == .sides ? "Knock near the left or right edge of the palm rest." : "Knock on the palm rest, the lid, or the desk beside the Mac."
        }
        return knock.describe(heard.event, action: heard.action, app: heard.app) + " · " + heard.at.formatted(.relative(presentation: .named))
    }

    /// The movement's peak against the line a knock must cross, drawn at the middle.
    private var meter: some View {
        row("Movement") {
            ZStack {
                Bar(fraction: reading.peak / max(reading.threshold * 2, 0.001),
                    color: reading.peak >= reading.threshold ? .accentColor : .secondary)
                Rectangle()
                    .fill(.primary)
                    .frame(width: 1)
            }
            .frame(width: 200, height: 6) // grid: ok a bar's thickness, not spacing
            .accessibilityElement()
            .accessibilityLabel("Movement")
            .accessibilityValue(reading.peak >= reading.threshold ? "Strong enough for a knock" : "Below a knock")
            .help("A knock must pass the middle line")
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(.fill.quinary, in: .rect(cornerRadius: 8))
    }

    private func row<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Space.md) {
            Text(label)
            Spacer(minLength: Space.md)
            trailing()
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .controlSize(surface == .popover ? .small : .regular)
    }
}

/// The actions, grouped, for a knock menu.
struct KnockActionItems: View {
    var body: some View {
        Label(KnockAction.nothing.title, systemImage: KnockAction.nothing.symbol).tag(KnockAction?.some(.nothing))
        ForEach(KnockAction.Group.allCases, id: \.self) { group in
            Section(group.rawValue) {
                ForEach(KnockAction.allCases.filter { $0.group == group }) { action in
                    Label(action.title, systemImage: action.symbol).tag(KnockAction?.some(action))
                }
            }
        }
    }
}

/// What a slot does everywhere. Used on the Knock page and in Settings.
struct KnockActionPicker: View {
    let slot: KnockSlot

    var body: some View {
        Picker(slot.title, selection: Binding<KnockAction?>(get: { Knock.shared.action(for: slot) },
                                                            set: { Knock.shared.setAction($0 ?? .nothing, for: slot) })) {
            KnockActionItems()
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Fills every slot of the layout from a preset.
struct KnockPresetMenu: View {
    var body: some View {
        Menu {
            ForEach(KnockPreset.all) { preset in
                Button {
                    Knock.shared.apply(preset)
                } label: {
                    Label(preset.title, systemImage: preset.symbol)
                    Text(preset.subtitle)
                }
            }
        } label: {
            Text(Knock.shared.currentPreset.map { "Preset: \($0.title)" } ?? "Use a Preset")
        }
        .fixedSize()
        .help("Set every knock at once from a ready-made set")
    }
}

struct KnockSensitivitySlider: View {
    var body: some View {
        Slider(value: Binding(get: { Knock.shared.sensitivity }, set: { Knock.shared.sensitivity = $0 }), in: 0...1) {
            Text("Sensitivity")
        } minimumValueLabel: {
            Text("Firm")
        } maximumValueLabel: {
            Text("Light")
        }
        .labelsHidden()
        .help("How light a knock still counts")
    }
}

/// Settings > Knock > Apps: rules that change some knocks in one app.
struct KnockAppRules: View {
    private var knock: Knock { .shared }

    var body: some View {
        Section {
            ForEach(knock.rules) { rule in
                DisclosureGroup {
                    ForEach(knock.layout.slots, id: \.self) { slot in
                        Picker(slot.title, selection: Binding<KnockAction?>(get: { knock.ruleAction(rule, slot) },
                                                                            set: { knock.setRuleAction($0, for: slot, in: rule) })) {
                            Text("Same as Everywhere (\(knock.action(for: slot).title))").tag(KnockAction?.none)
                            Divider()
                            KnockActionItems()
                        }
                    }
                    Button("Remove Rule", role: .destructive) { knock.removeRule(rule) }
                } label: {
                    AppLabel(id: rule.id, name: rule.name, detail: summary(rule))
                }
            }
            Menu("Add a Rule for an App") {
                ForEach(runningApps, id: \.id) { app in
                    Button(app.name) { knock.addRule(KnockAppRule(id: app.id, name: app.name, slots: [:])) }
                }
            }
            .fixedSize()
            .disabled(runningApps.isEmpty)
        } header: {
            Text("Apps")
        } footer: {
            Text("In an app with a rule, its knocks win while that app is in front. Knocks it leaves alone do what they do everywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !knock.suggestions.isEmpty {
            Section("Suggested for Your Apps") {
                ForEach(knock.suggestions, id: \.rule.id) { suggestion in
                    HStack(spacing: Space.md) {
                        AppLabel(id: suggestion.rule.id, name: suggestion.rule.name, detail: suggestion.why)
                        Spacer(minLength: Space.md)
                        Button("Add") { knock.addRule(suggestion.rule) }
                            .help("Add the suggested rule for \(suggestion.rule.name)")
                    }
                }
            }
        }
    }

    private func summary(_ rule: KnockAppRule) -> String {
        let set = knock.layout.slots.compactMap { slot in knock.ruleAction(rule, slot).map { "\(slot.title): \($0.title)" } }
        return set.isEmpty ? "No changes yet" : set.joined(separator: " · ")
    }

    /// Apps open now that have no rule yet.
    private var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { app in !knock.rules.contains { $0.id == app.id } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// An app's icon, name and one line under it.
private struct AppLabel: View {
    let id: String
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: Space.md) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: Space.xl, height: Space.xl)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
