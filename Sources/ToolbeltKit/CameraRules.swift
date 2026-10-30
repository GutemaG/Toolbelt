import Foundation

/// Which camera the Camera tool shows.
public enum CameraRules {
    /// The camera picked last time while it is still connected, then the one
    /// macOS prefers (often a nearby iPhone), then the first one found.
    public static func pick(saved: String?, preferred: String?, available: [String]) -> String? {
        if let saved, available.contains(saved) { return saved }
        if let preferred, available.contains(preferred) { return preferred }
        return available.first
    }
}
