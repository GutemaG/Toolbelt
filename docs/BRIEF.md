# Toolbelt

A menu bar toolbox for one Mac user that replaces a stack of single-purpose
utilities: app launcher, clipboard history, screenshots, screen recording,
window snapping, a color picker and Keep Awake, each one shortcut away and
each one able to sit in the menu bar on its own.

## Replaces
Notchy (used today), the macOS screenshot tool (⇧⌘5), Spotlight for
launching apps, and separate clipboard, window and caffeine apps.

## Main jobs
1. Open an app or paste an earlier copy from the keyboard (done in v1).
2. Capture the screen: a screenshot of an area, window or the whole screen,
   or a recording of one, then copy, save or share it.
3. Arrange windows with a shortcut: halves, thirds, maximize, center.
4. Choose which tools are on, which have their own menu bar icon, and what
   permissions they use, in one Settings window.

## Data
- ClipItem, AppLaunch: as in v1.
- Capture: kind (screenshot, recording), file URL, pixel size, duration, created at (the recent captures list).
- Tool settings in UserDefaults: enabled, shows own menu bar icon, order in the menu bar panel, shortcut.

## Shape
Menu bar app (no Dock icon by default). One Toolbelt menu bar icon opens the
panel with every enabled tool; any tool can also get its own menu bar icon.
Floating panels for the launcher and clipboard; a full-screen selection
overlay for capture. A sidebar Settings window like the reference
screenshot: Settings (Permissions, Menu bar and Dock, Menu bar panel),
Input (Launcher, Clipboard), Capture (Screenshots, Recording, Colors),
Windows (Window Snapping), Tools (Keep Awake), App (Appearance).
macOS 26 or later. Local data. Works offline. No accounts.

## System hooks
- Menu bar: the Toolbelt item plus optional per-tool `NSStatusItem`s with saved positions; a recording turns its icon into a stop button with a timer.
- Global shortcuts per tool (Carbon), so a tool works even when macOS hides its icon.
- ScreenCaptureKit for screenshots and recording (Screen Recording permission, asked when a capture tool is first turned on).
- Accessibility for paste and window snapping (asked when first needed).
- Microphone, only when "Record microphone" is turned on.
- Keep Awake with an IOKit power assertion.
- Show in Dock toggle; Open at login.
- Signed with an Apple Development certificate, so permissions survive rebuilds.

## Reference
Notchy (features, permission model, detachable tabs) and the user's "Onyx"
settings screenshot (layout). Research: docs/research/menu-bar-suite.md.

## Look
Native Mac with the system accent color. Settings sidebar with small colored
icon tiles per page, grouped sections with switches and short descriptions,
like the reference screenshot.

## Not in version two
- Markup editor, scrolling capture, OCR, GIF export.
- Snippets, command palette, system stats, music, notch UI.
- Window switcher.
- iCloud sync.
