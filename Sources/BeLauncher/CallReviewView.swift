import SwiftUI
import BeLauncherCore

@MainActor
final class CallReviewModel: ObservableObject {
    let title: String
    let transcript: String
    private let analyze: (String) async throws -> String
    private let save: (String, String) throws -> Void
    @Published var analysis = ""
    @Published var working = false
    @Published var error: String?
    @Published var saved = false

    init(title: String, transcript: String,
         analyze: @escaping (String) async throws -> String,
         save: @escaping (String, String) throws -> Void = { _, _ in }) {
        self.title = title; self.transcript = transcript; self.analyze = analyze; self.save = save
    }

    func extractActions() {
        guard !working else { return }
        working = true; error = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                analysis = try await analyze("""
                    Analyze this call transcript without inventing facts. Return four concise Markdown sections:
                    ## Decisions
                    ## Commitments
                    ## Tasks
                    ## Open questions
                    Every item must cite the speaker label and exact wording when possible. Mark uncertain items as uncertain.

                    TRANSCRIPT:
                    \(transcript)
                    """)
            } catch let failure { self.error = failure.localizedDescription }
            working = false
        }
    }

    func saveAnalysis() {
        guard !analysis.isEmpty else { return }
        do {
            try save(title, analysis)
            saved = true
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}

@MainActor
struct CallReviewView: View {
    @ObservedObject var model: CallReviewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                transcriptPane
                    .frame(minWidth: 360, idealWidth: 470)
                proposalsPane
                    .frame(minWidth: 360, idealWidth: 470)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 620, idealHeight: 720)
        .toolbar { toolbarContent }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.title3.weight(.semibold))
                Text(L("Transcript")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.saved {
                Label(L("Saved to Brain"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(L("Transcript"), symbol: "text.quote")
            Divider()
            ScrollView {
                Text(model.transcript.isEmpty ? L("Nothing extracted yet.") : model.transcript)
                    .font(.system(size: 13, design: .default))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .scrollIndicators(.automatic)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var proposalsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader(L("Proposals"), symbol: "checklist")
            Divider()
            if model.working {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("Reading the call…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(model.analysis.isEmpty ? L("Nothing extracted yet.") : model.analysis)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .scrollIndicators(.automatic)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func paneHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.extractActions() } label: {
                Label(L("Extract actions"), systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.working)

            Button { model.saveAnalysis() } label: {
                Label(model.saved ? L("Saved to Brain") : L("Save proposals"),
                      systemImage: model.saved ? "checkmark" : "square.and.arrow.down")
            }
            .disabled(model.analysis.isEmpty || model.working || model.saved)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).foregroundStyle(.secondary)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text(L("Audio stays on this Mac.")).foregroundStyle(.secondary)
            }
            Spacer()
            Text(L("Proposals are not committed automatically."))
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }
}
