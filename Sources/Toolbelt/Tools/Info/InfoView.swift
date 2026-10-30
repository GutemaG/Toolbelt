import AppKit
import SwiftUI
import ToolbeltKit

/// The Info tool: tabs across the top, then grouped name–value rows. The
/// search field filters the rows of the open tab. Click a value to copy it.
struct InfoView: View {
    let surface: Surface
    let query: String
    @Environment(AppModel.self) private var model
    @Bindable private var info = MacInfo.shared

    var body: some View {
        VStack(spacing: 0) {
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
                Button("Copy All", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.report(info.tab), forType: .string)
                    Toast.show("Copied \(info.tab.title) info", symbol: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(info.sections[info.tab]?.isEmpty ?? true)
                .help("Copy everything on this tab as text")
                Button("Refresh", systemImage: "arrow.clockwise") { info.load(info.tab, force: true) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(info.loading.contains(info.tab))
                    .help("Read this tab again (⌘R)")
            }
            .controlSize(surface == .popover ? .small : .regular)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            Divider()
            content
                .frame(maxHeight: .infinity)
        }
        .onAppear(perform: openOnBattery)
        .onChange(of: model.openCount, openOnBattery)
    }

    /// Every time Info opens it starts on Battery.
    private func openOnBattery() {
        info.tab = .battery
        info.load(.battery, force: true)
    }

    @ViewBuilder
    private var content: some View {
        let sections = filtered
        if sections.isEmpty {
            if info.loading.contains(info.tab) || info.sections[info.tab] == nil {
                ProgressView("Reading \(info.tab.title)…")
                    .controlSize(.small)
            } else if !query.isEmpty {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                       description: Text("Nothing on \(info.tab.title) matches “\(query)”."))
            } else if info.tab == .battery {
                ContentUnavailableView("No Battery", systemImage: "powerplug",
                                       description: Text("This Mac runs on power only."))
            } else {
                ContentUnavailableView("Nothing Found", systemImage: info.tab.symbol,
                                       description: Text(info.tab == .developer ? "No developer tools are installed." : "Toolbelt could not read this."))
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Space.sm)
                                .accessibilityAddTraits(.isHeader)
                            VStack(spacing: 0) {
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                                    if index > 0 { Divider().padding(.leading, Space.md) }
                                    InfoRowView(row: row, section: section.title)
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
                .padding(Space.md)
            }
            .defaultScrollAnchor(.top)
            .id(info.tab)
        }
    }

    /// Sections with the rows that match the search. A matching section title keeps all its rows.
    private var filtered: [InfoSection] {
        let all = info.sections[info.tab] ?? []
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.compactMap { section in
            if ClipRules.matches(query, text: section.title) { return section }
            var copy = section
            copy.rows = section.rows.filter { ClipRules.matches(query, text: $0.label) || (!$0.secret && ClipRules.matches(query, text: $0.value)) }
            return copy.rows.isEmpty ? nil : copy
        }
    }
}

private struct InfoRowView: View {
    let row: InfoRow
    let section: String
    @State private var hovering = false
    @State private var revealed = false

    private var shown: String { row.secret && !revealed ? "••••••••••" : row.value }

    var body: some View {
        HStack(spacing: Space.md) {
            Text(row.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: Space.md)
            if let fraction = row.fraction {
                Bar(fraction: fraction, color: .accentColor)
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
        .onTapGesture(perform: activate)
        .help(row.help.map { "\($0). Click to copy." } ?? (row.action == nil ? "Click to copy" : "Click to allow"))
        .contextMenu {
            Button("Copy \(row.label)") { copy(row.value) }
            Button("Copy Line") { copy("\(row.label): \(row.value)") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityValue(row.secret && !revealed ? "Hidden" : row.value)
        .accessibilityAction(named: "Copy") { copy(row.value) }
    }

    private func activate() {
        switch row.action {
        case .allowLocation?: LocationAccess.shared.request()
        case nil: copy(row.value)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("Copied \(row.label.lowercased())", symbol: "doc.on.doc")
    }
}
