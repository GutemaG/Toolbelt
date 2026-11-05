import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI
import ToolbeltKit

// Toolbelt
//   Toolbelt                      the app
//   APP_STORE=<file> Toolbelt     use another database (tests, experiments)
//   APP_SNAPSHOT=<dir> Toolbelt   save a PNG of each tool's panel and every Settings tab in light and dark mode, then quit
//   APP_SEED=1 Toolbelt           fill an empty /tmp store with sample clips (tools/snap.sh)
//   Toolbelt --selftest           run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> Toolbelt      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 Toolbelt           draw the 8 pt grid and the layout probes over the window

@main
struct ToolbeltApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Toolbelt lives in the menu bar (AppDelegate). Settings is its own
        // window (SettingsWindow), so it opens from the popover and the panel.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(container: Store.makeContainer())
    private var statusItems: StatusItems!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon unless Settings says so. Info.plist says so too (LSUIElement), this covers a run from the terminal.
        NSApp.setActivationPolicy(.accessory)
        // Services first: the panel and popovers draw the last used tool at once, and the capture tools read these.
        CaptureController.shared = CaptureController(model: model)
        Recorder.shared = Recorder(model: model)
        KeepAwake.shared = KeepAwake(model: model)
        ColorPicker.shared = ColorPicker(model: model)
        TimerTool.shared = TimerTool(model: model)
        PanelController.shared = PanelController(model: model)
        statusItems = StatusItems(model: model)
        StatusItems.shared = statusItems

        SeedData.insertIfRequested(into: model)
        if SelfTest.requested || Snapshot.requested {
            statusItems.apply(ToolPrefs.shared)
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model)
            return
        }
        model.apps.refresh()
        ToolPrefs.shared.onChange = { [weak self] in self?.apply() }
        apply()
    }

    /// Makes the menu bar, shortcuts, clipboard watcher and Dock match ToolPrefs.
    private func apply() {
        let prefs = ToolPrefs.shared
        statusItems.apply(prefs)

        // Every shortcut of every tool that is on, as chosen in Settings.
        Hotkeys.shared.unregisterAll()
        for id in ShortcutID.all where prefs.enabled.contains(id.tool) {
            guard let combo = ShortcutStore.shared.combo(for: id) else { continue }
            Hotkeys.shared.register(id.key, keyCode: combo.keyCode, modifiers: combo.modifiers) { id.run() }
        }
        if prefs.enabled.contains(.clipboard) { model.clipboard.start() } else { model.clipboard.stop() }
        if !prefs.enabled.contains(.keepAwake), KeepAwake.shared.isOn { KeepAwake.shared.stop() }
        if !prefs.enabled.contains(.recording), Recorder.shared.isRecording { Recorder.shared.stop() }
        Knock.shared.setEnabled(prefs.enabled.contains(.knock))
        if prefs.enabled.contains(.mixer) { VolumeMixer.shared.resume() } else { VolumeMixer.shared.stopAll() }
        SystemMonitor.shared.menuBar = prefs.enabled.contains(.system) && prefs.ownIcon.contains(.system)
            && UserDefaults.standard.object(forKey: SystemMonitor.menuBarKey) as? Bool ?? true
        if !prefs.panelTools.contains(model.tool), let first = prefs.panelTools.first { model.tool = first }

        let policy: NSApplication.ActivationPolicy = prefs.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            // Switching hides windows for a moment; keep Settings in front.
            if SettingsWindow.shared.isVisible {
                NSApp.activate()
                SettingsWindow.shared.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// With the Dock icon on, clicking it opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { SettingsWindow.shared.show(model: model) }
        return true
    }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.shared?.stop()
        VolumeMixer.shared.stopAll()
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// All of Toolbelt's menu bar icons: the Toolbelt icon with every tool, plus
/// one icon per tool that has "Show in the menu bar" on.
final class StatusItems {
    static var shared: StatusItems?
    private let model: AppModel
    private var main: StatusItemController?
    private(set) var tools: [Tool: StatusItemController] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func apply(_ prefs: ToolPrefs) {
        if prefs.showMainIcon && !prefs.panelTools.isEmpty {
            if main == nil { main = StatusItemController(model: model, tool: nil) }
        } else {
            main?.remove()
            main = nil
        }
        var wanted = Set(Tool.allCases.filter { prefs.enabled.contains($0) && prefs.ownIcon.contains($0) })
        // With the Toolbelt icon hidden, the city in the menu bar still needs an icon to sit on.
        if main == nil, WorldClock.shared.menuBarText != nil { wanted.insert(.worldClock) }
        for (tool, controller) in tools where !wanted.contains(tool) {
            controller.remove()
            tools[tool] = nil
        }
        for tool in Tool.allCases where wanted.contains(tool) && tools[tool] == nil {
            tools[tool] = StatusItemController(model: model, tool: tool)
        }
        refreshIcons()
        WorldClock.shared.updateTicking()
    }

    func closePopovers() {
        main?.closePopover()
        tools.values.forEach { $0.closePopover() }
    }

    /// Keep Awake's own icon fills while it is on.
    func refreshIcons() {
        tools[.keepAwake]?.setSymbol(KeepAwake.shared.isOn ? "cup.and.saucer.fill" : Tool.keepAwake.symbol)
        // The city's time and the time left sit on their tool's own icon, or
        // side by side on the Toolbelt icon without one.
        var onMain: [String] = []
        for (tool, text) in [(Tool.worldClock, WorldClock.shared.menuBarText), (.timer, TimerTool.shared?.menuBarText)] {
            if let item = tools[tool] {
                // A flag or a city name says what the icon would; the time alone needs it.
                item.setTitle(text, hidesImage: tool == .worldClock && WorldClock.shared.menuBarStyle != .timeOnly)
            } else if let text {
                onMain.append(text)
            }
        }
        // Two lines only work alone; beside a timer the city and time share one.
        let title = onMain.count > 1 ? onMain.map { $0.replacingOccurrences(of: "\n", with: " ") } : onMain
        main?.setTitle(title.isEmpty ? nil : title.joined(separator: "   "))
        tools[.system]?.setTitle(SystemMonitor.shared.menuBarText)
    }

    /// What the Toolbelt icon shows beside it, for the self-test.
    var mainTitle: String { main?.title ?? "" }
    /// The window holding the Toolbelt icon, for snapshots.
    var mainWindow: NSWindow? { main?.window }

    /// Shows the Toolbelt popover, or the first tool icon when it is hidden.
    func showMainPopover() {
        (main ?? tools.values.first)?.showPopover()
    }
}

/// One menu bar icon. A click opens its popover; a right-click shows a menu.
/// `tool` nil is the Toolbelt icon, which shows every tool in the panel.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    let tool: Tool?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    /// Hover opening: the pending open, and the watch that closes a peek
    /// once the pointer leaves the icon and the window.
    private var hoverTask: Task<Void, Never>?
    private var leaveWatch: Task<Void, Never>?

    init(model: AppModel, tool: Tool?) {
        self.model = model
        self.tool = tool
        super.init()
        // Keeps the icon's place in the menu bar across launches.
        item.autosaveName = "toolbelt." + (tool?.rawValue ?? "main")
        item.behavior = .removalAllowed
        if let button = item.button {
            button.image = NSImage(systemSymbolName: tool?.symbol ?? "wrench.and.screwdriver",
                                   accessibilityDescription: tool?.title ?? "Toolbelt")
            button.toolTip = tool?.title ?? "Toolbelt"
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self))
        }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView:
            ToolbeltView(surface: .popover, fixedTool: tool)
                .environment(model)
                .modelContainer(model.container)
                .themed()
        )
    }

    /// Text beside the icon, like a timer's time left. nil shows the icon alone.
    /// Text with a line break is drawn small on two lines, to fit the menu bar.
    func setTitle(_ text: String?, hidesImage: Bool = false) {
        guard let button = item.button else { return }
        let image = text != nil && hidesImage
        button.imagePosition = text == nil ? .imageOnly : image ? .noImage : .imageLeading
        item.length = text == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        if let text, text.contains("\n") {
            let lines = NSMutableParagraphStyle()
            lines.alignment = .center
            lines.minimumLineHeight = 11
            lines.maximumLineHeight = 11
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: lines,
            ])
        } else {
            button.title = text.map { (image ? "" : " ") + $0 } ?? ""
            if text != nil { button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        }
    }

    var title: String { item.button?.title ?? "" }
    var window: NSWindow? { item.button?.window }

    func setSymbol(_ symbol: String) {
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tool?.title ?? "Toolbelt")
    }

    func remove() {
        closePopover()
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: Open on hover

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        guard ToolPrefs.shared.openOnHover, !popover.isShown else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            // A short rest, so passing over the menu bar does not open it.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, !self.popover.isShown else { return }
            self.showPopover(activating: false)
            self.watchForLeaving()
        }
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        hoverTask?.cancel()
    }

    /// Closes a peek when the pointer has been away from the icon and the
    /// window for about half a second. A click inside makes it stay.
    private func watchForLeaving() {
        leaveWatch?.cancel()
        leaveWatch = Task { [weak self] in
            var away = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.popover.isShown else { return }
                if NSApp.isActive, self.popover.contentViewController?.view.window?.isKeyWindow == true { return }
                let mouse = NSEvent.mouseLocation
                let inside = [self.popover.contentViewController?.view.window?.frame, self.buttonFrame]
                    .compactMap { $0?.insetBy(dx: -Space.sm, dy: -Space.sm) }
                    .contains { $0.contains(mouse) }
                away = inside ? 0 : away + 1
                if away >= 3 { return self.closePopover() }
            }
        }
    }

    private var buttonFrame: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown, !NSApp.isActive {
            // Opened by hover: a click turns the peek into a normal, focused window.
            leaveWatch?.cancel()
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        } else if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// `activating: false` is the hover peek: the app you were typing in keeps focus.
    func showPopover(activating: Bool = true) {
        guard let button = item.button else { return }
        hoverTask?.cancel()
        if activating { leaveWatch?.cancel() }
        PanelController.shared.hide()
        StatusItems.shared?.closePopovers()
        if let tool { model.tool = tool }
        model.openCount += 1
        // Window snapping acts on the app that was in front before the popover.
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { WindowSnapper.shared.previousApp = front }
        if activating { NSApp.activate() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activating { popover.contentViewController?.view.window?.makeKey() }
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// Hand focus back to the app that was in front before the popover opened.
    func popoverDidClose(_ notification: Notification) {
        // Not while an Open panel (Other App…) or Settings is up: hiding would close it.
        if !SettingsWindow.shared.isVisible, NSApp.modalWindow == nil, !ToolPrefs.shared.showInDock { NSApp.hide(nil) }
    }

    private func showMenu() {
        let menu = NSMenu()
        for tool in ToolPrefs.shared.panelOrder where ToolPrefs.shared.enabled.contains(tool) {
            let entry = NSMenuItem(title: "Open \(tool.title)", action: #selector(openTool), keyEquivalent: "")
            entry.target = self
            entry.representedObject = tool.rawValue
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Toolbelt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openTool(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let tool = Tool(rawValue: raw) {
            PanelController.shared.show(tool)
        }
    }

    @objc private func openSettings() {
        if let tool { model.settingsPage = SettingsPage(rawValue: tool.rawValue) ?? .settings }
        SettingsWindow.shared.show(model: model)
    }
}

/// The Settings window, made by hand because a menu bar app has no
/// SwiftUI scene to open Settings from.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environment(model)
                .modelContainer(model.container)   // Snippets and other pages query the database.
                .themed())
            let window = NSWindow(contentViewController: host)
            window.title = "Toolbelt Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // An empty unified toolbar gives the sidebar its full-height glass.
            window.toolbar = NSToolbar(identifier: "settings")
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 640))
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ToolbeltSettings")
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Where the data lives: ~/Library/Application Support/Toolbelt/Toolbelt.store
enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, seed data).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let dir = URL.applicationSupportDirectory.appending(path: "Toolbelt", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Toolbelt.store")
    }

    static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: ClipItem.self, AppLaunch.self, Capture.self, Snippet.self, configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Could not open the database at \(url.path): \(error)")
        }
    }
}
