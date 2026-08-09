import Testing
import Foundation
@testable import BeLauncherCore

@MainActor
private func temporaryStore() throws -> Store {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("belauncher-test-\(UUID().uuidString)")
        .appendingPathComponent("test.sqlite3").path
    return try Store(path: path)
}

@Suite("Store")
@MainActor
struct StoreTests {

    @Test("snippets round-trip and reject invalid input")
    func snippetValidation() throws {
        let store = try temporaryStore()
        try store.addSnippet(keyword: "  SIG ", title: "Signature", body: "bye")
        #expect(store.snippets().count == 1)
        #expect(store.snippets()[0].keyword == "sig")   // normalised

        #expect(throws: ValidationError.duplicateKeyword("sig")) {
            try store.addSnippet(keyword: "sig", title: "Other", body: "x")
        }
        #expect(throws: ValidationError.keywordHasWhitespace) {
            try store.addSnippet(keyword: "two words", title: "T", body: "x")
        }
        #expect(throws: ValidationError.emptyBody) {
            try store.addSnippet(keyword: "k", title: "T", body: "   ")
        }
    }

    @Test("workflows reject templates that are not web URLs")
    func workflowValidation() throws {
        let store = try temporaryStore()
        try store.addWorkflow(keyword: "gh", title: "GitHub", urlTemplate: "https://github.com/search?q={query}")
        #expect(store.workflows().count == 1)
        #expect(throws: ValidationError.self) {
            try store.addWorkflow(keyword: "sh", title: "Shell", urlTemplate: "file:///bin/sh")
        }
    }

    @Test("re-copying the same text moves it up instead of duplicating")
    func clipDeduplication() throws {
        let store = try temporaryStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.recordClip(text: "one", at: start)
        store.recordClip(text: "two", at: start.addingTimeInterval(1))
        store.recordClip(text: "one", at: start.addingTimeInterval(2))
        #expect(store.clips().count == 2)
        #expect(store.clips().first?.text == "one")
    }

    @Test("blank clips are ignored")
    func ignoresBlankClips() throws {
        let store = try temporaryStore()
        store.recordClip(text: "   \n ")
        #expect(store.clips().isEmpty)
    }

    @Test("trimming honours retention and item count")
    func trimming() throws {
        let store = try temporaryStore()
        let now = Date(timeIntervalSince1970: 2_000_000)
        store.recordClip(text: "old", at: now.addingTimeInterval(-40 * 86_400))
        store.recordClip(text: "recent", at: now)
        store.trimClips(retentionDays: 30, maxItems: 500, now: now)
        #expect(store.clips().map(\.text) == ["recent"])

        for index in 0..<5 { store.recordClip(text: "clip \(index)", at: now.addingTimeInterval(Double(index))) }
        store.trimClips(retentionDays: 0, maxItems: 3, now: now)
        #expect(store.clips().count == 3)
    }

    @Test("quick commands appear for everyone, without ever overwriting an edited one")
    func quickCommands() throws {
        let store = try temporaryStore()
        // Someone who already made their own "g" keeps it.
        try store.addWorkflow(keyword: "g", title: "Mi propio Google", urlTemplate: "https://duckduckgo.com/?q={query}")

        store.ensureQuickCommands()
        let byKeyword = Dictionary(uniqueKeysWithValues: store.workflows().map { ($0.keyword, $0) })
        #expect(byKeyword["g"]?.title == "Mi propio Google")
        #expect(byKeyword["c"]?.title == "Preguntar a Claude")
        #expect(byKeyword["gpt"] != nil)
        #expect(byKeyword["p"] != nil)
        #expect(byKeyword["yt"] != nil)

        // Running again on every launch must not duplicate anything.
        store.ensureQuickCommands()
        #expect(store.workflows().count == byKeyword.count)

        // And they actually build a usable URL.
        let claude = try #require(byKeyword["c"])
        #expect(WorkflowURL.build(template: claude.urlTemplate, query: "swift 6 concurrency")?.absoluteString
            == "https://claude.ai/new?q=swift%206%20concurrency")
    }

    @Test("settings persist with typed defaults")
    func settings() throws {
        let store = try temporaryStore()
        #expect(store.setting("clipboard_enabled", default: true) == true)
        store.setSetting("clipboard_enabled", false)
        #expect(store.setting("clipboard_enabled", default: true) == false)
        store.setSetting("clipboard_max_items", 250)
        #expect(store.setting("clipboard_max_items", default: 500) == 250)
    }

    @Test("settings can be removed when a durable marker is no longer true")
    func removeSetting() throws {
        let store = try temporaryStore()
        store.setSetting("corpus_checkpoint", "pending")
        #expect(store.setting("corpus_checkpoint") == "pending")

        store.removeSetting("corpus_checkpoint")

        #expect(store.setting("corpus_checkpoint") == nil)
    }

    @Test("export/import round-trips and never overwrites existing keywords")
    func archiveRoundTrip() throws {
        let source = try temporaryStore()
        try source.addSnippet(keyword: "sig", title: "Signature", body: "bye {cursor}")
        try source.addWorkflow(keyword: "gh", title: "GitHub", urlTemplate: "https://github.com/search?q={query}")
        source.setSetting("clipboard_max_items", 42)
        source.recordClip(text: "secret-ish clipboard text")

        let data = try Archive.encode(source.exportArchive())
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-ish"))  // clipboard excluded by default

        let destination = try temporaryStore()
        try destination.addSnippet(keyword: "sig", title: "Mine", body: "keep me")
        let summary = destination.importArchive(try Archive.decode(data))

        #expect(summary.addedSnippets == 0)
        #expect(summary.addedWorkflows == 1)
        #expect(summary.skipped == 1)
        #expect(destination.snippets().first?.body == "keep me")
        #expect(destination.setting("clipboard_max_items", default: 0) == 42)
    }

    @Test("archives from a future format version are refused")
    func futureArchive() throws {
        let json = #"{"version":99,"exportedAt":"2026-01-01T00:00:00Z","snippets":[],"workflows":[],"settings":{}}"#
        #expect(throws: ArchiveError.self) {
            try Archive.decode(Data(json.utf8))
        }
    }

    @Test("diagnostics never contain snippet bodies or clipboard text")
    func diagnosticsAreBoring() throws {
        let store = try temporaryStore()
        try store.addSnippet(keyword: "sig", title: "Signature", body: "TOP-SECRET-BODY")
        store.recordClip(text: "TOP-SECRET-CLIP")
        let report = store.diagnostics(appVersion: "1.0", systemVersion: "macOS", accessibilityGranted: false)
            .render()
        #expect(!report.contains("TOP-SECRET-BODY"))
        #expect(!report.contains("TOP-SECRET-CLIP"))
        #expect(report.contains("snippets: 1"))
    }
}
