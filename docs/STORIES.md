# Toolbelt stories

Snapshot pages (no reference app): `popover-launcher`, `popover-clipboard`,
`panel-launcher`, `panel-clipboard`, `settings-general`, `settings-clipboard`,
`settings-shortcuts`, `permission-accessibility`.

## Seed data

- 30 ClipItems: plain text, code, links, two images; copied from Safari,
  Xcode, Notes, Terminal, Messages; three pinned; spread over the last week.
- AppLaunch rows for Safari (40), Xcode (25), Ghostty (18), Notes (6), so
  ranking is visible.

## M1 Core loop

### S-001 Open Toolbelt from the menu bar
As the user, I click the Toolbelt icon in the menu bar and a popover opens
with two tabs, Launcher and Clipboard.
Screens: popover-launcher, popover-clipboard
Acceptance:
- [snap] The popover shows a segmented control with Launcher and Clipboard; the last used tab is selected.
- [manual] The app has no Dock icon and no app switcher entry.
- [manual] Clicking outside the popover or pressing Escape closes it.
- [self] Command-1 and Command-2 switch tabs while the popover is open.
UX:
- Flow: click the menu bar icon -> popover opens on the last used tool, search field has focus -> Command-1 / Command-2 or the segmented control switches tool -> Escape, a click outside, or a second click on the icon closes it
- Surface: popover attached to the menu bar icon (a few related choices tied to one control); about 360 × 480 pt, never opens another popover
- States: first open shows Launcher; each tab owns its own empty state (S-003, S-008)
- Words: segment labels "Launcher" and "Clipboard"; menu bar icon tooltip "Toolbelt"; segment tooltips "Find and open apps (⌘1)", "Search clipboard history (⌘2)"
- Access: menu bar icon VoiceOver label "Toolbelt"; segmented control reads "Tool, Launcher, 1 of 2"; focus goes to the search field on open; Reduce Motion skips the popover slide
Status: done

### S-002 Record copied text and links
As the user, I copy text or a link in any app and it appears at the top of
my clipboard history.
Depends: S-001
Acceptance:
- [unit] A pasteboard change with a string creates a ClipItem of kind text; a string that parses as an http(s) URL creates kind link.
- [unit] Copying the same text again moves the existing item to the top instead of adding a duplicate.
- [unit] The source app's bundle id and the copy time are stored.
- [self] Items are still there after quitting and relaunching the app.
UX:
- Flow: Command-C in any app -> within half a second the clip is at the top of Recent -> no alert, no sound
- Surface: none; background recording, result shows in the Clipboard tab (information that needs no action stays inline)
- States: a duplicate copy moves the existing clip to the top with its new time; nothing to show for errors, a failed read is skipped and logged
- Words: none new
- Access: nothing on screen to read
Status: done

### S-003 Browse clipboard history
As the user, I open the Clipboard tab and see my recent copies, newest first.
Screens: popover-clipboard
Depends: S-002
Acceptance:
- [snap] Each row shows a one-line preview, the source app icon, and a relative time ("2 min ago").
- [snap] Links show the host name and a link symbol.
- [snap] With no history, an empty state says how to start ("Copy something and it shows up here").
UX:
- Flow: Command-2 or the Clipboard segment -> list of clips, newest first, first row selected -> Up/Down move -> Escape closes
- Surface: list in the popover's Clipboard tab (a place people come back to)
- States: empty "No Clips Yet" with "Copy something and it shows up here."; too much: preview is one line with a tail ellipsis and the first 500 characters in the tooltip; 500 rows scroll smoothly (lazy list)
- Words: section header "Recent"; relative times "Just now", "2 min ago", "Yesterday", then a short date
- Access: row reads "<preview>, from <source app>, <time>"; link rows add "link"; icon has no separate VoiceOver stop
Status: done

