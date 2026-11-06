import AVFoundation
import IOKit
import SwiftUI
import ToolbeltKit

extension MacFacts {
    /// What this Mac has. Snapshots can pretend to be a Mac mini with
    /// APP_SIMULATE_MAC=desktop; real runs always read the hardware.
    static var current: MacFacts {
        if Store.isOverridden, ProcessInfo.processInfo.environment["APP_SIMULATE_MAC"] == "desktop" {
            return MacFacts(hasMotionSensor: false, hasCamera: false, hasBattery: false, hasFans: true)
        }
        return MacFacts(hasMotionSensor: KnockSensor.isPresent, hasCamera: hasCamera, hasBattery: hasBattery, hasFans: hasFans)
    }

    // Finding cameras asks for no permission; only opening one does.
    private static var hasCamera: Bool {
        !AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                          mediaType: .video, position: .unspecified).devices.isEmpty
    }

    private static var hasBattery: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    private static var hasFans: Bool {
        (SMC().uint8("FNum") ?? 0) > 0
    }
}

extension Tool {
    var support: ToolSupport { CompatibilityRules.support(forTool: rawValue, on: .current) }
}

/// Settings > Compatibility: this Mac, and what each tool needs on it.
struct CompatibilitySettings: View {
    @State private var mac: MacFacts?

    var body: some View {
        Section {
            LabeledContent("Chip", value: Self.text("machdep.cpu.brand_string") ?? "Unknown")
            LabeledContent("Model", value: Self.text("hw.model") ?? "Unknown")
            LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
        } header: {
            Text("This Mac")
        } footer: {
            Text("Toolbelt needs macOS 26 or later on an Apple silicon Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Tools") {
            if let mac {
                // What needs attention comes first.
                let tools = Tool.allCases.map { ($0, CompatibilityRules.support(forTool: $0.rawValue, on: mac)) }
                ForEach(tools.filter { $0.1 != .ready } + tools.filter { $0.1 == .ready }, id: \.0) { tool, support in
                    CompatibilityRow(tool: tool, support: support)
                }
            }
        }
        .task { mac = .current }
    }

    private static func text(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private struct CompatibilityRow: View {
    let tool: Tool
    let support: ToolSupport

    var body: some View {
        LabeledContent {
            status
                .font(.callout)
                .fixedSize()
        } label: {
            HStack(spacing: Space.sm) {
                IconTile(symbol: tool.symbol, tint: tool.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                    Text(support.note ?? CompatibilityRules.requirement(forTool: tool.rawValue))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch support {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .limited:
            Label("Limited", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .unavailable:
            Label("Not on This Mac", systemImage: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}
