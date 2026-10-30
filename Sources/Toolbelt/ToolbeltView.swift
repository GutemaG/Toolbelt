import AppKit
import SwiftData
import SwiftUI
import ToolbeltKit

/// Where a ToolbeltView lives. In the popover Return copies a clip; in the
/// panel Return pastes it into the app that was in front.
enum Surface {
    case popover, panel
}

/// The search field, the result list, and the footer, shared by the menu bar
/// popover and the floating panel.
struct ToolbeltView: View {
    let surface: Surface
    @Environment(AppModel.self) private var model
    @Query(sort: \ClipItem.copiedAt, order: .reverse) private var clips: [ClipItem]
    @State private var query = ""
    @State private var selected = 0
    @State private var window: NSWindow?
    @State private var monitor: Any?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
            Divider()
            footer
        }
        .background(WindowReader { window = $0 })
        .modifier(SurfaceBackground(surface: surface))
        .onAppear {
            installKeyMonitor()
            reset()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: model.openCount) { reset() }
        .onChange(of: model.tool) {
            query = ""
            selected = 0
            if model.tool == .launcher { model.apps.refresh() }
        }
        .onChange(of: query) { selected = 0 }
    }

    // MARK: Parts

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            TextField(model.tool == .launcher ? "Search Apps" : "Search Clips", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($searchFocused)
                .accessibilityLabel(model.tool == .launcher ? "Search apps" : "Search clips")
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
            }
            Picker("Tool", selection: $model.tool) {
                ForEach(Tool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol)
                        .labelStyle(.iconOnly)
                        .help(tool.help)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private var results: some View {
        let sections = self.sections
        let count = sections.reduce(0) { $0 + $1.entries.count }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        if let title = section.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Space.sm)
                                .padding(.top, Space.sm)
                                .padding(.bottom, Space.xs)
                                .accessibilityAddTraits(.isHeader)
                        }
                        let start = sections[..<index].reduce(0) { $0 + $1.entries.count }
                        ForEach(Array(section.entries.enumerated()), id: \.element.id) { offset, entry in
                            row(entry, selected: start + offset == selected)
                                .contentShape(.rect)
                                .onTapGesture { activate(entry, plainText: false) }
                                .onHover { if $0 { selected = start + offset } }
                        }
                    }
                }
                .padding(Space.sm)
            }
            .onChange(of: selected) {
                let entries = flatEntries
                if entries.indices.contains(selected) { proxy.scrollTo(entries[selected].id) }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if count == 0 { emptyState }
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: Space.md) {
            switch entry {
            case .app(let app):
                Image(nsImage: model.apps.icon(for: app.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(app.name)
                Spacer(minLength: 0)
            case .clip(let clip):
                ClipRow(clip: clip, icon: model.apps.icon(bundleID: clip.sourceBundleID), selected: selected)
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected { RoundedRectangle(cornerRadius: 8).fill(Palette.accent) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: entry.isApp ? "Open" : (surface == .panel ? "Paste" : "Copy")) {
            activate(entry, plainText: false)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                   description: Text(model.tool == .launcher
                                                     ? "No apps match “\(query)”."
                                                     : "No clips match “\(query)”."))
        } else if model.tool == .clipboard {
            ContentUnavailableView("No Clips Yet", systemImage: "doc.on.clipboard",
                                   description: Text("Copy something and it shows up here."))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings", systemImage: "gearshape") { openSettings() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Open Toolbelt settings (⌘,)")
            Button("Quit Toolbelt", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Quit Toolbelt (⌘Q)")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }

    private var hint: String {
        switch model.tool {
        case .launcher: return "↩ Open"
        case .clipboard:
            let main = surface == .panel ? "↩ Paste   ⌥↩ Paste as Plain Text" : "↩ Copy"
            return main + "   ⌘P Pin   ⌘⌫ Delete"
        }
    }

    // MARK: Data

    enum Entry: Identifiable {
        case app(LaunchCandidate)
        case clip(ClipItem)

        var id: String {
            switch self {
            case .app(let app): "a:" + app.path
            case .clip(let clip): "c:" + clip.uuid.uuidString
            }
        }

        var isApp: Bool { if case .app = self { true } else { false } }
    }

    struct Section {
        var title: String?
        var entries: [Entry]
    }

    private var sections: [Section] {
        switch model.tool {
        case .launcher:
            let candidates = model.launchCandidates()
            let ranked = LauncherRanking.rank(candidates, query: query)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                return [Section(entries: ranked.map(Entry.app))]
            }
            let frequent = Set(ranked.map(\.path))
            let rest = candidates.filter { !frequent.contains($0.path) }
            if ranked.isEmpty { return [Section(title: "Applications", entries: rest.map(Entry.app))] }
            return [Section(title: "Frequent", entries: ranked.map(Entry.app)),
                    Section(title: "Applications", entries: rest.map(Entry.app))]
        case .clipboard:
            let matching = clips.filter { $0.kind == .image ? query.isEmpty : ClipRules.matches(query, text: $0.text) }
            let pinned = matching.filter(\.isPinned).map(Entry.clip)
            let recent = matching.filter { !$0.isPinned }.map(Entry.clip)
            return [pinned.isEmpty ? nil : Section(title: "Pinned", entries: pinned),
                    recent.isEmpty ? nil : Section(title: pinned.isEmpty ? nil : "Recent", entries: recent)]
                .compactMap { $0 }
        }
    }

    private var flatEntries: [Entry] { sections.flatMap(\.entries) }

    // MARK: Actions

    private func reset() {
        query = ""
        selected = 0
        model.apps.refresh()
        searchFocused = true
    }

    private func activate(_ entry: Entry, plainText: Bool) {
        switch entry {
        case .app(let app):
            close()
            model.open(app)
        case .clip(let clip):
            if surface == .panel {
                PanelController.shared.paste(clip, plainText: plainText)
            } else {
                model.copy(clip, plainText: plainText)
                close()
            }
        }
    }

    private func close() {
        switch surface {
        case .panel: PanelController.shared.hide()
        case .popover: StatusItemController.shared?.closePopover()
        }
    }

    private func openSettings() {
        close()
        SettingsWindow.shared.show(model: model)
    }

    // MARK: Keyboard

    /// Arrow keys, Return, Escape, and Command shortcuts while the search
    /// field has focus. A local monitor sees them before the field editor.
    private func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window === window else { return event }
            return handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let entries = flatEntries
        let current = entries.indices.contains(selected) ? entries[selected] : nil
        switch (event.keyCode, flags.contains(.command)) {
        case (125, false): // Down
            selected = min(selected + 1, max(entries.count - 1, 0))
        case (126, false): // Up
            selected = max(selected - 1, 0)
        case (36, _), (76, _): // Return, Enter
            if let current { activate(current, plainText: flags.contains(.option)) }
        case (53, _): // Escape
            if query.isEmpty { close() } else { query = "" }
        case (48, false): // Tab switches tool
            model.tool = model.tool == .launcher ? .clipboard : .launcher
        case (18, true): model.tool = .launcher   // Command-1
        case (19, true): model.tool = .clipboard  // Command-2
        case (43, true): openSettings()            // Command-,
        case (12, true): NSApp.terminate(nil)      // Command-Q
        case (35, true): // Command-P pins
            guard case .clip(let clip)? = current else { return false }
            model.togglePin(clip)
        case (51, true): // Command-Delete
            guard case .clip(let clip)? = current else { return false }
            model.delete(clip)
            selected = min(selected, max(entries.count - 2, 0))
        default:
            return false
        }
        return true
    }
}

/// One clip: source app icon, a one-line preview or thumbnail, and its age.
private struct ClipRow: View {
    let clip: ClipItem
    let icon: NSImage?
    let selected: Bool

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "doc.on.clipboard").frame(width: 20, height: 20)
            }
            switch clip.kind {
            case .image:
                if let thumb = Thumbnails.shared.image(for: clip) {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 48)
                        .clipShape(.rect(cornerRadius: 4))
                }
                Text("Image")
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
            case .link:
                Image(systemName: "link").font(.caption)
                Text(ClipRules.preview(clip.text))
                    .lineLimit(1)
                    .help(String(clip.text.prefix(500)))
            case .text:
                Text(ClipRules.preview(clip.text))
                    .lineLimit(1)
                    .help(String(clip.text.prefix(500)))
            }
            Spacer(minLength: Space.sm)
            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .accessibilityLabel("Pinned")
            }
            Text(clip.copiedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption)
                .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                .fixedSize()
        }
    }
}

/// Small images for clip rows, made once per clip.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [UUID: NSImage] = [:]

    func image(for clip: ClipItem) -> NSImage? {
        if let image = cache[clip.uuid] { return image }
        guard let data = clip.imageData, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache[clip.uuid] = image
        return image
    }
}

/// The panel gets Liquid Glass with rounded corners; the popover draws its own.
private struct SurfaceBackground: ViewModifier {
    let surface: Surface

    func body(content: Content) -> some View {
        switch surface {
        case .panel:
            content
                .frame(width: PanelController.size.width, height: PanelController.size.height)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
        case .popover:
            content.frame(width: 440, height: 480)
        }
    }
}

/// Reports the NSWindow a view sits in.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.found = found
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [found] in found?(window) }
        }
    }
}
