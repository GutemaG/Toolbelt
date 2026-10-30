import ServiceManagement
import SwiftUI
import ToolbeltKit

/// The Settings window. One tab per topic, at most about six. Each tab is a
/// grouped Form that sizes to its content, so the window grows to fit and
/// shows no scroll bar it does not need.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        }
    }
}

struct GeneralSettings: View {
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var canPaste = PanelController.canPaste(prompt: false)
    @State private var loginError: String?

    var body: some View {
        Section {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        Section("Shortcuts") {
            LabeledContent("Open Launcher", value: "⌥Space")
            LabeledContent("Open Clipboard", value: "⇧⌘V")
            ForEach(Hotkeys.shared.failed, id: \.self) { name in
                Text("Unable to use the shortcut for “\(name)”. Another app uses it.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        Section {
            LabeledContent("Paste into apps") {
                if canPaste {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Allow in Privacy Settings…") {
                        _ = PanelController.canPaste(prompt: true)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        } header: {
            Text("Clipboard")
        } footer: {
            Text("Keeps the last \(ClipRules.historyLimit) clips. Pinned clips are always kept. Pasting into the app you were using needs Accessibility; without it, Return only copies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            // Nothing calls the app back when Accessibility is granted. Check while Settings is open.
            while !Task.isCancelled {
                canPaste = PanelController.canPaste(prompt: false)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
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
