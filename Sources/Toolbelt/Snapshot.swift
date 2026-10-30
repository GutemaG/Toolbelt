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
                    // System needs two readings before its energy list fills.
                    try? await Task.sleep(for: .seconds(tool == .system ? 2.5 : 0.8))
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
            // Info's other tabs, once each has been read.
            if only == nil || only?.contains("info") == true {
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    PanelController.shared.show(.info)
                    try? await Task.sleep(for: .seconds(0.5))
                    for tab in InfoTab.allCases.dropFirst() {
                        MacInfo.shared.tab = tab
                        for _ in 0..<40 where MacInfo.shared.loading.contains(tab) || MacInfo.shared.sections[tab] == nil {
                            try? await Task.sleep(for: .seconds(0.25))
                        }
                        try? await Task.sleep(for: .seconds(0.5))
                        capture(to: "\(dir)/panel-info-\(tab.rawValue)-\(mode).png", window: PanelController.shared.panel)
                    }
                }
            }
            PanelController.shared.hide()
            // The scrolling capture bar, as it first shows.
            if only == nil || only?.contains("scrollbar") == true {
                let host = NSHostingView(rootView: ScrollCaptureBar(capture: .shared).themed())
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 200, y: 400), size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.contentView = host
                window.orderFrontRegardless()
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    try? await Task.sleep(for: .seconds(0.6))
                    capture(to: "\(dir)/scrollbar-\(mode).png", window: window)
                }
                window.orderOut(nil)
            }
            // The menu bar popover's width, where the tool picker wraps onto two rows.
            if only == nil || only?.contains("popover") == true {
                let host = NSHostingView(rootView: ToolbeltView(surface: .popover)
                    .environment(model)
                    .modelContainer(model.container)
                    .themed())
                let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 440, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                for (tool, mode) in [(Tool.knock, "light"), (.launcher, "dark")] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    model.tool = tool
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/popover-\(tool.rawValue)-\(mode).png", window: window)
                }
                window.orderOut(nil)
            }
            // The Markup window, on a drawn sample image that is deleted afterwards.
            if only == nil || only?.contains("markup") == true {
                let url = CapturePrefs.folder.appendingPathComponent("markup-sample.png")
                let sample = NSImage(size: NSSize(width: 1200, height: 700), flipped: false) { rect in
                    NSColor.white.setFill(); rect.fill()
                    ("Quarterly numbers" as NSString).draw(at: NSPoint(x: 80, y: 520), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 64)])
                    ("Revenue up 12%, costs flat, account 4417-2210" as NSString).draw(at: NSPoint(x: 80, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 40)])
                    return true
                }
                if let tiff = sample.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    MarkupWindow.open(Capture(kind: .screenshot, url: url, width: 1200, height: 700), model: model)
                    try? await Task.sleep(for: .seconds(1))
                    for mode in ["light", "dark"] {
                        NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                        try? await Task.sleep(for: .seconds(0.6))
                        capture(to: "\(dir)/markup-\(mode).png", window: NSApp.keyWindow ?? NSApp.windows.first { $0.title.hasPrefix("Markup") })
                    }
                    NSApp.windows.filter { $0.title.hasPrefix("Markup") }.forEach { $0.close() }
                    try? FileManager.default.removeItem(at: url)
                }
            }
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
