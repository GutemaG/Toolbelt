import AppKit
import SwiftUI

/// Every tool in Toolbelt. Settings pages, menu bar icons, shortcuts and the
/// panel picker all read from this, so a new tool shows up everywhere at once.
enum Tool: String, CaseIterable, Identifiable {
    case launcher, clipboard, screenshots, recording, colors, windows, keepAwake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launcher: "Launcher"
        case .clipboard: "Clipboard"
        case .screenshots: "Screenshots"
        case .recording: "Recording"
        case .colors: "Colors"
        case .windows: "Windows"
        case .keepAwake: "Keep Awake"
        }
    }

    var symbol: String {
        switch self {
        case .launcher: "magnifyingglass"
        case .clipboard: "doc.on.clipboard"
        case .screenshots: "camera.viewfinder"
        case .recording: "record.circle"
        case .colors: "eyedropper"
        case .windows: "rectangle.split.2x1"
        case .keepAwake: "cup.and.saucer"
        }
    }

    /// One line under the title in Settings.
    var summary: String {
        switch self {
        case .launcher: "Find and open apps, with your pinned apps on top."
        case .clipboard: "Search everything you copied and paste it again."
        case .screenshots: "Capture an area, a window or the whole screen."
        case .recording: "Record an area, a window or the screen to a movie."
        case .colors: "Pick any color on the screen and copy it."
        case .windows: "Snap the front window to halves, thirds or full size."
        case .keepAwake: "Stop the Mac from sleeping for a while."
        }
    }

    /// The color of the tool's icon tile in Settings.
    var tint: Color {
        switch self {
        case .launcher: .blue
        case .clipboard: .orange
        case .screenshots: .purple
        case .recording: .red
        case .colors: .teal
        case .windows: .indigo
        case .keepAwake: .brown
        }
    }

    var help: String {
        switch self {
        case .launcher: "Find and open apps"
        case .clipboard: "Search clipboard history"
        case .screenshots: "Take a screenshot"
        case .recording: "Record the screen"
        case .colors: "Pick a color"
        case .windows: "Snap windows"
        case .keepAwake: "Keep the Mac awake"
        }
    }

    /// The tool's shortcuts as shown on screen.
    @MainActor var shortcutLabel: String {
        let labels = ShortcutID.all.filter { $0.tool == self }.compactMap { ShortcutStore.shared.combo(for: $0)?.label }
        return labels.isEmpty ? "None" : labels.prefix(3).joined(separator: ", ")
    }
}

/// Which tools are on, which have their own menu bar icon, and the order of
/// the panel. Saved in UserDefaults; test and snapshot runs keep it in memory.
@Observable
final class ToolPrefs {
    static let shared = ToolPrefs()

    var enabled: Set<Tool> { didSet { changed() } }
    var ownIcon: Set<Tool> { didSet { changed() } }
    var inPanel: Set<Tool> { didSet { changed() } }
    var panelOrder: [Tool] { didSet { changed() } }
    var showMainIcon: Bool { didSet { changed() } }
    var showInDock: Bool { didSet { changed() } }

    /// Called after every change; AppDelegate applies it to the menu bar, shortcuts and Dock.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?

    init() {
        defaults = Store.isOverridden ? nil : .standard
        func tools(_ key: String, _ fallback: [Tool]) -> [Tool] {
            guard let raw = UserDefaults.standard.stringArray(forKey: key), !Store.isOverridden else { return fallback }
            return raw.compactMap(Tool.init(rawValue:))
        }
        // A tool missing from the saved order came with a later version: it
        // starts on and in the panel, at the end, instead of staying hidden.
        let order = tools("tools.panelOrder", Tool.allCases)
        // "tools.known" lists every tool the last saved version had. Older
        // versions did not save it; their order is the best guess.
        let added = Self.newTools(savedOrder: tools("tools.known", order))
        enabled = Set(tools("tools.enabled", Tool.allCases) + added)
        ownIcon = Set(tools("tools.ownIcon", []))
        inPanel = Set(tools("tools.inPanel", Tool.allCases) + added)
        panelOrder = order + added.filter { !order.contains($0) }
        showMainIcon = Store.isOverridden ? true : (UserDefaults.standard.object(forKey: "tools.showMainIcon") as? Bool ?? true)
        showInDock = Store.isOverridden ? false : UserDefaults.standard.bool(forKey: "tools.showInDock")
    }

    /// Tools this version has that a saved order from an older version lacks.
    static func newTools(savedOrder: [Tool]) -> [Tool] {
        Tool.allCases.filter { !savedOrder.contains($0) }
    }

    /// The tools the Toolbelt panel shows, in order.
    var panelTools: [Tool] {
        panelOrder.filter { enabled.contains($0) && inPanel.contains($0) }
    }

    func move(_ tool: Tool, by offset: Int) {
        guard let from = panelOrder.firstIndex(of: tool) else { return }
        let to = min(max(from + offset, 0), panelOrder.count - 1)
        var order = panelOrder
        order.insert(order.remove(at: from), at: to)
        panelOrder = order
    }

    /// Binding for a switch that adds or removes a tool from one of the sets.
    func binding(_ keyPath: ReferenceWritableKeyPath<ToolPrefs, Set<Tool>>, _ tool: Tool) -> Binding<Bool> {
        Binding(get: { self[keyPath: keyPath].contains(tool) },
                set: { on in
                    if on { self[keyPath: keyPath].insert(tool) } else { self[keyPath: keyPath].remove(tool) }
                })
    }

    private func changed() {
        if let defaults {
            defaults.set(enabled.map(\.rawValue), forKey: "tools.enabled")
            defaults.set(ownIcon.map(\.rawValue), forKey: "tools.ownIcon")
            defaults.set(inPanel.map(\.rawValue), forKey: "tools.inPanel")
            defaults.set(panelOrder.map(\.rawValue), forKey: "tools.panelOrder")
            defaults.set(Tool.allCases.map(\.rawValue), forKey: "tools.known")
            defaults.set(showMainIcon, forKey: "tools.showMainIcon")
            defaults.set(showInDock, forKey: "tools.showInDock")
        }
        onChange?()
    }
}

/// A small rounded square in the tool's color with its symbol, like System
/// Settings. The symbol is white on purpose: the tile colors are fixed and
/// all dark enough, so it never sits on a user-chosen accent.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
