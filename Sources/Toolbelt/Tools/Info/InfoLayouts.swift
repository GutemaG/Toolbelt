import SwiftUI

// MARK: Overview Grid

/// A card per area. Clicking one opens its details; searching looks through all five.
struct InfoOverview: View {
    let surface: Surface
    let query: String
    private var info: MacInfo { .shared }

    var body: some View {
        if info.detailOpen {
            detailBar
            Divider()
            InfoDetail(tab: info.tab, query: query, tint: info.tab.tint)
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ScrollView {
                grid
                    .padding(Space.md)
            }
            .defaultScrollAnchor(.top)
            .frame(maxHeight: .infinity)
        } else {
            searchResults
        }
    }

    private var grid: some View {
        Grid(horizontalSpacing: Space.sm, verticalSpacing: Space.sm) {
            if surface == .popover {
                GridRow { card(.battery); card(.storage) }
                GridRow { card(.hardware); card(.network) }
                GridRow { card(.developer).gridCellColumns(2) }
            } else {
                GridRow { card(.battery); card(.storage); card(.hardware) }
                GridRow { card(.network); card(.developer).gridCellColumns(2) }
            }
        }
    }

    private func card(_ tab: InfoTab) -> some View {
        InfoOverviewCard(tab: tab, selected: tab == info.tab, height: surface == .popover ? Space.section * 2 + Space.xxl : Space.section * 3 + Space.xxl) { info.open(tab) }
    }

