import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon. Info.plist says so too (LSUIElement), this covers a run from the terminal.
        NSApp.setActivationPolicy(.accessory)
        PanelController.shared = PanelController(model: model)
        StatusItemController.shared = StatusItemController(model: model)

        SeedData.insertIfRequested(into: model)
        if SelfTest.requested || Snapshot.requested {
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model)
            return
        }
        model.clipboard.start()
        model.apps.refresh()
        Hotkeys.shared.register("Open Launcher", keyCode: kVK_Space, modifiers: optionKey) {
            PanelController.shared.toggle(.launcher)
        }
        Hotkeys.shared.register("Open Clipboard", keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey) {
            PanelController.shared.toggle(.clipboard)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// The menu bar icon. A click opens the popover; a right-click shows a menu.
final class StatusItemController: NSObject, NSPopoverDelegate {
    static var shared: StatusItemController?
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Toolbelt")
            button.toolTip = "Toolbelt"
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView:
            ToolbeltView(surface: .popover)
                .environment(model)
                .modelContainer(model.container)
                .themed()
        )
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            closePopover()
        } else {
            PanelController.shared.hide()
            model.openCount += 1
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    /// Hand focus back to the app that was in front before the popover opened.
    func popoverDidClose(_ notification: Notification) {
        if !SettingsWindow.shared.isVisible { NSApp.hide(nil) }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Launcher", action: #selector(openLauncher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Clipboard", action: #selector(openClipboard), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Toolbelt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openLauncher() { PanelController.shared.show(.launcher) }
    @objc private func openClipboard() { PanelController.shared.show(.clipboard) }
    @objc private func openSettings() { SettingsWindow.shared.show(model: model) }
}

/// The Settings window, made by hand because a menu bar app has no
/// SwiftUI scene to open Settings from.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environment(model).themed())
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = "Toolbelt Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        NSApp.activate()
        window?.center()
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
            return try ModelContainer(for: ClipItem.self, AppLaunch.self, configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Could not open the database at \(url.path): \(error)")
        }
    }
}