### S-004 Copy a past item back to the clipboard
As the user, I select a row and press Return (or click it) to put it back on
the clipboard.
Screens: popover-clipboard
Depends: S-003
Acceptance:
- [unit] Choosing an item writes its contents to the general pasteboard and moves it to the top.
- [unit] Toolbelt does not record its own write as a new item.
- [manual] The popover closes and Command-V in another app pastes the item.
UX:
- Flow: select a row -> Return, double-click, or click -> clip is copied, moves to the top, popover closes -> Command-V in the app pastes it
- Surface: inline action on the row (changes one value already on screen); in the popover Return means Copy, in the clipboard panel (S-012) Return means Paste, and each surface's footer says which
- States: done: popover closes at once, which is the feedback; reopening shows the clip at the top
- Words: footer hint "↩ Copy"; row hover tooltip "Copy this clip (↩)"
- Access: Return on the focused row copies; VoiceOver custom action "Copy"
Status: done

### S-005 Search clipboard history
As the user, I type in the search field above the list to filter history.
Screens: popover-clipboard
Depends: S-003
Acceptance:
- [unit] Search matches anywhere in the text, ignoring case and accents.
- [snap] Matching text in each row is highlighted.
- [self] Filtering 500 items takes under 16 ms.
- [snap] No matches shows "No clips match '<query>'".
UX:
- Flow: Clipboard tab opens with the search field focused -> type -> list filters on every keystroke, first match selected -> Escape clears the search, a second Escape closes
- Surface: inline search field at the top of the tab (changes one value on screen)
- States: no matches "No Results" with "No clips match “<query>”."; clearing the field brings back the full list with the old selection
- Words: placeholder "Search Clips"; clear button tooltip "Clear the search"
- Access: field VoiceOver label "Search clips"; result count announced after typing pauses ("12 clips"); highlight uses bold weight as well as accent color
Status: done

### S-006 Find an app by typing
As the user, I type a few letters in the Launcher tab and see matching apps.
Screens: popover-launcher
Depends: S-001
Acceptance:
- [unit] Apps are indexed from /Applications, ~/Applications, /System/Applications and their Utilities folders.
- [unit] Fuzzy match: "vsc" finds Visual Studio Code, "gst" finds Ghostty; prefix matches rank above fuzzy ones.
- [snap] Each result shows the app icon and name; the first result is selected.
- [self] A newly installed app appears without restarting Toolbelt.
UX:
- Flow: Command-1 or the Launcher segment -> search field focused -> type -> results update per keystroke, first result selected -> Up/Down move -> Escape clears, then closes
- Surface: inline search field and result list in the popover's Launcher tab (changes one value on screen)
- States: indexing on first run shows Frequent from cache and never blocks typing; no matches "No Results" with "No apps match “<query>”."; long app names truncate with the full name in the tooltip
- Words: placeholder "Search Apps"; matched letters in bold
- Access: result reads "<app name>, application"; matched letters use bold, not color alone
Status: done

### S-007 Launch an app with Return
As the user, I press Return on the selected result and the app opens or comes
to the front.
Screens: popover-launcher
Depends: S-006
Acceptance:
- [manual] Return opens the app, or activates it if it is already running, and the popover closes.
- [unit] Each launch increments the app's AppLaunch count and sets last launched at.
UX:
- Flow: selected result -> Return, double-click, or click -> app opens or comes to the front, popover closes -> nothing to undo
- Surface: inline action on the result row
- States: an app that was moved or deleted shows inline under the row "Unable to open <app>. It may have been moved or deleted." and is dropped from the index on the next refresh
- Words: footer hint "↩ Open"; row tooltip "Open <app> (↩)"; running apps show a small dot plus the word "Running" for VoiceOver
- Access: Return on the focused row opens; VoiceOver custom action "Open"
Status: done

