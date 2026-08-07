import SwiftUI
import BeLauncherCore

struct QuickNoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let save: (String) -> Void

    init(initialText: String = "", save: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L("Quick note"), systemImage: "note.text").font(.headline)
                Spacer()
                Text(L("Saved as Markdown in inbox")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(16)
            Divider()
            HStack {
                Text(L("⌘↩ Save")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save note")) { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value)
        dismiss()
    }
}
