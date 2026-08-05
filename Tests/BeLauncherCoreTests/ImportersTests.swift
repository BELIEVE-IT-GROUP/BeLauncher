import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Importing from Alfred and Raycast")
struct ImportersTests {

    @Test("an Alfred snippet keeps its keyword and text")
    func alfredSnippet() {
        let json = #"""
        {"alfredsnippet":{"snippet":"Un saludo,\n{cursor}","uid":"x","name":"Firma","keyword":"sig"}}
        """#
        let snippet = Importers.parseAlfredSnippet(Data(json.utf8))
        #expect(snippet?.keyword == "sig")
        #expect(snippet?.title == "Firma")
        #expect(snippet?.body.contains("{cursor}") == true)
    }

    @Test("an Alfred snippet with no keyword gets one from its name")
    func alfredWithoutKeyword() {
        let json = #"{"alfredsnippet":{"snippet":"hola","name":"Saludo Rápido","keyword":""}}"#
        #expect(Importers.parseAlfredSnippet(Data(json.utf8))?.keyword == "saludo-rapido")
    }

    @Test("malformed or empty Alfred files are refused, not imported blank")
    func alfredRejects() {
        #expect(Importers.parseAlfredSnippet(Data("{}".utf8)) == nil)
        #expect(Importers.parseAlfredSnippet(Data("no json".utf8)) == nil)
        #expect(Importers.parseAlfredSnippet(Data(#"{"alfredsnippet":{"snippet":""}}"#.utf8)) == nil)
    }

    @Test("a Raycast export brings snippets and quicklinks apart")
    func raycastExport() {
        let json = #"""
        [
          {"name":"Firma","keyword":"sig","text":"Un saludo"},
          {"name":"Buscar en GitHub","keyword":"gh","link":"https://github.com/search?q={argument}"},
          {"name":"Roto","link":"file:///etc/passwd"},
          {"name":"Vacío"}
        ]
        """#
        let result = Importers.parseRaycastExport(Data(json.utf8))
        #expect(result.snippets.map(\.keyword) == ["sig"])
        #expect(result.workflows.count == 1)
        #expect(result.workflows.first?.urlTemplate == "https://github.com/search?q={query}",
                "{argument} is Raycast's placeholder, {query} is ours")
        #expect(result.skipped.count == 2, "a file:// link and an empty entry must be reported")
    }

    @Test("placeholders that have an equivalent are converted, the rest stay visible")
    func placeholders() {
        let converted = Importers.convertPlaceholders("Hola {argument}, hoy es {date}. {unknown}")
        #expect(converted.contains("{query}"))
        #expect(converted.contains("{date}"))
        #expect(converted.contains("{unknown}"), "an unknown placeholder must stay visible")
    }

    @Test("importing never overwrites what you already had")
    @MainActor
    func doesNotOverwrite() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-import-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)
        try store.addSnippet(keyword: "sig", title: "La mía", body: "no me toques")

        var incoming = Importers.Result()
        incoming.snippets = [
            Snippet(keyword: "sig", title: "De Alfred", body: "otra cosa"),
            Snippet(keyword: "nuevo", title: "Nuevo", body: "texto"),
        ]
        incoming.skipped = ["archivo-roto.json"]

        let summary = store.apply(incoming)
        #expect(summary.addedSnippets == 1)
        #expect(summary.skipped == 2, "the duplicate plus the file that could not be parsed")
        #expect(store.snippets().first { $0.keyword == "sig" }?.body == "no me toques")
    }

    @Test("a folder that is not there imports nothing instead of failing")
    func missingFolder() {
        let result = Importers.importAlfredSnippets(from: "/tmp/no-existe-\(UUID().uuidString)")
        #expect(result.snippets.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test("a real folder of Alfred snippets is walked, collections included")
    func walksFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alfred-\(UUID().uuidString)")
        let collection = root.appendingPathComponent("Trabajo")
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        try #"{"alfredsnippet":{"snippet":"hola","name":"Saludo","keyword":"hi"}}"#
            .write(to: collection.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        try "roto".write(to: collection.appendingPathComponent("b.json"),
                         atomically: true, encoding: .utf8)

        let result = Importers.importAlfredSnippets(from: root.path)
        #expect(result.snippets.map(\.keyword) == ["hi"])
        #expect(result.skipped == ["b.json"])
    }
}
