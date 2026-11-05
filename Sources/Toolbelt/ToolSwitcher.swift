import SwiftUI

/// How the popover and panel switch tools. People choose in Settings > Appearance.
enum ToolSwitcherStyle: String, CaseIterable, Identifiable {
    case colorTiles, titleMenu, sideRail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colorTiles: "Color Tiles"
        case .titleMenu: "Title Menu"
        case .sideRail: "Side Rail"
        }
    }

    var detail: String {
        switch self {
        case .colorTiles: "A tile for each tool, in its own color, under the search field."
        case .titleMenu: "The tool's name beside the search field opens a menu of every tool (⌘T)."
        case .sideRail: "A column of tool icons stays down the left side."
        }
    }
}

/// A tile per tool under the search field: tinted in the tool's color, filled
/// when chosen. Hovering one names it at once, under the tile; the system
/// tooltip is slow and can stay away while the app is inactive. All on one row
/// in the panel, two balanced rows in the narrower popover.
struct ToolTiles: View {
    let tools: [Tool]
    let current: Tool
    let surface: Surface
    @Binding var hovered: Tool?
    let pick: (Tool) -> Void

    private var size: CGFloat { surface == .panel ? Space.section : Space.section + Space.xs }
    private var gap: CGFloat { surface == .panel ? Space.xs : Space.sm }
    private var perRow: Int { surface == .panel ? max(tools.count, 1) : max((tools.count + 1) / 2, 1) }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(size), spacing: gap), count: perRow), spacing: gap) {
            ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                Button {
                    pick(tool)
                } label: {
                    tile(tool)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = tool } else if hovered == tool { hovered = nil }
                }
                .overlay(alignment: labelAlignment(index)) {
                    if tool == hovered { label(tool, index: index) }
                }
                .zIndex(tool == hovered ? 1 : 0)
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(tool == current ? [.isSelected, .isButton] : .isButton)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    /// Tiles at the ends line up with the label, so the window doesn't cut it off.
    private func labelAlignment(_ index: Int) -> Alignment {
        switch index % perRow {
        case 0: .topLeading
        case perRow - 1: .topTrailing
        default: .top
        }
    }

    /// The name under the tile: an empty spacer the tile's height pushes it down.
    private func label(_ tool: Tool, index: Int) -> some View {
        VStack(alignment: labelAlignment(index).horizontal, spacing: 0) {
            Color.clear.frame(width: 0, height: size + Space.xs)
            HStack(spacing: Space.xs) {
                Text(tool.title)
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: .capsule)
            .shadow(radius: 2, y: 1)
        }
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(_ tool: Tool) -> some View {
        if tool == current {
            IconTile(symbol: tool.symbol, tint: tool.tint, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(tool.tint.opacity(tool == hovered ? 0.35 : 0.18))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: tool.symbol)
                        .font(.system(size: size * 0.5, weight: .medium))
                        .foregroundStyle(tool.tint)
                }
                .contentShape(.rect)
        }
    }
}

/// The current tool's icon and name beside the search field. Clicking opens
/// the menu of every tool.
struct ToolMenuButton: View {
    let tool: Tool
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                IconTile(symbol: tool.symbol, tint: tool.tint, size: Space.xxl)
                Text(tool.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, Space.xs)
            .padding(.trailing, Space.sm)
            .padding(.vertical, Space.xs)
            .background(isOpen || hovering ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary),
                        in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Switch tools (⌘T)")
        .accessibilityLabel("Switch tools, \(tool.title) is open")
    }
}

/// Every tool with its name, over the content under the header.
struct ToolMenu: View {
    let tools: [Tool]
    let current: Tool
    let columns: Int
    @Binding var highlighted: Int
    let pick: (Tool) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.xs), count: columns), spacing: Space.xs) {
            ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                Button {
                    pick(tool)
                } label: {
                    VStack(spacing: Space.xs) {
                        IconTile(symbol: tool.symbol, tint: tool.tint, size: Space.section)
                        Text(tool.title)
                            .font(.caption.weight(tool == current ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.sm)
                    .background(index == highlighted ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
                .help(tool.help + (index < 9 ? " (⌘\(index + 1))" : ""))
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(tool == current ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(Space.sm)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: Space.md, y: Space.xs)
        .padding(.horizontal, Space.sm)
        .padding(.top, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }
}

/// A column of colored tool icons down the left side. Hovering one names it
/// in the footer; a floating label would be cut off by the scrolling column.
struct ToolRail: View {
    let tools: [Tool]
    let current: Tool
    @Binding var hovered: Tool?
    let pick: (Tool) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(tools) { tool in
                        Button {
                            pick(tool)
                        } label: {
                            icon(tool)
                                .frame(width: Space.section, height: Space.xxl)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { hovered = tool } else if hovered == tool { hovered = nil }
                        }
                        .help(tool.title)
                        .accessibilityLabel(tool.title)
                        .accessibilityAddTraits(tool == current ? [.isSelected, .isButton] : .isButton)
                        .id(tool)
                    }
                }
                .padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity)
            }
            .frame(width: Space.section + Space.md)
            .background(.fill.quaternary)
            .onAppear { proxy.scrollTo(current) }
            .onChange(of: current) { proxy.scrollTo(current) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    @ViewBuilder
    private func icon(_ tool: Tool) -> some View {
        if tool == current {
            IconTile(symbol: tool.symbol, tint: tool.tint, size: Space.xxl)
        } else {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tool == hovered ? AnyShapeStyle(.primary) : AnyShapeStyle(tool.tint))
        }
    }
}
