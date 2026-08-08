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
        #expect(match?.confidence == 900)
    }

    @Test("unknown or ambiguous text is not turned into a side effect")
    func safeUnknowns() {
        #expect(BELActionResolver.resolve("xyzzy does something") == nil)
        #expect(BELActionResolver.resolve("s") == nil)
    }
}
