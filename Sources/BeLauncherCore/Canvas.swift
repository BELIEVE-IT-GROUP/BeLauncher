import Foundation

/// A small, temporary workspace that appears when one answer is not enough.
///
/// Some outcomes are not a result, they are a set of pieces: a campaign is an audience and an offer
/// and a concept and a landing page and the ads and the email and the tasks. Returning that as one
/// wall of text makes it unusable, and building a second app to hold it makes BeLauncher into the
/// thing it was meant to replace.
///
/// So: blocks, generated in one pass, each one editable and runnable on its own, and the whole
/// thing gone when it is done. It is a workflow rendered at the moment it is needed rather than a
/// document you now have to maintain.
/// Deliberately not `Codable`: a canvas is a workspace that exists while you are using it and is
/// gone afterwards. Persisting it would turn a temporary surface into documents to manage, which is
/// exactly the app this one is meant to replace.
public struct Canvas: Sendable, Equatable, Identifiable {

    public struct Block: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
            /// Text the model produced; editable.
            case draft
            /// A list the person is meant to tick through.
            case checklist
            /// Something that will be done when the canvas runs.
            case action
            /// Read-only context: what this was based on.
            case reference

            public var symbol: String {
                switch self {
                case .draft: "text.alignleft"
                case .checklist: "checklist"
                case .action: "bolt"
                case .reference: "quote.opening"
                }
            }
        }

        public var id: String
        public var kind: Kind
        public var title: String
        public var body: String
        /// Blocks are filled one at a time, so each says whether it is ready.
        public var isReady: Bool
        /// For `.action` blocks: what running the canvas will actually do.
        public var action: LauncherModel.Action?
        /// Set when the person edited it, so regenerating never silently discards their work.
        public var editedByHand: Bool

        public init(id: String = UUID().uuidString, kind: Kind, title: String, body: String = "",
                    isReady: Bool = false, action: LauncherModel.Action? = nil,
                    editedByHand: Bool = false) {
            self.id = id
            self.kind = kind
            self.title = title
            self.body = body
            self.isReady = isReady
            self.action = action
            self.editedByHand = editedByHand
        }
    }

    public var id: String
    public var title: String
    /// What the person asked for, kept so a regenerate has the same brief.
    public var brief: String
    public var blocks: [Block]
    public var createdAt: Date

    public init(id: String = UUID().uuidString, title: String, brief: String,
                blocks: [Block], createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.brief = brief
        self.blocks = blocks
        self.createdAt = createdAt
    }

    public var isComplete: Bool { blocks.allSatisfy(\.isReady) }

    public var progress: Double {
        guard !blocks.isEmpty else { return 0 }
        return Double(blocks.filter(\.isReady).count) / Double(blocks.count)
    }

    /// The actions running the whole canvas would carry out, in order.
    public var actions: [LauncherModel.Action] {
        blocks.compactMap { $0.kind == .action && $0.isReady ? $0.action : nil }
    }

    /// Replaces a block's text, marking it as the person's so nothing regenerates over it.
    public mutating func edit(_ blockID: String, body: String) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        blocks[index].body = body
        blocks[index].isReady = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        blocks[index].editedByHand = true
    }

    /// Fills a block from a model. Hand edits win: regenerating over someone's own words is the
    /// fastest way to make them stop trusting the thing.
    public mutating func fill(_ blockID: String, body: String) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }),
              !blocks[index].editedByHand else { return }
        blocks[index].body = body
        blocks[index].isReady = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The blocks still waiting on a model, so filling can be driven one at a time and shown.
    public var pending: [Block] { blocks.filter { !$0.isReady && $0.kind != .action } }

    public func render() -> String {
        var text = ["# \(title)", ""]
        for block in blocks {
            text.append("## \(block.title)")
            text.append(block.body.isEmpty ? "_(vacío)_" : block.body)
            text.append("")
        }
        return text.joined(separator: "\n")
    }
}

/// The canvases the app knows how to lay out.
///
/// A closed catalogue, like missions: five shapes done properly beats a generic outline generator
/// that produces a plausible skeleton for anything and a useful one for nothing.
public enum CanvasTemplate {

    public struct Definition: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let blocks: [(title: String, kind: Canvas.Block.Kind, instruction: String)]

