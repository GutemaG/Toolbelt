import Foundation

/// The words Quick Note shows for a note.
public enum NoteRules {
    public static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    /// The first line with something on it, or "New Note".
    public static func title(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return "New Note"
    }

    /// "1 word", "12 words".
    public static func wordCount(_ text: String) -> String {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return count == 1 ? "1 word" : "\(count) words"
    }
}
