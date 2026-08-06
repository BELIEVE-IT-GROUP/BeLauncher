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
            text.append(block.body.isEmpty ? L("_(empty)_") : block.body)
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
        .init(id: "campaign", title: L("Campaign"), blocks: [
            ("Audiencia", .draft, "Describe who this campaign is aimed at: who they are, what hurts and what moves them. Three sentences."),
            ("Oferta", .draft, "State the concrete offer in one sentence, no filler adjectives."),
            ("Concepto", .draft, "Propose the creative concept: the idea the whole campaign hangs on."),
            ("Landing", .draft, "Write the headline, subhead and call to action for the page."),
            ("Anuncios", .draft, "Three ad variants, one line each."),
            ("Email", .draft, "A short launch email: subject and body."),
            ("Tareas", .checklist, "List what has to happen to launch this, in order."),
        ]),
        .init(id: "proposal", title: L("Proposal"), blocks: [
            ("Contexto", .reference, "Sum up what we know about the client and the previous conversation."),
            ("Problema", .draft, "State the problem in the client’s words, not ours."),
            (L("Solution"), .draft, "What we propose: concrete, no jargon."),
            ("Alcance", .checklist, "What is included and what is not. What is not included prevents half the trouble."),
            (L("Price and timings"), .draft, "Propose a price structure and a realistic timeline."),
            (L("Next step"), .draft, "One clear action for the client to say yes to."),
        ]),
        .init(id: "meeting-prep", title: L("Meeting prep"), blocks: [
            (L("Who they are"), .reference, "Who is coming and what we know about them."),
            (L("Where we left it"), .reference, "The last thing decided or promised."),
            ("Objetivo", .draft, "What we want out of this meeting, in one sentence."),
            ("Preguntas", .checklist, "The three questions that have to be asked."),
            ("Riesgos", .draft, "What could go wrong, or which objection is coming."),
        ]),
        .init(id: "post-mortem", title: L("Project wrap-up"), blocks: [
            (L("What happened"), .draft, "Sum up what happened, without blame."),
            (L("What worked"), .checklist, "What is worth doing again, and why it worked."),
            (L("What did not"), .checklist, "What to stop doing, stated plainly."),
            ("Decisiones", .draft, "What we decide from this. This goes into the brain."),
        ]),
        .init(id: "onboarding", title: L("Client onboarding"), blocks: [
            ("Ficha", .draft, "Client details: who they are, what they do, who the contact is."),
            ("Accesos", .checklist, "Which accesses to ask them for."),
            ("Entregables", .checklist, "What they will receive and when."),
            (L("Folder"), .action, "Create the client folder."),
            (L("First meeting"), .draft, "Agenda for the kick-off meeting."),
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
