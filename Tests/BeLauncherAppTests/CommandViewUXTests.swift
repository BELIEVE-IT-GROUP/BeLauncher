import Foundation
import Testing
@testable import BeLauncher

@Suite("Launcher UX source contracts")
struct CommandViewUXTests {
    private static var repositoryRoot: URL {
        var path = URL(fileURLWithPath: #filePath)
        while path.pathComponents.count > 1 {
            path.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: path.appendingPathComponent("Package.swift").path) {
                return path
            }
        }
        return URL(fileURLWithPath: "")
    }

    private static var commandViewSource: String {
        get throws {
            try String(contentsOf: repositoryRoot
                .appendingPathComponent("Sources/BeLauncher/CommandView.swift"), encoding: .utf8)
        }
    }

    @Test("clipboard quick preview selects the card before expanding it")
    func clipboardPreviewSelectionOrder() throws {
        let source = try Self.commandViewSource
        let selectRange = try #require(source.range(of: "model.select(index)\n                                     expandedClipID = result.id"))
        let staleDetailRange = try #require(source.range(of: "let selectedID = visibleEntries.first(where: { $0.index == new })?.result.id"))

        #expect(selectRange.lowerBound < staleDetailRange.lowerBound)
        #expect(!source.contains("if expandedClipID != model.selected?.id { expandedClipID = nil }"),
                "preview clearing must use the carousel's selected entry, not a possibly stale model.selected")
    }

    @Test("footer has a minimal fallback when quick actions no longer fit")
    func footerHasMinimalFallback() throws {
        let source = try Self.commandViewSource
        let fitsRange = try #require(source.range(of: "ViewThatFits(in: .horizontal)"))
        let minimalRange = try #require(source.range(of: "minimalFooterRow"))
        let voiceMenuRange = try #require(source.range(of: "Label(L(\"Dictate into the current app\"), systemImage: \"text.cursor\")"))

        #expect(fitsRange.lowerBound < minimalRange.lowerBound)
        #expect(minimalRange.lowerBound < voiceMenuRange.lowerBound)
        #expect(source.contains(".help(L(\"Voice\"))"))
    }
}
