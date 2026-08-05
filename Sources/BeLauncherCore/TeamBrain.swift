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

        public init(version: Int = Bundle.currentVersion, team: String, exportedAt: Date = .now,
                    exportedBy: String, objects: [MemoryObject], members: [Member]) {
            self.version = version
            self.team = team
            self.exportedAt = exportedAt
            self.exportedBy = exportedBy
            self.objects = objects
            self.members = members
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
                "Tu rol (\(role.rawValue)) no permite hacer eso."
            case .wrongKey:
                "La clave del equipo no abre este paquete."
            case .corrupted:
                "El paquete está dañado o no es de BeLauncher."
            case .unsupportedVersion(let version):
                "Este paquete lo escribió una versión más nueva (formato \(version))."
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
