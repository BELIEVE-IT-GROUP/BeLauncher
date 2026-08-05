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

    public init(body: String, isMonospaced: Bool = false, metadata: [Item] = []) {
        self.body = body
        self.isMonospaced = isMonospaced
        self.metadata = metadata
    }
}

public enum DetailBuilder {

    public static func detail(
        for result: SearchResult,
        snippets: [Snippet] = [],
        flows: [Flow] = [],
        clips: [Clip] = [],
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
            return ResultDetail(
                body: result.payload,
                isMonospaced: looksLikeData(result.payload),
                metadata: [
                    .init(label: "Origen", value: clip?.sourceApp.isEmpty == false ? clip!.sourceApp : "Desconocido"),
                    .init(label: "Copiado", value: clip.map { relative($0.createdAt) } ?? "—"),
                    .init(label: "Longitud", value: "\(result.payload.count) caracteres"),
                ]
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

        case .application, .file:
            return ResultDetail(
                body: (result.payload as NSString).lastPathComponent,
                metadata: [.init(label: "Ruta", value: result.payload)] + fileInfo(result.payload)
            )

        case .bookmark:
            return ResultDetail(body: result.payload, isMonospaced: true,
                                metadata: [.init(label: "Tipo", value: "Marcador del navegador")])

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
