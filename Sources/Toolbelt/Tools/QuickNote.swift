import AppKit
import SwiftData
import SwiftUI
import ToolbeltKit

/// A note written in Quick Note. Saved as it's typed.
@Model
final class QuickNote {
    var text: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var uuid: UUID = UUID()

    init(text: String) {
        self.text = text
    }
}

/// A deleted note, kept until the next one so Undo can bring it back.
struct DeletedNote {
    let text: String
    let createdAt: Date
    let updatedAt: Date
}

extension AppModel {
    /// Newest first.
    func allNotes() -> [QuickNote] {
        (try? context.fetch(FetchDescriptor<QuickNote>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
    }

    /// The note in the editor. nil means a new one, saved at its first character.
    func currentNote() -> QuickNote? {
        guard !writingNewNote else { return nil }
        let notes = allNotes()
        return notes.first { $0.uuid == currentNoteID } ?? notes.first
    }

    func setNoteText(_ text: String) {
        if let note = currentNote() {
            guard note.text != text else { return }
            note.text = text
            note.updatedAt = .now
        } else {
            guard !text.isEmpty else { return }
            let note = QuickNote(text: text)
            context.insert(note)
            currentNoteID = note.uuid
            writingNewNote = false
        }
        try? context.save()
    }

    func newNote() {
        writingNewNote = true
        currentNoteID = nil
        dropBlankNotes()
        noteEditorID = UUID()
    }

    func selectNote(_ note: QuickNote) {
        guard note.uuid != currentNote()?.uuid else { return }
        let id = note.uuid
        writingNewNote = false
        currentNoteID = id
        dropBlankNotes()
        noteEditorID = UUID()
    }

    /// One note along in the list, for ⌘[ and ⌘].
    func stepNote(by offset: Int) {
        let notes = allNotes()
        guard !notes.isEmpty else { return }
        guard let current = currentNote(), let index = notes.firstIndex(of: current) else {
            if offset > 0 { selectNote(notes[0]) }
            return
        }
        let next = index + offset
        if notes.indices.contains(next) { selectNote(notes[next]) }
    }

    func deleteNote(_ note: QuickNote) {
        if !NoteRules.isBlank(note.text) {
            deletedNote = DeletedNote(text: note.text, createdAt: note.createdAt, updatedAt: note.updatedAt)
        }
        let wasCurrent = note.uuid == currentNote()?.uuid
        context.delete(note)
        try? context.save()
        if wasCurrent {
            currentNoteID = nil
            noteEditorID = UUID()
        }
    }

    func undoDeleteNote() {
        guard let deleted = deletedNote else { return }
        let note = QuickNote(text: deleted.text)
        note.createdAt = deleted.createdAt
        note.updatedAt = deleted.updatedAt
        context.insert(note)
        try? context.save()
        deletedNote = nil
        writingNewNote = false
        currentNoteID = note.uuid
        noteEditorID = UUID()
    }

    func copyNote(_ note: QuickNote) {
        lastCopiedNote = note.text
        // Test runs never touch the real clipboard.
        if !Store.isOverridden { clipboard.write(text: note.text) }
        Toast.show("Copied Note", symbol: "doc.on.doc")
    }

    /// Notes left empty aren't worth a row. The one you're on stays until you leave it.
    func dropBlankNotes(keepingCurrent: Bool = true) {
        let kept = keepingCurrent && !writingNewNote ? currentNoteID : nil
        let blank = allNotes().filter { NoteRules.isBlank($0.text) && $0.uuid != kept }
        guard !blank.isEmpty else { return }
        blank.forEach { context.delete($0) }
        try? context.save()
    }

    /// The window opened again: tidy up, and forget a deletion from last time.
    func quickNoteOpened() {
        dropBlankNotes(keepingCurrent: false)
        deletedNote = nil
    }
}

// MARK: The tool

/// Quick Note: the notes on the left, the one you're writing on the right. It
/// opens ready to type.
struct QuickNoteView: View {
    let surface: Surface
    @Environment(AppModel.self) private var model
    @Query(sort: \QuickNote.updatedAt, order: .reverse) private var notes: [QuickNote]
    @FocusState private var writing: Bool

    private var listWidth: CGFloat { surface == .panel ? Space.section * 6 : Space.section * 4 + Space.lg }

    var body: some View {
        let current = model.currentNote()
        HStack(spacing: 0) {
            list(current: current)
                .frame(width: listWidth)
            Divider()
            editor(current: current)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.quickNoteOpened()
            writing = true
        }
        .onChange(of: model.openCount) {
            model.quickNoteOpened()
            writing = true
        }
        .onChange(of: model.noteEditorID) {
            // The fresh editor needs focus handed over: it's already "true" for the old one.
            writing = false
            Task { writing = true }
        }
    }

    private func list(current: QuickNote?) -> some View {
        VStack(spacing: 0) {
            Button {
                model.newNote()
            } label: {
                Label("New Note", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(QuickActionStyle())
            .help("Start a new note (⌘N)")
            .padding(Space.sm)
            Divider()
            ScrollView {
                LazyVStack(spacing: Space.xs) {
                    if current == nil {
                        NoteRow(title: "New Note", date: nil, selected: true)
                    }
                    ForEach(notes) { note in
                        NoteRow(title: NoteRules.title(note.text), date: note.updatedAt, selected: note.uuid == current?.uuid)
                            .contentShape(.rect)
                            .onTapGesture { model.selectNote(note) }
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { model.copyNote(note) }
                                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteNote(note) }
                            }
                    }
                }
                .padding(Space.sm)
            }
            if model.deletedNote != nil {
                Divider()
                HStack(spacing: Space.sm) {
                    Text("Deleted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Undo") { model.undoDeleteNote() }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.accentText)
                        .help("Bring the note back")
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
            }
        }
    }

    private func editor(current: QuickNote?) -> some View {
        let text = Binding(get: { model.currentNote()?.text ?? "" }, set: { model.setNoteText($0) })
        return VStack(spacing: 0) {
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($writing)
                // A fresh editor per note, so ⌘Z can't undo into a different one.
                .id(model.noteEditorID)
                .padding(Space.sm)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text("Write something…")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.md + 1) // grid: ok lines up with the editor's own text inset
                            .padding(.vertical, Space.sm)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Note")
            Divider()
            HStack(spacing: Space.md) {
                Text(NoteRules.wordCount(text.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Copy", systemImage: "doc.on.doc") {
                    if let current { model.copyNote(current) }
                }
                .help("Copy this note (⌘⇧C)")
                Button("Delete", systemImage: "trash") {
                    if let current { model.deleteNote(current) }
                }
                .help("Delete this note (⌘⇧⌫)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(current == nil)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
    }
}

private struct NoteRow: View {
    let title: String
    let date: Date?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Group {
                if let date {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                } else {
                    Text("Not saved until you type")
                }
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected { RoundedRectangle(cornerRadius: 8).fill(Palette.accent) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Settings > Quick Note.
struct QuickNoteOptions: View {
    var body: some View {
        Section {
        } footer: {
            Text("Notes save as you type, in Toolbelt’s database on this Mac. A note you leave empty is removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
