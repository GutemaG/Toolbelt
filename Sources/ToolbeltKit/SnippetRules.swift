import Foundation

/// Searching snippets: an exact keyword wins, then title, then the text.
public enum SnippetRules {
    /// A sort score for one snippet, or nil when it does not match. Higher is better.
    public static func score(query: String, title: String, keyword: String, text: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        if !keyword.isEmpty, keyword.compare(q, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 4 }
        if let match = FuzzyMatch.match(q, in: title), match.tier >= 2 { return 3 }
        if !keyword.isEmpty, ClipRules.matches(q, text: keyword) { return 2 }
        if ClipRules.matches(q, text: text) { return 1 }
        return nil
    }
}
