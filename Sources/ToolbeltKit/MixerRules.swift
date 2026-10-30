import Foundation

/// Volume rules for the Volume Mixer. A level is what the slider shows, 0 to 1.
public enum MixerRules {
    /// How much to multiply the sound by. Squared, so the slider's middle sounds
    /// about half as loud, like the Mac's own volume.
    public static func gain(level: Double, muted: Bool) -> Float {
        muted ? 0 : Float(min(max(level, 0), 1) * min(max(level, 0), 1))
    }

    /// An app at full volume and not muted is left alone: its sound is not rerouted.
    public static func needsTap(level: Double, muted: Bool) -> Bool {
        muted || level < 0.995
    }

    /// A step from the arrow keys, kept on whole tenths.
    public static func nudge(_ level: Double, by step: Double) -> Double {
        min(max(((level + step) * 10).rounded() / 10, 0), 1)
    }

    /// "64%".
    public static func percent(_ level: Double) -> String {
        "\(Int((min(max(level, 0), 1) * 100).rounded()))%"
    }
}
