import Testing
import Foundation
@testable import BeLauncherCore

// MARK: - Snippet expansion (the core transformation)

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC

private func expander(clipboard: String? = nil, secrets: [String: String] = [:]) -> SnippetExpander {
    SnippetExpander(
        clipboard: { clipboard },
        secret: { secrets[$0] },
        uuid: { "FIXED-UUID" },
        now: fixedDate,
        locale: Locale(identifier: "en_US_POSIX")
    )
}

@Suite("Snippet expansion")
struct SnippetExpanderTests {

    @Test("plain text passes through untouched")
    func plainText() {
        let result = expander().expand("Hello there")
        #expect(result.text == "Hello there")
        #expect(result.cursorOffset == nil)
    }

    @Test("clipboard token is substituted, and empty when the clipboard is empty")
    func clipboardToken() {
        #expect(expander(clipboard: "pasted").expand("> {clipboard}").text == "> pasted")
        #expect(expander(clipboard: nil).expand("> {clipboard}").text == "> ")
    }

    @Test("date and time use the injected clock")
    func dateTokens() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let expected = DateFormatter()
        expected.locale = Locale(identifier: "en_US_POSIX")
        expected.dateFormat = "yyyy-MM-dd"
        #expect(expander().expand("{date}").text == expected.string(from: fixedDate))

        expected.dateFormat = "yyyy"
        #expect(expander().expand("{date:yyyy}").text == expected.string(from: fixedDate))
    }

    @Test("uuid uses the injected generator")
    func uuidToken() {
        #expect(expander().expand("id={uuid}").text == "id=FIXED-UUID")
    }

    @Test("cursor marker is removed and reported as an offset")
    func cursorToken() {
        let result = expander().expand("Dear {cursor},\nthanks!")
        #expect(result.text == "Dear ,\nthanks!")
        #expect(result.cursorOffset == 5)
    }

    @Test("only the first cursor marker counts")
    func firstCursorWins() {
        let result = expander().expand("a{cursor}b{cursor}c")
        #expect(result.text == "abc")
        #expect(result.cursorOffset == 1)
    }

    @Test("secrets come from the injected resolver, missing ones expand to nothing")
    func secretToken() {
        #expect(expander(secrets: ["TOKEN": "s3cr3t"]).expand("Bearer {secret:TOKEN}").text == "Bearer s3cr3t")
        #expect(expander().expand("Bearer {secret:NOPE}").text == "Bearer ")
    }

    @Test("unknown tokens are left visible instead of silently deleted")
    func unknownToken() {
        #expect(expander().expand("{nope} {secret:}").text == "{nope} {secret:}")
    }

    @Test("doubled braces are literal")
    func escapedBraces() {
        #expect(expander().expand("{{clipboard}}").text == "{clipboard}")
    }

    @Test("query token carries the text typed after the keyword")
    func queryToken() {
        #expect(expander().expand("search: {query}", query: "swift 6").text == "search: swift 6")
    }
}

// MARK: - Workflow URLs

@Suite("Workflow URL building")
struct WorkflowURLTests {

    @Test("query is percent-encoded")
    func encodesQuery() {
        let url = WorkflowURL.build(template: "https://example.com/s?q={query}", query: "a b&c=d")
        #expect(url?.absoluteString == "https://example.com/s?q=a%20b%26c%3Dd")
    }

    @Test("secrets are substituted")
    func substitutesSecret() {
        let url = WorkflowURL.build(
            template: "https://api.example.com/{query}?key={secret:API}",
            query: "items", secret: { $0 == "API" ? "abc123" : nil }
        )
        #expect(url?.absoluteString == "https://api.example.com/items?key=abc123")
    }

