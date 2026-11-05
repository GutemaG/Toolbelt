import SwiftUI

/// How the popover and panel switch tools. People choose in Settings > Appearance.
enum ToolSwitcherStyle: String, CaseIterable, Identifiable {
    case titleMenu, sideRail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleMenu: "Title Menu"
        case .sideRail: "Side Rail"
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
