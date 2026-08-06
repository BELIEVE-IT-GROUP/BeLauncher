import Foundation

/// A store of outcomes, not of plugins.
///
/// "Install the Google Calendar extension" asks a person to know which tool solves their problem
/// and how to wire it. L("Get me ready for any meeting") asks them to know what they want. The
/// second is the only one an ordinary user can answer, and it is the one place where a launcher
/// with agents can beat a launcher with a plugin directory.
///
/// A pack is therefore not code. It is a description of an outcome: the command that triggers it,
/// what it is allowed to read, the permissions it needs, the rules it must follow, and the canvas
/// it lays out. Nothing in a pack can execute arbitrary anything — the app carries out the steps it
/// already knows how to carry out, which is what makes installing a stranger's pack safe.
public struct OutcomePack: Sendable, Equatable, Identifiable, Codable {

    /// House rules the outcome has to respect: brand voice, formats, who approves.
    public struct Rule: Sendable, Equatable, Codable, Identifiable {
        public var id: String { name }
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public let id: String
    public let name: String
    /// What the person gets, in their words. This is the whole pitch.
    public let outcome: String
    public let verb: String
    public let symbol: String
    public let reads: [AgentCommand.ContextSource]
    /// A canvas template id, when the outcome is a set of pieces rather than one answer.
    public let canvasTemplate: String?
    /// What the model is told to do when there is no canvas.
    public let instruction: String
    public var rules: [Rule]
    public let author: String

    public init(version: Int = OutcomePack.currentVersion, id: String, name: String,
                outcome: String, verb: String, symbol: String = "sparkles",
                reads: [AgentCommand.ContextSource] = [.clipboard], canvasTemplate: String? = nil,
                instruction: String = "", rules: [Rule] = [], author: String = "") {
        self.version = version
        self.id = id
        self.name = name
        self.outcome = outcome
        self.verb = verb
        self.symbol = symbol
        self.reads = reads
        self.canvasTemplate = canvasTemplate
        self.instruction = instruction
        self.rules = rules
        self.author = author
    }

    public var command: AgentCommand {
        AgentCommand(id: id, verb: verb, title: name, summary: outcome, reads: reads,
                     argument: nil, symbol: symbol, opensCanvas: canvasTemplate != nil)
    }

    /// Rules folded into the instruction, so a shared pack actually changes what comes out.
    ///
    /// This is what makes a team pack worth having: without it, "prepara una propuesta" produces
    /// the model's idea of a proposal instead of yours.
    public func instruction(with brief: String) -> String {
        var text = instruction.isEmpty ? "Produce the result that was asked for." : instruction
        if !rules.isEmpty {
            text += "\n\nHouse rules, not optional:\n"
            text += rules.map { "- \($0.name): \($0.value)" }.joined(separator: "\n")
        }
        if !brief.isEmpty {
            text += "\n\nEncargo: \(brief)"
        }
        return text
    }
}

public enum PackError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case malformed
    case verbTaken(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            L("This package was written by a newer version (format %@).", String(version))
        case .malformed:
            L("The file is not a BeLauncher package.")
        case .verbTaken(let verb):
            L("You already have a /%@ command. Rename one of the two.", verb)
        }
    }
}

extension OutcomePack {

