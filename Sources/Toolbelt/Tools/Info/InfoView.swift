import AppKit
import SwiftUI
import ToolbeltKit

/// The Info tool, in the layout chosen in Settings > Info. The search field
/// filters the rows. Click a value to copy it.
struct InfoView: View {
    let surface: Surface
    let query: String
    @Environment(AppModel.self) private var model
    @Bindable private var info = MacInfo.shared

    var body: some View {
        VStack(spacing: 0) {
            switch info.layout {
            case .overview: InfoOverview(surface: surface, query: query)
            case .gauges: InfoGauges(query: query)
            case .glance: InfoGlance(query: query)
            case .list:
                listTabs
                Divider()
                InfoDetail(tab: info.tab, query: query)
            }
        }
        .onAppear { info.opened() }
        .onChange(of: model.openCount) { info.opened() }
    }

    private var listTabs: some View {
        HStack(spacing: Space.sm) {
            Picker("Info", selection: $info.tab) {
                ForEach(InfoTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            InfoTabButtons(tab: info.tab)
        }
        .controlSize(surface == .popover ? .small : .regular)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }
}

/// Copy All and Refresh for a tab.
struct InfoTabButtons: View {
    let tab: InfoTab
    private var info: MacInfo { .shared }

    var body: some View {
        Button("Copy All", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info.report(tab), forType: .string)
            Toast.show("Copied \(tab.title) info", symbol: "doc.on.doc")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(info.sections[tab]?.isEmpty ?? true)
        .help("Copy everything on this tab as text")
        Button("Refresh", systemImage: "arrow.clockwise") { info.refresh() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(info.loading.contains(tab))
            .help("Read this tab again (⌘R)")
    }
}

/// A tab's rows with its search and its empty states. `tint` colors the bars
/// and, when `symbols` is on, an icon on each row.
struct InfoDetail: View {
    let tab: InfoTab
    let query: String
    var tint: Color?
    var symbols = false
    /// Copy All and Refresh beside the first section's title.
    var buttons = false
    private var info: MacInfo { .shared }

    var body: some View {
        let sections = info.filtered(tab, query: query)
        Group {
            if sections.isEmpty {
                InfoEmptyState(tab: tab, query: query)
            } else {
                ScrollView {
                    InfoSectionList(sections: sections, query: query, tab: tab, tint: tint, symbols: symbols, buttons: buttons)
                        .padding(Space.md)
                }
                .defaultScrollAnchor(.top)
                .id(tab)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct InfoEmptyState: View {
    let tab: InfoTab
    let query: String
    private var info: MacInfo { .shared }

    var body: some View {
        if !query.isEmpty, info.sections[tab] != nil {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                   description: Text("Nothing on \(tab.title) matches “\(query)”."))
        } else if info.loading.contains(tab) || info.sections[tab] == nil {
            ProgressView("Reading \(tab.title)…")
                .controlSize(.small)
        } else if tab == .battery {
            ContentUnavailableView("No Battery", systemImage: "powerplug",
                                   description: Text("This Mac runs on power only."))
        } else {
            ContentUnavailableView("Nothing Found", systemImage: tab.symbol,
                                   description: Text(tab == .developer ? "No developer tools are installed." : "Toolbelt could not read this."))
        }
    }
}

/// Grouped name–value rows.
struct InfoSectionList: View {
    let sections: [InfoSection]
    let query: String
    let tab: InfoTab
    var tint: Color?
    var symbols = false
    var buttons = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        if buttons, section.id == sections.first?.id {
                            Spacer(minLength: 0)
                            InfoTabButtons(tab: tab)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, Space.sm)
                    VStack(spacing: 0) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider().padding(.leading, Space.md) }
                            InfoRowView(row: row, tint: tint, symbol: symbols ? row.symbol(in: tab) : nil)
                        }
                    }
                    .background(.fill.quinary, in: .rect(cornerRadius: 8))
                    if let note = section.note, query.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.sm)
                    }
                }
            }
        }
    }
}

/// Copying a value, shared by rows and cards.
enum InfoCopy {
    static func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("Copied \(label.lowercased())", symbol: "doc.on.doc")
    }

    static func activate(_ row: InfoRow) {
        switch row.action {
        case .allowLocation?: LocationAccess.shared.request()
        case nil: copy(row.value, label: row.label)
        }
    }

    static func help(_ row: InfoRow) -> String {
        row.help.map { "\($0). Click to copy." } ?? (row.action == nil ? "Click to copy" : "Click to allow")
    }
}

private struct InfoRowView: View {
    let row: InfoRow
    var tint: Color?
    var symbol: String?
    @State private var hovering = false
    @State private var revealed = false

    private var shown: String { row.secret && !revealed ? "••••••••••" : row.value }

    var body: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.sm) {
                if let symbol, let tint {
                    RoundedRectangle(cornerRadius: Space.xs, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .frame(width: Space.xl, height: Space.xl)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tint)
                        }
                        .accessibilityHidden(true)
                }
                Text(row.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: Space.md)
            if let fraction = row.fraction {
                Bar(fraction: fraction, color: tint ?? .accentColor)
                    .frame(width: 64, height: 6) // grid: ok a bar's thickness, not spacing
            }
            Text(shown)
                .foregroundStyle(row.action == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Palette.accentText))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            if row.secret {
                Button(revealed ? "Hide" : "Show", systemImage: revealed ? "eye.slash" : "eye") { revealed.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(revealed ? "Hide \(row.label.lowercased())" : "Show \(row.label.lowercased())")
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs + 2)
        .background {
            if hovering { RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary) }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { InfoCopy.activate(row) }
        .help(InfoCopy.help(row))
        .contextMenu {
            Button("Copy \(row.label)") { InfoCopy.copy(row.value, label: row.label) }
            Button("Copy Line") { InfoCopy.copy("\(row.label): \(row.value)", label: row.label) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityValue(row.secret && !revealed ? "Hidden" : row.value)
        .accessibilityAction(named: "Copy") { InfoCopy.copy(row.value, label: row.label) }
    }
}

extension InfoRow {
    /// An icon for the row in Glance Tabs; rows without their own use the tab's.
    func symbol(in tab: InfoTab) -> String {
        let symbols = [
            "Charge": "bolt.fill", "Status": "powerplug", "Low Power Mode": "leaf", "Time to full": "clock",
            "Time remaining": "clock", "Condition": "heart", "Maximum capacity": "gauge.with.dots.needle.50percent",
            "Cycle count": "arrow.triangle.2.circlepath", "Temperature": "thermometer.medium", "Voltage": "bolt",
            "Used": "internaldrive", "Available": "square.stack.3d.up", "File system": "doc", "FileVault": "lock",
            "Location": "mappin", "Health": "checkmark.shield", "Model": "laptopcomputer", "Chip": "cpu",
            "CPU cores": "cpu", "GPU cores": "square.grid.3x3", "Memory": "memorychip", "Uptime": "clock",
            "Signal": "wifi", "Network": "wifi", "Link speed": "speedometer", "Security": "lock",
            "Public IP": "globe", "Local IP": "house", "Router": "wifi.router", "DNS servers": "server.rack",
            "Connected through": "network", "Serial number": "number", "Firmware": "memorychip",
        ]
        if label == "Status", tab == .network { return "wifi" }
        return symbols[label] ?? tab.symbol
    }
}
