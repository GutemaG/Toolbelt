import AppKit
import AVFoundation
import IOKit.ps
import CoreImage
import ScreenCaptureKit
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

            check("tools from a newer version start on",
                  ToolPrefs.newTools(savedOrder: [.launcher, .clipboard]) == Array(Tool.allCases.dropFirst(2)))

            // S-015 clear history
            model.clearHistory()
            check("Clear History keeps only pinned clips", clips().allSatisfy(\.isPinned) && !clips().isEmpty)

            // S-040, S-050 capture, only when this run may record the screen
            if CGPreflightScreenCaptureAccess(), let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let display = content.displays.first {
                let shot = await SelectionOverlay.captureDisplay(display, content: content)
                check("a screen capture is at Retina size", shot.map { $0.image.width == Int(CGFloat(display.width) * $0.scale) } ?? false,
                      shot.map { "\($0.image.width) px for \(display.width) pt" } ?? "no image")
                if let shot {
                    let area = shot.image.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 100))
                    if let area { CaptureController.shared.save(area) }
                    let saved = (try? context.fetch(FetchDescriptor<Capture>()))?.first { $0.kind == .screenshot }
                    check("a screenshot is saved as a file", saved?.exists == true && saved?.pixelWidth == 200, saved?.path ?? "none")
                    CapturePreview.shared.hide()
                }
                await Recorder.shared.begin(.screen(display))
                check("recording starts", Recorder.shared.isRecording && model.isRecording)
                try? await Task.sleep(for: .seconds(2))
                Recorder.shared.stop()
                check("Record/Stop follows the recorder", !model.isRecording)
                for _ in 0..<20 where ((try? context.fetch(FetchDescriptor<Capture>()))?.contains { $0.kind == .recording } ?? false) == false {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                let movie = (try? context.fetch(FetchDescriptor<Capture>()))?.first { $0.kind == .recording }
                var seconds: Double?
                if let movie { seconds = try? await AVURLAsset(url: movie.url).load(.duration).seconds }
                check("a recording is saved as a playable movie", (seconds ?? 0) > 1, movie.map { "\($0.path) \(seconds ?? 0) s" } ?? "none")
                CapturePreview.shared.hide()
                // The captures show whatever was on screen; never leave them on disk.
                try? FileManager.default.removeItem(at: CapturePrefs.folder)
            } else {
                print("SKIP capture checks: this run may not record the screen")
            }

            // S-019 shortcuts
            let store = ShortcutStore.shared
            check("shortcuts start at their defaults", store.combo(for: .shotArea)?.label == "⌃⇧4")
            store.set(KeyCombo(keyCode: 49, modifiers: KeyCombo.option), for: .clipboard)
            check("a changed shortcut is used", store.combo(for: .clipboard)?.label == "⌥Space")
            check("two tools on one shortcut are flagged", store.conflict(for: .clipboard) == .launcher)
            store.set(nil, for: .clipboard)
            check("Delete clears a shortcut", store.combo(for: .clipboard) == nil)
            store.reset(.clipboard)
            check("Reset brings the default back", store.combo(for: .clipboard)?.label == "⇧⌘V")

            // S-073 snippets
            let address = model.addSnippet(title: "Home address", text: "1 Main St", keyword: ";addr")
            model.addSnippet(title: "Reply", text: "Thanks, I'll check the address", keyword: "")
            let saved = (try? context.fetch(FetchDescriptor<Snippet>())) ?? []
            check("a keyword finds its snippet first", model.searchSnippets(saved, query: ";addr").first?.uuid == address.uuid)
            check("search also looks in the text", model.searchSnippets(saved, query: "check the").count == 1)
            model.deleteSnippet(address)
            check("deleting a snippet removes it", ((try? context.fetch(FetchDescriptor<Snippet>())) ?? []).count == saved.count - 1)

            // S-074 markup: marks land in the saved pixels, at full size
            let blank = Self.render(text: " ")
            let marked = MarkPainter.render(blank, marks: [.redact(CGRect(x: 10, y: 10, width: 50, height: 50))]) // grid: ok test pixels, not layout
            check("markup keeps the image's pixel size", marked?.width == blank.width && marked?.height == blank.height,
                  "\(marked?.width ?? 0)×\(marked?.height ?? 0) for \(blank.width)×\(blank.height)")
            if let marked, let data = marked.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                let offset = 30 * marked.bytesPerRow + 30 * (marked.bitsPerPixel / 8)
                check("a redaction turns its pixels black", bytes[offset] < 20 && bytes[offset + 1] < 20 && bytes[offset + 2] < 20)
            }

            // S-061 Keep Awake
            KeepAwake.shared.start(for: 60)
            check("Keep Awake holds a power assertion", KeepAwake.shared.isOn && model.awakeUntil != nil)
            KeepAwake.shared.stop()
            check("Turn Off releases it", !KeepAwake.shared.isOn && model.awakeUntil == nil)

            // S-070 timer
            TimerTool.shared.start(2)
            check("a timer counts down", TimerTool.shared.isRunning && TimerTool.shared.remaining > 1)
            TimerTool.shared.pause()
            let paused = TimerTool.shared.remaining
            try? await Task.sleep(for: .seconds(1.2))
            check("a paused timer holds its time", TimerTool.shared.remaining == paused)
            TimerTool.shared.add(60)
            check("+1 min adds a minute", TimerTool.shared.remaining == paused + 60)
            TimerTool.shared.stop()
            TimerTool.shared.start(1)
            try? await Task.sleep(for: .seconds(2.5))
            check("a timer ends by itself", !TimerTool.shared.isRunning)

            // S-071 sound output, read only: never switches this Mac's sound
            let outputs = AudioOutput.devices()
            check("sound output devices are listed", !outputs.isEmpty, "\(outputs.map(\.name))")
            check("the current output is one of them", outputs.contains { $0.id == AudioOutput.current })

            // S-077 scrolling capture: frames of a drawn page join back into the page
            let page = Self.noisePage(width: 300, height: 1200)
            let frameHeight = 500
            let scroll = ScrollSession(frameHeight: frameHeight)
            var steps: [ScrollStitcher.Step] = []
            for y in [0, 0, 180, 400, 400, 700] {
                if let frame = page.cropping(to: CGRect(x: 0, y: y, width: 300, height: frameHeight)) { steps.append(await scroll.add(frame).step) }
            }
            check("scrolling frames are matched by how far they moved",
                  steps == [.first, .same, .moved(by: 180, keep: 320..<500), .moved(by: 220, keep: 280..<500), .same, .moved(by: 300, keep: 200..<500)],
                  "\(steps)")
            let joined = await scroll.compose()
            let expected = page.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 1200))!
            let difference = joined.map { image in
                zip(ScrollSession.signature(image), ScrollSession.signature(expected)).map { ScrollStitcher.difference($0, $1) }.max() ?? 999
            } ?? 999
            check("the joined image is the whole page, top first", joined?.height == 1200 && difference < 300,
                  "\(joined?.width ?? 0)×\(joined?.height ?? 0), worst row \(difference)")

            // S-079 camera: listing cameras is safe; test runs never turn one on
            let camera = Camera.shared
            camera.refreshDevices()
            let viewer = UUID()
            camera.show(viewer, true)
            check("test runs never turn the camera on", camera.isSimulated && camera.state == .off)
            camera.show(viewer, false)
            check("the picked camera is one of those found", camera.deviceID == nil || camera.devices.contains { $0.id == camera.deviceID },
                  camera.devices.map(\.name).joined(separator: ", "))
            let wide = CGContext(data: nil, width: 4, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            wide.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            wide.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            let flipped = wide.makeImage().flatMap(Camera.flipped)
            check("a mirrored photo is flipped left to right", flipped.map { Self.isRed($0, x: 3) && !Self.isRed($0, x: 0) } ?? false)

            // S-078 Info: every tab reads, offline (no public IP lookup)
            let offline = InfoReader.Options(locationAllowed: false, lookUpPublicIP: false)
            func rows(_ tab: InfoTab) async -> [InfoRow] { await InfoReader.read(tab, options: offline).flatMap(\.rows) }
            let battery = await rows(.battery)
            let hasBattery = IOPSCopyPowerSourcesList(IOPSCopyPowerSourcesInfo().takeRetainedValue()).takeRetainedValue() as? [Any] ?? []
            check("Battery shows charge, cycles and condition",
                  hasBattery.isEmpty || (battery.contains { $0.label == "Cycle count" } && battery.contains { $0.label == "Condition" } && battery.contains { $0.label == "Charge" }),
                  battery.prefix(4).map { "\($0.label)=\($0.value)" }.joined(separator: ", "))
            let hardware = await rows(.hardware)
            check("Hardware names the chip and macOS build", hardware.contains { $0.label == "Chip" && $0.value == InfoReader.sysctlString("machdep.cpu.brand_string") }
                  && hardware.contains { $0.label == "Build" && $0.value == InfoReader.sysctlString("kern.osversion") })
            check("serial numbers are hidden until shown", hardware.filter { $0.label == "Serial number" }.allSatisfy(\.secret))
            let storage = await InfoReader.read(.storage, options: offline)
            check("Storage lists the startup volume and its disk", storage.contains { $0.rows.contains { $0.label == "FileVault" } }
                  && storage.contains { $0.rows.contains { $0.label == "Health" } }, storage.map(\.title).joined(separator: ", "))
            let network = await rows(.network)
            check("Network shows DNS and the public IP only when asked", network.contains { $0.label == "DNS servers" } && !network.contains { $0.label == "Public IP" })
            let started = Date.now
            let developer = await rows(.developer)
            check("Developer finds installed tools with versions", developer.contains { $0.label == "Git" && $0.value.first?.isNumber == true },
                  "\(developer.count) in \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s: " + developer.prefix(6).map { "\($0.label) \($0.value)" }.joined(separator: ", "))

            // S-076 System: read only, nothing is quit
            let sensors = SystemSensors()
            _ = await sensors.read(processes: true)
            try? await Task.sleep(for: .seconds(1))
            let reading = await sensors.read(processes: true)
            check("CPU load is between 0 and 100%", reading.cpu.map { (0...1).contains($0) } ?? false, "\(reading.cpu ?? -1)")
            check("memory in use is below the total", reading.memoryUsed > 0 && reading.memoryUsed <= reading.memoryTotal)
            check("the chip temperature is believable", reading.temperature.map { (10...120).contains($0) } ?? true, "\(reading.temperature ?? -1)")
            let apps = reading.apps ?? []
            check("apps using energy are listed, helpers grouped", !apps.isEmpty && !apps.contains { $0.path.contains(".app/") },
                  apps.prefix(3).map { "\($0.path.split(separator: "/").last ?? "") \(SystemRules.powerText($0.watts))" }.joined(separator: ", "))

            // S-072 toggles: the scripts compile; nothing on this Mac is switched
            for script in [QuickToggles.darkModeScript, QuickToggles.emptyTrashScript] {
                var error: NSDictionary?
                check("a toggle's script compiles", NSAppleScript(source: script)?.compileAndReturnError(&error) == true, "\(error ?? [:])")
            }

            // S-060 colors
            ColorPicker.shared.remember(RGB(r: 255, g: 128, b: 0))
            ColorPicker.shared.remember(RGB(r: 0, g: 0, b: 0))
            ColorPicker.shared.remember(RGB(r: 255, g: 128, b: 0))
            check("recent colors are newest first without repeats", model.recentColors == ["#FF8000", "#000000"])
            Toast.show("Self-test", symbol: "checkmark")

            // S-063 text and QR codes, on drawn images so the screen is never read
            let words = await TextGrabber.read(Self.render(text: "Toolbelt reads text"))
            check("text in an image is read", words.text?.contains("Toolbelt reads text") == true && !words.isCode, words.text ?? "nothing")
            if let qr = Self.renderQR("https://notchy.dev") {
                let code = await TextGrabber.read(qr)
                check("a QR code is read before text", code.isCode && code.text == "https://notchy.dev", code.text ?? "nothing")
            }

            // S-002 secrets
            check("password manager copies are skipped",
                  ClipRules.shouldSkip(types: ["org.nspasteboard.ConcealedType"], sourceApp: nil))

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// Black text on white, at Retina size.
    /// A page of random colored blocks, different on every row band, for the scrolling capture check.
    private static func isRed(_ image: CGImage, x: Int) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        return (rep.colorAt(x: x, y: 0)?.redComponent ?? 0) > 0.9
    }

    private static func noisePage(width: Int, height: Int) -> CGImage {
        var seed: UInt64 = 7
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 8) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let (r, g, b) = (UInt8(truncatingIfNeeded: seed >> 24), UInt8(truncatingIfNeeded: seed >> 32), UInt8(truncatingIfNeeded: seed >> 40))
                for row in y..<min(y + 2, height) {
                    for column in x..<min(x + 8, width) {
                        let index = (row * width + column) * 4
                        pixels[index] = r; pixels[index + 1] = g; pixels[index + 2] = b
                    }
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func render(text: String) -> CGImage {
        let image = NSImage(size: NSSize(width: 600, height: 120), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 36)])
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    private static func renderQR(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
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
