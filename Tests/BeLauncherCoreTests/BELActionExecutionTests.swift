import Foundation
import Testing
@testable import BeLauncherCore

@Suite("BEL action gates and handlers")
struct BELActionExecutionTests {

    @Test("a missing capability blocks before the handler can run")
    func capabilityGateRunsFirst() async throws {
        let definition = try #require(BELActionCatalog.named("files.empty_trash"))
        let handler = SpyHandler(actionID: definition.id)
        let result = BELActionGate.decide(definition,
                                          capabilities: BELCapabilitySnapshot(states: [:]))
        #expect(result == .blocked(.missingCapability(.accessibility)))
        await #expect(throws: BELActionExecutionError.blocked(.missingCapability(.accessibility))) {
            try await BELActionExecutor.execute(definition,
                                                capabilities: BELCapabilitySnapshot(),
                                                handler: handler)
        }
        #expect(await handler.calls == 0)
    }

    @Test("R3 actions require confirmation and run only after it")
    func confirmationIsCentral() async throws {
        let definition = try #require(BELActionCatalog.named("files.empty_trash"))
        let handler = SpyHandler(actionID: definition.id)
        #expect(BELActionGate.decide(definition, capabilities: .allGranted)
                == .requiresConfirmation)
        await #expect(throws: BELActionExecutionError.confirmationRequired) {
            try await BELActionExecutor.execute(definition, capabilities: .allGranted,
                                                handler: handler)
        }
        #expect(await handler.calls == 0)
        let output = try await BELActionExecutor.execute(definition, capabilities: .allGranted,
                                                         confirmed: true, handler: handler)
        #expect(output.receipt == "spy receipt")
        #expect(await handler.calls == 1)
    }

    @Test("an unavailable catalog entry never reaches a handler")
    func unavailableIsHonest() async throws {
        let definition = BELActionDefinition(id: "future.action", kind: .native,
                                             titleKey: "future.action", aliases: ["future"],
                                             risk: .r0, adapter: .none,
                                             availability: .unavailable)
        let handler = SpyHandler(actionID: definition.id)
        #expect(BELActionGate.decide(definition, capabilities: .allGranted)
                == .blocked(.unavailable))
        await #expect(throws: BELActionExecutionError.blocked(.unavailable)) {
            try await BELActionExecutor.execute(definition, capabilities: .allGranted,
                                                handler: handler)
        }
        #expect(await handler.calls == 0)
    }

    @Test("a handler for another stable ID is rejected")
    func handlerIdentityIsChecked() async throws {
        let definition = try #require(BELActionCatalog.named("brain.open"))
        let handler = SpyHandler(actionID: "wrong.id")
        await #expect(throws: BELActionExecutionError.handlerDoesNotMatch(
            expected: definition.id, received: "wrong.id")) {
            try await BELActionExecutor.execute(definition, capabilities: .allGranted,
                                                handler: handler)
        }
        #expect(await handler.calls == 0)
    }
}

private actor SpyHandler: BELActionHandler {
    let actionID: String
    private(set) var calls = 0

    init(actionID: String) { self.actionID = actionID }

    func perform(input: Data) async throws -> BELActionResult {
        calls += 1
        return BELActionResult(text: "ok", receipt: "spy receipt")
    }
}
