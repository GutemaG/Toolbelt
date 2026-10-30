import AVFoundation
import ApplicationServices
import ServiceManagement
import SwiftUI
import ToolbeltKit

/// The Settings window: a sidebar of pages, because a suite of tools has
/// more than six topics. Each page is a header plus one grouped Form.
/// Settings apply at once; there is no Save button.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.settingsPage) {
                ForEach(SettingsGroup.allCases) { group in
                    let pages = SettingsPage.allCases.filter { $0.group == group }
                    if group == .top {
                        rows(pages)
                    } else {
                        Section(group.title) { rows(pages) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 212, max: 260)
        } detail: {
            page(model.settingsPage)
                .navigationSplitViewColumnWidth(min: 480, ideal: 560)
        }
        .noInitialFocus()
    }

    private func rows(_ pages: [SettingsPage]) -> some View {
        ForEach(pages) { page in
            Label {
                Text(page.title)
            } icon: {
                IconTile(symbol: page.symbol, tint: page.tint)
            }
            .tag(page)
        }
    }

    @ViewBuilder
    private func page(_ page: SettingsPage) -> some View {
        Form {
            Section {
            } header: {
                PageHeader(page: page)
            }
            switch page {
            case .settings: GeneralSettings()
            case .launcher: ToolSettings(tool: .launcher)
            case .clipboard: ToolSettings(tool: .clipboard)
            case .snippets: ToolSettings(tool: .snippets)
            case .screenshots: ToolSettings(tool: .screenshots)
            case .recording: ToolSettings(tool: .recording)
            case .colors: ToolSettings(tool: .colors)
            case .camera: ToolSettings(tool: .camera)
            case .windows: ToolSettings(tool: .windows)
            case .timer: ToolSettings(tool: .timer)
            case .sound: ToolSettings(tool: .sound)
            case .toggles: ToolSettings(tool: .toggles)
            case .system: ToolSettings(tool: .system)
            case .info: ToolSettings(tool: .info)
            case .keepAwake: ToolSettings(tool: .keepAwake)
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .id(page)
    }
}

/// Sidebar groups, in order. The first has no heading.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case top, input, capture, windows, tools, app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: ""
        case .input: "Input"
        case .capture: "Capture"
        case .windows: "Windows"
        case .tools: "Tools"
        case .app: "App"
        }
    }
}

/// The Settings pages. Snapshot mode walks through every case.
enum SettingsPage: String, CaseIterable, Identifiable {
    case settings, launcher, clipboard, snippets, screenshots, recording, colors, camera, windows, timer, sound, toggles, system, info, keepAwake, appearance

    var id: String { rawValue }

    var tool: Tool? { Tool(rawValue: rawValue) }

    var group: SettingsGroup {
        switch self {
        case .settings: .top
        case .launcher, .clipboard, .snippets: .input
        case .screenshots, .recording, .colors, .camera: .capture
        case .windows: .windows
        case .timer, .sound, .toggles, .system, .info, .keepAwake: .tools
        case .appearance: .app
        }
    }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .appearance: "Appearance"
        default: tool?.title ?? ""
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        default: tool?.symbol ?? "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .settings: .indigo
        case .appearance: .pink
        default: tool?.tint ?? .gray
        }
    }

    var summary: String {
        switch self {
        case .settings: "Permissions, menu bar, Dock and startup."
        case .appearance: "The accent color for every tool."
        default: tool?.summary ?? ""
        }
    }
}