    /// What ships with the app: five outcomes done properly rather than an empty store.
    ///
    /// An outcome marketplace with nothing in it teaches people the feature is not for them. These
    /// are also the worked examples someone copies to write their own.
    public static let builtIn: [OutcomePack] = [
        .init(id: "prepare-any-meeting", name: L("Get me ready for any meeting"),
              outcome: L("It gathers who is coming, what was decided last time and what is still open, and leaves you a script before you walk in."),
              verb: "prepare", symbol: "person.2",
              reads: [.calendar, .brain, .workGraph], canvasTemplate: "meeting-prep",
              author: "BeLauncher"),

        .init(id: "close-my-day", name: L("Close my day"),
              outcome: L("It goes back over what you did, pulls out what was left open, and keeps it in your brain."),
              verb: "cierre", symbol: "moon",
              reads: [.workGraph, .brain, .clipboard],
              instruction: "Go back over the day's work and return: what closed, what stayed open and "
                         + "what should be decided tomorrow. Be short and concrete.",
              author: "BeLauncher"),

        .init(id: "follow-up", name: L("Follow up on a proposal"),
              outcome: L("It writes the follow-up in the right tone, knowing where things were left."),
              verb: "followup", symbol: "arrowshape.turn.up.right",
              reads: [.brain, .workGraph, .clipboard],
              instruction: "Write a short, direct follow-up. No filler apologies, no "
                         + "“hope you are well”. Recall the last agreement and propose one "
                         + "concreto.",
              author: "BeLauncher"),

        .init(id: "call-to-actions", name: L("Turn a call into actions"),
              outcome: L("From raw notes it pulls out decisions and commitments, and offers them to you one at a time for the brain."),
              verb: L("actions"), symbol: "checklist",
              reads: [.clipboard, .brain],
              instruction: "Pull the decisions taken and the commitments made out of the text. "
                         + "One line each, with owner and date if they appear. No "
                         + "resumen general.",
              author: "BeLauncher"),

        .init(id: "new-client", name: L("Onboard a new client"),
              outcome: L("Profile, access, deliverables, folder and a kick-off agenda, in one pass."),
              verb: "alta", symbol: "person.badge.plus",
              reads: [.brain, .clipboard], canvasTemplate: "onboarding",
              author: "BeLauncher"),

        .init(id: "campaign", name: L("Put a campaign together"),
              outcome: L("Audience, offer, concept, landing page, ads, email and tasks."),
              verb: "campana", symbol: "megaphone",
              reads: [.brain, .clipboard], canvasTemplate: "campaign",
              author: "BeLauncher"),
    ]

    // MARK: - Sharing

    public static func encode(_ packs: [OutcomePack]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(packs)
    }

    public static func decode(_ data: Data) throws -> [OutcomePack] {
        guard let packs = try? JSONDecoder().decode([OutcomePack].self, from: data) else {
            throw PackError.malformed
        }
        if let newer = packs.first(where: { $0.version > currentVersion }) {
            throw PackError.unsupportedVersion(newer.version)
        }
        return packs
    }

    /// Checks an incoming pack against what is already installed.
    ///
    /// Two commands answering to `/prepare` is not a merge conflict to resolve quietly: whichever
    /// one runs, half the time it is the wrong one, and the person has no way to tell.
    public static func conflicts(_ incoming: [OutcomePack],
                                 with installed: [OutcomePack]) -> [PackError] {
        let taken = Set(installed.map(\.verb))
        var seen = Set<String>()
        return incoming.compactMap { pack in
            guard taken.contains(pack.verb) || !seen.insert(pack.verb).inserted else { return nil }
            return PackError.verbTaken(pack.verb)
        }
    }
}

// MARK: - Storage

extension Store {

    public func installPack(_ pack: OutcomePack, source: String = "") throws {
        let data = try OutcomePack.encode([pack])
        try? database.execute("""
            INSERT INTO packs (id, payload, installedAt, source) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, installedAt = excluded.installedAt
            """,
            [.text(pack.id), .text(String(decoding: data, as: UTF8.self)),
             .double(Date().timeIntervalSince1970), .text(source)]
        )
    }

    public func installedPacks() -> [OutcomePack] {
        let rows = (try? database.query("SELECT payload FROM packs ORDER BY installedAt ASC")) ?? []
        return rows.compactMap { row in
            try? OutcomePack.decode(Data(row.string("payload").utf8)).first
        }.compactMap { $0 }
    }

    public func removePack(id: String) {
        try? database.execute("DELETE FROM packs WHERE id = ?", [.text(id)])
    }

    /// Everything the slash menu should offer: what ships with the app plus what has been added,
    /// with installed packs winning so a team can replace a built-in with their own version.
    public func availablePacks() -> [OutcomePack] {
        let installed = installedPacks()
        let installedVerbs = Set(installed.map(\.verb))
        return installed + OutcomePack.builtIn.filter { !installedVerbs.contains($0.verb) }
    }
}
