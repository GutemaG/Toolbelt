import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/test.store APP_SNAPSHOT=/tmp/shots ~/Applications/Toolbelt.app/Contents/MacOS/Toolbelt
/// writes panel-<tool>-light.png and panel-<tool>-dark.png for each tool, and
/// settings-<tab>-light.png and settings-<tab>-dark.png for every Settings tab, then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=launcher,clipboard limits the pages. Add "settings" to include Settings.
/// Add APP_ACCENT=<id> to see the pages in another accent.
enum Snapshot {
    static var requested: Bool { !(ProcessInfo.processInfo.environment["APP_SNAPSHOT"] ?? "").isEmpty }

    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        // Snapshots never run against the real database.
        guard Store.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE to a file in /tmp")
            NSApp.terminate(nil)
            return
        }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            model.apps.refresh()
            try? await Task.sleep(for: .seconds(1.5))
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for tool in Tool.allCases where only?.contains(tool.rawValue) ?? true {
                    PanelController.shared.show(tool)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/panel-\(tool.rawValue)-\(mode).png", window: PanelController.shared.panel)
                }
            }
            // The Launcher after Add…: every app with a pin button.
            if only == nil || only?.contains("pick") == true {
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    PanelController.shared.show(.launcher)
                    // Opening resets the view; switch to the pick list after that.
                    try? await Task.sleep(for: .seconds(0.3))
                    model.pickingApps = true
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/panel-pick-\(mode).png", window: PanelController.shared.panel)
                }
                model.pickingApps = false
            }
            PanelController.shared.hide()
            if only == nil || only?.contains("settings") == true {
                SettingsWindow.shared.show(model: model)
                try? await Task.sleep(for: .seconds(1))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsPage.allCases {
                        model.settingsPage = tab
                        try? await Task.sleep(for: .seconds(0.8))
                        capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: SettingsWindow.shared.window)
                    }
                }
            }
            print("SNAPSHOT done \(dir)")
            NSApp.terminate(nil)
        }
    }

    /// Captures the real window with screencapture, so glass and materials
    /// look exactly as on screen. That needs Screen Recording permission for
    /// the app that started this one (your terminal, or Claude). Without it,
    /// falls back to drawing the view hierarchy, which leaves glass blank.
    private static func capture(to path: String, window: NSWindow?) {
        // Another app can hide this one while snapshots run (computer use hides
        // apps it does not control). Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window else {
            print("SNAPSHOT no window")
            return
        }
        // Active, like a window someone is using: real accent colors and focus rings.
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKey()
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        // Draw the current state first; a cached layer can still hold the last page.
        view.appearance = NSApp.appearance
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, glass is blank)")
        }
    }
}