### S-008 Rank launcher results by how often I use them
As the user, the apps I open most appear first, and with an empty query I
see my most used apps.
Screens: popover-launcher
Depends: S-007
Acceptance:
- [unit] Among equal match quality, higher launch count and more recent use rank first.
- [snap] With an empty query the list shows the top eight apps by usage under the heading "Frequent".
UX:
- Flow: open the Launcher with an empty search -> Frequent shows the top eight -> Return opens the first -> typing replaces Frequent with results ranked by match, then use
- Surface: same list in the Launcher tab, with a section header
- States: before any app has been opened, Frequent is replaced by "No Frequent Apps Yet" with "Apps you open from Toolbelt show up here." and an A–Z list below
- Words: section header "Frequent"; when searching, no header
- Access: section header is a VoiceOver heading
Status: done

## M2 Speed

### S-009 Open the launcher with Option-Space
As the user, I press Option-Space anywhere and a floating launcher panel
appears in the middle of the screen with the cursor in the search field.
Screens: panel-launcher
Depends: S-008
Acceptance:
- [manual] The shortcut works from any app, including full screen apps.
- [snap] The panel is a Liquid Glass floating panel with the same results as the Launcher tab.
- [manual] Pressing the shortcut again, Escape, or clicking elsewhere closes it and returns focus to the previous app.
Status: done

### S-010 Open clipboard history with Shift-Command-V
As the user, I press Shift-Command-V and a floating clipboard panel appears.
Screens: panel-clipboard
Depends: S-005
Acceptance:
- [manual] The shortcut works from any app; the search field has focus.
- [snap] The panel shows the list on the left and a preview of the selected item on the right.
Status: doing (needs the preview pane beside the list)

### S-011 Navigate lists with the keyboard
As the user, I move through results with the arrow keys and pick one with
Command-1 to Command-9.
Screens: panel-launcher, panel-clipboard
Depends: S-009, S-010
Acceptance:
- [self] Up and Down move the selection and keep it scrolled into view; typing keeps focus in search.
- [snap] Rows 1–9 show their Command-number hint.
- [self] Command-number picks that row.
Status: doing (arrows, Return, Tab and ⌘1/⌘2 for tools done; ⌘1–9 rows conflict with ⌘1/⌘2 tool switching)

### S-012 Paste straight into the front app
As the user, I press Return in the clipboard panel and the item is pasted
where my cursor was.
Screens: panel-clipboard, permission-accessibility
Depends: S-010
Acceptance:
- [manual] With Accessibility allowed, the panel closes, the previous app is focused, and the item is pasted.
- [manual] Without Accessibility, the item is copied and a sheet explains why pasting needs the permission, with a button that opens System Settings.
- [unit] Option-Return pastes as plain text (no formatting).
Status: done

## M3 Clips

### S-013 Pin a clip
As the user, I press Command-P on a row (or use its pin button) so it stays at
the top and is never removed.
Screens: popover-clipboard, panel-clipboard
Depends: S-003
Acceptance:
- [snap] Pinned items show in a "Pinned" section above "Recent".
- [unit] Pruning never removes pinned items.
Status: done

### S-014 Delete a clip
As the user, I press Delete on a row to remove it from history.
Depends: S-003
Acceptance:
- [unit] The item is removed from the store.
- [self] Command-Z right after brings it back.
Status: doing (delete done, Undo not yet)

### S-015 Clear history
As the user, I choose Clear History and every unpinned item is removed after I
confirm.
Depends: S-013
Acceptance:
- [snap] A confirmation names the count ("Clear 214 Clips?" with "Pinned clips stay.") and buttons "Clear History" and "Cancel".
- [unit] Only unpinned items are removed.
Status: done

### S-016 Record copied images
As the user, I copy an image or take a screenshot to the clipboard and it is
saved in history with a thumbnail.
Screens: popover-clipboard, panel-clipboard
Depends: S-002
Acceptance:
- [unit] PNG and TIFF pasteboard data create a kind image item; images over 10 MB are skipped.
- [snap] Rows show a thumbnail; the panel preview shows the full image and its pixel size.
- [manual] Choosing it puts the image back on the clipboard and pastes it into Preview.
Status: done