    @Test("non-web schemes are rejected — BeLauncher never executes anything")
    func rejectsDangerousSchemes() {
        #expect(WorkflowURL.build(template: "file:///etc/passwd", query: "") == nil)
        #expect(WorkflowURL.build(template: "javascript:alert(1)", query: "") == nil)
        #expect(throws: ValidationError.self) {
            try WorkflowURL.validateTemplate("file:///bin/sh")
        }
        #expect(throws: ValidationError.self) {
            try WorkflowURL.validateTemplate("")
        }
    }

    @Test("valid templates pass validation")
    func acceptsValidTemplates() throws {
        try WorkflowURL.validateTemplate("https://github.com/search?q={query}")
        try WorkflowURL.validateTemplate("mailto:someone@example.com")
    }
}

// MARK: - Fuzzy ranking

@Suite("Fuzzy matching")
struct FuzzyTests {

    @Test("matches subsequences and rejects non-matches")
    func basics() {
        #expect(Fuzzy.match(query: "sfr", candidate: "Safari") != nil)
        #expect(Fuzzy.match(query: "xyz", candidate: "Safari") == nil)
        #expect(Fuzzy.match(query: "safaris", candidate: "Safari") == nil)
    }

    @Test("exact and prefix hits outrank scattered ones")
    func ranking() throws {
        let exact = try #require(Fuzzy.match(query: "mail", candidate: "Mail"))
        let prefix = try #require(Fuzzy.match(query: "mail", candidate: "Mailbox Pro"))
        let scattered = try #require(Fuzzy.match(query: "mail", candidate: "Muse Application Installer"))
        #expect(exact.score > prefix.score)
        #expect(prefix.score > scattered.score)
    }

    @Test("word starts are rewarded")
    func wordStarts() throws {
        let initials = try #require(Fuzzy.match(query: "sp", candidate: "System Preferences"))
        let inside = try #require(Fuzzy.match(query: "sp", candidate: "Passport"))
        #expect(initials.score > inside.score)
    }

    @Test("case and accents are ignored")
    func folding() {
        #expect(Fuzzy.match(query: "CAF", candidate: "café") != nil)
    }

    @Test("matched indices point at the highlighted characters")
    func indices() throws {
        let match = try #require(Fuzzy.match(query: "sa", candidate: "Safari"))
        #expect(match.matched == [0, 1])
    }
}

// MARK: - Safe filenames

@Suite("Safe filenames")
struct SafeFilenameTests {

    @Test("path separators cannot escape the target folder")
    func stripsSeparators() {
        let name = SafeFilename.make("../../etc/passwd", extension: "json")
        #expect(!name.contains("/"))
        #expect(!name.hasPrefix("."))
    }

    @Test("whitespace collapses, extension is added once")
    func normalises() {
        #expect(SafeFilename.make("  my   backup ", extension: "json") == "my-backup.json")
        #expect(SafeFilename.make("report.txt", extension: "txt") == "report.txt")
    }

    @Test("empty or reserved names fall back")
    func fallback() {
        #expect(SafeFilename.make("", fallback: "belauncher", extension: "json") == "belauncher.json")
        #expect(SafeFilename.make("..", fallback: "belauncher", extension: "json") == "belauncher.json")
        #expect(SafeFilename.make("   ", fallback: "belauncher", extension: "json") == "belauncher.json")
    }

    @Test("control characters are removed and length is bounded")
    func hardens() {
        let name = SafeFilename.make("a\u{0}b\nc" + String(repeating: "x", count: 300), extension: "txt")
        #expect(!name.contains("\u{0}"))
        #expect(name.count <= 84)
    }
}

// MARK: - .env parsing

@Suite("Env parsing")
struct EnvTests {

    @Test("reads pairs, ignores comments and blank lines, strips quotes")
    func parsing() {
        let values = Env.parse("""
            # comment
            BELAUNCHER_UPDATE_FEED_URL="https://example.com/feed.json"

            export OTHER=plain
            BROKEN
            """)
        #expect(values["BELAUNCHER_UPDATE_FEED_URL"] == "https://example.com/feed.json")
        #expect(values["OTHER"] == "plain")
        #expect(values["BROKEN"] == nil)
    }
}
