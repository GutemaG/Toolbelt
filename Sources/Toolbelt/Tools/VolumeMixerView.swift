import AppKit
import SwiftUI
import ToolbeltKit

/// The Volume Mixer page: the output on top, then one slider per app. The
/// search field filters the apps.
struct VolumeMixerView: View {
    let surface: Surface
    let window: NSWindow?
    let query: String
    @Environment(AppModel.self) private var model
    private var mixer: VolumeMixer { .shared }

    var body: some View {
        let shown = Self.shown(query)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(spacing: 0) {
                    MixerRow(icon: Image(systemName: "speaker.wave.2.fill"), name: mixer.outputName,
                             detail: mixer.outputVolume == nil ? "Set the volume on the device itself" : nil,
                             level: mixer.outputMuted ? 0 : mixer.outputVolume ?? 1, muted: mixer.outputMuted,
                             enabled: mixer.outputVolume != nil, selected: mixer.selection == 0,
                             setLevel: mixer.setOutputVolume, toggleMute: mixer.toggleOutputMute)
                }
                .background(.fill.quinary, in: .rect(cornerRadius: 8))

                if mixer.permission == .denied, !shown.isEmpty {
                    permissionNote
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Apps")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.sm)
                        .accessibilityAddTraits(.isHeader)
                    if shown.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "No Apps Playing Sound" : "No Results",
                                               systemImage: query.isEmpty ? "speaker.wave.2" : "magnifyingglass",
                                               description: Text(query.isEmpty ? "Play something and it shows up here with its own volume."
                                                                 : "No app playing sound matches “\(query)”."))
                            .padding(.vertical, Space.lg)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, app in
                                if index > 0 { Divider().padding(.leading, Space.md) }
                                appRow(app, selected: mixer.selection == index + 1)
                            }
                        }
                        .background(.fill.quinary, in: .rect(cornerRadius: 8))
                    }
                }
            }
            .padding(Space.md)
        }
        .defaultScrollAnchor(.top)
        .onAppear {
            mixer.selection = 0
            if Snapshot.requested { mixer.useSampleLevels() }
        }
        .onChange(of: model.openCount) { mixer.selection = 0 }
        .onChange(of: query) { mixer.selection = min(mixer.selection, shown.count) }
        .task(id: window) {
            // Follows the volume keys and apps starting to play while the window shows.
            while !Task.isCancelled {
                if window?.isVisible == true { mixer.refresh() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static func shown(_ query: String) -> [VolumeMixer.App] {
        VolumeMixer.shared.apps.filter { query.isEmpty || ClipRules.matches(query, text: $0.name) }
    }

    private func appRow(_ app: VolumeMixer.App, selected: Bool) -> some View {
        let muted = mixer.isMuted(app)
        return MixerRow(icon: app.path.map { Image(nsImage: NSWorkspace.shared.icon(forFile: $0)) } ?? Image(systemName: "app"),
                        name: app.name, detail: app.isPlaying ? nil : "Not playing",
                        level: muted ? 0 : mixer.level(app), muted: muted,
                        enabled: true, selected: selected,
                        setLevel: { mixer.setLevel($0, for: app) }, toggleMute: { mixer.toggleMute(app) })
            .contextMenu {
                Button(muted ? "Unmute \(app.name)" : "Mute \(app.name)") { mixer.toggleMute(app) }
                Button("Reset to Full Volume") { mixer.reset(app) }
                    .disabled(!MixerRules.needsTap(level: mixer.level(app), muted: muted))
                if let path = app.path {
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
    }

    private var permissionNote: some View {
        HStack(spacing: Space.md) {
            Label("App volumes need System Audio Recording.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.sm)
            Button("Open Privacy Settings", action: AudioCapture.openSettings)
        }
        .font(.callout)
        .padding(.horizontal, Space.sm)
    }
}

/// One line: icon, name, slider, percent and a mute button.
private struct MixerRow: View {
    let icon: Image
    let name: String
    let detail: String?
    let level: Double
    let muted: Bool
    let enabled: Bool
    let selected: Bool
    let setLevel: @MainActor @Sendable (Double) -> Void
    let toggleMute: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            icon
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: Space.xl, height: Space.xl)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(name)
            Slider(value: Binding(get: { level }, set: setLevel), in: 0...1)
                .controlSize(.small)
                .frame(width: 140)
                .disabled(!enabled)
                .accessibilityLabel("\(name) volume")
            Text(muted ? "Muted" : MixerRules.percent(level))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            Button(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2", action: toggleMute)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(muted ? AnyShapeStyle(Palette.accentText) : AnyShapeStyle(.secondary))
                .frame(width: Space.xl)
                .help(muted ? "Turn \(name) back on" : "Mute \(name)")
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background {
            if selected { RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary) }
        }
        .accessibilityElement(children: .contain)
    }
}
