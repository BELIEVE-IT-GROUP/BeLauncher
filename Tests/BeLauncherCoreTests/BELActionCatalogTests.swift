import Foundation
import Testing
@testable import BeLauncherCore

@Suite("Stable BEL action catalogue")
struct BELActionCatalogTests {

    @Test("current native and AI actions have unique stable IDs")
    func catalogIsValid() {
        let definitions = BELActionCatalog.all

        #expect(definitions.count >= SystemCommand.all.count + AIVerb.all.count)
        #expect(BELActionCatalog.validate(definitions).isEmpty)
        #expect(Set(definitions.map(\.id)).count == definitions.count)
        #expect(definitions.allSatisfy { $0.id.contains(".") })
    }

    @Test("the full spec inventory is present without pretending seeds work")
    func specInventoryIsHonest() {
        let definitions = BELActionCatalog.all
        let native = definitions.filter { $0.kind == .native }
        let ai = definitions.filter { $0.kind == .ai }
        let seeds = definitions.filter { $0.availability == .unavailable }

        #expect(native.count >= 100)
        #expect(ai.count >= 80)
        #expect(!seeds.isEmpty)
        #expect(seeds.allSatisfy { definition in
            definition.adapter == .none
                && definition.output != nil
                && !definition.aliases.isEmpty
        })
        #expect(seeds.allSatisfy { definition in
            definition.arguments.allSatisfy { !$0.name.isEmpty }
        })
    }

    @Test("the stable AI ID resolves to the existing verb runner ID")
    func aiIDsBridgeToLegacyVerbs() {
        for verb in AIVerb.all {
            let stableID = "ai.verb.\(verb.id)"
            #expect(BELActionCatalog.legacyAIVerbID(for: stableID) == verb.id)
            #expect(BELActionCatalog.named(stableID)?.availability == .implemented)
        }
    }

    @Test("aliases remain bilingual and are not used as identity")
    func aliasesResolveWithoutRenamingIDs() throws {
        let brain = try #require(BELActionCatalog.named("brain.open"))
        #expect(brain.id == "brain.open")
        #expect(brain.aliases.contains("brain"))
        #expect(brain.aliases.contains("cerebro"))

        let summary = try #require(BELActionCatalog.named("ai.verb.summarise"))
        #expect(summary.id == "ai.verb.summarise")
        #expect(summary.aliases.contains("summarise"))
    }

    @Test("risk and route policy survive Codable round trips")
    func contractRoundTrips() throws {
        let definitions = BELActionCatalog.all
        let data = try JSONEncoder().encode(definitions)
        let decoded = try JSONDecoder().decode([BELActionDefinition].self, from: data)

        #expect(decoded == definitions)
        #expect(BELActionCatalog.named("files.empty_trash")?.alwaysConfirms == true)
        #expect(BELActionCatalog.named("ai.verb.extract-tasks")?.isLocalOnly == true)
    }

    @Test("invalid definitions are rejected before they enter the registry")
    func invalidDefinitionsAreReported() {
        let invalid = BELActionDefinition(
            id: "broken",
            kind: .native,
            titleKey: "",
            risk: .r0,
            adapter: .none,
            availability: .implemented)

        #expect(BELActionCatalog.validate([invalid]).contains(.invalidNamespace("broken")))
        #expect(BELActionCatalog.validate([invalid]).contains(.emptyTitleKey("broken")))
        #expect(BELActionCatalog.validate([invalid]).contains(.missingAlias("broken")))
        #expect(BELActionCatalog.validate([invalid]).contains(.implementedWithoutAdapter("broken")))
    }

    @Test("Shortcut fallback mappings have stable IDs and safe names")
    func shortcutMappingsAreSafe() throws {
        let mappings = [
            BELShortcutMapping(actionID: "calendar.upcoming", shortcutName: "BEL • Upcoming meetings"),
            BELShortcutMapping(actionID: "screen.read_context", shortcutName: "BEL • Read screen"),
        ]
        #expect(BELShortcutMapping.validate(mappings).isEmpty)
        #expect(BELShortcutMapping.validate([
            BELShortcutMapping(actionID: "calendar.upcoming", shortcutName: "BEL • One"),
            BELShortcutMapping(actionID: "calendar.upcoming", shortcutName: "BEL • Two"),
        ]) == ["duplicate:calendar.upcoming"])
        let roundTrip = try JSONDecoder().decode([BELShortcutMapping].self,
                                                  from: JSONEncoder().encode(mappings))
        #expect(roundTrip == mappings)
    }
}