### S-017 Skip passwords and secret copies
As the user, things copied from password managers are never saved.
Depends: S-002
Acceptance:
- [unit] Items marked org.nspasteboard.ConcealedType or TransientType are ignored.
- [unit] Items from apps in the excluded list are ignored.
Status: done

### S-018 Keep history to a size limit
As the user, history keeps the last 500 unpinned items by default.
Depends: S-013
Acceptance:
- [unit] Adding item 501 removes the oldest unpinned item.
Status: done

## M4 System

### S-019 Change shortcuts in Settings
As the user, I record a different shortcut for each tool in Settings.
Screens: settings-shortcuts
Depends: S-009, S-010
Acceptance:
- [snap] Settings has a Shortcuts pane with a recorder per tool and a Clear button.
- [manual] A new shortcut works at once; a shortcut already used by the system shows a warning.
Status: todo

### S-020 Choose history size and excluded apps
As the user, I set how many items to keep and which apps are never recorded.
Screens: settings-clipboard
Depends: S-017, S-018
Acceptance:
- [snap] A picker offers 100, 500, 1000, 5000; an app list has add and remove buttons; 1Password and Keychain Access are in it by default.
- [unit] Lowering the size prunes right away.
Status: todo

### S-021 Start Toolbelt at login
As the user, I turn on "Open at login" in Settings.
Screens: settings-general
Acceptance:
- [manual] With it on, Toolbelt runs after a restart; the toggle reflects System Settings > Login Items.
Status: done

### S-022 Pause clipboard recording
As the user, I choose Pause Recording from the menu bar icon's menu so the
next copies are not saved.
Screens: popover-clipboard
Depends: S-002
Acceptance:
- [snap] While paused, the menu bar icon is dimmed and the Clipboard tab shows "Recording paused" with a Resume button.
- [unit] No items are recorded while paused.
Status: todo

## M5 Polish

### S-023 Act on a clip from its context menu
As the user, I right-click a row to Paste, Paste as Plain Text, Pin, Copy, or
Delete.
Depends: S-012, S-013, S-014
Acceptance:
- [snap] The context menu lists those actions with their shortcuts.
Status: todo

### S-024 Drag a clip into another app
As the user, I drag a row from the clipboard panel into another app.
Depends: S-010
Acceptance:
- [manual] Dragging text into Notes and an image into Finder works.
Status: todo

### S-025 Reach Settings, About and Quit from the menu bar
As the user, I right-click the menu bar icon to open Settings, About Toolbelt,
or Quit.
Screens: settings-general
Depends: S-001
Acceptance:
- [manual] Right-click shows the menu; Command-, in the popover opens Settings.
Status: done

### S-026 App icon
As the user, I see a Toolbelt icon in Settings, About, and Login Items.
Acceptance:
- [snap] The icon renders in light, dark, and tinted looks.
Status: todo

### S-027 Pin apps to the top of the Launcher
As the user, I pin the apps I use most so they show as a grid of icons at the
top of the Launcher, like pinned clips.
Screens: panel-launcher, popover-launcher
Depends: S-006
Acceptance:
- [snap] With an empty search, a "Pinned" grid of icons with names sits above Frequent, ending with an "Add…" tile (6 across in the panel, 4 in the popover).
- [self] Add… pins the chosen apps at the end; Move Left/Right reorders; Unpin removes; pinning again adds at the end.
- [manual] ⌘P or right-click > Pin on any app row pins it; pinned apps leave Frequent and show a pin in search results.
- [manual] Arrow keys move through the grid by column and row; Return opens the selected app.
- [snap] Add… switches the Launcher to "Choose Apps to Pin": every app with a pin button, search, Other App… and Done; nothing closes while picking.
- [manual] A pin button shows on the hovered or selected app row; dragging an app from Finder or the Dock onto the grid pins it.
UX:
- Flow: pin button on a row, ⌘P, right-click > Pin, drag onto the grid, or Add… > click apps in the pick list > Done (esc) -> tile appears at the end of the grid -> right-click a tile > Move Left / Move Right / Unpin / Show in Finder
- Surface: grid section inside the Launcher list (a place people come back to); Add… turns the list into a pick list in place (inline), Other App… uses the system Open panel
- States: no pinned apps shows only the Add… tile; an app that was moved or deleted drops out of the grid
- Words: "Pinned", "Add…", "Pin", "Unpin", "Move Left", "Move Right", "Show in Finder"; Open panel title "Pin Apps", button "Pin"; Add… tooltip "Pin apps to the top of the Launcher"
- Access: tiles are buttons that read the app name; arrows, Return and ⌘P work without a mouse
Status: done

