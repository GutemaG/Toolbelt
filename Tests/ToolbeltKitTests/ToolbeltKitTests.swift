import Foundation
import Testing
@testable import ToolbeltKit

@Test("Fuzzy matches", arguments: [
    ("vsc", "Visual Studio Code"),
    ("gst", "Ghostty"),
    ("saf", "Safari"),
    ("studio", "Android Studio"),
    ("ÉDGE", "Microsoft Edge"),
])
func fuzzyFinds(_ query: String, name: String) {
    #expect(FuzzyMatch.match(query, in: name) != nil)
}

@Test func fuzzyRejectsOutOfOrder() {
    #expect(FuzzyMatch.match("xq", in: "Safari") == nil)
    #expect(FuzzyMatch.match("ts", in: "Safari") == nil)
}

@Test func prefixBeatsFuzzy() {
    let prefix = FuzzyMatch.match("te", in: "Telegram")!
    let word = FuzzyMatch.match("te", in: "Microsoft Teams")!
    let fuzzy = FuzzyMatch.match("te", in: "Ghostty Extra")!
    #expect(prefix > word)
    #expect(word > fuzzy)
}

@Test func rankingUsesMatchThenUsage() {
    let apps = [
        LaunchCandidate(name: "Xcode", path: "/x", launchCount: 1),
        LaunchCandidate(name: "Microsoft Excel", path: "/e", launchCount: 50),
        LaunchCandidate(name: "Xcodes", path: "/xs", launchCount: 9),
    ]
    // Both "Xcode" names start with the query; the one used more wins.
    #expect(LauncherRanking.rank(apps, query: "xc").map(\.name) == ["Xcodes", "Xcode", "Microsoft Excel"])
}

@Test func emptyQueryShowsFrequent() {
    let apps = (0..<12).map { LaunchCandidate(name: "App \($0)", path: "/\($0)", launchCount: $0) }
    let frequent = LauncherRanking.rank(apps, query: "  ")
    #expect(frequent.count == 8)
    #expect(frequent.first?.name == "App 11")
    #expect(!frequent.contains { $0.launchCount == 0 })
}

@Test func linksAreDetected() {
    #expect(ClipRules.isLink("https://apple.com/mac"))
    #expect(ClipRules.isLink("  http://example.org \n"))
    #expect(!ClipRules.isLink("apple.com"))
    #expect(!ClipRules.isLink("see https://apple.com"))
    #expect(!ClipRules.isLink("ftp://files.example.org"))
}

@Test func previewIsOneLine() {
    #expect(ClipRules.preview("  let x = 1\n\n  let y = 2 ") == "let x = 1 let y = 2")
    #expect(ClipRules.preview(String(repeating: "a", count: 300), limit: 10) == "aaaaaaaaaa…")
}

@Test func searchIgnoresCaseAndAccents() {
    #expect(ClipRules.matches("cafe", text: "Meet at the Café"))
    #expect(ClipRules.matches("", text: "anything"))
    #expect(!ClipRules.matches("tea", text: "Meet at the Café"))
}

@Test func secretsAreSkipped() {
    #expect(ClipRules.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], sourceApp: nil))
    #expect(ClipRules.shouldSkip(types: ["public.utf8-plain-text"], sourceApp: "com.1password.1password"))
    #expect(!ClipRules.shouldSkip(types: ["public.utf8-plain-text"], sourceApp: "com.apple.Safari"))
}

@Test func pruningKeepsPinned() {
    let clips: [(id: Int, isPinned: Bool)] = [(1, false), (2, true), (3, false), (4, false), (5, true)]
    #expect(ClipRules.pruned(clips, limit: 2) == [4])
}

@Test func captureFileNames() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_793_383_452) // 2026-10-30 18:04:12 UTC
    #expect(CaptureRules.fileName(kind: "Screenshot", date: date, ext: "png", calendar: calendar)
            == "Toolbelt Screenshot 2026-10-30 at 18.04.12.png")
    let folder = URL(fileURLWithPath: "/tmp")
    let taken: Set<String> = ["/tmp/a.png", "/tmp/a 2.png"]
    #expect(CaptureRules.uniqueURL(in: folder, name: "a.png") { taken.contains($0.path) }.lastPathComponent == "a 3.png")
}

@Test func selectionBecomesPixels() {
    // A 100×50 pt box 10 pt from the left and 20 pt from the bottom of a 900 pt tall Retina screen.
    let rect = CaptureRules.pixelRect(selection: CGRect(x: 10, y: 20, width: 100, height: 50), screenHeight: 900, scale: 2)
    #expect(rect == CGRect(x: 20, y: 1660, width: 200, height: 100))
    #expect(CaptureRules.topLeftRect(selection: CGRect(x: 10, y: 20, width: 100, height: 50), screenHeight: 900)
            == CGRect(x: 10, y: 830, width: 100, height: 50))
}

