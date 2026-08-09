import Foundation

/// What the preview pane shows for the selected result: a body plus key/value metadata,
/// the same shape Raycast settled on because it fits everything from a file to an AI answer.
public struct ResultDetail: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label + value }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Monospaced when the body is data rather than prose.
    public let body: String
    public let isMonospaced: Bool
    public let metadata: [Item]
    /// A file worth *looking* at rather than reading: the image you copied, the PDF you found.
    /// Empty when there is nothing to show. Text-only previews were the reason a copied screenshot
    /// showed up as the word "imagen" and nothing else.
    public let previewPath: String

    public init(body: String, isMonospaced: Bool = false, metadata: [Item] = [],
                previewPath: String = "") {
        self.body = body
        self.isMonospaced = isMonospaced
        self.metadata = metadata
        self.previewPath = previewPath
    }
}

public enum DetailBuilder {

    public static func detail(
        for result: SearchResult,
        snippets: [Snippet] = [],
        flows: [Flow] = [],
        clips: [Clip] = [],
        memories: [MemoryObject] = [],
        commits: [MemoryCommit] = [],
        expander: SnippetExpander = SnippetExpander(),
        fileInfo: @Sendable (String) -> [ResultDetail.Item] = { _ in [] }
    ) -> ResultDetail? {
        switch result.kind {
        case .snippet:
            guard let snippet = snippets.first(where: { $0.id == result.recordID }) else { return nil }
            let expanded = expander.expand(snippet.body)
            return ResultDetail(
                body: expanded.text,
                metadata: [
                    .init(label: L("Keyword"), value: snippet.keyword),
                    .init(label: L("Used"), value: "\(snippet.uses)"),
                    .init(label: L("Unexpanded"), value: preview(snippet.body)),
                ]
            )

        case .clipboard:
            let clip = clips.first(where: { $0.id == result.recordID })
            // An image or a copied file is shown, not described. `assetPath` for a copied image,
            // the payload itself when what was copied *is* a file.
            let preview = clip?.assetPath.isEmpty == false
                ? clip!.assetPath
                : (clip?.kind == .file ? result.payload : "")
            var metadata: [ResultDetail.Item] = [
                .init(label: L("From"), value: clip?.sourceApp.isEmpty == false ? clip!.sourceApp : L("Unknown")),
                .init(label: L("Copied"), value: clip.map { relative($0.createdAt) } ?? "—"),
            ]
            if preview.isEmpty {
                metadata.append(ResultDetail.Item(label: L("Length"),
                                                  value: L("%@ characters", String(result.payload.count))))
            }
            return ResultDetail(
                body: preview.isEmpty ? result.payload : (preview as NSString).lastPathComponent,
                isMonospaced: preview.isEmpty && looksLikeData(result.payload),
                metadata: metadata + (preview.isEmpty ? [] : fileInfo(preview)),
                previewPath: preview
            )

        case .flow:
            guard let flow = flows.first(where: { $0.id == result.recordID }) else { return nil }
            let steps = flow.steps.enumerated()
                .map { "\($0.offset + 1). \($0.element.summary)" }
                .joined(separator: "\n")
            return ResultDetail(
                body: steps,
                metadata: [
                    .init(label: L("Keyword"), value: flow.keyword),
                    .init(label: L("Steps"), value: "\(flow.steps.count)"),
                    .init(label: L("Used"), value: "\(flow.uses)"),
                ]
            )

        case .calculation:
            return ResultDetail(
                body: result.title,
                isMonospaced: true,
                metadata: [.init(label: L("Sum"), value: result.subtitle
                    .replacingOccurrences(of: " · " + L("↩ copies it"), with: ""))]
            )

        case .process:
            return ResultDetail(
                body: result.title,
                metadata: [.init(label: L("Using"), value: result.subtitle),
                           .init(label: "PID", value: result.payload)]
            )

        case .agent:
            return ResultDetail(
                body: result.subtitle,
                metadata: [.init(label: L("Runs"), value: L("in the background, with a receipt"))]
            )

        case .application, .file:
            return ResultDetail(
                body: (result.payload as NSString).lastPathComponent,
                metadata: [.init(label: L("Path"), value: result.payload)] + fileInfo(result.payload),
                previewPath: result.payload
            )

        case .bookmark:
            return ResultDetail(body: result.payload, isMonospaced: true,
                                metadata: [.init(label: L("Kind"), value: L("Browser bookmark"))])

        case .mission:
            let mission = MissionPlanner.plan(result.payload)
            let steps = (mission?.steps ?? []).enumerated()
                .map { "\($0.offset + 1). \($0.element.title)" }
                .joined(separator: "\n")
            return ResultDetail(
                body: steps,
                metadata: [
                    .init(label: L("First"), value: L("You see the plan and can cancel")),
                    .init(label: L("Afterwards"), value: L("A receipt of what changed")),
                ]
            )

        case .answer:
            // A typed verb packs "<verb id>\u{1F}<text>" into the payload so it can be run later.
            // The preview must show the text it will work on, not the plumbing.
            if result.id.hasPrefix("verb-"),
               let split = result.payload.firstIndex(of: "\u{1F}") {
                let source = String(result.payload[result.payload.index(after: split)...])
                return ResultDetail(
                    body: source,
                    metadata: [.init(label: L("Will work on"), value: L("%@ characters", String(source.count)))]
                )
            }
            return ResultDetail(body: result.payload,
                                metadata: [.init(label: L("Based on"), value: result.subtitle)])

        case .recall:
            // The whole passage, so the row's one-line excerpt can be read in full before it is
            // trusted — a citation nobody can expand is a citation nobody should believe.
            return ResultDetail(body: result.payload,
                                metadata: [.init(label: L("Where from"), value: result.subtitle)])

        case .memory:
            let memory = memories.first { $0.id == result.payload }
            return ResultDetail(
                body: memory?.body.isEmpty == false ? memory!.body : result.title,
                metadata: [
                    .init(label: L("Kind"), value: memory?.kind.rawValue.capitalized ?? L("Memory")),
                    .init(label: L("In force"),
                          value: memory?.isCurrent() == true ? L("Yes") : L("No")),
                    .init(label: L("Owner"), value: memory?.owner ?? "—"),
                    .init(label: L("Source"), value: memory?.source ?? "—"),
                ]
            )

        case .pendingCommit:
            let commit = commits.first { $0.id == result.payload }
            return ResultDetail(
                body: commit?.object.statement ?? result.title,
                metadata: [
                    .init(label: L("Why"), value: commit?.reason ?? "—"),
                    .init(label: L("Would replace"),
                          value: commit.map { "\($0.conflicts.count)" } ?? "0"),
                    .init(label: L("Note"),
                          value: L("Nothing enters the brain without you confirming it.")),
                ]
            )

        case .shortcut:
            return ResultDetail(
                body: result.title,
                metadata: [
                    .init(label: L("From"), value: L("Shortcuts app")),
                    .init(label: L("Note"),
                          value: L("You made it; BeLauncher only calls it by name.")),
                ]
            )

        case .reminder:
            return ResultDetail(
                body: result.title,
                metadata: [.init(label: L("List and due date"), value: result.subtitle),
                           .init(label: L("Source"), value: L("Reminders on this Mac"))]
            )

        case .contact:
            return ResultDetail(body: result.title,
                                metadata: [.init(label: L("Contact detail"), value: result.subtitle)])

        case .photo:
            return ResultDetail(body: result.title,
                                metadata: [.init(label: L("Album"), value: result.subtitle),
                                           .init(label: L("Local identifier"), value: result.payload)])

        case .window:
            return ResultDetail(body: result.title,
                                metadata: [.init(label: L("Needs"), value: L("Accessibility permission"))])

        case .system:
            let command = SystemCommand.all.first { $0.kind.rawValue == result.payload }
            return ResultDetail(
                body: result.title,
                metadata: [
                    .init(label: L("Kind"), value: L("System command")),
                    .init(label: L("Confirmation"),
                          value: command?.needsConfirmation == true
                              ? L("Yes, before it runs") : L("Not needed")),
                ]
            )

        case .workflow:
            return ResultDetail(
                body: result.payload.isEmpty
                    ? L("Type a term after the keyword.")
                    : result.payload,
                isMonospaced: !result.payload.isEmpty,
                metadata: [.init(label: "Workflow", value: result.title)]
            )
        }
    }

    static func looksLikeData(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("<") { return true }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return true }
        // A line that reads like a command or a path.
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("$ ") || trimmed.contains("://")
    }

    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎ ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "hace instantes"
        case ..<3600: return "hace \(seconds / 60) min"
        case ..<86_400: return "hace \(seconds / 3600) h"
        default: return "hace \(seconds / 86_400) d"
        }
    }
}
