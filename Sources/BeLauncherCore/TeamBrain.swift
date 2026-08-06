import Foundation
import CryptoKit

/// Sharing a brain between people, without giving it away.
///
/// The rule that shapes everything here: a shared brain is a *bundle the user exports*, encrypted
/// on their Mac with a key only the team has. Believe never holds the key and never holds the
/// plaintext. Sync that requires trusting us would undo the reason anyone put their company's
/// memory in a local app.
public enum TeamBrain {

    /// Who can do what. Deliberately three roles: more than that and nobody configures it right.
    public enum Role: String, Sendable, Codable, CaseIterable, Comparable {
        /// Sees shared memory. Cannot change it.
        case reader
        /// Proposes and confirms into shared memory.
        case editor
        /// Also decides who is in and who is out.
        case owner

        var rank: Int {
            switch self {
            case .reader: 0
            case .editor: 1
            case .owner: 2
            }
        }

        public static func < (lhs: Role, rhs: Role) -> Bool { lhs.rank < rhs.rank }

        public var canConfirm: Bool { self >= .editor }
        public var canManageMembers: Bool { self == .owner }
    }

    public struct Member: Sendable, Equatable, Codable, Identifiable {
        public var id: String { email }
        public let email: String
        public let name: String
        public let role: Role

        public init(email: String, name: String, role: Role) {
            self.email = email.lowercased().trimmingCharacters(in: .whitespaces)
            self.name = name
            self.role = role
        }
    }

    /// What actually travels between Macs: shared objects only, never personal ones.
    public struct Bundle: Sendable, Equatable, Codable {
        public static let currentVersion = 1

        public var version: Int
        public var team: String
        public var exportedAt: Date
        public var exportedBy: String
        public var objects: [MemoryObject]
        public var members: [Member]
        /// The team's own commands: `/alta`, `/propuesta`, each carrying the house rules.
        ///
        /// Shared memory alone made BeLauncher a company *encyclopedia*. Shared commands make it
        /// the company's operational layer: everyone's `/propuesta` produces the proposal your
        /// company makes, with your structure, your voice and your approvals, instead of the
        /// model's generic idea of one.
        public var packs: [OutcomePack]
        /// Flows and snippets the team all share.
        public var flows: [Flow]
        public var snippets: [Snippet]
        /// Standards every shared command has to respect: brand voice, formats, folders.
        public var standards: [OutcomePack.Rule]

        public init(version: Int = Bundle.currentVersion, team: String, exportedAt: Date = .now,
                    exportedBy: String, objects: [MemoryObject], members: [Member],
                    packs: [OutcomePack] = [], flows: [Flow] = [], snippets: [Snippet] = [],
                    standards: [OutcomePack.Rule] = []) {
            self.version = version
            self.team = team
            self.exportedAt = exportedAt
            self.exportedBy = exportedBy
            self.objects = objects
            self.members = members
            self.packs = packs
            self.flows = flows
            self.snippets = snippets
            self.standards = standards
        }
    }

    public enum ShareError: Error, Equatable, CustomStringConvertible {
        case notAllowed(Role)
        case wrongKey
        case corrupted
        case unsupportedVersion(Int)

        public var description: String {
            switch self {
            case .notAllowed(let role):
                L("Your role (%@) does not allow that.", role.rawValue)
            case .wrongKey:
                L("The team key does not open this package.")
            case .corrupted:
                L("The package is damaged, or it is not from BeLauncher.")
            case .unsupportedVersion(let version):
                L("This package was written by a newer version (format %@).", String(version))
            }
        }
    }

    // MARK: - What is shared

    /// Only objects explicitly marked as shared leave the Mac. Personal memory is personal:
    /// exporting everything by default is how a "team feature" becomes a leak.
    public static let sharedMarker = "shared"

    public static func shareable(_ objects: [MemoryObject]) -> [MemoryObject] {
        objects.filter { object in
            object.level == .committed
                && object.entities.contains { $0.lowercased() == sharedMarker }
        }
    }

    // MARK: - Sealing

    /// A key derived from a passphrase the team already shares by other means. No account, no
    /// server, nothing of ours in the path.
    public static func key(fromPassphrase passphrase: String, team: String) -> SymmetricKey {
        let salt = Data(("belauncher.team." + team.lowercased()).utf8)
        let material = SHA256.hash(data: Data(passphrase.utf8) + salt)
        return SymmetricKey(data: material)
    }

