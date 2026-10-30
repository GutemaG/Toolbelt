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
Status: todo

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
Status: todo

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
Status: todo

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
Status: todo

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
Status: todo

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
Status: todo

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
Status: todo

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
Status: todo

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
Status: todo

### S-010 Open clipboard history with Shift-Command-V
As the user, I press Shift-Command-V and a floating clipboard panel appears.
Screens: panel-clipboard
Depends: S-005
Acceptance:
- [manual] The shortcut works from any app; the search field has focus.
- [snap] The panel shows the list on the left and a preview of the selected item on the right.
Status: todo

### S-011 Navigate lists with the keyboard
As the user, I move through results with the arrow keys and pick one with
Command-1 to Command-9.
Screens: panel-launcher, panel-clipboard
Depends: S-009, S-010
Acceptance:
- [self] Up and Down move the selection and keep it scrolled into view; typing keeps focus in search.
- [snap] Rows 1–9 show their Command-number hint.
- [self] Command-number picks that row.
Status: todo

### S-012 Paste straight into the front app
As the user, I press Return in the clipboard panel and the item is pasted
where my cursor was.
Screens: panel-clipboard, permission-accessibility
Depends: S-010
Acceptance:
- [manual] With Accessibility allowed, the panel closes, the previous app is focused, and the item is pasted.
- [manual] Without Accessibility, the item is copied and a sheet explains why pasting needs the permission, with a button that opens System Settings.
- [unit] Option-Return pastes as plain text (no formatting).
Status: todo

## M3 Clips

### S-013 Pin a clip
As the user, I press Command-P on a row (or use its pin button) so it stays at
the top and is never removed.
Screens: popover-clipboard, panel-clipboard
Depends: S-003
Acceptance:
- [snap] Pinned items show in a "Pinned" section above "Recent".
- [unit] Pruning never removes pinned items.
Status: todo

### S-014 Delete a clip
As the user, I press Delete on a row to remove it from history.
Depends: S-003
Acceptance:
- [unit] The item is removed from the store.
- [self] Command-Z right after brings it back.
Status: todo

### S-015 Clear history
As the user, I choose Clear History and every unpinned item is removed after I
confirm.
Depends: S-013
Acceptance:
- [snap] A confirmation names the count ("Clear 214 Clips?" with "Pinned clips stay.") and buttons "Clear History" and "Cancel".
- [unit] Only unpinned items are removed.
Status: todo

### S-016 Record copied images
As the user, I copy an image or take a screenshot to the clipboard and it is
saved in history with a thumbnail.
Screens: popover-clipboard, panel-clipboard
Depends: S-002
Acceptance:
- [unit] PNG and TIFF pasteboard data create a kind image item; images over 10 MB are skipped.
- [snap] Rows show a thumbnail; the panel preview shows the full image and its pixel size.
- [manual] Choosing it puts the image back on the clipboard and pastes it into Preview.
Status: todo

### S-017 Skip passwords and secret copies
As the user, things copied from password managers are never saved.
Depends: S-002
Acceptance:
- [unit] Items marked org.nspasteboard.ConcealedType or TransientType are ignored.
- [unit] Items from apps in the excluded list are ignored.
Status: todo

### S-018 Keep history to a size limit
As the user, history keeps the last 500 unpinned items by default.
Depends: S-013
Acceptance:
- [unit] Adding item 501 removes the oldest unpinned item.
Status: todo

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
Status: todo

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
Status: todo

### S-026 App icon
As the user, I see a Toolbelt icon in Settings, About, and Login Items.
Acceptance:
- [snap] The icon renders in light, dark, and tinted looks.
Status: todo

## Later

- Snippets: saved text with a keyword.
- Window snapping: halves, thirds, full screen.
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
