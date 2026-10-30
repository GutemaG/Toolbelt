import AppKit
import SwiftData
import SwiftUI
import ToolbeltKit

/// Text the user saves to paste again: an address, a reply, a code block.
@Model
final class Snippet {
    var title: String = ""
    var keyword: String = ""
    var text: String = ""
    var createdAt: Date = Date.now
    var lastUsed: Date?
    var uuid: UUID = UUID()

    init(title: String, text: String, keyword: String = "") {
        self.title = title
        self.text = text
        self.keyword = keyword
    }

    /// The title, or the first line of the text when there is none.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? ClipRules.preview(text, limit: 40) : trimmed
    }
}

extension AppModel {
    @discardableResult
    func addSnippet(title: String = "New Snippet", text: String = "", keyword: String = "") -> Snippet {
        let snippet = Snippet(title: title, text: text, keyword: keyword)
        context.insert(snippet)
        try? context.save()
        return snippet
    }

    func deleteSnippet(_ snippet: Snippet) {
        context.delete(snippet)
        try? context.save()
    }

    /// Matching snippets, best first; most recently used first among equals.
    func searchSnippets(_ snippets: [Snippet], query: String) -> [Snippet] {
        snippets.compactMap { s in SnippetRules.score(query: query, title: s.title, keyword: s.keyword, text: s.text).map { (s, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return (a.0.lastUsed ?? a.0.createdAt) > (b.0.lastUsed ?? b.0.createdAt)
            }
            .map(\.0)
    }

    /// Opens Settings > Snippets with this snippet ready to edit.
    func editSnippet(_ snippet: Snippet) {
        editingSnippet = snippet.uuid
        settingsPage = .snippets
        SettingsWindow.shared.show(model: self)
    }
}

/// Settings > Snippets: the list, and the selected snippet's fields.
struct SnippetSettings: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Snippet.title) private var snippets: [Snippet]
    @State private var confirmDelete = false

    private var selected: Snippet? { snippets.first { $0.uuid == model.editingSnippet } ?? snippets.first }

    var body: some View {
        Section {
            if snippets.isEmpty {
                Text("No snippets yet. Add one, or right-click a clip and choose Save as Snippet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(snippets) { snippet in
                Button {
                    model.editingSnippet = snippet.uuid
                } label: {
                    HStack {
                        Text(snippet.displayTitle)
                            .foregroundStyle(.primary)
                        if !snippet.keyword.isEmpty {
                            Text(snippet.keyword)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if snippet.uuid == selected?.uuid {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Button("Add Snippet", systemImage: "plus") {
                model.editingSnippet = model.addSnippet().uuid
            }
        } header: {
            Text("Snippets")
        }

        if let snippet = selected {
            @Bindable var snippet = snippet
            Section {
                TextField("Title", text: $snippet.title)
                TextField("Keyword", text: $snippet.keyword, prompt: Text("Optional, like ;addr"))
                TextEditor(text: $snippet.text)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .accessibilityLabel("Snippet text")
                Button("Delete Snippet…", role: .destructive) { confirmDelete = true }
            } header: {
                Text("Edit “\(snippet.displayTitle)”")
            } footer: {
                Text("Type the keyword or the title in the Snippets search, then press Return to paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: snippet.text) { try? model.context.save() }
            .onChange(of: snippet.title) { try? model.context.save() }
            .onChange(of: snippet.keyword) { try? model.context.save() }
            .confirmationDialog("Delete “\(snippet.displayTitle)”?", isPresented: $confirmDelete) {
                Button("Delete Snippet", role: .destructive) {
                    model.editingSnippet = nil
                    model.deleteSnippet(snippet)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
