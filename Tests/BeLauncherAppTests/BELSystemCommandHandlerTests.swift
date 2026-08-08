import Foundation
import Testing
import BeLauncherCore
@testable import BeLauncher

@Suite("Native BEL adapters")
struct BELSystemCommandHandlerTests {
    @Test("the existing closed system commands execute through stable BEL IDs")
    @MainActor
    func systemCommandBridge() async throws {
        let definition = try #require(BELActionCatalog.named("brain.open"))
        let handler = try #require(SystemCommandActionHandler(definition: definition))

        let result = try await BELActionExecutor.execute(definition,
                                                         capabilities: .allGranted,
                                                         handler: handler)
        #expect(result.receipt == "system:openBrain")
        #expect(handler.actionID == definition.id)
    }

    @Test("the adapter refuses AI and unavailable definitions")
    func adapterDoesNotPretend() throws {
        let ai = try #require(BELActionCatalog.named("ai.verb.summarise"))
        #expect(SystemCommandActionHandler(definition: ai) == nil)

        let unavailable = BELActionDefinition(id: "future.native", kind: .native,
                                              titleKey: "future.native", aliases: ["future"],
                                              risk: .r0, adapter: .none,
                                              availability: .unavailable)
        #expect(SystemCommandActionHandler(definition: unavailable) == nil)
    }

    @Test("the app runtime cannot bypass the central confirmation gate")
    func runtimeUsesGate() async throws {
        let definition = try #require(BELActionCatalog.named("files.empty_trash"))
        let runtime = BELActionRuntime()

        await #expect(throws: BELActionExecutionError.confirmationRequired) {
            try await runtime.execute(definition, capabilities: .allGranted)
        }
    }

    @Test("user shortcuts are stable actions and require confirmation")
    func shortcutActionUsesGate() async throws {
        let definition = try #require(BELActionCatalog.named("shortcuts.run"))
        let input = try JSONEncoder().encode(BELShortcutActionInput(name: "Focus"))
        let runtime = BELActionRuntime()

        await #expect(throws: BELActionExecutionError.confirmationRequired) {
            try await runtime.execute(definition, input: input, capabilities: .allGranted)
        }
    }
}
