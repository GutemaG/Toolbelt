# All-in-one menu bar suite

Research for Toolbelt. Done 2026-10-30.
[V] verified in a source, [K] from knowledge, [U] unverified, test first.

Question: what should Toolbelt add to grow from a launcher + clipboard into a
suite like Notchy, with a sidebar Settings window, screenshots, screen
recording, and tools pinned as their own menu bar items?
Decision it informs: the version-two tool list, the Settings structure, the
menu bar model, and the capture implementation.

## Findings

### Market
- Notchy: $24.99 once, macOS 13+, 74 features in 8 groups, lives in the notch or a floating pill; no Dock icon, no main window [V](https://notchy.dev/) [V](https://notchy.dev/features/) [V](https://notchy.dev/help/where-is-notchy/)
- Notchy lets you right-click a tab and add it to the menu bar as its own popover; a detached Timer shows time left in the menu bar [V](https://notchy.dev/changelog/)
- iStat Menus is the closest match to "one item per tool": each module is its own menu bar item, with an optional Combined mode [V](https://bjango.com/mac/istatmenus/)
- Supercharge ($20, macOS 26+) puts ~150 tweaks in one reorderable menu; only a few features get their own icon [V](https://sindresorhus.com/supercharge)
- Raycast 2 needs macOS 26 and Apple Silicon; clipboard, windows, snippets free; Pro $10/mo [V](https://www.raycast.com/new) [V](https://www.raycast.com/pricing)
- macOS 26 Spotlight has its own clipboard history, off by default [V](https://www.ithinkdiff.com/spotlight-macos-tahoe-quick-keys-clipboard/)
- Capture depth bar: CleanShot X (scrolling capture, OCR, pinned shots, recording with webcam and keystrokes, $35) [V](https://cleanshot.com/) and Shottr (scrolling, OCR, color picker) [V](https://shottr.cc/)

### Notchy in detail
- Groups: Dynamic Island; Music & Audio; Focus & Time; Files & Clipboard; System & Hardware; Input, Shortcuts & Windows; Notifications & Privacy; Developers & AI [V](https://notchy.dev/features/)
- Settings opens from right-click, ⌘, or the command palette, with a searchable sidebar; pages include General, Behavior, Displays, Appearance, Notifications, Permissions, Screenshots, Developer, About, and one "Tools" section [V](https://notchy.dev/help/open-notchy-settings/) [V](https://notchy.dev/changelog/)
- Permissions page with a guide and "Copy Permission Diagnostics"; only Accessibility at first run, every other permission asked when a feature needs it [V](https://notchy.dev/help/permissions-notchy-needs/)
- Recording hands off to macOS's own recorder (⇧⌘5 style): area, window, or screen, timer in the notch, one-click stop, saves where macOS screenshots go [V](https://notchy.dev/mac-screen-recorder/)
- Markup: arrow, rectangle, ellipse, line, highlighter, text, redaction; 7 colors, 3 weights, ⌘Z; saves an annotated copy beside the original [V](https://notchy.dev/mac-screenshot-annotation/)
- Scrolling capture stitches up to 30 shots, needs Screen Recording [V](https://notchy.dev/mac-scrolling-screenshot/)
- Shortcuts: open ⌃⌥N, palette ⌃⌥K, clipboard ⌃⌥C, snapping ⌃⌥⌘+arrows [V](https://notchy.dev/help/keyboard-shortcuts/)
- Settings was reorganized four times and ~80 options removed [V](https://notchy.dev/changelog/)
- The user's reference screenshot (sidebar: Settings; Windows: Windows, Switcher; Input: Launcher, Clipboard, Snippets; Capture: Colors, Screenshots, Recording; Tools: Toolbox, Creator, Developer, System, Commands; App: Appearance, Features; "Menu bar panel" with reorder arrows and toggles) is titled "Onyx" and matches no public app found, Notchy included [U]. We use it as the target layout.

### Platform
- Screenshots: `SCScreenshotManager.captureImage(contentFilter:configuration:)` macOS 14+; `captureImage(in: CGRect)` macOS 15.2+; macOS 26 adds `captureScreenshot` with `SCScreenshotConfiguration` (HDR, file type, fileURL, showsCursor, ignoreShadows) [V](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager) [V](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration)
- Area select: capture the display first, show a borderless panel per screen at screen-saver level with the frozen image, draw the selection, crop [K]. Exclude own windows with `SCContentFilter(display:excludingApplications:)` [K]. Scale by `pointPixelScale` or the shot is 1x [K]
- Recording: `SCStream` + `SCRecordingOutput` (macOS 15) writes .mov/.mp4 itself; delegate is passed in init [V](https://developer.apple.com/documentation/screencapturekit/screcordingoutputconfiguration) [V](https://developer.apple.com/forums/thread/804839). `sourceRect` for area, `capturesAudio` system audio, `captureMicrophone` (15), `showMouseClicks` (15) [V](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showmouseclicks)
- GIF: no native encoder; `CGImageDestination` with `UTType.gif` from frames [K]
- Screen Recording permission: `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`; prompts once, then System Settings; often needs a relaunch [K]. macOS 15 asks again monthly [V](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/)
- Ad hoc signing loses Screen Recording and Accessibility grants on every rebuild; an Apple Development certificate fixes it [V](https://developer.apple.com/forums/thread/795739)
- Several `NSStatusItem`s per app work; `autosaveName` keeps position, `isVisible` toggles [K]. On macOS 26 users can disallow items in System Settings with no API to read it; `behavior = .removalAllowed` + KVO on `isVisible` [V](https://developer.apple.com/forums/thread/788101). Raycast warns macOS hides items when the bar is crowded [V](https://developers.raycast.com/api-reference/menu-bar-commands)
- Show in Dock at runtime: `setActivationPolicy(.regular)` then `NSApp.activate()`; switching back to `.accessory` can drop focus [K]
- Settings from a menu bar app: `openSettings` needs a SwiftUI scene context; our own NSWindow with an NSHostingController already works (Toolbelt does this) [V](https://developer.apple.com/documentation/swiftui/opensettingsaction)

## Likes and dislikes

| App | People like | People dislike | Sources |
| --- | --- | --- | --- |
| Notchy | One app instead of many; polished look; pay once; asks few permissions | CPU and battery bugs; freezes and blocked clicks; reversed "free forever" promise; alerts replace each other | [PH](https://www.producthunt.com/products/notchy), [changelog](https://notchy.dev/changelog) |
| Raycast | Replaces clipboard, window, snippet apps; free core; extensions; ships fast | Memory 350MB–1GB; moved to WebView in v2; AI forced into paid tier; learning curve | [pricing](https://www.raycast.com/pricing), [MPU](https://talk.macpowerusers.com/t/sindre-sorhus-switched-from-raycast-to-tinycast/46944?page=2), [2.6](https://www.raycast.com/changelog/macos/2-6) |
| CleanShot X | Full screenshot replacement; scrolling capture; OCR; pay once | Breaks after macOS updates; regressions in scrolling and OCR; paid updates; monthly permission prompts | [Setapp](https://setapp.com/en/apps/cleanshot/customer-reviews), [TidBITS](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly) |
| Boring Notch | Free, open source; escape from NotchNook; music, file shelf | Battery drain from leaked timers; breaks on OS updates; users want to switch features off | [repo](https://github.com/TheBoredTeam/boring.notch), [#1260](https://github.com/TheBoredTeam/boring.notch/issues/1260) |
| iStat Menus | One menu bar item per module, optional combine | Not researched in depth [U] | [bjango](https://bjango.com/mac/istatmenus/) |
| Supercharge | One reorderable menu, few icons | Not researched in depth [U] | [site](https://sindresorhus.com/supercharge) |

Patterns: people love one app replacing many, pay-once, native speed, and
asking for permissions only when needed. They leave over CPU/memory leaks
(timers that never stop), features they cannot turn off, and capture that
breaks after a macOS update. Reddit was blocked; Product Hunt, Hacker News,
MPU forum, Setapp reviews and GitHub issues stood in.

## Feature matrix

| Feature | Notchy | CleanShot X | Raycast | iStat Menus | Version one? |
| --- | --- | --- | --- | --- | --- |
| Launcher + pinned apps | yes | – | yes | – | done |
| Clipboard history | yes | – | yes | – | done |
| Sidebar Settings, page per tool | yes | tabs | yes | – | yes |
| Permissions page with live status | yes | – | – | – | yes |
| Turn each tool on/off | partly | – | per extension | per module | yes |
| Each tool as its own menu bar item | 4 tabs | – | per extension | yes | yes |
| Show in Dock toggle | no | – | – | – | yes |
| Screenshot: area, window, screen | yes | yes | – | – | yes |
| Screenshot to clipboard/file, after-capture preview | yes | yes | – | – | yes |
| Screen recording: area, window, screen, stop in menu bar | yes | yes | – | – | yes |
| Recording: system audio, mic, show clicks | [U] | yes | – | – | yes (toggles) |
| Markup editor | yes | yes | – | – | later |
| Scrolling capture | yes | yes | – | – | later |
| OCR (text from screen) | yes | yes | – | – | later |
| Color picker | yes | – | – | – | yes (small) |
| Keep Awake / system toggles | yes | – | – | – | yes (small) |
| Window snapping | yes | – | yes | – | later |
| GIF export | convert | yes | – | – | later |
| Snippets | yes | – | yes | – | later |
| System stats | yes | – | – | yes | later |

## Decisions
1. Settings becomes a sidebar window (NavigationSplitView in our own NSWindow) with groups like the reference: Settings; Input (Launcher, Clipboard); Capture (Colors, Screenshots, Recording); Tools (Toolbox); App (Appearance), because the user asked for that layout and Notchy's page-per-tool Settings needed four reorganizations when it grew [V](https://notchy.dev/changelog/).
2. Each tool can be shown as its own menu bar item (`NSStatusItem` with `autosaveName`), turned on per tool in Settings, plus the existing combined Toolbelt item, because per-tool items set us apart (Notchy only detaches four tabs [V](https://notchy.dev/changelog/), iStat Menus proves the model [V](https://bjango.com/mac/istatmenus/)). Every tool keeps a global shortcut so it works when macOS hides its icon [V](https://developer.apple.com/forums/thread/788101).
3. Every tool has an on/off switch, and a tool that is off runs no timers and asks for no permission, because CPU leaks and features you can't turn off are the top reasons people leave [V](https://github.com/TheBoredTeam/boring.notch/issues/1260).
4. A Permissions section shows Accessibility and Screen Recording with live status and a button to the right System Settings pane; each is asked only when a tool that needs it is turned on, because Notchy moved to exactly this [V](https://notchy.dev/help/permissions-notchy-needs/).
5. Screenshots use ScreenCaptureKit: freeze the screen, select an area (or click a window, or press Space for full screen), copy to the clipboard and save to a folder, with a small preview after capture. Planned test: capture at Retina scale on this Mac and compare pixel size.
6. Recording uses `SCStream` + `SCRecordingOutput` to .mp4, reusing the area selector; the menu bar icon turns into a stop button with elapsed time; toggles for system audio, microphone and showing clicks [V](https://developer.apple.com/documentation/screencapturekit/screcordingoutputconfiguration). Planned test: record 5 s with and without mic and check the file plays and has audio.
7. Sign with an Apple Development certificate before capture work, because ad hoc builds lose the Screen Recording grant every rebuild [V](https://developer.apple.com/forums/thread/795739).
8. Stay on macOS 26+, because the category already requires it (Raycast 2, Supercharge [V](https://sindresorhus.com/supercharge)) and it gives `SCScreenshotConfiguration` [V](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration).
9. Show in Dock is a toggle (default off) using `setActivationPolicy`. Planned test: flip it while Settings is open and check Settings stays in front.
10. Markup, scrolling capture, OCR, window snapping, snippets, GIF, system stats go to Later, because CleanShot shows capture depth is a product on its own and reviews punish regressions [V](https://setapp.com/en/apps/cleanshot/customer-reviews).

## Open questions
- Does macOS 26 still ask monthly for Screen Recording for a non-sandboxed, development-signed app? Test: grant, then check `CGPreflightScreenCaptureAccess` across relaunches.
- Can we detect that macOS hid one of our status items? Test: KVO on `isVisible`, then disallow the item in System Settings > Menu Bar.
- Does `captureImage(in:)` include the frozen-overlay panel if it is still on screen? Test: capture while the panel is visible, with our app excluded from the filter.