        public static func == (lhs: Definition, rhs: Definition) -> Bool { lhs.id == rhs.id }

        public init(id: String, title: String,
                    blocks: [(title: String, kind: Canvas.Block.Kind, instruction: String)]) {
            self.id = id
            self.title = title
            self.blocks = blocks
        }
    }

    public static let all: [Definition] = [
        .init(id: "campaign", title: "Campaña", blocks: [
            ("Audiencia", .draft, "Describe a quién va dirigida esta campaña: quién es, qué le duele y qué le mueve. Tres frases."),
            ("Oferta", .draft, "Formula la oferta concreta en una frase, sin adjetivos de relleno."),
            ("Concepto", .draft, "Propón el concepto creativo: la idea que sostiene toda la campaña."),
            ("Landing", .draft, "Escribe el titular, subtitular y la llamada a la acción de la página."),
            ("Anuncios", .draft, "Tres variantes de anuncio, una línea cada una."),
            ("Email", .draft, "Un correo corto de lanzamiento: asunto y cuerpo."),
            ("Tareas", .checklist, "Lista lo que hay que hacer para lanzar esto, en orden."),
        ]),
        .init(id: "proposal", title: "Propuesta", blocks: [
            ("Contexto", .reference, "Resume qué sabemos del cliente y de la conversación previa."),
            ("Problema", .draft, "Enuncia el problema con las palabras del cliente, no con las nuestras."),
            ("Solución", .draft, "Qué proponemos, concreto, sin jerga."),
            ("Alcance", .checklist, "Qué incluye y qué no incluye. Lo que no incluye evita la mitad de los problemas."),
            ("Precio y plazos", .draft, "Propón una estructura de precio y un plazo realista."),
            ("Siguiente paso", .draft, "Una sola acción clara para que el cliente diga que sí."),
        ]),
        .init(id: "meeting-prep", title: "Preparación de reunión", blocks: [
            ("Quién es", .reference, "Quién viene y qué sabemos de ellos."),
            ("Dónde lo dejamos", .reference, "Lo último que se decidió o se prometió."),
            ("Objetivo", .draft, "Qué queremos sacar de esta reunión, en una frase."),
            ("Preguntas", .checklist, "Las tres preguntas que hay que hacer sí o sí."),
            ("Riesgos", .draft, "Qué puede salir mal o qué objeción va a aparecer."),
        ]),
        .init(id: "post-mortem", title: "Cierre de proyecto", blocks: [
            ("Qué pasó", .draft, "Resume lo ocurrido, sin culpables."),
            ("Qué funcionó", .checklist, "Lo que hay que repetir."),
            ("Qué no", .checklist, "Lo que hay que dejar de hacer."),
            ("Decisiones", .draft, "Qué decidimos a partir de esto. Esto va al cerebro."),
        ]),
        .init(id: "onboarding", title: "Alta de cliente", blocks: [
            ("Ficha", .draft, "Datos del cliente: quién es, qué hace, quién es el contacto."),
            ("Accesos", .checklist, "Qué accesos hay que pedirles."),
            ("Entregables", .checklist, "Qué recibirán y cuándo."),
            ("Carpeta", .action, "Crear la carpeta del cliente."),
            ("Primera reunión", .draft, "Agenda de la reunión de arranque."),
        ]),
    ]

    public static func named(_ id: String) -> Definition? { all.first { $0.id == id } }

    /// Builds an empty canvas from a template, ready to be filled block by block.
    public static func canvas(_ definition: Definition, brief: String) -> Canvas {
        Canvas(
            title: brief.isEmpty ? definition.title : "\(definition.title): \(brief)",
            brief: brief,
            blocks: definition.blocks.map { block in
                Canvas.Block(kind: block.kind, title: block.title)
            }
        )
    }

    /// The prompt for one block, carrying the brief so every block answers the same question.
    public static func instruction(for definition: Definition, blockTitle: String,
                                   brief: String, context: String = "") -> String? {
        guard let block = definition.blocks.first(where: { $0.title == blockTitle }) else {
            return nil
        }
        var prompt = "\(block.instruction)\n\nEncargo: \(brief)"
        if !context.isEmpty {
            prompt += "\n\nContexto conocido:\n\(context)"
        }
        return prompt
    }
}