    private var detailBar: some View {
        HStack(spacing: Space.sm) {
            Button {
                _ = info.closeDetail()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
                    .frame(width: Space.xxl, height: Space.xxl)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Back to the Overview (Esc)")
            .accessibilityLabel("Back to the Overview")
            IconTile(symbol: info.tab.symbol, tint: info.tab.tint, size: Space.xxl)
            Text(info.tab.title)
                .font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            InfoTabButtons(tab: info.tab)
                .controlSize(.small)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    /// Matching rows from every area.
    private var searchResults: some View {
        let groups = InfoTab.allCases.map { (tab: $0, sections: info.filtered($0, query: query)) }.filter { !$0.sections.isEmpty }
        return Group {
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        ForEach(groups, id: \.tab) { group in
                            InfoSectionList(sections: group.sections.map { section in
                                var titled = section
                                titled.title = "\(group.tab.title) · \(section.title)"
                                return titled
                            }, query: query, tab: group.tab, tint: group.tab.tint)
                        }
                    }
                    .padding(Space.md)
                }
                .defaultScrollAnchor(.top)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct InfoOverviewCard: View {
    let tab: InfoTab
    let selected: Bool
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false
    private var info: MacInfo { .shared }

    var body: some View {
        let summary = InfoSummary.make(tab, sections: info.sections[tab] ?? [])
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.sm) {
                    IconTile(symbol: tab.symbol, tint: tab.tint, size: Space.xxl)
                    Text(tab.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if let summary {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(summary.stat)
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(summary.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let fraction = summary.fraction {
                        Bar(fraction: fraction, color: tab.tint)
                            .frame(height: 6) // grid: ok a bar's thickness, not spacing
                    }
                } else if info.loading.contains(tab) || info.sections[tab] == nil {
                    ProgressView()
                        .controlSize(.small)
                    Spacer(minLength: 0)
                } else {
                    Text(tab == .battery ? "No Battery" : "Nothing Found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quinary), in: .rect(cornerRadius: 12))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(tab.tint.opacity(0.6))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityValue(summary.map { "\($0.stat), \($0.caption)" } ?? "")
    }
}

// MARK: Gauge Cards

/// A gauge and four cards for each tab; everything else one click away.
struct InfoGauges: View {
    let query: String
    private var info: MacInfo { .shared }

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(InfoTab.allCases) { tab in
                InfoGaugeTab(tab: tab, selected: tab == info.tab) { info.tab = tab }
            }
            Spacer(minLength: Space.xs)
            InfoTabButtons(tab: info.tab)
                .controlSize(.small)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        if query.trimmingCharacters(in: .whitespaces).isEmpty, let summary = InfoSummary.make(info.tab, sections: info.sections[info.tab] ?? []) {
            InfoGaugePage(tab: info.tab, summary: summary)
                .id(info.tab)
        } else {
            InfoDetail(tab: info.tab, query: query, tint: info.tab.tint)
        }
    }
}

private struct InfoGaugeTab: View {
    let tab: InfoTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tab.tint)
                    .frame(height: Space.lg)
                Text(tab.title)
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xs)
            .frame(minWidth: Space.section * 2 - Space.xs)
            .background(tab.tint.opacity(selected ? 0.28 : hovering ? 0.16 : 0.08), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct InfoGaugePage: View {
    let tab: InfoTab
    let summary: InfoSummary
    @State private var showsAll = false
    private var info: MacInfo { .shared }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.sm) {
                hero
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 2), spacing: Space.sm) {
                    ForEach(summary.highlights, id: \.label) { row in
                        InfoStatCard(row: row, tint: tab.tint)
                    }
                }
                Button(showsAll ? "Show Less" : "Show All Details") { showsAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                if showsAll {
                    InfoSectionList(sections: info.sections[tab] ?? [], query: "", tab: tab, tint: tab.tint)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.sm)
        }
        .defaultScrollAnchor(.top)
        .frame(maxHeight: .infinity)
    }

    private var hero: some View {
        HStack(spacing: Space.lg) {
            if let fraction = summary.fraction, tab != .network {
                InfoRing(fraction: fraction, tint: tab.tint)
                    .frame(width: Space.section * 2, height: Space.section * 2)
            } else {
                IconTile(symbol: tab.symbol, tint: tab.tint, size: Space.section * 2)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(summary.headline)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(tab.tint.opacity(0.14), in: .rect(cornerRadius: 12))
    }
}

private struct InfoRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: Space.sm)
            Circle()
                .trim(from: 0, to: min(fraction, 1))
                .stroke(tint, style: StrokeStyle(lineWidth: Space.sm, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.callout.weight(.bold))
                .monospacedDigit()
        }
        .padding(Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// A small card with one value. Clicking copies it, like a row.
private struct InfoStatCard: View {
    let row: InfoRow
    let tint: Color
    @State private var hovering = false
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: Space.sm) {
                Text(row.secret && !revealed ? "••••••••••" : row.value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let fraction = row.fraction {
                    Bar(fraction: fraction, color: tint)
                        .frame(height: 6) // grid: ok a bar's thickness, not spacing
                }
                if row.secret {
                    Spacer(minLength: 0)
                    Button(revealed ? "Hide" : "Show", systemImage: revealed ? "eye.slash" : "eye") { revealed.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help(revealed ? "Hide \(row.label.lowercased())" : "Show \(row.label.lowercased())")
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quinary), in: .rect(cornerRadius: 8))
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

// MARK: Glance Tabs

/// Tabs that show their own value, above the rows with an icon each.
struct InfoGlance: View {
    let query: String
    private var info: MacInfo { .shared }

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(InfoTab.allCases) { tab in
                InfoGlanceTab(tab: tab, selected: tab == info.tab) { info.tab = tab }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        Divider()
        InfoDetail(tab: info.tab, query: query, tint: info.tab.tint, symbols: true, buttons: true)
    }
}

private struct InfoGlanceTab: View {
    let tab: InfoTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    private var info: MacInfo { .shared }

    var body: some View {
        let stat = InfoSummary.make(tab, sections: info.sections[tab] ?? [])?.stat
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Image(systemName: tab.symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tab.tint)
                    .frame(height: Space.lg)
                Group {
                    if let stat {
                        Text(stat)
                    } else if info.loading.contains(tab) || info.sections[tab] == nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("None")
                    }
                }
                .font(.callout.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: Space.lg)
                Text(tab.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity)
            .background(selected ? AnyShapeStyle(tab.tint.opacity(0.28)) : hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quinary),
                        in: .rect(cornerRadius: 8))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(tab.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityValue(stat ?? "")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Settings

/// Settings > Info.
struct InfoOptions: View {
    @Bindable private var info = MacInfo.shared

    var body: some View {
        Section {
            Picker(selection: $info.layout) {
                ForEach(InfoLayout.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Layout")
                Text(info.layout.detail)
            }
        } footer: {
            Text("Info opens on Battery; switch tabs with ← and →. Serial numbers, hardware addresses and the public IP stay hidden until you click the eye. The public IP is looked up at api.ipify.org when Network itself opens, not for the cards, and the Wi-Fi name needs Location Services, asked only when you click it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
