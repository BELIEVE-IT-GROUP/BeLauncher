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
    }

    @Test("confirmation is explicit and makes the object current")
    func confirm() throws {
        let vault = try vault()
        let commit = try BELBrainWriteback.propose(
            json: "{\"statement\":\"Usar Ollama\",\"kind\":\"policy\"}", vault: vault)
        let object = try BELBrainWriteback.confirm(commitID: commit.id, in: vault)

        #expect(object.level == .committed)
        #expect(vault.current().map(\.id) == [object.id])
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
}
