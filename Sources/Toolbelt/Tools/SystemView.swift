import AppKit
import SwiftUI
import ToolbeltKit

/// The top of the System tool: one row per reading, each with a bar where a
/// share makes sense. Bars turn orange and red as they fill; the number
/// beside them says the same in words.
struct SystemGauges: View {
    let window: NSWindow?
    @Environment(AppModel.self) private var model
    private var monitor: SystemMonitor { .shared }

    var body: some View {
        let reading = monitor.reading
        VStack(spacing: Space.sm) {
            GaugeRow(symbol: "cpu", title: "CPU", fraction: reading.cpu,
                     value: reading.cpu.map(SystemRules.percentText) ?? "–")
            GaugeRow(symbol: "memorychip", title: "Memory",
                     fraction: reading.memoryUsed > 0 ? Double(reading.memoryUsed) / Double(reading.memoryTotal) : nil,
                     value: reading.memoryUsed > 0 ? SystemRules.memoryText(used: reading.memoryUsed, total: reading.memoryTotal) : "–")
            if let temperature = reading.temperature {
                GaugeRow(symbol: "thermometer.medium", title: "CPU Temperature", fraction: nil,
                         value: "\(Int(temperature.rounded()))°C")
            }
            ForEach(reading.fans) { fan in
                GaugeRow(symbol: "fan", title: "Fan \(fan.id)",
                         fraction: fan.maxRPM > 0 ? fan.rpm / fan.maxRPM : nil, value: "\(Int(fan.rpm.rounded())) RPM", warns: false)
            }
            if let battery = reading.battery {
                GaugeRow(symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent", title: "Battery",
                         fraction: Double(battery.percent) / 100,
                         value: "\(battery.percent)%" + (battery.isCharging ? " · Charging" : battery.onPower ? " · On Power" : ""),
                         warns: false)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .onAppear { monitor.watch(window) }
        .onChange(of: window) { monitor.watch(window) }
        .onChange(of: model.openCount) { monitor.watch(window) }
    }
}

private struct GaugeRow: View {
    let symbol: String
    let title: String
    let fraction: Double?
    let value: String
    /// Load and memory warn as they fill; fans and battery do not.
    var warns = true

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Space.xl)
            Text(title)
            Spacer(minLength: Space.sm)
            if let fraction {
                Bar(fraction: fraction, color: color(fraction))
                    .frame(width: 96, height: 6) // grid: ok a bar's thickness, not spacing
            }
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 112, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func color(_ fraction: Double) -> Color {
        guard warns else { return .accentColor }
        return fraction > 0.85 ? .red : fraction > 0.6 ? .orange : .green
    }
}

private struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: fraction > 0 ? max(geo.size.width * min(fraction, 1), geo.size.height) : 0)
                }
        }
    }
}

/// One app in "Using the Most Energy": icon, name, CPU share, and power.
struct UsageRow: View {
    let use: AppUse
    let icon: NSImage
    let selected: Bool

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: Space.xl, height: Space.xl)
        Text(UsageRow.name(of: use))
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer(minLength: Space.sm)
        Text("\(Int(use.cpu.rounded()))% CPU")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
        Text(SystemRules.powerText(use.watts))
            .monospacedDigit()
            .frame(minWidth: 64, alignment: .trailing)
    }

    static func name(of use: AppUse) -> String {
        use.isApp ? AppIndex.name(atPath: use.path) : URL(fileURLWithPath: use.path).lastPathComponent
    }
}
