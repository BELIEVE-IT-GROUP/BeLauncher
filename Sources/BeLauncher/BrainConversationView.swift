import SwiftUI
import UniformTypeIdentifiers
import BeLauncherCore

struct BrainAnswer: Equatable {
    let text: String
    let sources: [String]
}

@MainActor
struct BrainConversationView: View {
    let ask: @MainActor (String) async throws -> BrainAnswer
    let importText: @MainActor (String, String) -> Void
    let importFile: @MainActor (URL) -> Void
    let saveNote: @MainActor (String) -> Void
    let runIntent: @MainActor (String) -> Void
    @State private var question = ""
    @State private var answer: BrainAnswer?
    @State private var isAsking = false
    @State private var error: String?
    @State private var showingImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Theme.accent)
                Text(L("Talk to your knowledge")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { showingImporter = true } label: {
                    Label(L("Import file"), systemImage: "arrow.down.doc")
                }.buttonStyle(.borderless).help(L("Add a file as evidence"))
                Button {
                    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { importText(text, L("Pasted evidence")); question = "" }
                } label: {
                    Label(L("Import pasted text"), systemImage: "text.badge.plus")
                }.buttonStyle(.borderless)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Ask anything your Brain knows..."), text: $question, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...3).padding(9)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .onSubmit { submit() }
                Button { submit() } label: {
                    Image(systemName: isAsking ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 18))
                }.buttonStyle(.borderless)
                    .disabled(isAsking || question.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            }
            if let answer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(answer.text).font(.system(size: 12.5)).textSelection(.enabled)
                        if !answer.sources.isEmpty {
                            Text(L("Sources")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(answer.sources, id: \.self) { source in
                                Label(source, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 10) {
                            Button(L("Save answer as note")) { saveNote(answer.text) }
                            Button(L("Turn into mission")) { runIntent("enfoque") }
                            Button(L("Open Canvas")) { runIntent("turn this into a proposal") }
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 110)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.white.opacity(0.035))
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.item, .text, .plainText, .pdf, .data]) { result in
            if case .success(let url) = result { importFile(url) }
        }
    }

    private func submit() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3, !isAsking else { return }
        isAsking = true; error = nil
        Task { @MainActor in
            do { answer = try await ask(value) }
            catch { self.error = error.localizedDescription }
            isAsking = false
        }
    }
}