## V2-M1 Settings and tool switches

### S-030 Open a sidebar Settings window
As the user, I open Settings (⌘, or the gear) and see a sidebar of pages grouped as Settings, Input, Capture, Windows, Tools, App, each with a small colored icon tile.
Screens: settings-settings, settings-launcher, settings-screenshots
Acceptance:
- [snap] Sidebar groups and pages match the brief; the selected page shows a header with its icon, title and one-line description.
- [snap] Each page is one grouped Form; no page scrolls when it fits.
- [self] Settings reopens on the last page.
Status: done

### S-031 See and grant permissions in one place
As the user, I see Accessibility and Screen Recording with On/Off status and what each is for, and a button that opens the right System Settings pane.
Screens: settings-settings
Depends: S-030
Acceptance:
- [snap] Each permission row has an icon, name, one-line purpose, and an "On" badge or "Allow…" button.
- [manual] Status updates within 2 seconds of granting in System Settings, without reopening the window.
Status: done

### S-032 Turn a tool on or off
As the user, I switch a tool off on its page and it disappears from the panel, its shortcut stops, and it uses no CPU.
Screens: settings-launcher, settings-screenshots
Depends: S-030
Acceptance:
- [self] A disabled tool has no registered shortcut, no status item and no running timers.
- [snap] Each tool page starts with an "Enabled" switch and the tool's shortcut.
Status: done

### S-033 Give a tool its own menu bar icon
As the user, I turn on "Show in menu bar" for a tool and it gets its own icon that opens just that tool.
Screens: settings-clipboard, settings-settings
Depends: S-032
Acceptance:
- [manual] The icon keeps its position after relaunch (autosaveName).
- [manual] Clicking it opens that tool alone; a Toolbelt icon still shows all tools.
- [self] Turning it off removes the item.
Status: done

### S-034 Order the tools in the menu bar panel
As the user, I move tools up and down and switch them on or off in "Menu bar panel", and the Toolbelt panel shows them in that order.
Screens: settings-settings
Depends: S-032
Acceptance:
- [snap] Rows have icon, name, description, up/down buttons and a switch, like the reference.
- [self] Order and switches survive relaunch.
Status: done

### S-035 Show or hide Toolbelt in the Dock and menu bar
As the user, I choose whether Toolbelt shows in the Dock and whether its main menu bar icon shows.
Screens: settings-settings
Depends: S-030
Acceptance:
- [manual] Show in Dock switches at once and Settings stays in front.
- [manual] Hiding the main icon is refused with a note when no tool has its own icon and no shortcut is set.
Status: done

## V2-M2 Screenshots

### S-040 Capture an area
As the user, I press ⇧⌘4-style shortcut (default ⌃⇧4), drag over the frozen screen, and the image is copied and saved.
Screens: overlay-select, settings-screenshots
Depends: S-031
Acceptance:
- [manual] The screen freezes, a crosshair and live size label follow the pointer; Escape cancels.
- [unit] The saved PNG is at Retina pixel size of the selection.
- [manual] The image is on the clipboard and in the save folder (default Desktop) named "Toolbelt <date> at <time>.png".
Status: todo

