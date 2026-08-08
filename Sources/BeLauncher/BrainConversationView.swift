import SwiftUI
import UniformTypeIdentifiers
import BeLauncherCore

struct BrainAnswer: Equatable {
    let text: String
    let sources: [BrainCitation]
}

struct BrainConversationContext: Equatable, Sendable {
    let sourceID: String
    let title: String
    let body: String
}

/// A citation is a route back to evidence, not a decorative label. Some indexed sources do not
/// have a local Markdown document yet, so the UI can say that instead of opening an empty reader.
struct BrainCitation: Equatable, Identifiable {
    let sourceID: String
    let title: String
    let kind: String
    let canOpen: Bool

    var id: String { sourceID + ":" + kind }
}

@MainActor
struct BrainConversationView: View {
    @Bindable var coordinator: BrainCommandCoordinator
    let context: @MainActor () -> BrainConversationContext?
    let ask: @MainActor (String, BrainConversationContext?) async throws -> BrainAnswer
    let importText: @MainActor (String, String) -> Void
    let importFile: @MainActor (URL) -> Void
    let saveNote: @MainActor (String) -> Void
    let newNote: @MainActor () -> Void
    let prepareMission: @MainActor (String) -> Void
    let runIntent: @MainActor (String) -> Void
    let openCitation: @MainActor (BrainCitation) -> Void
    @State private var question = ""
    @State private var answer: BrainAnswer?
    @State private var isAsking = false
    @State private var error: String?
    @State private var showingImporter = false
    @State private var askTask: Task<Void, Never>?

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
                Button { newNote() } label: {
                    Label(L("New note"), systemImage: "note.text.badge.plus")
                }
                .buttonStyle(.borderless)
            }
            if let context = context() {
                Label(L("Current document: %@", context.title), systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(Theme.cyan)
                    .lineLimit(1)
                    .help(L("The question will use this document as context."))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Ask anything your Brain knows..."), text: $question, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...3).padding(9)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .onSubmit { submit() }
                Button {
                    if isAsking { coordinator.cancel() } else { submit() }
                } label: {
                    Image(systemName: isAsking ? "xmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 18))
                }.buttonStyle(.borderless)
                    .disabled(!isAsking && question.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                    .help(isAsking ? L("Cancel") : L("Ask Brain"))
            }
            if let answer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(answer.text).font(.system(size: 12.5)).textSelection(.enabled)
                        if !answer.sources.isEmpty {
                            Text(L("Sources")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(answer.sources) { source in
                                Button { openCitation(source) } label: {
                                    Label(source.title + " · " + source.kind,
                                          systemImage: source.canOpen ? "doc.text" : "doc.text.magnifyingglass")
                                        .font(.caption)
                                        .foregroundStyle(source.canOpen ? Theme.cyan : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .disabled(!source.canOpen)
                                .help(source.canOpen ? L("Open evidence in the Brain")
                                      : L("This source has no local document yet"))
                            }
                        }
                        HStack(spacing: 10) {
                            Button(L("Save answer as note")) { saveNote(answer.text) }
                            Button(L("Turn into mission")) {
                                prepareMission(answer.text)
                            }
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
        .onDisappear {
            if isAsking { coordinator.cancel() }
            askTask?.cancel()
        }
    }

    private func submit() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3, !isAsking else { return }
        isAsking = true; error = nil
        let runID = UUID().uuidString
        let selectedContext = context()
        askTask = Task { @MainActor in
            do {
                answer = try await ask(value, selectedContext)
                coordinator.finish(id: runID)
            }
            catch is CancellationError {
                error = L("Question cancelled.")
                coordinator.finish(id: runID, cancelled: true)
            }
            catch {
                self.error = (error as? IntelligenceError)?.description ?? error.localizedDescription
                coordinator.finish(id: runID, failed: true)
            }
            isAsking = false
            askTask = nil
        }
        coordinator.begin(id: runID, label: L("Ask Brain"), source: L("Brain conversation"),
                          cancel: { askTask?.cancel() })
    }
}
