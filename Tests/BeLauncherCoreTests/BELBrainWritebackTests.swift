import Foundation
import Testing
@testable import BeLauncherCore

@Suite("AI brain writeback")
@MainActor
struct BELBrainWritebackTests {
    private func vault() throws -> Vault {
        try Vault(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("writeback-\(UUID().uuidString)").path)
    }

    @Test("valid model JSON becomes a proposal, never a committed object")
    func proposalOnly() throws {
        let vault = try vault()
        let commit = try BELBrainWriteback.propose(
            json: "{\"statement\":\"Precio Pro: 59\",\"kind\":\"decision\",\"entities\":[\"Pro\"]}",
            vault: vault
        )

        #expect(commit.state == .proposed)
        #expect(vault.current().isEmpty)
        #expect(vault.commits(state: .proposed).count == 1)
        #expect(vault.aiAuditEvents().map(\.action) == [.proposalRecorded])
    }

    @Test("confirmation is explicit and makes the object current")
    func confirm() throws {
        let vault = try vault()
        let commit = try BELBrainWriteback.propose(
            json: "{\"statement\":\"Usar Ollama\",\"kind\":\"policy\"}", vault: vault)
        let object = try BELBrainWriteback.confirm(commitID: commit.id, in: vault)

        #expect(object.level == .committed)
        #expect(vault.current().map(\.id) == [object.id])
        #expect(vault.aiAuditEvents().map(\.action) == [.proposalRecorded, .proposalConfirmed])
    }

    @Test("invalid or unknown model output cannot reach the vault")
    func rejectsUnsafeOutput() throws {
        let vault = try vault()
        #expect(throws: BELStructuredOutputError.invalidJSON) {
            try BELBrainWriteback.propose(json: "not json", vault: vault)
        }
        #expect(throws: BELWritebackError.invalidKind("guess")) {
            try BELBrainWriteback.propose(
                json: "{\"statement\":\"x\",\"kind\":\"guess\"}", vault: vault)
        }
        #expect(vault.commits().isEmpty)
    }

    @Test("saving evidence is typed, durable and does not become a memory")
    func savesEvidenceOnly() throws {
        let vault = try vault()
        let path = try BELBrainWriteback.save(
            json: "{\"title\":\"Call\",\"text\":\"A source note\"}", vault: vault)

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(vault.objects().isEmpty)
        #expect(vault.aiAuditEvents().last?.action == .evidenceSaved)
    }

    @Test("project updates are proposals until a person confirms them")
    func projectUpdateIsProposed() throws {
        let vault = try vault()
        let commit = try BELBrainWriteback.updateProject(
            json: "{\"statement\":\"Atlas está en beta\",\"entities\":[\"Atlas\"]}",
            vault: vault)

        #expect(commit.object.kind == .project)
        #expect(vault.current().isEmpty)
        #expect(vault.commits(state: .proposed).count == 1)
    }

    @Test("forget requires an explicit confirmation call and is audited")
    func forgetIsTwoStep() throws {
        let storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("writeback-store-\(UUID().uuidString)/store.sqlite3").path
        let store = try Store(path: storePath)
        let vault = try vault()
        let at = Date(timeIntervalSince1970: 2_000_000)
        _ = store.recordClip(text: "private", sourceApp: "Test", at: at)
        let period = Privacy.Period(from: at.addingTimeInterval(-1), to: at.addingTimeInterval(1))

        let preview = try BELBrainWriteback.previewForget(period, store: store, vault: vault, date: at)
        #expect(preview.clips == 1)
        #expect(store.clips().count == 1)
        _ = try BELBrainWriteback.confirmForget(period, store: store, vault: vault, date: at)
        #expect(store.clips().isEmpty)
        #expect(vault.aiAuditEvents().map(\.action) == [.forgetPreviewed, .forgetConfirmed])
    }
}
