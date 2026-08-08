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
            try BELStructuredOutputValidator.validate("{\"statement\":", against: schema)
        }
        #expect(throws: BELStructuredOutputError.wrongType(field: "statement", expected: .string)) {
            try BELStructuredOutputValidator.validate("{\"statement\":42}", against: schema)
        }
    }
}
