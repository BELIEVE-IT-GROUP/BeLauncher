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
    private let argumentSchema: BELJSONSchema

    public init?(definition: BELActionDefinition, runner: AIVerbRunner) {
        guard definition.kind == .ai,
              definition.adapter == .model,
              let legacyID = BELActionCatalog.legacyAIVerbID(for: definition.id),
              let verb = AIVerb.named(legacyID) else { return nil }
        self.actionID = definition.id
        self.verb = verb
        self.runner = runner
        self.argumentSchema = BELJSONSchema(fields: definition.arguments.map {
            BELJSONField($0.name, Self.jsonKind(for: $0.type), required: $0.isRequired)
        })
    }

    public func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELTextActionInput.self, from: input)
        let text = try await runner.run(verb, on: value.text)
        return BELActionResult(text: text, receipt: "ai:\(verb.id)")
    }

    /// Entry point for model-produced tool calls. It is intentionally separate from `perform` so
    /// an already-gated app action can still receive its typed JSON input directly.
    public func perform(toolCall raw: String) async throws -> BELActionResult {
        let arguments = try BELStructuredOutputValidator.validateToolCall(
            raw, toolName: actionID, arguments: argumentSchema)
        let data = try JSONEncoder().encode(arguments)
        return try await perform(input: data)
    }

    private static func jsonKind(for type: BELActionDefinition.ArgumentSpec.ValueType)
        -> BELJSONField.Kind {
        switch type {
        case .text, .path, .url, .date, .duration, .audioRef, .imageRef, .contactRef,
             .enumeration: .string
        case .integer: .number
        case .decimal, .percentage: .number
        case .boolean: .boolean
        case .fileList: .array
        }
    }
}