    public static func seal(_ bundle: Bundle, with key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(bundle)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw ShareError.corrupted }
        return combined
    }

    public static func open(_ data: Data, with key: SymmetricKey) throws -> Bundle {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: data)
        } catch {
            throw ShareError.corrupted
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            // Authenticated encryption cannot tell "wrong key" from "tampered with", and that is
            // the right answer either way: do not trust it.
            throw ShareError.wrongKey
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(Bundle.self, from: plaintext) else {
            throw ShareError.corrupted
        }
        guard bundle.version <= Bundle.currentVersion else {
            throw ShareError.unsupportedVersion(bundle.version)
        }
        return bundle
    }

    // MARK: - Merging

    public struct MergeResult: Sendable, Equatable {
        public var added: [MemoryObject] = []
        /// Incoming objects that would replace something the local brain believes.
        public var conflicts: [(incoming: MemoryObject, existing: MemoryObject)] = []
        public var skipped = 0

        public static func == (lhs: MergeResult, rhs: MergeResult) -> Bool {
            lhs.added == rhs.added && lhs.skipped == rhs.skipped
                && lhs.conflicts.map(\.incoming) == rhs.conflicts.map(\.incoming)
        }
    }

    /// The entities that are actually subjects. The share marker is bookkeeping, not a topic:
    /// counting it as one made every shared memory collide with every other shared memory.
    static func topics(of object: MemoryObject) -> Set<String> {
        Set(object.entities.map { $0.lowercased() }).subtracting([sharedMarker])
    }

    /// What a shared bundle would add beyond memory: commands, flows, snippets and the standards
    /// that make them the company's rather than the model's.
    ///
    /// Kept separate from the memory merge because the rules differ. A memory that contradicts one
    /// you hold is a conflict for a person to settle. A command whose verb is already taken is a
    /// collision that must simply be refused: two things answering to `/propuesta` means half the
    /// time the wrong one runs and nobody can tell which.
    public struct CommandMerge: Sendable, Equatable {
        public var packs: [OutcomePack] = []
        public var flows: [Flow] = []
        public var snippets: [Snippet] = []
        public var standards: [OutcomePack.Rule] = []
        /// Refused because their name is already in use here.
        public var refused: [String] = []
    }

    /// Works out what an incoming bundle's commands would change, without changing anything.
    ///
    /// Anything of the person's own wins. A team pack is a proposal, exactly like a team memory:
    /// nothing a colleague exported may quietly replace something you built.
    public static func planCommands(
        _ bundle: Bundle, installedPacks: [OutcomePack], flows: [Flow], snippets: [Snippet]
    ) -> CommandMerge {
        var merge = CommandMerge(standards: bundle.standards)
        let takenVerbs = Set(installedPacks.map(\.verb))
            .union(flows.map(\.keyword))
            .union(snippets.map(\.keyword))

        for pack in bundle.packs {
            if takenVerbs.contains(pack.verb), !installedPacks.contains(where: { $0.id == pack.id }) {
                merge.refused.append("/\(pack.verb)")
            } else {
                // The team's standards travel with the command, or the command is just a name.
                var copy = pack
                copy.rules = pack.rules + bundle.standards.filter { standard in
                    !pack.rules.contains { $0.name == standard.name }
                }
                merge.packs.append(copy)
            }
        }
        let existingFlows = Set(flows.map(\.keyword))
        for flow in bundle.flows {
            existingFlows.contains(flow.keyword)
                ? merge.refused.append(flow.keyword)
                : merge.flows.append(flow)
        }
        let existingSnippets = Set(snippets.map(\.keyword))
        for snippet in bundle.snippets {
            existingSnippets.contains(snippet.keyword)
                ? merge.refused.append(snippet.keyword)
                : merge.snippets.append(snippet)
        }
        return merge
    }

    /// Works out what an incoming bundle would change, without changing anything.
    ///
    /// Nothing arrives silently, exactly as with a local capture: a teammate's decision is a
    /// proposal on your Mac until you accept it. A brain that rewrites itself from the network is
    /// a brain you cannot trust.
    public static func plan(_ bundle: Bundle, against local: [MemoryObject]) -> MergeResult {
        var result = MergeResult()
        let byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

        for incoming in bundle.objects {
            if let existing = byID[incoming.id] {
                // Same object: only newer versions are interesting.
                if incoming.validFrom > existing.validFrom || incoming.status != existing.status {
                    result.conflicts.append((incoming, existing))
                } else {
                    result.skipped += 1
                }
                continue
            }
            if let clash = local.first(where: {
                $0.kind == incoming.kind && $0.isCurrent()
                    && !topics(of: $0).isDisjoint(with: topics(of: incoming))
                    && $0.statement.caseInsensitiveCompare(incoming.statement) != .orderedSame
            }) {
                result.conflicts.append((incoming, clash))
            } else {
                result.added.append(incoming)
            }
        }
        return result
    }
}
