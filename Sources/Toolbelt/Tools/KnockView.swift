import SwiftUI
import ToolbeltKit

/// The Knock page: whether it listens, a live meter for tuning, the last
/// knock heard, and what one, two and three knocks do.
struct KnockView: View {
    let surface: Surface
    let window: NSWindow?
    @State private var reading = KnockSensor.Reading()
    private var knock: Knock { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                status
                if knock.state == .listening || knock.isSimulated {
                    card("Knocks") {
                        ForEach(1...3, id: \.self) { count in
                            if count > 1 { Divider().padding(.leading, Space.md) }
                            row(count == 1 ? "1 knock" : "\(count) knocks") {
                                KnockActionPicker(count: count)
                            }
                        }
                    }
                    card("Tuning") {
                        meter
                        Divider().padding(.leading, Space.md)
                        row("Sensitivity") {
                            KnockSensitivitySlider()
                                .frame(width: 200)
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
        guard let heard = knock.heard else { return "Knock on the palm rest, the lid, or the desk beside the Mac." }
        return Knock.describe(heard.event, action: heard.action) + " · " + heard.at.formatted(.relative(presentation: .named))
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

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.sm)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(.fill.quinary, in: .rect(cornerRadius: 8))
        }
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

/// What a number of knocks does. Used on the Knock page and in Settings.
struct KnockActionPicker: View {
    let count: Int
    var label = ""

    var body: some View {
        Picker(label, selection: Binding(get: { Knock.shared.action(for: count) }, set: { Knock.shared.setAction($0, for: count) })) {
            ForEach(KnockAction.allCases) { action in
                Label(action.title, systemImage: action.symbol).tag(action)
                if action == .nothing { Divider() }
            }
        }
        .labelsHidden(label.isEmpty)
        .fixedSize()
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

private extension View {
    @ViewBuilder
    func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}
