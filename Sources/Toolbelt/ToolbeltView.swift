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
    @Environment(AppModel.self) private var model
    @Query(sort: \ClipItem.copiedAt, order: .reverse) private var clips: [ClipItem]
    @Query(filter: #Predicate<AppLaunch> { $0.isPinned }, sort: \AppLaunch.pinOrder) private var pinnedLaunches: [AppLaunch]
    @Query(sort: \Capture.createdAt, order: .reverse) private var captures: [Capture]
    @State private var query = ""
    @State private var selected = 0
    /// Bumped by the arrow keys. Only keyboard moves scroll; hovering never does.
    @State private var keyboardMoves = 0
    @State private var window: NSWindow?
    @State private var monitor: Any?
    @FocusState private var searchFocused: Bool

    private var tool: Tool { fixedTool ?? model.tool }
    /// Safe before the recorder exists, which can happen while the app starts.
    private var isRecording: Bool { model.isRecording }
    private var panelTools: [Tool] { ToolPrefs.shared.panelTools }

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

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: Space.md) {
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
            if fixedTool == nil, panelTools.count > 1 {
                Picker("Tool", selection: $model.tool) {
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
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    /// A thin row of capture buttons under the search field in the Launcher,
    /// so screenshots and recording are one click from the menu bar.
    @ViewBuilder
    private var quickActions: some View {
        let prefs = ToolPrefs.shared
        let shots = prefs.enabled.contains(.screenshots), record = prefs.enabled.contains(.recording)
        if tool == .launcher, !model.pickingApps, shots || record {
            HStack(spacing: Space.sm) {
                if shots {
                    ForEach(CaptureMode.allCases) { mode in
                        quickButton(mode.title, symbol: mode.symbol,
                                    help: mode == .screen ? "Screenshot of the whole screen (⌃⇧3)"
                                        : "Screenshot of \(mode == .area ? "an area" : "a window") (⌃⇧4)") {
                            close()
                            CaptureController.shared.screenshot(mode)
                        }
                    }
                }
                if shots && record {
                    Divider().frame(height: Space.lg)
                }
                if record {
                    quickButton(isRecording ? "Stop" : "Record", symbol: isRecording ? "stop.circle.fill" : "record.circle",
                                help: isRecording ? "Stop recording (⌃⇧5)" : "Record an area, a window or the screen (⌃⇧5)") {
                        close()
                        isRecording ? Recorder.shared?.stop() : Recorder.shared?.start(.area)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            Divider()
        }
    }

    private func quickButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(QuickActionStyle())
        .help(help)
    }

    private var placeholder: String {
        switch tool {
        case .clipboard: return "Search Clips"
        case .screenshots: return "Search Screenshots"
        case .recording: return "Search Recordings"
        case .launcher: return model.pickingApps ? "Search Apps to Pin" : "Search Apps"
        }
    }

    private var searchNoun: String {
        switch tool {
        case .launcher: "apps"
        case .clipboard: "clips"
        case .screenshots: "screenshots"
        case .recording: "recordings"
        }
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
    private func tile(_ entry: Entry, selected: Bool) -> some View {
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
            case .action(let mode):
                Image(systemName: isRecording && tool == .recording ? "stop.circle.fill" : mode.symbol)
                    .font(.system(size: 28, weight: .light))
                    .frame(width: 48, height: 48)
                Text(isRecording && tool == .recording ? "Stop" : mode.title)
                    .font(.caption)
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
            } else if case .add = entry {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            }
        }
        .help(tileHelp(entry))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func tileHelp(_ entry: Entry) -> String {
        switch entry {
        case .add: return "Pin apps to the top of the Launcher"
        case .action(let mode):
            if tool == .recording { return isRecording ? "Stop recording (⌃⇧5)" : "Record \(mode.title.lowercased())" }
            return mode == .screen ? "Capture the whole screen (⌃⇧3)" : "Capture \(mode == .area ? "an area" : "a window") (⌃⇧4)"
        default: return ""
        }
    }

    @ViewBuilder
    private func menu(for entry: Entry) -> some View {
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
            Divider()
            Button("Delete", role: .destructive) { model.delete(clip) }
                .keyboardShortcut(.delete)
        case .add:
            Button("Add…") { activate(entry, plainText: false) }
        case .action:
            EmptyView()
        case .capture(let capture):
            Button("Open") { activate(entry, plainText: false) }
            Button("Copy") { CaptureController.shared.copy(capture) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([capture.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { CaptureController.shared.delete(capture) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                   description: Text("No \(searchNoun) match “\(query)”."))
        } else if tool == .clipboard {
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

    private var hint: String {
        switch tool {
        case .launcher: return model.pickingApps ? "↩ Pin or Unpin   esc Done" : "↩ Open   ⌘P Pin"
        case .screenshots: return "⌃⇧4 Area or Window   ⌃⇧3 Screen   ↩ Open"
        case .recording: return isRecording ? "⌃⇧5 Stop" : "⌃⇧5 Start or Stop   ↩ Open"
        case .clipboard:
            let main = surface == .panel ? "↩ Paste   ⌥↩ Paste as Plain Text" : "↩ Copy"
            return main + "   ⌘P Pin   ⌘⌫ Delete"
        }
    }

    // MARK: Data

    enum Entry: Identifiable {
        case app(LaunchCandidate)
        case clip(ClipItem)
        /// The Add… tile at the end of the pinned apps.
        case add
        /// Area, Window or Screen in the capture tools.
        case action(CaptureMode)
        case capture(Capture)

        var id: String {
            switch self {
            case .app(let app): "a:" + app.path
            case .clip(let clip): "c:" + clip.uuid.uuidString
            case .add: "add"
            case .action(let mode): "m:" + mode.rawValue
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

    private var gridColumns: Int { surface == .panel ? 6 : 4 }

    /// Pinned apps that still exist, in grid order.
    private var pinnedApps: [LaunchCandidate] {
        pinnedLaunches
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { LaunchCandidate(name: AppIndex.name(atPath: $0.path), path: $0.path,
                                   launchCount: $0.count, lastLaunched: $0.lastLaunched) }
    }

    private var pinnedPaths: Set<String> { Set(pinnedLaunches.map(\.path)) }

    /// How many entries the grid at the top holds (0 when it is hidden).
    private var gridCount: Int {
        sections.first.map { $0.grid ? $0.entries.count : 0 } ?? 0
    }

    private var sections: [Section] {
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
        case .screenshots, .recording:
            let kind: CaptureKind = tool == .screenshots ? .screenshot : .recording
            let recent = captures.filter { $0.kind == kind && $0.exists && (query.isEmpty || ClipRules.matches(query, text: $0.name)) }
            let modes: [CaptureMode] = tool == .recording && isRecording ? [.area] : CaptureMode.allCases
            var result: [Section] = []
            if query.isEmpty { result.append(Section(title: tool == .screenshots ? "Capture" : "Record", entries: modes.map(Entry.action), grid: true)) }
            if !recent.isEmpty { result.append(Section(title: "Recent", entries: recent.map(Entry.capture))) }
            return result
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
        model.pickingApps = false
        query = ""
        selected = 0
        model.apps.refresh()
        searchFocused = true
    }

    private func activate(_ entry: Entry, plainText: Bool) {
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
        case .action(let mode):
            close()
            if tool == .recording {
                isRecording ? Recorder.shared?.stop() : Recorder.shared?.start(mode)
            } else {
                CaptureController.shared.screenshot(mode)
            }
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

    private func stopPicking() {
        model.pickingApps = false
        query = ""
        selected = 0
        searchFocused = true
    }

    /// Add…: pick apps in an Open panel and pin them.
    private func chooseAppsToPin() {
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

    private func close() {
        switch surface {
        case .panel: PanelController.shared.hide()
        case .popover: StatusItems.shared?.closePopovers()
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

    /// Key codes of 1 to 9 on the top row.
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let entries = flatEntries
        let current = entries.indices.contains(selected) ? entries[selected] : nil
        switch (event.keyCode, flags.contains(.command)) {
        case (125, false): // Down: one row, or one grid row inside the pinned grid
            let step = selected < gridCount ? min(gridColumns, max(gridCount - selected, 1)) : 1
            selected = min(selected + step, max(entries.count - 1, 0))
        case (126, false): // Up
            if selected < gridCount { selected = max(selected - gridColumns, 0) }
            else if selected == gridCount { selected = max(gridCount - 1, 0) }
            else { selected = max(selected - 1, 0) }
        case (124, false) where selected < gridCount && query.isEmpty: // Right, inside the grid
            selected = min(selected + 1, gridCount - 1)
        case (123, false) where selected < gridCount && query.isEmpty: // Left, inside the grid
            selected = max(selected - 1, 0)
        case (36, _), (76, _): // Return, Enter
            if let current { activate(current, plainText: flags.contains(.option)) }
        case (53, _): // Escape
            if !query.isEmpty { query = "" } else if model.pickingApps { stopPicking() } else { close() }
        case (48, false) where fixedTool == nil && panelTools.count > 1: // Tab switches tool
            let index = panelTools.firstIndex(of: model.tool) ?? 0
            model.tool = panelTools[(index + 1) % panelTools.count]
        case (let key, true) where fixedTool == nil && Self.digitKeys.firstIndex(of: key).map({ $0 < panelTools.count }) == true:
            model.tool = panelTools[Self.digitKeys.firstIndex(of: key)!] // Command-1 to Command-9
        case (43, true): openSettings()            // Command-,
        case (12, true): NSApp.terminate(nil)      // Command-Q
        case (35, true): // Command-P pins a clip or an app
            switch current {
            case .clip(let clip)?: model.togglePin(clip)
            case .app(let app)?: model.togglePin(appPath: app.path)
            default: return false
            }
        case (51, true): // Command-Delete
            guard case .clip(let clip)? = current else { return false }
            model.delete(clip)
            selected = min(selected, max(entries.count - 2, 0))
        default:
            return false
        }
        if [123, 124, 125, 126].contains(event.keyCode) { keyboardMoves += 1 }
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

/// The capture buttons under the Launcher search: full-contrast text on a
/// tinted fill. The system bordered style washes out on the glass panel and
/// in the popover, so these draw their own fill and hover state.
private struct QuickActionStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs + 2)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering || configuration.isPressed ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.fill.secondary))
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
