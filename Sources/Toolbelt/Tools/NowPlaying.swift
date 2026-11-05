import AppKit
import SwiftUI
import ToolbeltKit

/// Now Playing: the song in Music or Spotify, through their own scripting.
/// macOS doesn't let apps read what's playing in general, so other players
/// get only the media keys. It reads only while the tool is open, and never
/// starts a player. Test and snapshot runs use a sample song and touch no player.
@Observable
final class NowPlaying {
    static let shared = NowPlaying()

    private(set) var track: NowPlayingTrack?
    /// When `track.position` was read, to move the time on between reads.
    private(set) var readAt = Date.now
    private(set) var artwork: NSImage?
    /// macOS refused the script: Automation is off for this player.
    private(set) var needsPermission = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var readAgain = false

    /// A safety net between the players' own change notices.
    private static let pollGap: Duration = .seconds(5)
    /// Long enough to answer the Automation question, which the script waits on.
    private static let scriptTimeout: TimeInterval = 60

    /// The tool opened.
    func start() {
        if Store.isOverridden {
            if track == nil, usesSample { track = Self.sample }
            readAt = .now
            return
        }
        if observers.isEmpty {
            observers = MusicPlayer.allCases.map { player in
                DistributedNotificationCenter.default().addObserver(forName: .init(player.changeNotification), object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { NowPlaying.shared.read() }
                }
            }
        }
        read()
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollGap)
                guard !Task.isCancelled else { return }
                self?.read()
            }
        }
    }

    /// The tool closed. Nothing runs until it opens again.
    func stop() {
        polling?.cancel()
        polling = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }

    private var runningPlayers: [MusicPlayer] {
        MusicPlayer.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
    }

    /// Reads the running players; the one playing wins, then Music.
    func read() {
        guard !Store.isOverridden else { return }
        guard !isReading else {
            readAgain = true
            return
        }
        let players = runningPlayers
        guard !players.isEmpty else {
            show(nil)
            needsPermission = false
            return
        }
        isReading = true
        Task {
            var found: [NowPlayingTrack] = []
            var denied = false
            for player in players {
                guard let result = await Shell.run("/usr/bin/osascript", ["-e", NowPlayingRules.readScript(player)], timeout: Self.scriptTimeout) else { continue }
                if result.status != 0, NowPlayingRules.isPermissionDenied(result.output) { denied = true }
                if result.status == 0, let track = NowPlayingRules.parse(result.output, player: player) { found.append(track) }
            }
            needsPermission = denied && found.isEmpty
            show(found.first(where: \.isPlaying) ?? found.first)
            isReading = false
            if readAgain {
                readAgain = false
                read()
            }
        }
    }

    private func show(_ new: NowPlayingTrack?) {
        track = new
        readAt = .now
        guard new?.key != artworkKey else { return }
        artworkKey = new?.key
        artwork = nil
        guard let new else { return }
        Task { await loadArtwork(for: new) }
    }

    private func loadArtwork(for track: NowPlayingTrack) async {
        var image: NSImage?
        switch track.player {
        case .spotify:
            if let url = track.artworkURL, let (data, _) = try? await URLSession.shared.data(from: url) { image = NSImage(data: data) }
        case .music:
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("toolbelt-artwork-\(UUID().uuidString)")
            _ = await Shell.run("/usr/bin/osascript", ["-e", NowPlayingRules.artworkScript(path: file.path)], timeout: Self.scriptTimeout)
            image = NSImage(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
        }
        // The song may have moved on while this loaded.
        if artworkKey == track.key { artwork = image }
    }

    /// Seconds into the song at a moment, moving on while it plays.
    func elapsed(at date: Date) -> TimeInterval {
        guard let track else { return 0 }
        let moved = track.isPlaying ? date.timeIntervalSince(readAt) : 0
        return track.duration > 0 ? min(track.position + moved, track.duration) : track.position + moved
    }

    func send(_ command: PlayerCommand) {
        guard let current = track else { return sendMediaKey(command) }
        if case .seek(let seconds) = command { track?.position = seconds; readAt = .now }
        if command == .playPause {
            let reached = elapsed(at: .now)
            track?.position = reached
            readAt = .now
            track?.isPlaying.toggle()
        }
        guard !Store.isOverridden else { return }
        Task {
            _ = await Shell.run("/usr/bin/osascript", ["-e", NowPlayingRules.commandScript(current.player, command)], timeout: Self.scriptTimeout)
            read()
        }
    }

    /// For any other player: the Mac's play, next and back keys. They need Accessibility.
    private func sendMediaKey(_ command: PlayerCommand) {
        guard !Store.isOverridden else { return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return }
        switch command {
        case .playPause: KnockAction.playPause.run()
        case .next: KnockAction.nextTrack.run()
        case .previous: KnockAction.previousTrack.run()
        case .seek: break
        }
    }

    func openPlayer(_ player: MusicPlayer) {
        guard !Store.isOverridden, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    var installedPlayers: [MusicPlayer] {
        MusicPlayer.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// Snapshots turn this off to show the empty screen.
    @ObservationIgnored var usesSample = true {
        didSet { if !usesSample { track = nil } }
    }

    private static let sample = NowPlayingTrack(player: .music, isPlaying: true, title: "Sample Song", artist: "Sample Artist", album: "Sample Album",
                                                duration: 212, position: 74)
}

// MARK: The tool

struct NowPlayingView: View {
    let surface: Surface
    @Environment(AppModel.self) private var model
    private var player: NowPlaying { .shared }

    var body: some View {
        Group {
            if let track = player.track {
                playing(track)
            } else {
                nothing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { player.start() }
        .onDisappear { player.stop() }
        .onChange(of: model.openCount) { player.start() }
    }

    private func playing(_ track: NowPlayingTrack) -> some View {
        VStack(spacing: Space.md) {
            HStack(spacing: Space.lg) {
                cover
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(track.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.callout)
                        .lineLimit(1)
                    Text(track.album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        player.openPlayer(track.player)
                    } label: {
                        Label("In \(track.player.title)", systemImage: track.isPlaying ? "waveform" : "pause")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(track.player.title)")
                }
                Spacer(minLength: 0)
            }
            PlayerScrubber(track: track)
            PlayerButtons(isPlaying: track.isPlaying)
        }
        .padding(Space.lg)
        .background {
            ZStack {
                Tool.nowPlaying.tint.opacity(0.1)
                if let artwork = player.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: Space.section)
                        .opacity(0.3)
                }
            }
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding(Space.md)
    }

    private var cover: some View {
        let size = Space.section * 3 + Space.xxl
        return Group {
            if let artwork = player.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 12))
            } else {
                IconTile(symbol: Tool.nowPlaying.symbol, tint: Tool.nowPlaying.tint, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    private var nothing: some View {
        VStack(spacing: Space.md) {
            if player.needsPermission {
                message("Toolbelt Can’t See Your Player", symbol: "lock",
                        detail: "Turn on your player under Toolbelt in System Settings > Privacy & Security > Automation.")
                Button("Open System Settings") { player.openAutomationSettings() }
                    .buttonStyle(TintedActionStyle(tint: Tool.nowPlaying.tint))
            } else {
                message("Nothing Playing", symbol: Tool.nowPlaying.symbol,
                        detail: "Songs in Music and Spotify show here. For other players, like a browser, these buttons press your Mac’s media keys.")
                PlayerButtons(isPlaying: false)
                HStack(spacing: Space.sm) {
                    ForEach(player.installedPlayers, id: \.self) { installed in
                        Button("Open \(installed.title)") { player.openPlayer(installed) }
                            .buttonStyle(QuickActionStyle())
                    }
                }
            }
        }
        .padding(Space.md)
    }

    private func message(_ title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(Tool.nowPlaying.tint)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: Space.section * 10)
    }
}

private struct PlayerButtons: View {
    let isPlaying: Bool
    private var player: NowPlaying { .shared }

    var body: some View {
        HStack(spacing: Space.lg) {
            button("Previous", symbol: "backward.fill", shortcut: "←", size: Space.section) { player.send(.previous) }
            Button {
                player.send(.playPause)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: Space.section + Space.md, height: Space.section + Space.md)
                    .background(Tool.nowPlaying.tint.opacity(0.28), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause (↩)" : "Play (↩)")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            button("Next", symbol: "forward.fill", shortcut: "→", size: Space.section) { player.send(.next) }
        }
    }

    private func button(_ title: String, symbol: String, shortcut: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout)
                .frame(width: size, height: size)
                .background(.fill.tertiary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
    }
}

/// The time bar. Dragging moves through the song when you let go.
private struct PlayerScrubber: View {
    let track: NowPlayingTrack
    @State private var dragged: Double?
    private var player: NowPlaying { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = dragged.map { $0 * track.duration } ?? player.elapsed(at: context.date)
            VStack(spacing: Space.xs) {
                GeometryReader { geometry in
                    Bar(fraction: track.duration > 0 ? position / track.duration : 0, color: Tool.nowPlaying.tint)
                        .frame(height: 6) // grid: ok a bar's thickness, not spacing
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { dragged = min(max($0.location.x / max(geometry.size.width, 1), 0), 1) }
                            .onEnded { _ in
                                if let dragged { player.send(.seek(dragged * track.duration)) }
                                dragged = nil
                            })
                }
                .frame(height: Space.md)
                HStack {
                    Text(NowPlayingRules.clock(position))
                    Spacer(minLength: 0)
                    Text(NowPlayingRules.clock(track.duration))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time")
            .accessibilityValue("\(NowPlayingRules.clock(position)) of \(NowPlayingRules.clock(track.duration))")
        }
    }
}

/// Settings > Now Playing.
struct NowPlayingOptions: View {
    var body: some View {
        Section {
        } footer: {
            Text("macOS lets apps read only the players that offer it, so songs show from Music and Spotify, each asking once for Automation. Other players, like a browser, get play, next and back through your Mac’s media keys, which need Accessibility. Nothing is read while this tool is closed. Spotify’s album covers download from Spotify; Music’s come from Music itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
