# Toolbelt design plan

1. **Archetype**: menu bar extra + panels + Settings window. The toolbar
   and sidebar rules apply to the Settings window only.
2. **Information architecture** (Settings sidebar, two levels at most):
   - Settings: Permissions, Menu bar and Dock, Menu bar panel
   - Input: Launcher, Clipboard
   - Capture: Screenshots, Recording, Colors (as they are built)
   - Windows: Window Snapping (when built)
   - Tools: Keep Awake (when built)
   - App: Appearance
   Pages appear only for tools that exist.
3. **Command map**:
   | Action | Where | Shortcut |
   | --- | --- | --- |
   | Open Launcher | Toolbelt icon, Launcher icon, right-click menu | ⌥Space |
   | Open Clipboard | Toolbelt icon, Clipboard icon, right-click menu | ⇧⌘V |
   | Switch tool | panel picker | Tab, ⌘1, ⌘2 |
   | Open, Paste, Copy | row click | Return, ⌥Return |
   | Pin / Unpin | row button, context menu | ⌘P |
   | Delete clip | context menu | ⌘⌫ |
   | Settings | gear, right-click menu | ⌘, |
   | Quit | power button, right-click menu | ⌘Q |
4. **Empty states**: Launcher pinned grid shows only Add…; Clipboard shows
   "No Clips Yet"; Menu bar panel with every tool off says "Turn on a tool
   to show it here".
5. **Feeling**: quick and calm. Panels open in one frame, no bounce, no
   spinners; Settings reads like System Settings.

Settings window: a sidebar window (more than six topics, so not tabs). Each
page: a header with a colored icon tile, title and one-line description,
then one grouped Form. Rows are statements with a caption line; switches are
mini; trailing controls line up. Permission rows show "On" or an "Allow…"
button that opens the right System Settings pane.
