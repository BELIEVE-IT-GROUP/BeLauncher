import Testing
import Foundation
import CryptoKit
@testable import BeLauncherCore

@Suite("Sharing a brain without giving it away")
struct TeamBrainTests {

    private func object(_ statement: String, entities: [String] = ["shared", "pricing"],
                        from: Double = -100) -> MemoryObject {
        MemoryObject(level: .committed, kind: .decision, statement: statement,
                     source: "Reunión", owner: "Jorge",
                     createdAt: .now.addingTimeInterval(from),
                     validFrom: .now.addingTimeInterval(from), entities: entities)
    }

    private func bundle(_ objects: [MemoryObject]) -> TeamBrain.Bundle {
        TeamBrain.Bundle(team: "believe", exportedBy: "jorge@believe-global.com",
                         objects: objects,
                         members: [.init(email: "jorge@believe-global.com", name: "Jorge",
                                         role: .owner)])
    }

    // MARK: - What leaves the Mac

    @Test("personal memory never leaves, only what was marked as shared")
    func onlyMarkedObjectsTravel() {
        let personal = object("Nota mía sobre el precio", entities: ["pricing"])
        let shared = object("Precio enterprise 2000", entities: ["shared", "pricing"])
        var draft = object("Todavía una propuesta", entities: ["shared"])
        draft.level = .extracted

        let shareable = TeamBrain.shareable([personal, shared, draft])
        #expect(shareable.map(\.statement) == ["Precio enterprise 2000"],
                "exporting everything by default is how a team feature becomes a leak")
    }

    // MARK: - Encryption

    @Test("a bundle round-trips through the team key")
    func sealAndOpen() throws {
        let key = TeamBrain.key(fromPassphrase: "la frase del equipo", team: "believe")
        let sealed = try TeamBrain.seal(bundle([object("Precio enterprise 2000")]), with: key)

        #expect(!String(decoding: sealed, as: UTF8.self).contains("Precio"),
                "the ciphertext must not carry the plaintext")

        let opened = try TeamBrain.open(sealed, with: key)
        #expect(opened.objects.first?.statement == "Precio enterprise 2000")
        #expect(opened.team == "believe")
    }

    @Test("the wrong passphrase opens nothing")
    func wrongKey() throws {
        let sealed = try TeamBrain.seal(
            bundle([object("Secreto")]),
            with: TeamBrain.key(fromPassphrase: "correcta", team: "believe")
        )
        #expect(throws: TeamBrain.ShareError.wrongKey) {
            try TeamBrain.open(sealed, with: TeamBrain.key(fromPassphrase: "otra", team: "believe"))
        }
    }

    @Test("the same passphrase in another team is a different key")
    func teamScopedKeys() throws {
        let sealed = try TeamBrain.seal(
            bundle([object("Secreto")]),
            with: TeamBrain.key(fromPassphrase: "misma frase", team: "believe")
        )
        #expect(throws: TeamBrain.ShareError.wrongKey) {
            try TeamBrain.open(sealed,
                               with: TeamBrain.key(fromPassphrase: "misma frase", team: "otra"))
        }
    }

    @Test("a tampered bundle is refused rather than half-trusted")
    func tamperDetected() throws {
        let key = TeamBrain.key(fromPassphrase: "frase", team: "believe")
        var sealed = try TeamBrain.seal(bundle([object("Precio 2000")]), with: key)
        sealed[sealed.count - 5] ^= 0xFF

        #expect(throws: TeamBrain.ShareError.wrongKey) { try TeamBrain.open(sealed, with: key) }
    }

    @Test("garbage is refused with a clear reason")
    func refusesGarbage() {
        let key = TeamBrain.key(fromPassphrase: "frase", team: "believe")
        #expect(throws: TeamBrain.ShareError.corrupted) {
            try TeamBrain.open(Data("no soy un paquete".utf8), with: key)
        }
    }

    // MARK: - Roles

    @Test("roles say who may confirm and who may manage people")
    func roles() {
        #expect(TeamBrain.Role.reader.canConfirm == false)
        #expect(TeamBrain.Role.editor.canConfirm)
        #expect(TeamBrain.Role.owner.canConfirm)

        #expect(TeamBrain.Role.editor.canManageMembers == false)
        #expect(TeamBrain.Role.owner.canManageMembers)
        #expect(TeamBrain.Role.reader < TeamBrain.Role.editor)
    }

    // MARK: - Merging

    @Test("a teammate's memory arrives as a proposal, never as a fact")
    func incomingIsPlannedNotApplied() {
        let local = [object("Precio enterprise 1500")]
        let incoming = bundle([object("Precio enterprise 2000", from: -10)])

        let plan = TeamBrain.plan(incoming, against: local)
        #expect(plan.added.isEmpty)
        #expect(plan.conflicts.count == 1, "it contradicts what this Mac believes: ask, do not apply")
        #expect(plan.conflicts.first?.existing.statement == "Precio enterprise 1500")
    }

    @Test("something genuinely new arrives as an addition")
    func newObjectsAdded() {
        let incoming = bundle([object("Vacaciones cerradas en agosto", entities: ["shared", "hr"])])
        let plan = TeamBrain.plan(incoming, against: [object("Precio enterprise 1500")])
        #expect(plan.added.count == 1)
        #expect(plan.conflicts.isEmpty)
    }

    @Test("the share marker is not a topic: two shared memories do not collide by being shared")
    func markerIsNotATopic() {
        let plan = TeamBrain.plan(
            bundle([object("Vacaciones en agosto", entities: ["shared", "hr"])]),
            against: [object("Precio enterprise 1500", entities: ["shared", "pricing"])]
        )
        #expect(plan.conflicts.isEmpty)
        #expect(plan.added.count == 1)
    }

    @Test("what this Mac already has is skipped, not duplicated")
    func alreadyKnown() {
        let existing = object("Precio enterprise 2000")
        let plan = TeamBrain.plan(bundle([existing]), against: [existing])
        #expect(plan.skipped == 1)
        #expect(plan.added.isEmpty)
        #expect(plan.conflicts.isEmpty)
    }

    @Test("a newer version of the same object is offered, not forced")
    func newerVersionOfSameObject() {
        var older = object("Precio enterprise 2000", from: -1000)
        var newer = older
        newer.validFrom = Date.now.addingTimeInterval(-10)
        older.status = .active
        newer.status = .superseded

        let plan = TeamBrain.plan(bundle([newer]), against: [older])
        #expect(plan.conflicts.count == 1, "a brain that rewrites itself from the network is one you cannot trust")
    }
}
