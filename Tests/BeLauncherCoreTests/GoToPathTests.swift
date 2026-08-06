import Testing
import Foundation
@testable import BeLauncherCore

/// Pegar una ruta y entrar. La regla: no confundir cualquier palabra con una ruta.
@Suite("Ir a una ruta")
struct GoToPathTests {

    static let home = "/Users/prueba"

    @Test("solo las formas que son inequívocamente una ruta")
    func narrowOnPurpose() {
        #expect(GoToPath.looksLikePath("/Users/mac/Developer"))
        #expect(GoToPath.looksLikePath("~/Desktop"))
        #expect(GoToPath.looksLikePath("./docs"))
        #expect(GoToPath.looksLikePath("../src"))
        #expect(GoToPath.looksLikePath("file:///Users/mac"))

        // Si cualquier palabra fuera una ruta, la lista se llenaría de cosas que no existen.
        #expect(!GoToPath.looksLikePath("notion"))
        #expect(!GoToPath.looksLikePath("Users/mac"))
        #expect(!GoToPath.looksLikePath("/"))
        #expect(!GoToPath.looksLikePath(""))
    }

    @Test("la tilde se expande a la carpeta personal")
    func expandsTilde() {
        #expect(GoToPath.expand("~", home: Self.home) == Self.home)
        #expect(GoToPath.expand("~/Desktop", home: Self.home) == "/Users/prueba/Desktop")
    }

    @Test("una URL de archivo pegada del navegador funciona, con espacios y todo")
    func handlesFileURLs() {
        #expect(GoToPath.expand("file:///Users/mac/Documentos") == "/Users/mac/Documentos")
        // Los espacios llegan codificados desde un navegador o un chat.
        #expect(GoToPath.expand("file:///Users/mac/Mi%20Carpeta") == "/Users/mac/Mi Carpeta")
    }

    @Test("una ruta copiada de un terminal trae las barras invertidas")
    func handlesShellEscaping() {
        #expect(GoToPath.expand("/Users/mac/Mi\\ Carpeta") == "/Users/mac/Mi Carpeta")
    }

    @Test("una carpeta que existe se ofrece para entrar")
    func resolvesExisting() throws {
        let target = try #require(GoToPath.resolve(
            "/x/proyecto", home: Self.home,
            contents: { _ in [] }, exists: { _ in (true, true) }
        ))
        #expect(target.exists)
        #expect(target.isDirectory)
        #expect(target.name == "proyecto")
        // Tab añade la barra para seguir escribiendo dentro.
        #expect(target.completion == "/x/proyecto/")
    }

    @Test("con una sola coincidencia, Tab la completa")
    func completesWhenUnambiguous() throws {
        let target = try #require(GoToPath.resolve(
            "/x/Dev", home: Self.home,
            contents: { _ in ["Developer", "Documentos"] },
            exists: { path in (path == "/x", true) }
        ))
        #expect(target.completion == "/x/Developer")
    }

    @Test("con varias coincidencias no completa, porque eso sería adivinar")
    func refusesToGuess() throws {
        let target = try #require(GoToPath.resolve(
            "/x/D", home: Self.home,
            contents: { _ in ["Developer", "Documentos", "Descargas"] },
            exists: { path in (path == "/x", true) }
        ))
        #expect(target.completion == nil)
        #expect(!target.exists)
    }

    @Test("los archivos ocultos no se completan solos")
    func ignoresDotfiles() throws {
        let target = try #require(GoToPath.resolve(
            "/x/.g", home: Self.home,
            contents: { _ in [".git", ".gitignore"] },
            exists: { path in (path == "/x", true) }
        ))
        #expect(target.completion == nil)
    }

    @Test("si no existe, dice qué parte falla y dónde")
    func explainsWhatIsMissing() throws {
        let target = try #require(GoToPath.resolve(
            "/x/noexiste", home: Self.home,
            contents: { _ in [] }, exists: { path in (path == "/x", true) }
        ))
        let message = GoToPath.explain(target)
        #expect(message.contains("noexiste"))
        #expect(message.contains("/x"), "decir solo «no existe» no ayuda a nadie")
    }

    @Test("lo que no parece una ruta no produce nada")
    func staysOutOfTheWay() {
        #expect(GoToPath.resolve("notion") == nil)
        #expect(GoToPath.resolve("qué decidimos sobre precios") == nil)
    }
}
