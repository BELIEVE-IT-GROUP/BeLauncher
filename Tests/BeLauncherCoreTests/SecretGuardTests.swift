import Testing
import Foundation
@testable import BeLauncherCore

/// Token literals are assembled at runtime: writing them out would trip GitHub's push
/// protection, and a test fixture is not worth a blocked repository.
private func token(_ prefix: String, _ body: String) -> String { prefix + body }

@Suite("Secret guard")
struct SecretGuardTests {

    @Test("credential-shaped tokens are refused")
    func refusesTokens() {
        #expect(SecretGuard.looksLikeSecret(token("sk_", "live_0000EXAMPLEEXAMPLEEXAMPLE0000")))
        #expect(SecretGuard.looksLikeSecret(token("ghp", "_16CharactersAndThenSomeMore1234567")))
        #expect(SecretGuard.looksLikeSecret("AKIAIOSFODNN7EXAMPLE12345"))
        #expect(SecretGuard.looksLikeSecret("xoxb-123456789012-1234567890123-abcdefgh"))
        #expect(SecretGuard.looksLikeSecret("sk-ant-api03-aaaaaaaaaaaaaaaaaaaaaaaaaa"))
    }

    @Test("assignments whose name says secret are refused")
    func refusesAssignments() {
        #expect(SecretGuard.looksLikeSecret("STRIPE_SECRET_KEY=abc123"))
        #expect(SecretGuard.looksLikeSecret("export DATABASE_PASSWORD=hunter2"))
        #expect(SecretGuard.looksLikeSecret("api_key: 8f3a9c"))
    }

    @Test("private keys and JWTs are refused")
    func refusesKeyBlocks() {
        #expect(SecretGuard.looksLikeSecret("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n"))
        #expect(SecretGuard.looksLikeSecret(
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"
        ))
    }

    @Test("ordinary text is kept — a guard that eats normal copies is worse than none")
    func keepsOrdinaryText() {
        #expect(!SecretGuard.looksLikeSecret("https://belauncher.app"))
        #expect(!SecretGuard.looksLikeSecret("Reunión el martes a las 10"))
        #expect(!SecretGuard.looksLikeSecret("git commit -m \"fix: rename\""))
        #expect(!SecretGuard.looksLikeSecret("name: BeLauncher"))
        #expect(!SecretGuard.looksLikeSecret(token("sk_", "live_short")))     // too short to be a real key
        #expect(!SecretGuard.looksLikeSecret(""))
        #expect(!SecretGuard.looksLikeSecret("El total: 45"))
    }

    @Test("the store refuses to write them at all")
    @MainActor
    func storeRefuses() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-secret-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)
        store.recordClip(text: token("sk_", "live_0000EXAMPLEEXAMPLEEXAMPLE0000"))
        store.recordClip(text: "una nota normal")
        #expect(store.clips().map(\.text) == ["una nota normal"])
    }

    @Test("secrets captured before the guard existed are purged on launch")
    @MainActor
    func purgesExistingSecrets() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-purge-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)
        // Written directly, the way an older build would have stored it.
        try store.database.execute(
            "INSERT INTO clips (text, digest, source_app, created_at) VALUES (?, ?, '', ?)",
            [.text(token("sk_", "live_0000EXAMPLEEXAMPLEEXAMPLE0000")), .text("d1"), .double(1)]
        )
        try store.database.execute(
            "INSERT INTO clips (text, digest, source_app, created_at) VALUES (?, ?, '', ?)",
            [.text("texto normal"), .text("d2"), .double(2)]
        )
        #expect(store.purgeSecrets() == 1)
        #expect(store.clips().map(\.text) == ["texto normal"])
    }
}
