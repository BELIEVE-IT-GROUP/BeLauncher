import Testing
@testable import BeLauncherCore

@Suite("Human action resolver")
struct BELActionResolverTests {
    @Test("stable IDs resolve exactly")
    func stableID() {
        #expect(BELActionResolver.resolve("system.lock_screen")?.actionID == "system.lock_screen")
    }

    @Test("Spanish and English aliases resolve to the same native action")
    func bilingualAliases() {
        #expect(BELActionResolver.resolve("cerebro")?.actionID == "brain.open")
        #expect(BELActionResolver.resolve("lock")?.actionID == "system.lock_screen")
    }

    @Test("a prefix preserves the argument after the action")
    func prefixArgument() {
        let match = BELActionResolver.resolve("summarise esta nota")
        #expect(match?.actionID == "ai.verb.summarise")
        #expect(match?.argument == "esta nota")
        #expect(match?.arguments["text"] == "esta nota")
        #expect(match?.confidence == 900)
    }

    @Test("unavailable seeds and incomplete required arguments do not resolve")
    func unavailableAndIncompleteActionsAreRejected() {
        #expect(BELActionResolver.resolve("system.open_app") == nil)
        #expect(BELActionResolver.resolve("open file") == nil)
        #expect(BELActionResolver.resolve("files.open") == nil)
    }

    @Test("a required path is only accepted as an explicit prefix argument")
    func requiredArgumentIsMapped() {
        let match = BELActionResolver.resolve("open file /tmp/notes.md")
        #expect(match?.actionID == "files.open")
        #expect(match?.arguments["path"] == "/tmp/notes.md")
    }

    @Test("unknown or ambiguous text is not turned into a side effect")
    func safeUnknowns() {
        #expect(BELActionResolver.resolve("xyzzy does something") == nil)
        #expect(BELActionResolver.resolve("s") == nil)
        #expect(BELActionResolver.resolve("sa") == nil)
    }
}
