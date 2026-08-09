import Foundation
import BeLauncherCore

/// The app-side registry for the stable BEL action contract.
///
/// Definitions and the permission/risk gate live in Core. Concrete adapters live here because
/// they need AppKit or the existing app services. Keeping the lookup in one place prevents a new
/// UI surface from quietly falling back to a legacy switch and bypassing the gate.
struct BELActionRuntime: Sendable {
    let aiRunner: AIVerbRunner?

    /// N1's resolution order is a contract, not an incidental order of `??` expressions.
    /// Keeping it explicit prevents a future adapter from silently taking precedence over a
    /// first-party API or from turning a missing adapter into a shell fallback.
    static let nativeAdapterOrder: [BELActionDefinition.Adapter] = [
        .publicAPI, .ownAppIntent, .shortcut, .urlScheme, .appleScript, .allowlistedShell,
    ]

    init(aiRunner: AIVerbRunner? = nil) {
        self.aiRunner = aiRunner
    }

    func handler(for definition: BELActionDefinition) -> (any BELActionHandler)? {
        switch definition.kind {
        case .native:
            return nativeHandler(for: definition)
        case .ai:
            guard let aiRunner else { return nil }
            return BELAIActionHandler(definition: definition, runner: aiRunner)
        case .agentic:
            return nil
        }
    }

    private func nativeHandler(for definition: BELActionDefinition)
        -> (any BELActionHandler)? {
        for adapter in Self.nativeAdapterOrder where definition.adapter == adapter {
            switch adapter {
            case .publicAPI:
                return FileActionHandler(definition: definition)
                    ?? PDFActionHandler(definition: definition)
                    ?? ScreenActionHandler(definition: definition)
                    ?? CalendarActionHandler(definition: definition)
            case .ownAppIntent:
                // App Intents are an exposure surface today. They do not become an execution
                // adapter unless their stable BEL ID is wired to a concrete handler.
                return nil
            case .shortcut:
                return ShortcutActionHandler(definition: definition)
            case .urlScheme, .appleScript:
                return nil
            case .allowlistedShell:
                return SystemCommandActionHandler(definition: definition)
            case .model, .none:
                return nil
            }
        }
        return nil
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
