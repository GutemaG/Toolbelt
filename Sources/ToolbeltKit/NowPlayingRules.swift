import Foundation

/// A player Toolbelt can read and control through its own scripting.
public enum MusicPlayer: String, Sendable, CaseIterable {
    case music, spotify

    public var title: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    public var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    /// Posted to every app when the track or state changes.
    public var changeNotification: String {
        switch self {
        case .music: "com.apple.Music.playerInfo"
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        }
    }
}

public enum PlayerCommand: Sendable, Equatable {
    case playPause, next, previous
    case seek(TimeInterval)
}

public struct NowPlayingTrack: Sendable, Equatable {
    public var player: MusicPlayer
    public var isPlaying: Bool
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var position: TimeInterval
    /// Spotify's cover. Music's comes from a separate script.
    public var artworkURL: URL?

    public init(player: MusicPlayer, isPlaying: Bool, title: String, artist: String, album: String,
                duration: TimeInterval, position: TimeInterval, artworkURL: URL? = nil) {
        self.player = player
        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.artworkURL = artworkURL
    }

    /// The same song, whatever its position or state.
    public var key: String { [player.rawValue, title, artist, album].joined(separator: "|") }
}

/// The AppleScript for each player, and reading what it prints.
public enum NowPlayingRules {
    /// Between fields. Song titles can hold any printable character.
    private static let separator = "\u{1F}"

    private static func tell(_ player: MusicPlayer, _ body: String) -> String {
        "tell application id \"\(player.bundleID)\"\n\(body)\nend tell"
    }

    /// Prints the state and, unless stopped, the track. Never starts the
    /// player by itself, so run it only when the player is running.
    public static func readScript(_ player: MusicPlayer) -> String {
        let artwork = player == .spotify ? "artwork url of t" : "\"\""
        return tell(player, """
        set s to player state as string
        if s is "stopped" then return s
        set t to current track
        set d to ASCII character 31
        return s & d & (name of t) & d & (artist of t) & d & (album of t) & d & (duration of t) & d & player position & d & \(artwork)
        """)
    }

    public static func commandScript(_ player: MusicPlayer, _ command: PlayerCommand) -> String {
        switch command {
        case .playPause: tell(player, "playpause")
        case .next: tell(player, "next track")
        case .previous: tell(player, "previous track")
        case .seek(let seconds): tell(player, "set player position to \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(seconds, 0)))")
        }
    }

    /// Writes the current track's cover in Music to a file. Fails, harmlessly, when it has none.
    public static func artworkScript(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        \(tell(.music, "set a to raw data of artwork 1 of current track"))
        set f to open for access (POSIX file "\(escaped)") with write permission
        try
        set eof f to 0
        write a to f
        end try
        close access f
        """
    }

    /// nil for a stopped player or output that isn't a track.
    public static func parse(_ output: String, player: MusicPlayer) -> NowPlayingTrack? {
        let fields = output.trimmingCharacters(in: .newlines).components(separatedBy: separator)
        guard fields.count >= 6, fields[0] == "playing" || fields[0] == "paused", !fields[1].isEmpty else { return nil }
        // AppleScript prints numbers in the Mac's own format: "212,5" in much of Europe.
        func number(_ text: String) -> TimeInterval { TimeInterval(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let duration = number(fields[4])
        return NowPlayingTrack(player: player, isPlaying: fields[0] == "playing", title: fields[1], artist: fields[2], album: fields[3],
                               // Spotify counts the length in milliseconds, its position in seconds.
                               duration: player == .spotify ? duration / 1000 : duration,
                               position: number(fields[5]),
                               artworkURL: fields.count > 6 && fields[6].hasPrefix("https://") ? URL(string: fields[6]) : nil)
    }

    /// True when macOS refused the script because Automation is off for it.
    public static func isPermissionDenied(_ output: String) -> Bool {
        output.contains("-1743") || output.localizedCaseInsensitiveContains("not authorized")
    }

    /// "3:32", "1:02:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
