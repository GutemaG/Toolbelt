# Toolbelt

A menu bar toolbox for one Mac user that puts an app launcher and clipboard
history one shortcut away, with room to add more small tools later.

## Replaces
Notchy (the notch utility used today), plus Spotlight for launching apps.

## Main jobs
1. Launch an app: press a shortcut, type a few letters, press Return.
2. Paste something copied earlier: press a shortcut, search or pick from
   history, press Return to paste it into the front app.
3. Keep important clips: pin an item so it stays at the top and is never
   pruned.

## Data
- ClipItem: kind (text, link, image), text, image data, source app bundle id,
  copied at, pinned, last used at.
- AppLaunch: bundle id, launch count, last launched at (ranks launcher
  results). The app list itself is read live from /Applications,
  ~/Applications and /System/Applications, not stored.

## Shape
Menu bar extra with a popover that has two tabs (Launcher, Clipboard), plus a
floating Spotlight-style panel for each tool opened by a global shortcut.
A Settings window for shortcuts, history size and excluded apps.
macOS 26 or later. Local data (SwiftData). Works offline. No accounts.

## System hooks
- Menu bar item (no Dock icon).
- Global shortcuts: Option-Space for the launcher, Shift-Command-V for
  clipboard history (changeable in Settings; decided by the agent).
- Clipboard watching: poll the pasteboard change count; keep the last 500
  items; skip concealed/transient items from password managers.
- Paste into the front app: synthesize Command-V, which needs Accessibility
  permission (fall back to "copy only" without it).
- Launch at login (login item).

## Reference
None. Notchy is what it replaces, not a look to copy.

## Look
Native Mac with the system accent color: Liquid Glass panels, SF Symbols,
keyboard-first (arrow keys, Return, Escape, Command-1…9).

## Not in version one
- More tools: snippets, window snapping, quick notes (the tab design should
  make adding them easy).
- Launcher search for files, system commands and web search.
- Copied files from Finder in clipboard history.
- iCloud sync between Macs (later).