/// The big icon, title and one line at the top of a page.
private struct PageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: Space.md) {
            IconTile(symbol: page.symbol, tint: page.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(page.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, Space.sm)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Settings > Settings: permissions, menu bar and Dock, the menu bar panel.
struct GeneralSettings: View {
    @Bindable private var prefs = ToolPrefs.shared
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

    var body: some View {
        Section {
            PermissionRow(symbol: "hand.raised.fill", title: "Accessibility",
                          detail: "Pastes clips into the app you were using, and moves windows.",
                          isOn: accessibility) {
                _ = PanelController.canPaste(prompt: true)
                open("Privacy_Accessibility")
            }
            PermissionRow(symbol: "record.circle", title: "Screen Recording",
                          detail: "Screenshots and screen recordings.",
                          isOn: screenRecording) {
                CGRequestScreenCaptureAccess()
                open("Privacy_ScreenCapture")
            }
            PermissionRow(symbol: "web.camera", title: "Camera",
                          detail: "The live preview in Camera.",
                          isOn: camera) {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    Task { camera = await AVCaptureDevice.requestAccess(for: .video) }
                } else {
                    open("Privacy_Camera")
                }
            }
        } header: {
            // Follows the page header, which would otherwise make it render light; match the other headings.
            Text("Permissions").font(.headline).foregroundStyle(.primary)
        } footer: {
            Text("Toolbelt asks for a permission only when a tool needs it. After you allow Screen Recording, macOS may ask you to quit and reopen Toolbelt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            // Nothing calls the app back when a permission changes. Check while the page is open.
            while !Task.isCancelled {
                accessibility = AXIsProcessTrusted()
                screenRecording = CGPreflightScreenCaptureAccess()
                camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                try? await Task.sleep(for: .seconds(1.5))
            }
        }

        Section("Menu bar and Dock") {
            Toggle(isOn: $prefs.showMainIcon) {
                Text("Show Toolbelt in the menu bar")
                Text(prefs.ownIcon.intersection(prefs.enabled).isEmpty
                     ? "One icon with every tool. To hide it, first give a tool its own icon."
                     : "One icon with every tool. Tools with their own icon stay either way.")
            }
            .disabled(prefs.showMainIcon && prefs.ownIcon.intersection(prefs.enabled).isEmpty)
            Toggle(isOn: $prefs.openOnHover) {
                Text("Open when the pointer rests on the icon")
                Text("Peeks without taking focus; click inside to type. Moving away closes it.")
            }
            Toggle(isOn: $prefs.showInDock) {
                Text("Show Toolbelt in the Dock")
                Text("Also shows Toolbelt in ⌘Tab.")
            }
            Toggle(isOn: $openAtLogin) {
                Text("Open at login")
                Text("Start Toolbelt when you log in to this Mac.")
            }
            .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
            if let loginError {
                Label(loginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)

        Section {
            ForEach(prefs.panelOrder) { tool in
                PanelToolRow(tool: tool, prefs: prefs)
            }
        } header: {
            Text("Menu bar panel")
        } footer: {
            Text(prefs.showMainIcon || !prefs.ownIcon.isEmpty
                 ? "The tools the Toolbelt icon and panel show, in this order. A tool that is off in its own page never shows."
                 : "The Toolbelt icon is hidden. Open the panel with a tool's shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Unable to change Open at login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// One permission: what it is for, and "On" or a button that opens System Settings.
private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isOn: Bool
    let allow: () -> Void

    var body: some View {
        LabeledContent {
            if isOn {
                Label("On", systemImage: "circle.fill")
                    .labelStyle(StatusBadgeStyle())
                    .accessibilityLabel("\(title) is allowed")
            } else {
                Button("Allow…", action: allow)
                    .controlSize(.small)
                    .help("Open Privacy & Security in System Settings")
            }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A green capsule with a dot and a word, so the state never rests on color alone.
private struct StatusBadgeStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs) {
            configuration.icon.font(.system(size: 6))
            configuration.title.font(.caption.weight(.semibold))
        }
        .foregroundStyle(.green)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 2)
        .background(.green.opacity(0.15), in: .capsule)
    }
}

/// A tool in the Menu bar panel list: icon, name, summary, move buttons, switch.
private struct PanelToolRow: View {
    let tool: Tool
    @Bindable var prefs: ToolPrefs

    var body: some View {
        let index = prefs.panelOrder.firstIndex(of: tool) ?? 0
        LabeledContent {
            HStack(spacing: Space.xs) {
                Button("Move Up", systemImage: "chevron.up") { prefs.move(tool, by: -1) }
                    .disabled(index == 0)
                    .help("Move \(tool.title) up")
                Button("Move Down", systemImage: "chevron.down") { prefs.move(tool, by: 1) }
                    .disabled(index == prefs.panelOrder.count - 1)
                    .help("Move \(tool.title) down")
                Toggle("Show \(tool.title) in the panel", isOn: prefs.binding(\.inPanel, tool))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!prefs.enabled.contains(tool))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        } label: {
            HStack(spacing: Space.sm) {
                IconTile(symbol: tool.symbol, tint: tool.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                    Text(prefs.enabled.contains(tool) ? tool.summary : "Off. Turn it on in its own page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A tool's own page: on or off, its own menu bar icon, its shortcut, and its options.
struct ToolSettings: View {
    let tool: Tool
    @Environment(AppModel.self) private var model
    @Bindable private var prefs = ToolPrefs.shared
    @State private var confirmClear = false

    var body: some View {
        Section {
            Toggle(isOn: prefs.binding(\.enabled, tool)) {
                Text("Turn on \(tool.title)")
                Text("When off, its shortcut and menu bar icon go away and it uses no power.")
            }
            Toggle(isOn: prefs.binding(\.ownIcon, tool)) {
                Text("Show \(tool.title) in the menu bar")
                Text("Gives \(tool.title) its own icon that opens just this tool.")
            }
            .disabled(!prefs.enabled.contains(tool))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)

        let shortcuts = ShortcutID.all.filter { $0.tool == tool }
        if !shortcuts.isEmpty {
            Section {
                ForEach(shortcuts) { ShortcutRecorder(id: $0) }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Click a shortcut and press new keys. Esc cancels, Delete removes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!prefs.enabled.contains(tool))
        }

        switch tool {
        case .launcher:
            Section {
                LabeledContent("Pinned apps") {
                    Text("Pin with ⌘P, the pin button on a row, or Add… in the Launcher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .snippets:
            SnippetSettings()
        case .screenshots:
            ScreenshotOptions()
        case .colors:
            ColorOptions()
        case .camera:
            CameraOptions()
        case .windows:
            WindowOptions()
        case .keepAwake:
            KeepAwakeOptions()
        case .system:
            SystemOptions()
        case .info:
            Section {
            } footer: {
                Text("Info opens on Battery; switch tabs with ← and →. Serial numbers, hardware addresses and the public IP stay hidden until you click the eye. The public IP is looked up at api.ipify.org when Network opens, and the Wi-Fi name needs Location Services, asked only when you click it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .toggles:
            Section {
            } footer: {
                Text("Dark Mode asks once to control System Events, and Empty Trash to control Finder. Desktop Icons and Hidden Files restart Finder. Lock Screen needs Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .sound:
            Section {
            } footer: {
                Text("Switching here changes the output for the whole Mac, like Sound in Control Center. Give Sound its own menu bar icon for one-click switching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .timer:
            Section {
            } footer: {
                Text("Type any length in the Timer's search field, like 12, 90s or 1h30m. When time is up you hear a chime and see a notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .recording:
            RecordingOptions()
        case .clipboard:
            Section {
                LabeledContent("History", value: "Last \(ClipRules.historyLimit) clips")
                CleanLinksToggle()
                LabeledContent("Paste") {
                    Text("Return pastes, ⌥Return pastes as plain text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Clear History") {
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .controlSize(.small)
                }
            } footer: {
                Text("Pinned clips are always kept. Copies from password managers are never saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog("Clear \(model.unpinnedClipCount()) Clips?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive) { model.clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pinned clips stay.")
            }
        }
    }
}

/// Settings > Screenshots: where files go and what they look like.
private struct ScreenshotOptions: View {
    @AppStorage(CapturePrefs.folderKey) private var folder = ""
    @AppStorage(CapturePrefs.formatKey) private var format = ImageFormat.png.rawValue
    @AppStorage(CapturePrefs.copyKey) private var copy = true
    @AppStorage(CapturePrefs.previewKey) private var preview = true
    @AppStorage(CapturePrefs.cursorKey) private var cursor = false
    @AppStorage(CapturePrefs.shadowKey) private var shadow = false

    var body: some View {
        Section {
            SaveFolderRow(folder: $folder)
            Picker("File format", selection: $format) {
                ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle(isOn: $copy) {
                Text("Copy to the clipboard")
                Text("Paste the screenshot right away with ⌘V.")
            }
            Toggle(isOn: $preview) {
                Text("Show a preview after capture")
                Text("A small card in the corner to copy, drag, open or delete it.")
            }
            Toggle(isOn: $cursor) {
                Text("Include the pointer")
            }
            Toggle(isOn: $shadow) {
                Text("Include the window shadow")
                Text("For window screenshots.")
            }
        } header: {
            Text("Options")
        } footer: {
            Text("While selecting: drag for an area, Space to pick a window, Return for the whole screen, Esc to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

/// Settings > Recording: sound and what the pointer shows.
private struct RecordingOptions: View {
    @AppStorage(CapturePrefs.folderKey) private var folder = ""
    @AppStorage(CapturePrefs.systemAudioKey) private var systemAudio = false
    @AppStorage(CapturePrefs.microphoneKey) private var microphone = false
    @AppStorage(CapturePrefs.clicksKey) private var clicks = true
    @AppStorage(CapturePrefs.recordCursorKey) private var cursor = true
    @AppStorage(CapturePrefs.previewKey) private var preview = true

    var body: some View {
        Section {
            SaveFolderRow(folder: $folder)
            LabeledContent("File format", value: "MP4 (H.264)")
            Toggle(isOn: $systemAudio) {
                Text("Record system audio")
                Text("Sound from your apps, not from Toolbelt.")
            }
            Toggle(isOn: $microphone) {
                Text("Record the microphone")
                Text("macOS asks for microphone access the first time.")
            }
            Toggle(isOn: $cursor) {
                Text("Show the pointer")
            }
            Toggle(isOn: $clicks) {
                Text("Show clicks")
                Text("A ring around the pointer each time you click.")
            }
            .disabled(!cursor)
            Toggle(isOn: $preview) {
                Text("Show a preview after recording")
            }
        } header: {
            Text("Options")
        } footer: {
            Text("Stop with the red timer in the menu bar or \(ShortcutID.record.label). The red frame around the area is not in the movie.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

/// The save folder, shared by screenshots and recordings.
private struct SaveFolderRow: View {
    @Binding var folder: String

    var body: some View {
        LabeledContent("Save to") {
            HStack(spacing: Space.sm) {
                Text(CapturePrefs.folder.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .help(CapturePrefs.folder.path)
                Button("Choose…") {
                    let open = NSOpenPanel()
                    open.canChooseDirectories = true
                    open.canChooseFiles = false
                    open.canCreateDirectories = true
                    open.prompt = "Choose"
                    open.directoryURL = CapturePrefs.folder
                    if open.runModal() == .OK, let url = open.url { folder = url.path }
                }
                .controlSize(.small)
            }
        }
    }
}

private struct CleanLinksToggle: View {
    @AppStorage(ClipboardMonitor.cleanLinksKey) private var clean = true

    var body: some View {
        Toggle(isOn: $clean) {
            Text("Remove tracking from copied links")
            Text("Strips utm_, fbclid and similar from links you copy.")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

/// Settings > Colors: what a pick copies.
private struct ColorOptions: View {
    @AppStorage(ColorPicker.formatKey) private var format = ColorTextFormat.hex.rawValue

    var body: some View {
        Section {
            Picker("Copy as", selection: $format) {
                Text("Hex  #FF8000").tag(ColorTextFormat.hex.rawValue)
                Text("RGB  rgb(255, 128, 0)").tag(ColorTextFormat.rgb.rawValue)
                Text("HSL  hsl(30, 100%, 50%)").tag(ColorTextFormat.hsl.rawValue)
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Options")
        } footer: {
            Text("Picking a color needs no Screen Recording permission. Right-click a recent color to copy it in another format.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings > Windows: what snapping needs. The shortcuts are above.
private struct WindowOptions: View {
    var body: some View {
        Section {
        } footer: {
            Text("Moves the front window on the screen it is on. Needs Accessibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings > Camera.
private struct CameraOptions: View {
    @AppStorage(Camera.mirrorKey) private var mirror = true

    var body: some View {
        Section {
            Toggle(isOn: $mirror) {
                Text("Mirror the preview")
                Text("Shows you the way a mirror does. Photos are saved the way the preview shows them.")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        } header: {
            Text("Options")
        } footer: {
            Text("The camera turns on only while Camera is open and turns off when the window closes. Photos go to your screenshot folder. Asks for Camera access the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings > Keep Awake.
private struct KeepAwakeOptions: View {
    @AppStorage(KeepAwake.displayKey) private var display = true

    var body: some View {
        Section {
            Toggle(isOn: $display) {
                Text("Keep the display on too")
                Text("When off, the screen can still dim and sleep; only the Mac stays awake.")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        } header: {
            Text("Options")
        } footer: {
            Text("Give Keep Awake its own menu bar icon to see at a glance when it is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings > System.
private struct SystemOptions: View {
    @AppStorage(SystemMonitor.menuBarKey) private var menuBarCPU = true

    var body: some View {
        Section {
            Toggle(isOn: $menuBarCPU) {
                Text("Show CPU use next to the menu bar icon")
                Text("Shows the load beside System’s own icon, read every two seconds.")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!ToolPrefs.shared.ownIcon.contains(.system))
            .onChange(of: menuBarCPU) { ToolPrefs.shared.onChange?() }
        } header: {
            Text("Options")
        } footer: {
            Text("Energy is what each app and its helpers used over the last few seconds, like the Energy tab in Activity Monitor. Apps from other users and the system are left out. Nothing here needs a permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
