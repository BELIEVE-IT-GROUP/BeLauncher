import Testing
@testable import BeLauncherCore

@Suite("Structured model output")
struct BELStructuredOutputTests {
    private let schema = BELJSONSchema(fields: [
        BELJSONField("statement", .string, required: true),
        BELJSONField("kind", .string),
    ])

    @Test("valid JSON and markdown fences are accepted")
    func valid() throws {
        let plain = try BELStructuredOutputValidator.validate(
            "{\"statement\":\"Usar Ollama\",\"kind\":\"decision\"}",
            against: schema
        )
        #expect(plain.objectValue?["kind"] == .string("decision"))

        let value = try BELStructuredOutputValidator.validate(
            "```json\n{\"statement\":\"Usar Ollama\",\"kind\":\"decision\"}\n```",
            against: schema
        )
        #expect(value.objectValue?["statement"] == .string("Usar Ollama"))
    }

    @Test("missing and unknown fields are rejected")
    func shapeErrors() {
        #expect(throws: BELStructuredOutputError.missingField("statement")) {
            try BELStructuredOutputValidator.validate("{\"kind\":\"note\"}", against: schema)
        }
        #expect(throws: BELStructuredOutputError.unknownField("extra")) {
            try BELStructuredOutputValidator.validate(
                "{\"statement\":\"x\",\"extra\":true}", against: schema)
        }
    }

    @Test("truncated JSON and wrong types never become a writeback")
    func unsafeOutputRejected() {
        #expect(throws: BELStructuredOutputError.invalidJSON) {
            try BELStructuredOutputValidator.validate(
                "Use this JSON: {\"statement\":\"ok\"}",
                against: schema)
        }
        #expect(throws: BELStructuredOutputError.invalidJSON) {
            try BELStructuredOutputValidator.validate("{\"statement\":", against: schema)
        }
        #expect(throws: BELStructuredOutputError.wrongType(field: "statement", expected: .string)) {
            try BELStructuredOutputValidator.validate("{\"statement\":42}", against: schema)
        }
    }

    @Test("bounded input rejects oversized, deep, wide, and long values")
    func resourceLimits() {
        let limits = BELStructuredOutputLimits(
            maxBytes: 100,
            maxDepth: 2,
            maxObjectFields: 1,
            maxArrayItems: 2,
            maxStringCharacters: 4
        )

        #expect(throws: BELStructuredOutputError.inputTooLarge(maxBytes: 100)) {
            try BELStructuredOutputValidator.validate(
                "{\"statement\":\"" + String(repeating: "x", count: 100) + "\"}",
                against: schema, limits: limits)
        }
        #expect(throws: BELStructuredOutputError.depthExceeded(maxDepth: 2)) {
            try BELStructuredOutputValidator.validate(
                "{\"statement\":{\"nested\":{\"value\":true}}}",
                against: BELJSONSchema(fields: [BELJSONField("statement", .object, required: true)]),
                limits: limits)
        }
        #expect(throws: BELStructuredOutputError.objectTooLarge(maxFields: 1)) {
            try BELStructuredOutputValidator.validate(
                "{\"statement\":\"ok\",\"kind\":\"note\"}",
                against: schema, limits: BELStructuredOutputLimits(maxObjectFields: 1))
        }
        #expect(throws: BELStructuredOutputError.arrayTooLarge(maxItems: 2)) {
            try BELStructuredOutputValidator.validate(
                "{\"statement\":[1,2,3]}",
                against: BELJSONSchema(fields: [BELJSONField("statement", .array, required: true)]),
                limits: limits)
        }
        #expect(throws: BELStructuredOutputError.stringTooLong(maxCharacters: 4)) {
            try BELStructuredOutputValidator.validate(
                "{\"statement\":\"12345\"}", against: schema, limits: limits)
        }
    }

    @Test("unclosed markdown fences and truncated tool calls are rejected")
    func boundedRepairOnly() {
        #expect(throws: BELStructuredOutputError.invalidJSON) {
            try BELStructuredOutputValidator.validate(
                "```json\n{\"statement\":\"ok\"}", against: schema)
        }
        #expect(throws: BELStructuredOutputError.invalidJSON) {
            try BELStructuredOutputValidator.validateToolCall(
                "{\"name\":\"save\",\"arguments\":{\"text\":",
                toolName: "save",
                arguments: BELJSONSchema(fields: [BELJSONField("text", .string, required: true)]))
        }
    }

    @Test("tool calls return checked arguments only")
    func toolCallsReturnArgumentsOnly() throws {
        let arguments = try BELStructuredOutputValidator.validateToolCall(
            "{\"name\":\"saveEvidence\",\"arguments\":{\"title\":\"Call\",\"text\":\"Notes\"}}",
            toolName: "saveEvidence",
            arguments: BELJSONSchema(fields: [
                BELJSONField("title", .string, required: true),
                BELJSONField("text", .string, required: true),
            ])
        )

        #expect(arguments.objectValue == [
            "title": .string("Call"),
            "text": .string("Notes"),
        ])
    }

    @Test("unknown tools and malformed arguments are rejected before handlers")
    func toolCallShapeErrors() {
        let schema = BELJSONSchema(fields: [
            BELJSONField("title", .string, required: true),
            BELJSONField("text", .string, required: true),
        ])

        #expect(throws: BELStructuredOutputError.unknownTool("deleteAll")) {
            try BELStructuredOutputValidator.validateToolCall(
                "{\"name\":\"deleteAll\",\"arguments\":{\"title\":\"x\",\"text\":\"y\"}}",
                toolName: "saveEvidence",
                arguments: schema)
        }
        #expect(throws: BELStructuredOutputError.unknownField("afterValidation")) {
            try BELStructuredOutputValidator.validateToolCall(
                "{\"name\":\"saveEvidence\",\"arguments\":{\"title\":\"x\",\"text\":\"y\"},\"afterValidation\":\"run handler\"}",
                toolName: "saveEvidence",
                arguments: schema)
        }
        #expect(throws: BELStructuredOutputError.unknownField("extra")) {
            try BELStructuredOutputValidator.validateToolCall(
                "{\"name\":\"saveEvidence\",\"arguments\":{\"title\":\"x\",\"text\":\"y\",\"extra\":\"ignore schema\"}}",
                toolName: "saveEvidence",
                arguments: schema)
        }
        #expect(throws: BELStructuredOutputError.wrongType(field: "text", expected: .string)) {
            try BELStructuredOutputValidator.validateToolCall(
                "{\"name\":\"saveEvidence\",\"arguments\":{\"title\":\"x\",\"text\":[\"prompt\"]}}",
                toolName: "saveEvidence",
                arguments: schema)
        }
    }
}
