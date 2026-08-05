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
                    .init(label: "Palabra clave", value: snippet.keyword),
                    .init(label: "Usos", value: "\(snippet.uses)"),
                    .init(label: "Sin expandir", value: preview(snippet.body)),
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
                .init(label: "Origen", value: clip?.sourceApp.isEmpty == false ? clip!.sourceApp : "Desconocido"),
                .init(label: "Copiado", value: clip.map { relative($0.createdAt) } ?? "—"),
            ]
            if preview.isEmpty {
                metadata.append(ResultDetail.Item(label: "Longitud", value: "\(result.payload.count) caracteres"))
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
                    .init(label: "Palabra clave", value: flow.keyword),
                    .init(label: "Pasos", value: "\(flow.steps.count)"),
                    .init(label: "Usos", value: "\(flow.uses)"),
                ]
            )

        case .calculation:
            return ResultDetail(
                body: result.title,
                isMonospaced: true,
                metadata: [.init(label: "Operación", value: result.subtitle
                    .replacingOccurrences(of: " · ↩ copies it", with: ""))]
            )

        case .agent:
            return ResultDetail(
                body: result.subtitle,
                metadata: [.init(label: "Se ejecuta", value: "en segundo plano, con recibo")]
            )

        case .application, .file:
            return ResultDetail(
                body: (result.payload as NSString).lastPathComponent,
                metadata: [.init(label: "Ruta", value: result.payload)] + fileInfo(result.payload),
                previewPath: result.payload
            )

        case .bookmark:
            return ResultDetail(body: result.payload, isMonospaced: true,
                                metadata: [.init(label: "Tipo", value: "Marcador del navegador")])

        case .mission:
            let mission = MissionPlanner.plan(result.payload)
            let steps = (mission?.steps ?? []).enumerated()
                .map { "\($0.offset + 1). \($0.element.title)" }
                .joined(separator: "\n")
            return ResultDetail(
                body: steps,
                metadata: [
                    .init(label: "Antes de nada", value: "Verás el plan y podrás cancelar"),
                    .init(label: "Después", value: "Un recibo de lo que cambió"),
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
                    metadata: [.init(label: "Se hará sobre", value: "\(source.count) caracteres")]
                )
            }
            return ResultDetail(body: result.payload,
                                metadata: [.init(label: "Basado en", value: result.subtitle)])

        case .memory:
            let memory = memories.first { $0.id == result.payload }
            return ResultDetail(
                body: memory?.body.isEmpty == false ? memory!.body : result.title,
                metadata: [
                    .init(label: "Tipo", value: memory?.kind.rawValue.capitalized ?? "Memoria"),
                    .init(label: "Vigente", value: memory?.isCurrent() == true ? "Sí" : "No"),
                    .init(label: "Dueño", value: memory?.owner ?? "—"),
                    .init(label: "Fuente", value: memory?.source ?? "—"),
                ]
            )

        case .pendingCommit:
            let commit = commits.first { $0.id == result.payload }
            return ResultDetail(
                body: commit?.object.statement ?? result.title,
                metadata: [
                    .init(label: "Motivo", value: commit?.reason ?? "—"),
                    .init(label: "Sustituiría", value: commit.map { "\($0.conflicts.count)" } ?? "0"),
                    .init(label: "Nota", value: "Nada entra al cerebro sin que lo confirmes."),
                ]
            )

        case .shortcut:
            return ResultDetail(
                body: result.title,
                metadata: [
                    .init(label: "Origen", value: "App Atajos"),
                    .init(label: "Nota", value: "Lo creaste tú; BeLauncher solo lo invoca por nombre."),
                ]
            )

        case .window:
            return ResultDetail(body: result.title,
                                metadata: [.init(label: "Requiere", value: "Permiso de Accesibilidad")])

        case .system:
            let command = SystemCommand.all.first { $0.kind.rawValue == result.payload }
            return ResultDetail(
                body: result.title,
                metadata: [
                    .init(label: "Tipo", value: "Comando del sistema"),
                    .init(label: "Confirmación",
                          value: command?.needsConfirmation == true ? "Sí, antes de ejecutar" : "No hace falta"),
                ]
            )

        case .workflow:
            return ResultDetail(
                body: result.payload.isEmpty ? "Escribe un término después de la palabra clave." : result.payload,
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
