import Foundation

public struct BELTextActionInput: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) { self.text = text }
}

/// Adapter for the AI verbs that already exist. It keeps provider selection inside AIVerbRunner;
/// BEL contributes only stable identity, typed input and the permission/risk gate.
public struct BELAIActionHandler: BELActionHandler {
    public let actionID: String
    private let verb: AIVerb
    private let runner: AIVerbRunner

    public init?(definition: BELActionDefinition, runner: AIVerbRunner) {
        guard definition.kind == .ai,
              definition.adapter == .model,
              let legacyID = BELActionCatalog.legacyAIVerbID(for: definition.id),
              let verb = AIVerb.named(legacyID) else { return nil }
        self.actionID = definition.id
        self.verb = verb
        self.runner = runner
    }

    public func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELTextActionInput.self, from: input)
        let text = try await runner.run(verb, on: value.text)
        return BELActionResult(text: text, receipt: "ai:\(verb.id)")
    }
}
