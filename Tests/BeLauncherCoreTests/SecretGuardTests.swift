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

    @Test("launch maintenance purges a bounded recent batch")
    @MainActor
    func boundedPurgeDoesNotWalkTheWholeHistory() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-bounded-purge-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)
        try store.database.execute(
            "INSERT INTO clips (text, digest, source_app, created_at) VALUES (?, ?, '', ?)",
            [.text(token("sk_", "live_0000EXAMPLEEXAMPLEEXAMPLE0000")), .text("old-secret"), .double(1)]
        )
        try store.database.execute(
            "INSERT INTO clips (text, digest, source_app, created_at) VALUES (?, ?, '', ?)",
            [.text("newer one"), .text("newer-1"), .double(2)]
        )
        try store.database.execute(
            "INSERT INTO clips (text, digest, source_app, created_at) VALUES (?, ?, '', ?)",
            [.text("newer two"), .text("newer-2"), .double(3)]
        )

        #expect(store.purgeSecrets(limit: 2) == 0)
        #expect(store.clips(limit: 10).contains { $0.text.contains("EXAMPLE") })
    }
}

@Suite("Un token, envuelto como venga")
struct CarriesSecretTests {

    /// Las siete formas exactas que se escaparon en la re-auditoría, cada una una manera real en
    /// que un token acaba dentro de una frase. Las dos primeras rondas de arreglo tokenizaban con
    /// una lista de signos escrita a mano y a las dos les faltaba algún signo.
    @Test("Un token dentro de una URL de git no se escapa")
    func insideGitURL() {
        #expect(SecretGuard.carriesSecret(
            "El repo se clona desde https://ghp_16CharactersAndThenSomeMore1234567@github.com/acme/infra.git"))
    }

    @Test("Un token después de un igual no se escapa, aunque el nombre no esté en ninguna lista")
    func afterEquals() {
        #expect(SecretGuard.carriesSecret("GITHUB_KEY=ghp_16CharactersAndThenSomeMore1234567"))
        #expect(SecretGuard.carriesSecret("AUTH=sk-ant-api03-DEADBEEFDEADBEEFDEADBEEF"))
        #expect(SecretGuard.carriesSecret("key=sk_live_51ABCDEFGHIJKLMNOPQRSTUVWX"))
    }

    @Test("Un token dentro de una ruta no se escapa")
    func insidePath() {
        #expect(SecretGuard.carriesSecret("/Users/mac/.config/ghp_16CharactersAndThenSomeMore1234567"))
    }

    @Test("Un token pegado a una arroba o a una barra no se escapa")
    func gluedToPunctuation() {
        #expect(SecretGuard.carriesSecret("mándalo a @sk-ant-api03-DEADBEEFDEADBEEFDEADBEEF"))
        #expect(SecretGuard.carriesSecret("auth/sk_live_51ABCDEFGHIJKLMNOPQRSTUVWX"))
    }

    @Test("Un token con markdown o comillas alrededor no se escapa")
    func decorated() {
        #expect(SecretGuard.carriesSecret("la clave es **sk-ant-api03-DEADBEEFDEADBEEFDEADBEEF**"))
        #expect(SecretGuard.carriesSecret("«ghp_16CharactersAndThenSomeMore1234567»"))
        #expect(SecretGuard.carriesSecret("{\"apiKey\":\"sk-ant-api03-DEADBEEFDEADBEEFDEADBEEF\"}"))
    }

    @Test("Un token en cualquier línea de un texto largo no se escapa")
    func anyLine() {
        #expect(SecretGuard.carriesSecret("""
        Notas de la reunión con Acme.
        Quedamos el jueves a las 10.
        - 12:00 · Archivo · AKIAIOSFODNN7EXAMPLEKEY
        """))
    }

    /// El otro lado, que importa igual: tirar texto normal en silencio deja al usuario sin
    /// memoria y sin saber por qué.
    @Test("El filtro no es una escoba: el texto normal pasa")
    func ordinaryTextSurvives() {
        for line in [
            "La reunión con Acme quedó movida al jueves a las 10:00",
            "Hay que rotar el token de GitHub antes de fin de mes",
            "El precio base del plan Pro es 1000 euros al mes",
            "https://github.com/acme/infra/pull/1234",
            "clave: 4",
            "El monkey patch de la librería está en utils.swift",
        ] {
            #expect(!SecretGuard.carriesSecret(line), "descartó texto normal: \(line)")
        }
    }
}

@Suite("Las formas que midió la auditoría")
struct MeasuredLeakTests {

    /// Cada una salió de verdad en una sonda contra el módulo real. El comentario que estaba en
    /// `namesASecret` afirmaba que `GITHUB_KEY` se partía en dos y se detectaba; no lo hacía,
    /// porque el guion bajo contaba como parte del token.
    @Test("Un nombre compuesto delante del igual sí se detecta")
    func compoundNames() {
        #expect(SecretGuard.carriesSecret("SUPABASE_SERVICE_ROLE_KEY=9f8a7b6c5d4e3f2a1b0c9d8e"))
        #expect(SecretGuard.carriesSecret("GITHUB_KEY=9f8a7b6c5d4e3f2a1b0c9d8e"))
        #expect(SecretGuard.carriesSecret("MY_APP_SECRET=9f8a7b6c5d4e3f2a1b0c9d8e"))
    }

    @Test("Una cabecera de autorización no se escapa por los dos puntos de otra cosa")
    func headers() {
        #expect(SecretGuard.carriesSecret("Authorization: Bearer 9f8a7b6c5d4e3f2a1b0c9d8e7f6a"))
        #expect(SecretGuard.carriesSecret("x-api-key: 9f8a7b6c5d4e3f2a1b0c9d8e7f6a"))
    }

    @Test("Un token en el parámetro de una URL no se escapa")
    func urlParameter() {
        #expect(SecretGuard.carriesSecret("https://x.com/a?token=9f8a7b6c5d4e3f2a1b0c9d8e"))
    }

    @Test("Una cadena de conexión con contraseña dentro no se escapa")
    func connectionString() {
        // Es lo más dañino que puede salir de la app y no se parece a un token: sin prefijo, sin
        // nombre, solo dos puntos en medio de una URL.
        #expect(SecretGuard.carriesSecret("postgres://usuario:hunter2secreto@host:5432/db"))
        #expect(SecretGuard.carriesSecret("https://admin:hunter2secreto@panel.example.com"))
    }

    @Test("Y el texto normal con dos puntos sigue pasando")
    func ordinarySurvives() {
        for line in [
            "Nota: hay que rotar la clave antes del viernes",
            "Reunión: jueves a las 10:00 con Acme",
            "https://github.com/acme/infra/pull/1234",
            "Clave: 4",
            "correo: jorge@believe-global.com",
        ] {
            #expect(!SecretGuard.carriesSecret(line), "descartó texto normal: \(line)")
        }
    }
}
