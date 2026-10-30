import AppKit
import SwiftData
import UniformTypeIdentifiers

/// A screenshot or recording Toolbelt saved. The file is the source of truth;
/// this row lists it under Recent in the Screenshots and Recording tools.
@Model
final class Capture {
    var kindRaw: String = CaptureKind.screenshot.rawValue
    var path: String = ""
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var duration: Double = 0
    var createdAt: Date = Date.now
    var uuid: UUID = UUID()

    var kind: CaptureKind { CaptureKind(rawValue: kindRaw) ?? .screenshot }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    init(kind: CaptureKind, url: URL, width: Int, height: Int, duration: Double = 0) {
        kindRaw = kind.rawValue
        path = url.path
        pixelWidth = width
        pixelHeight = height
        self.duration = duration
    }
}

enum CaptureKind: String {
    case screenshot, recording
}

/// What a capture covers.
enum CaptureMode: String, CaseIterable, Identifiable {
    case area, window, screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .screen: "Screen"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        }
    }
}

/// Screenshot and recording options, saved in UserDefaults. Settings binds
/// to the same keys with @AppStorage.
enum CapturePrefs {
    static let folderKey = "capture.folder"
    static let formatKey = "capture.format"
    static let copyKey = "capture.copy"
    static let previewKey = "capture.preview"
    static let cursorKey = "capture.cursor"
    static let shadowKey = "capture.shadow"
    static let systemAudioKey = "record.systemAudio"
    static let microphoneKey = "record.microphone"
    static let clicksKey = "record.clicks"
    static let recordCursorKey = "record.cursor"

    private static var defaults: UserDefaults { .standard }

    static var folder: URL {
        // Test and snapshot runs never write to the real Desktop.
        if Store.isOverridden {
            let dir = URL(fileURLWithPath: "/tmp/Toolbelt-captures")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if let path = defaults.string(forKey: folderKey), !path.isEmpty { return URL(fileURLWithPath: path) }
        return URL.desktopDirectory
    }

    static var format: ImageFormat { ImageFormat(rawValue: defaults.string(forKey: formatKey) ?? "") ?? .png }
    /// Test runs never touch the real clipboard.
    static var copyToClipboard: Bool { !Store.isOverridden && (defaults.object(forKey: copyKey) as? Bool ?? true) }
    static var showPreview: Bool { defaults.object(forKey: previewKey) as? Bool ?? true }
    static var includeCursor: Bool { defaults.bool(forKey: cursorKey) }
    static var windowShadow: Bool { defaults.bool(forKey: shadowKey) }
    static var systemAudio: Bool { defaults.bool(forKey: systemAudioKey) }
    static var microphone: Bool { defaults.bool(forKey: microphoneKey) }
    static var showClicks: Bool { defaults.object(forKey: clicksKey) as? Bool ?? true }
    static var recordCursor: Bool { defaults.object(forKey: recordCursorKey) as? Bool ?? true }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}
