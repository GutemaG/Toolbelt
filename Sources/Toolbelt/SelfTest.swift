import AppKit
import SwiftData
import ToolbeltKit

/// Self-test for agents: runs the app's real functions on a test store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/Toolbelt-self.store ~/Applications/Toolbelt.app/Contents/MacOS/Toolbelt --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
/// It never touches the real clipboard.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let context = model.container.mainContext
            func clips() -> [ClipItem] {
                (try? context.fetch(FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]))) ?? []
            }

            // S-002 record copies
            let before = clips().count
            model.record(kind: .text, text: "hello", fingerprint: "t:hello", source: "com.apple.Notes")
            try? await Task.sleep(for: .milliseconds(10))
            model.record(kind: .link, text: "https://apple.com", fingerprint: "t:https://apple.com", source: nil)
            check("copies are saved", clips().count == before + 2)
            check("newest clip is first", clips().first?.text == "https://apple.com")
            try? await Task.sleep(for: .milliseconds(10))
            model.record(kind: .text, text: "hello", fingerprint: "t:hello", source: "com.apple.Notes")
            check("a repeat copy moves the clip up instead of adding one", clips().count == before + 2 && clips().first?.text == "hello")
            check("the source app is stored", clips().first?.sourceBundleID == "com.apple.Notes")

            // S-013 pin, S-018 history limit
            if let first = clips().first { model.togglePin(first) }
            for i in 0..<(ClipRules.historyLimit + 5) {
                model.record(kind: .text, text: "clip \(i)", fingerprint: "t:clip \(i)", source: nil)
            }
            let all = clips()
            check("history keeps \(ClipRules.historyLimit) unpinned clips", all.filter { !$0.isPinned }.count == ClipRules.historyLimit,
                  "\(all.filter { !$0.isPinned }.count)")
            check("pinned clips survive pruning", all.contains { $0.text == "hello" && $0.isPinned })

            // S-014 delete
            if let victim = clips().first(where: { !$0.isPinned }) {
                let id = victim.uuid
                model.delete(victim)
                check("deleting a clip removes it", !clips().contains { $0.uuid == id })
            }

            // S-006, S-007, S-008 launcher
            let scanned = AppIndex.scan()
            check("the app index finds Safari", scanned.contains { $0.name == "Safari" }, "\(scanned.count) apps")
            model.recordLaunch(path: "/Applications/Safari.app")
            model.recordLaunch(path: "/Applications/Safari.app")
            let launch = try? context.fetch(FetchDescriptor<AppLaunch>()).first { $0.path == "/Applications/Safari.app" }
            check("opening an app counts the launch", launch?.count == 2)
            let ranked = LauncherRanking.rank(scanned.map { LaunchCandidate(name: $0.name, path: $0.path,
                                                                             launchCount: $0.name == "Safari" ? 2 : 0) }, query: "")
            check("Frequent lists opened apps", ranked.first?.name == "Safari")

            // S-027 pinned apps
            let finder = "/System/Library/CoreServices/Finder.app", notes = "/System/Applications/Notes.app"
            model.pinApps(paths: [finder, notes])
            check("Add… pins apps in order", model.pinnedApps().map(\.path) == [finder, notes])
            model.movePinned(path: notes, by: -1)
            check("Move Left reorders pinned apps", model.pinnedApps().map(\.path) == [notes, finder])
            model.togglePin(appPath: notes)
            check("Unpin removes the app from the grid", model.pinnedApps().map(\.path) == [finder])
            model.togglePin(appPath: notes)
            check("pinning again adds it at the end", model.pinnedApps().map(\.path) == [finder, notes])

            // S-032, S-034 tool switches and panel order
            let prefs = ToolPrefs.shared
            check("every tool starts on and in the panel", prefs.panelTools == Tool.allCases)
            prefs.move(.clipboard, by: -1)
            check("Move Up reorders the panel", prefs.panelTools.first == .clipboard)
            prefs.enabled.remove(.clipboard)
            check("a tool that is off leaves the panel", !prefs.panelTools.contains(.clipboard))
            prefs.enabled.insert(.clipboard)
            prefs.ownIcon.insert(.launcher)
            StatusItems.shared?.apply(prefs)
            check("Show in the menu bar adds the tool's own icon", StatusItems.shared?.tools[.launcher] != nil)
            prefs.ownIcon.remove(.launcher)
            StatusItems.shared?.apply(prefs)
            check("turning it off removes the icon", StatusItems.shared?.tools[.launcher] == nil)
            prefs.move(.clipboard, by: 1)

            // S-015 clear history
            model.clearHistory()
            check("Clear History keeps only pinned clips", clips().allSatisfy(\.isPinned) && !clips().isEmpty)

            // S-002 secrets
            check("password manager copies are skipped",
                  ClipRules.shouldSkip(types: ["org.nspasteboard.ConcealedType"], sourceApp: nil))

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
