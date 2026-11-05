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
    @State var toolMenuOpen = false
    /// The tool the arrow keys or the pointer are on in the open menu.
    @State var toolMenuIndex = 0
    @State var hoveredTool: Tool?
    @FocusState var searchFocused: Bool

    var tool: Tool { fixedTool ?? model.tool }
    /// Safe before the recorder exists, which can happen while the app starts.
    var isRecording: Bool { model.isRecording }
    var panelTools: [Tool] { ToolPrefs.shared.panelTools }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if usesRail {
                    ToolRail(tools: panelTools, current: tool, hovered: $hoveredTool) { model.tool = $0 }
                    Divider()
                }
                VStack(spacing: 0) {
                    header
                        .zIndex(1) // a tile's name floats over the list
                    Divider()
                    ZStack(alignment: .top) {
                        toolContent
                        if toolMenuOpen, usesTitleMenu {
                            // A click beside the menu closes it, and doesn't reach the list.
                            Color.clear
                                .contentShape(.rect)
                                .onTapGesture { toolMenuOpen = false }
                            ToolMenu(tools: panelTools, current: tool, columns: toolMenuColumns, highlighted: $toolMenuIndex) { chosen in
                                model.tool = chosen
                                toolMenuOpen = false
                            }
                        }
                    }
                }
            }
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
            toolMenuOpen = false
            query = ""
            selected = 0
            model.pickingApps = false
            WorldClock.shared.travel = 0
            if tool == .launcher { model.apps.refresh() }
        }
        .onChange(of: query) {
            selected = 0
            toolMenuOpen = false
        }
        // The chosen city stays chosen when the list changes order.
        .onChange(of: WorldClock.shared.cities) { old, new in
            guard query.isEmpty, old.indices.contains(selected), let index = new.firstIndex(of: old[selected]) else { return }
            selected = index
        }
    }

    @ViewBuilder
    var toolContent: some View {
        VStack(spacing: 0) {
            quickActions
            if tool == .system {
                SystemGauges(window: window)
                Divider()
            }
            if tool == .worldClock {
                LocalTimeRow(selected: selected < 0) { selected = -1 }
                Divider()
            }
            if tool == .info {
                InfoView(surface: surface, query: query)
            } else if tool == .pomodoro {
                PomodoroView()
            } else if tool == .calendar {
                CalendarView(surface: surface, query: query)
            } else if tool == .nowPlaying {
                NowPlayingView(surface: surface)
            } else if tool == .camera {
                CameraView(surface: surface, window: window)
            } else if tool == .knock {
                KnockView(surface: surface, window: window)
            } else if tool == .mixer {
                VolumeMixerView(surface: surface, window: window, query: query)
            } else {
                results
            }
            if tool == .worldClock {
                Divider()
                TimeTravelBar(city: chosenCity)
            }
            if tool == .timer, model.timerEnd == nil, model.timerDone == nil {
                Divider()
                TimerCustomRow()
            }
        }
    }

    func toggleToolMenu() {
        toolMenuIndex = panelTools.firstIndex(of: tool) ?? 0
        toolMenuOpen.toggle()
    }

    /// The saved city highlighted in World Clock. nil means Local Time.
    var chosenCity: WorldCity? {
        let entries = flatEntries
        guard entries.indices.contains(selected), case .city(let city) = entries[selected],
              WorldClock.shared.cities.contains(city) else { return nil }
        return city
    }

    /// In World Clock a click chooses a saved city, and hovering leaves the
    /// highlight alone: the pointer crosses other cities on its way to the slider.
    func rowClicked(_ entry: Entry, index: Int) {
        if case .city(let city) = entry, WorldClock.shared.cities.contains(city) {
            selected = index
        } else {
            activate(entry, plainText: false)
        }
    }

    // MARK: Parts

    var header: some View {
        VStack(spacing: 0) {
            searchRow
            if usesTiles {
                ToolTiles(tools: panelTools, current: tool, surface: surface, hovered: $hoveredTool) { model.tool = $0 }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.md)
            }
        }
    }

    var showsPicker: Bool { fixedTool == nil && panelTools.count > 1 }
    var usesTiles: Bool { showsPicker && ToolPrefs.shared.toolSwitcher == .colorTiles }
    var usesTitleMenu: Bool { showsPicker && ToolPrefs.shared.toolSwitcher == .titleMenu }
    var usesRail: Bool { showsPicker && ToolPrefs.shared.toolSwitcher == .sideRail }
    var toolMenuColumns: Int { surface == .panel ? 6 : 4 }

    var searchRow: some View {
        HStack(spacing: usesTitleMenu ? Space.sm : Space.md) {
            if usesTitleMenu {
                ToolMenuButton(tool: tool, isOpen: toolMenuOpen, action: toggleToolMenu)
            }
            if tool == .camera || tool == .knock {
                // Nothing to search: the row keeps the title, unless the switcher already says it.
                if usesTitleMenu {
                    Spacer(minLength: 0)
                } else {
                    Image(systemName: tool.symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(tool.title)
                        .font(.title2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if usesTitleMenu {
                HStack(spacing: Space.sm) { searchField }
                    .padding(.horizontal, Space.sm)
                    .frame(height: Space.xxl + Space.sm)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            } else {
                searchField
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    @ViewBuilder
    var searchField: some View {
        Image(systemName: "magnifyingglass")
            .font(usesTitleMenu ? .callout : .title2)
            .foregroundStyle(.secondary)
        TextField(placeholder, text: $query)
            .textFieldStyle(.plain)
            .font(usesTitleMenu ? .callout : .title2)
            .focused($searchFocused)
            .accessibilityLabel(tool == .launcher ? "Search apps" : "Search clips")
        if !query.isEmpty {
            Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the search")
        }
    }

    var placeholder: String {
        switch tool {
        case .clipboard: return "Search Clips"
        case .screenshots: return "Search Screenshots"
        case .recording: return "Search Recordings"
        case .launcher: return model.pickingApps ? "Search Apps to Pin" : "Search Apps"
        case .mixer: return "Search Apps"
        case .worldClock: return "Search or Add Cities"
        case .timer: return "Type a Length, Like 12 or 1h30m"
        case .pomodoro: return "Type a Focus Length, Like 25"
        case .calendar: return "Search Events"
        case .nowPlaying: return "Now Playing"
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
                                    .onTapGesture { rowClicked(entry, index: start + offset) }
                                    .onHover { if $0, tool != .worldClock { selected = start + offset } }
                                    .contextMenu { menu(for: entry) }
                                    .reorderable(entry)
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
            case .usage(let use):
                UsageRow(use: use, icon: model.apps.icon(for: use.path), selected: selected)
            case .city(let city):
                WorldCityRow(city: city, selected: selected)
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
        .accessibilityAction(named: entry.isApp ? "Open" : entry.isUsage ? "Bring to Front" : entry.isCity ? "Add or Show in Menu Bar" : (surface == .panel ? "Paste" : "Copy")) {
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
        case .usage(let use):
            let monitor = SystemMonitor.shared
            if use.isApp {
                Button("Bring to Front") { activate(entry, plainText: false) }
                Button("Quit") { monitor.quit(use) }
                Button("Force Quit…") { close(); monitor.forceQuit(use, name: UsageRow.name(of: use)) }
                Divider()
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: use.path)]) }
            Button("Open Activity Monitor") { close(); monitor.openActivityMonitor() }
        case .city(let city):
            let clock = WorldClock.shared
            if clock.cities.contains(city) {
                Button(clock.menuBarCity == city ? "Remove from Menu Bar" : "Show in Menu Bar") { clock.toggleMenuBar(city) }
                Button("Move Up") { clock.move(city, by: -1) }
                Button("Move Down") { clock.move(city, by: 1) }
                Divider()
                Button("Remove City", role: .destructive) { clock.remove(city) }
                    .keyboardShortcut(.delete)
            } else {
                Button("Add City") { activate(entry, plainText: false) }
            }
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

    var hint: String {
        if toolMenuOpen, usesTitleMenu { return "↑↓←→ Choose   ↩ Open   esc Close" }
        if let hoveredTool {
            let number = panelTools.firstIndex(of: hoveredTool).flatMap { $0 < 9 ? "   ⌘\($0 + 1)" : nil } ?? ""
            return "\(hoveredTool.title): \(hoveredTool.help)\(number)"
        }
        return ToolActions.hint(for: tool, model: model, surface: surface)
    }

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
        /// An app in System's energy list.
        case usage(AppUse)
        /// A city in World Clock, saved or ready to add.
        case city(WorldCity)

        var id: String {
            switch self {
            case .app(let app): "a:" + app.path
            case .clip(let clip): "c:" + clip.uuid.uuidString
            case .add: "add"
            case .action(let action): "m:" + action.id
            case .color(let hex): "k:" + hex
            case .snippet(let snippet): "s:" + snippet.uuid.uuidString
            case .capture(let capture): "f:" + capture.uuid.uuidString
            case .usage(let use): "u:" + use.path
            case .city(let city): "w:" + city.id
            }
        }

        var isApp: Bool { if case .app = self { true } else { false } }
        var isUsage: Bool { if case .usage = self { true } else { false } }
        var isCity: Bool { if case .city = self { true } else { false } }
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
            case .system:
                let top = SystemMonitor.shared.apps.filter { query.isEmpty || ClipRules.matches(query, text: UsageRow.name(of: $0)) }
                if !top.isEmpty { result.append(Section(title: query.isEmpty ? "Using the Most Energy" : nil, entries: top.map(Entry.usage))) }
            case .colors:
                let recent = model.recentColors.filter { query.isEmpty || ClipRules.matches(query, text: $0) }
                if !recent.isEmpty { result.append(Section(title: "Recent", entries: recent.map(Entry.color))) }
            case .worldClock:
                let clock = WorldClock.shared
                let saved = clock.cities.filter { FuzzyMatch.match(query, in: $0.name) != nil }
                if !saved.isEmpty { result.append(Section(title: "Your Cities", entries: saved.map(Entry.city))) }
                // Suggestions only until you have a city; after that, typing finds more.
                if !query.isEmpty || clock.cities.isEmpty {
                    let more = WorldClockRules.search(query, excluding: clock.cities)
                    if !more.isEmpty { result.append(Section(title: "Add a City", entries: more.map(Entry.city))) }
                }
            default:
                break
            }
            return result
        }
    }

    var flatEntries: [Entry] { sections.flatMap(\.entries) }

    // MARK: Actions

    func reset() {
        toolMenuOpen = false
        WorldClock.shared.travel = 0
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
        case .usage(let use):
            close()
            SystemMonitor.shared.bringToFront(use)
        case .city(let city):
            let clock = WorldClock.shared
            if clock.cities.contains(city) {
                clock.toggleMenuBar(city)
            } else {
                clock.add(city)
                query = ""
                selected = 0
            }
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
