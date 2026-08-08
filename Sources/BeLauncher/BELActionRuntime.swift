import Foundation
import BeLauncherCore

/// The app-side registry for the stable BEL action contract.
///
/// Definitions and the permission/risk gate live in Core. Concrete adapters live here because
/// they need AppKit or the existing app services. Keeping the lookup in one place prevents a new
/// UI surface from quietly falling back to a legacy switch and bypassing the gate.
struct BELActionRuntime: Sendable {
    let aiRunner: AIVerbRunner?

    init(aiRunner: AIVerbRunner? = nil) {
        self.aiRunner = aiRunner
    }

    func handler(for definition: BELActionDefinition) -> (any BELActionHandler)? {
        switch definition.kind {
        case .native:
            return SystemCommandActionHandler(definition: definition)
        case .ai:
            guard let aiRunner else { return nil }
            return BELAIActionHandler(definition: definition, runner: aiRunner)
        case .agentic:
            return nil
        }
    }

    func execute(_ definition: BELActionDefinition, input: Data = Data(),
                 capabilities: BELCapabilitySnapshot,
                 confirmed: Bool = false) async throws -> BELActionResult {
        guard let handler = handler(for: definition) else {
            throw BELActionExecutionError.blocked(.unavailable)
        }
        return try await BELActionExecutor.execute(definition, input: input,
                                                   capabilities: capabilities,
                                                   confirmed: confirmed, handler: handler)
    }
}