### S-041 Capture a window or the whole screen
As the user, during selection I press Space to pick a window by hovering, or use the full-screen shortcut.
Depends: S-040
Acceptance:
- [manual] Space toggles window mode with a highlight on the hovered window; click captures it with its shadow off by default.
- [manual] The full-screen shortcut captures the display under the pointer.
Status: todo

### S-042 Act on a capture from the preview
As the user, after a capture a small preview appears in a corner where I can copy, save, show in Finder, drag it out, or close it.
Screens: capture-preview
Depends: S-040
Acceptance:
- [snap] Preview shows the thumbnail and buttons; it hides after 6 seconds unless hovered.
- [manual] Dragging the thumbnail into another app drops the image.
Status: todo

### S-043 Choose screenshot options
As the user, I set the save folder, file format (PNG/JPEG/HEIC), copy-to-clipboard, show preview, and include cursor.
Screens: settings-screenshots
Depends: S-040
Acceptance:
- [snap] Options are on the Screenshots page.
- [unit] File names and formats follow the options.
Status: todo

## V2-M3 Recording

### S-050 Record an area, window or screen
As the user, I start a recording from the shortcut or the Recording tool, pick an area, window or screen, and it records to MP4.
Screens: overlay-select, settings-recording
Depends: S-040
Acceptance:
- [manual] A 3-2-1 countdown, then recording; the selected area keeps a thin outline that is not in the video.
- [manual] The file plays in QuickTime at the selection's pixel size.
Status: todo

### S-051 Stop a recording from the menu bar
As the user, the menu bar shows a stop button with elapsed time while recording; clicking it or pressing the shortcut again stops and saves.
Depends: S-050
Acceptance:
- [manual] The timer updates every second; stop saves within a second and shows the capture preview.
Status: todo

### S-052 Choose recording options
As the user, I turn on system audio, microphone, show clicks and show cursor, and pick MP4 or MOV.
Screens: settings-recording
Depends: S-050
Acceptance:
- [manual] With microphone on, macOS asks for microphone access once; the file has audio.
- [snap] Options are on the Recording page.
Status: todo

## V2-M4 Small tools

### S-060 Pick a color from the screen
As the user, I press the Colors shortcut, move a magnifier over the screen, and click to copy the color as hex.
Screens: settings-colors
Acceptance:
- [manual] Click copies "#RRGGBB"; ⌥-click copies "rgb(r, g, b)"; Escape cancels. Uses NSColorSampler (no Screen Recording needed).
- [snap] The Colors page lists the last 12 picked colors; clicking one copies it.
Status: todo

### S-061 Keep the Mac awake
As the user, I turn on Keep Awake (indefinitely, 1 hour, or until a time) and the Mac does not sleep until it ends.
Screens: settings-keep-awake
Acceptance:
- [unit] The power assertion is created on start and released on end or quit.
- [manual] With its own menu bar icon, the icon fills while active.
Status: todo

### S-062 Snap the front window with a shortcut
As the user, I press ⌃⌥ plus an arrow (or other keys) to move the front window to a half, third, maximize or center.
Screens: settings-windows
Acceptance:
- [unit] Frame math for halves, thirds, maximize and center on a screen with a menu bar and Dock is correct.
- [manual] Works in Safari, Finder and Xcode; asks for Accessibility when first used.
Status: todo

## Later

- Snippets: saved text with a keyword.
- Markup editor, scrolling capture, OCR, GIF export (V2 research).
- Window switcher, command palette, system stats.
- Quick notes scratchpad.
- Launcher search for files, system commands, and the web.
- Copied Finder files in clipboard history.
- iCloud sync between Macs.

## Dropped

- Accounts and sign-in: one user, local data.
- Sharing clips with other people.
- Analytics and crash reporting services.
- Onboarding tour: the permission sheet in S-012 explains the one thing that needs explaining.
- Upgrade prompts and paid tiers.