@Test func dragRectIsClipped() {
    let r = CaptureRules.dragRect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: -10, y: 120), in: CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(r == CGRect(x: 0, y: 50, width: 50, height: 50))
}

@Test func elapsedTime() {
    #expect(CaptureRules.elapsed(65) == "1:05")
    #expect(CaptureRules.elapsed(3723) == "1:02:03")
}

@Test func colorFormats() {
    let orange = RGB(r: 255, g: 128, b: 0)
    #expect(orange.hex == "#FF8000")
    #expect(orange.rgb == "rgb(255, 128, 0)")
    #expect(orange.hsl == "hsl(30, 100%, 50%)")
    #expect(RGB(hex: "#ff8000") == orange)
    #expect(RGB(hex: "nope") == nil)
    #expect(RGB(red: 1, green: 0.5, blue: 0) == orange)
    #expect(RGB(r: 128, g: 128, b: 128).hsl == "hsl(0, 0%, 50%)")
}

@Test func windowPositions() {
    // A 1440×875 visible frame starting 25 pt up (above the Dock).
    let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    #expect(WindowPosition.leftHalf.frame(in: screen, current: window) == CGRect(x: 0, y: 25, width: 720, height: 875))
    #expect(WindowPosition.rightHalf.frame(in: screen, current: window) == CGRect(x: 720, y: 25, width: 720, height: 875))
    #expect(WindowPosition.centerThird.frame(in: screen, current: window) == CGRect(x: 480, y: 25, width: 480, height: 875))
    #expect(WindowPosition.maximize.frame(in: screen, current: window) == screen)
    #expect(WindowPosition.center.frame(in: screen, current: window) == CGRect(x: 320, y: 163, width: 800, height: 600))
    // On a 900 pt tall main screen, a frame whose top is at 875 pt sits 25 pt below the top edge (under the menu bar).
    #expect(WindowPosition.axFrame(CGRect(x: 0, y: 25, width: 720, height: 850), mainScreenHeight: 900)
            == CGRect(x: 0, y: 25, width: 720, height: 850))
}

@Test func linksAreCleaned() {
    #expect(LinkCleaner.clean("https://shop.com/item?id=4&utm_source=news&utm_medium=email") == "https://shop.com/item?id=4")
    #expect(LinkCleaner.clean("https://site.com/a?fbclid=XYZ") == "https://site.com/a")
    #expect(LinkCleaner.clean("https://youtu.be/abc?si=123") == "https://youtu.be/abc")
    #expect(LinkCleaner.clean("https://example.com/search?q=si") == nil)
    #expect(LinkCleaner.clean("https://example.com/") == nil)
    #expect(LinkCleaner.clean("not a link?utm_source=x") == nil)
}

@Test func keyCombos() {
    let shot = KeyCombo(keyCode: 21, modifiers: KeyCombo.control | KeyCombo.shift)
    #expect(shot.label == "⌃⇧4")
    #expect(KeyCombo(keyCode: 49, modifiers: KeyCombo.option).label == "⌥Space")
    #expect(KeyCombo(keyCode: 9, modifiers: KeyCombo.command | KeyCombo.shift).label == "⇧⌘V")
    #expect(KeyCombo(encoded: shot.encoded) == shot)
    #expect(KeyCombo(encoded: "nope") == nil)
    #expect(!KeyCombo(keyCode: 0, modifiers: KeyCombo.shift).isUsable)
    #expect(KeyCombo(keyCode: 122, modifiers: 0).isUsable)
}

@Test func timerInput() {
    #expect(TimerRules.parse("12") == 720)
    #expect(TimerRules.parse("12m") == 720)
    #expect(TimerRules.parse("90s") == 90)
    #expect(TimerRules.parse("1h30m") == 5400)
    #expect(TimerRules.parse("1:30") == 90)
    #expect(TimerRules.parse("0") == nil)
    #expect(TimerRules.parse("tea") == nil)
    #expect(TimerRules.parse("5x") == nil)
    #expect(TimerRules.title(5400) == "1 h 30 min")
    #expect(TimerRules.title(45) == "45 s")
}

@Test func snippetSearch() {
    #expect(SnippetRules.score(query: ";addr", title: "Home address", keyword: ";addr", text: "1 Main St") == 4)
    #expect(SnippetRules.score(query: "home", title: "Home address", keyword: ";addr", text: "1 Main St") == 3)
    #expect(SnippetRules.score(query: "main st", title: "Home address", keyword: "", text: "1 Main St") == 1)
    #expect(SnippetRules.score(query: "zebra", title: "Home address", keyword: "", text: "1 Main St") == nil)
}
