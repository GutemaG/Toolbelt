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
    /// Set for a tool's own menu bar icon: shows only that tool, no picker.
    var fixedTool: Tool? = nil
    @Environment(AppModel.self) var model
    @Query(sort: \ClipItem.copiedAt, order: .reverse) var clips: [ClipItem]
    @Query(filter: #Predicate<AppLaunch> { $0.isPinned }, sort: \AppLaunch.pinOrder) var pinnedLaunches: [AppLaunch]
    @Query(sort: \Capture.createdAt, order: .reverse) var captures: [Capture]
    @Query(sort: \Snippet.title) var snippets: [Snippet]
    @State var query = ""
    @State var selected = 0
    /// Bumped by the arrow keys. Only keyboard moves scroll; hovering never does.
    @State var keyboardMoves = 0
    @State var window: NSWindow?
    @State var monitor: Any?
    @FocusState var searchFocused: Bool

    var tool: Tool { fixedTool ?? model.tool }
    /// Safe before the recorder exists, which can happen while the app starts.
    var isRecording: Bool { model.isRecording }
    var panelTools: [Tool] { ToolPrefs.shared.panelTools }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            quickActions
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
            model.pickingApps = false
            if tool == .launcher { model.apps.refresh() }
        }
        .onChange(of: query) { selected = 0 }
    }

    // MARK: Parts

    /// In the panel the tool picker sits beside the search field; the popover
    /// is narrower, so it gets its own row below.
    var header: some View {
        VStack(spacing: 0) {
            searchRow
            if surface == .popover, showsPicker {
                toolPicker
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.md)
            }
        }
    }

    var showsPicker: Bool { fixedTool == nil && panelTools.count > 1 }

    var toolPicker: some View {
        @Bindable var model = model
        return Picker("Tool", selection: $model.tool) {
            ForEach(Array(panelTools.enumerated()), id: \.element) { index, tool in
                Label(tool.title, systemImage: tool.symbol)
                    .labelStyle(.iconOnly)
                    .help("\(tool.help) (⌘\(index + 1))")
                    .tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    var searchRow: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($searchFocused)
                .accessibilityLabel(tool == .launcher ? "Search apps" : "Search clips")
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
            }
            if surface == .panel, showsPicker {
                toolPicker
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    var placeholder: String {
        switch tool {
        case .clipboard: return "Search Clips"
        case .screenshots: return "Search Screenshots"
        case .recording: return "Search Recordings"
        case .launcher: return model.pickingApps ? "Search Apps to Pin" : "Search Apps"
        default: return "Search \(tool.title)"
        }
    }

    var results: some View {
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
                        if section.grid {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.xs), count: gridColumns),
                                      spacing: Space.xs) {
                                ForEach(Array(section.entries.enumerated()), id: \.element.id) { offset, entry in
                                    tile(entry, selected: start + offset == selected)
                                        .contentShape(.rect)
                                        .onTapGesture { activate(entry, plainText: false) }
                                        .onHover { if $0 { selected = start + offset } }
                                        .contextMenu { menu(for: entry) }
                                }
                            }
                            // Drag apps from Finder or the Dock onto the grid to pin them.
                            .dropDestination(for: URL.self) { urls, _ in
                                let apps = urls.filter { $0.pathExtension == "app" }.map(\.path)
                                model.pinApps(paths: apps)
                                return !apps.isEmpty
                            }
                        } else {
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { offset, entry in
                                row(entry, selected: start + offset == selected)
                                    .contentShape(.rect)
                                    .onTapGesture { activate(entry, plainText: false) }
                                    .onHover { if $0 { selected = start + offset } }
                                    .contextMenu { menu(for: entry) }
                            }
                        }
                    }
                }
                .padding(Space.sm)
            }
            .onChange(of: keyboardMoves) {
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
    func row(_ entry: Entry, selected: Bool) -> some View {
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
                let pinned = pinnedPaths.contains(app.path)
                if pinned || selected || model.pickingApps {
                    Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.fill" : "pin") {
                        model.togglePin(appPath: app.path)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : (pinned ? AnyShapeStyle(Palette.accentText) : AnyShapeStyle(.secondary)))
                    .help(pinned ? "Unpin from the top of the Launcher (⌘P)" : "Pin to the top of the Launcher (⌘P)")
                }
            case .clip(let clip):
                ClipRow(clip: clip, icon: model.apps.icon(bundleID: clip.sourceBundleID), selected: selected)
            case .capture(let capture):
                CaptureThumbnail(capture: capture)
                    .frame(width: 56, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(capture.pixelWidth) × \(capture.pixelHeight)" + (capture.kind == .recording ? " · " + CaptureRulesText.duration(capture.duration) : ""))
                        .font(.caption)
                        .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: Space.sm)
                Text(capture.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .fixedSize()
            case .color(let hex):
                let rgb = RGB(hex: hex) ?? RGB(r: 0, g: 0, b: 0)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255))
                    .stroke(.separator)
                    .frame(width: 32, height: 32)
                Text(hex).monospaced()
                Spacer(minLength: Space.sm)
                Text(rgb.rgb + "   " + rgb.hsl)
                    .font(.caption.monospaced())
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
            case .snippet(let snippet):
                Image(systemName: "text.quote")
                    .frame(width: 20)
                Text(snippet.displayTitle)
                    .lineLimit(1)
                if !snippet.keyword.isEmpty {
                    Text(snippet.keyword)
                        .font(.caption.monospaced())
                        .padding(.horizontal, Space.xs + 2)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Text(ClipRules.preview(snippet.text, limit: 80))
                    .lineLimit(1)
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .help(String(snippet.text.prefix(500)))
                Spacer(minLength: 0)
            case .add, .action:
                EmptyView()
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

    /// A pinned app as an icon with its name below, or the Add… tile.
    func tile(_ entry: Entry, selected: Bool) -> some View {
        VStack(spacing: Space.xs) {
            switch entry {
            case .app(let app):
                Image(nsImage: model.apps.icon(for: app.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                Text(app.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(app.name)
            case .action(let action):
                Image(systemName: action.symbol)
                    .font(.system(size: 28, weight: .light))
                    .frame(width: 48, height: 48)
                Text(action.title)
                    .font(.caption)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
            default:
                Image(systemName: "plus")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.secondary))
                Text("Add…")
                    .font(.caption)
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12).fill(Palette.accent)
            } else if case .action(let action) = entry, action.isOn {
                RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.25))
            } else if case .add = entry {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            }
        }
        .help(tileHelp(entry))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    func tileHelp(_ entry: Entry) -> String {
        switch entry {
        case .add: return "Pin apps to the top of the Launcher"
        case .action(let action): return action.help
        default: return ""
        }
    }

    @ViewBuilder
    func menu(for entry: Entry) -> some View {
        switch entry {
        case .app(let app):
            Button("Open") { activate(entry, plainText: false) }
            Button(pinnedPaths.contains(app.path) ? "Unpin" : "Pin") { model.togglePin(appPath: app.path) }
                .keyboardShortcut("p")
            if pinnedPaths.contains(app.path) {
                Button("Move Left") { model.movePinned(path: app.path, by: -1) }
                Button("Move Right") { model.movePinned(path: app.path, by: 1) }
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
        case .clip(let clip):
            Button(surface == .panel ? "Paste" : "Copy") { activate(entry, plainText: false) }
            Button(surface == .panel ? "Paste as Plain Text" : "Copy as Plain Text") { activate(entry, plainText: true) }
            Button(clip.isPinned ? "Unpin" : "Pin") { model.togglePin(clip) }
                .keyboardShortcut("p")
            if clip.kind != .image {
                Button("Save as Snippet…") {
                    close()
                    model.editSnippet(model.addSnippet(title: ClipRules.preview(clip.text, limit: 40), text: clip.text))
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(clip) }
                .keyboardShortcut(.delete)
        case .add:
            Button("Add…") { activate(entry, plainText: false) }
        case .action:
            EmptyView()
        case .snippet(let snippet):
            Button(surface == .panel ? "Paste" : "Copy") { activate(entry, plainText: false) }
            Button("Edit…") { close(); model.editSnippet(snippet) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteSnippet(snippet) }
        case .color(let hex):
            let rgb = RGB(hex: hex) ?? RGB(r: 0, g: 0, b: 0)
            ForEach(ColorTextFormat.allCases, id: \.self) { format in
                Button("Copy \(rgb.text(format))") { ColorPicker.shared.copy(rgb, as: format) }
            }
            Divider()
            Button("Remove", role: .destructive) { ColorPicker.shared.forget(hex) }
        case .capture(let capture):
            Button("Open") { activate(entry, plainText: false) }
            Button("Copy") { CaptureController.shared.copy(capture) }
            if capture.kind == .screenshot {
                Button("Markup…") { close(); CaptureController.shared.markup(capture) }
                Button("Pin to Screen") { PinnedImage.pin(capture.url) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([capture.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { CaptureController.shared.delete(capture) }
        }
    }

    @ViewBuilder
    var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                   description: Text("Nothing matches “\(query)”."))
        } else if tool == .clipboard {
            ContentUnavailableView("No Clips Yet", systemImage: "doc.on.clipboard",
                                   description: Text("Copy something and it shows up here."))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    var footer: some View {
        HStack(spacing: Space.md) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.pickingApps {
                Button("Other App…") { chooseAppsToPin() }
                    .help("Choose an app outside the Applications folders")
                Button("Done") { stopPicking() }
                    .buttonStyle(.borderedProminent)
                    .help("Go back to the Launcher (esc)")
            }
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

    var hint: String { ToolActions.hint(for: tool, model: model, surface: surface) }

    // MARK: Data

    enum Entry: Identifiable {
        case app(LaunchCandidate)
        case clip(ClipItem)
        /// The Add… tile at the end of the pinned apps.
        case add
        /// A tile from ToolActions: capture modes, window positions, Keep Awake lengths.
        case action(ToolAction)
        case capture(Capture)
        /// A recently picked color, "#RRGGBB".
        case color(String)
        case snippet(Snippet)

        var id: String {
            switch self {
            case .app(let app): "a:" + app.path
            case .clip(let clip): "c:" + clip.uuid.uuidString
            case .add: "add"
            case .action(let action): "m:" + action.id
            case .color(let hex): "k:" + hex
            case .snippet(let snippet): "s:" + snippet.uuid.uuidString
            case .capture(let capture): "f:" + capture.uuid.uuidString
            }
        }

        var isApp: Bool { if case .app = self { true } else { false } }
    }

    struct Section {
        var title: String?
        var entries: [Entry]
        /// Shown as a grid of icons instead of rows.
        var grid = false
    }

    var gridColumns: Int { surface == .panel ? 6 : 4 }

    /// Pinned apps that still exist, in grid order.
    var pinnedApps: [LaunchCandidate] {
        pinnedLaunches
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { LaunchCandidate(name: AppIndex.name(atPath: $0.path), path: $0.path,
                                   launchCount: $0.count, lastLaunched: $0.lastLaunched) }
    }

    var pinnedPaths: Set<String> { Set(pinnedLaunches.map(\.path)) }

    /// How many entries the grid at the top holds (0 when it is hidden).
    var gridCount: Int {
        sections.first.map { $0.grid ? $0.entries.count : 0 } ?? 0
    }

    var sections: [Section] {
        switch tool {
        case .launcher:
            let candidates = model.launchCandidates()
            if model.pickingApps {
                let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
                let apps = searching ? LauncherRanking.rank(candidates, query: query) : candidates
                return [Section(title: "Choose Apps to Pin", entries: apps.map(Entry.app))]
            }
            let ranked = LauncherRanking.rank(candidates, query: query)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                return [Section(entries: ranked.map(Entry.app))]
            }
            // Pinned apps sit in the grid, so Frequent leaves them out.
            let pinned = pinnedApps
            let pinnedSet = Set(pinned.map(\.path))
            let frequent = LauncherRanking.rank(candidates.filter { !pinnedSet.contains($0.path) }, query: "")
            let frequentSet = Set(frequent.map(\.path))
            let rest = candidates.filter { !frequentSet.contains($0.path) }
            return [Section(title: "Pinned", entries: pinned.map(Entry.app) + [.add], grid: true),
                    frequent.isEmpty ? nil : Section(title: "Frequent", entries: frequent.map(Entry.app)),
                    Section(title: "Applications", entries: rest.map(Entry.app))]
                .compactMap { $0 }
        case .clipboard:
            let matching = clips.filter { $0.kind == .image ? query.isEmpty : ClipRules.matches(query, text: $0.text) }
            let pinned = matching.filter(\.isPinned).map(Entry.clip)
            let recent = matching.filter { !$0.isPinned }.map(Entry.clip)
            return [pinned.isEmpty ? nil : Section(title: "Pinned", entries: pinned),
                    recent.isEmpty ? nil : Section(title: pinned.isEmpty ? nil : "Recent", entries: recent)]
                .compactMap { $0 }
        default:
            var result: [Section] = []
            if let grid = ToolActions.grid(for: tool, model: model, query: query) {
                // The Timer reads the search field as a length; other tools filter by name.
                let typedLength = tool == .timer && TimerRules.parse(query) != nil
                let actions = grid.actions.filter { query.isEmpty || typedLength || ClipRules.matches(query, text: $0.title) }
                if !actions.isEmpty { result.append(Section(title: grid.title, entries: actions.map(Entry.action), grid: true)) }
            }
            switch tool {
            case .screenshots, .recording:
                let kind: CaptureKind = tool == .screenshots ? .screenshot : .recording
                let recent = captures.filter { $0.kind == kind && $0.exists && (query.isEmpty || ClipRules.matches(query, text: $0.name)) }
                if !recent.isEmpty { result.append(Section(title: "Recent", entries: recent.map(Entry.capture))) }
            case .snippets:
                let found = model.searchSnippets(snippets, query: query)
                if !found.isEmpty { result.append(Section(title: query.isEmpty ? "All Snippets" : nil, entries: found.map(Entry.snippet))) }
            case .colors:
                let recent = model.recentColors.filter { query.isEmpty || ClipRules.matches(query, text: $0) }
                if !recent.isEmpty { result.append(Section(title: "Recent", entries: recent.map(Entry.color))) }
            default:
                break
            }
            return result
        }
    }

    var flatEntries: [Entry] { sections.flatMap(\.entries) }

    // MARK: Actions

    func reset() {
        model.pickingApps = false
        query = ""
        selected = 0
        model.apps.refresh()
        searchFocused = true
    }

    func activate(_ entry: Entry, plainText: Bool) {
        switch entry {
        case .app(let app):
            if model.pickingApps {
                model.togglePin(appPath: app.path)
                return
            }
            close()
            model.open(app)
        case .clip(let clip):
            if surface == .panel {
                PanelController.shared.paste(clip, plainText: plainText)
            } else {
                model.copy(clip, plainText: plainText)
                close()
            }
        case .action(let action):
            if action.closes { close() }
            action.run()
        case .snippet(let snippet):
            snippet.lastUsed = .now
            try? model.context.save()
            if surface == .panel {
                PanelController.shared.paste(text: snippet.text)
            } else {
                model.clipboard.write(text: snippet.text)
                close()
            }
        case .color(let hex):
            if let rgb = RGB(hex: hex) { ColorPicker.shared.copy(rgb, as: ColorPicker.format) }
            close()
        case .capture(let capture):
            close()
            NSWorkspace.shared.open(capture.url)
        case .add:
            query = ""
            selected = 0
            model.pickingApps = true
            searchFocused = true
        }
    }

    func stopPicking() {
        model.pickingApps = false
        query = ""
        selected = 0
        searchFocused = true
    }

    /// Add…: pick apps in an Open panel and pin them.
    func chooseAppsToPin() {
        // The popover closes by itself when the Open panel takes focus.
        if surface == .panel { close() }
        NSApp.unhide(nil)
        NSApp.activate()
        let open = NSOpenPanel()
        open.title = "Pin Apps"
        open.prompt = "Pin"
        open.message = "Choose apps to pin to the top of the Launcher."
        open.allowedContentTypes = [.application]
        open.allowsMultipleSelection = true
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        if open.runModal() == .OK { model.pinApps(paths: open.urls.map(\.path)) }
        // Come back to the Launcher so the new tiles are in view.
        switch surface {
        case .panel: PanelController.shared.show(.launcher)
        case .popover: StatusItems.shared?.showMainPopover()
        }
    }

    func close() {
        switch surface {
        case .panel: PanelController.shared.hide()
        case .popover: StatusItems.shared?.closePopovers()
        }
    }

    func openSettings() {
        close()
        SettingsWindow.shared.show(model: model)
    }
}
