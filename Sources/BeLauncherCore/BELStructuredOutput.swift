import Foundation

public enum BELJSONValue: Codable, Equatable, Sendable {
    case object([String: BELJSONValue])
    case array([BELJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var object: [String: BELJSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(BELJSONValue.self, forKey: key)
            }
            self = .object(object)
        } else if var container = try? decoder.unkeyedContainer() {
            var values: [BELJSONValue] = []
            while !container.isAtEnd { values.append(try container.decode(BELJSONValue.self)) }
            self = .array(values)
        } else if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else { self = .string(try container.decode(String.self)) }
        } else {
            throw BELStructuredOutputError.invalidJSON
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let values):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in values { try container.encode(value, forKey: AnyCodingKey(key)) }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .string(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer(); try container.encodeNil()
        }
    }

    public var objectValue: [String: BELJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

public struct BELJSONField: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case string, number, boolean, object, array, any
    }

    public let name: String
    public let kind: Kind
    public let required: Bool

    public init(_ name: String, _ kind: Kind, required: Bool = false) {
        self.name = name
        self.kind = kind
        self.required = required
    }
}

public struct BELJSONSchema: Sendable, Equatable {
    public let fields: [BELJSONField]
    public let rejectUnknownFields: Bool

    public init(fields: [BELJSONField], rejectUnknownFields: Bool = true) {
        self.fields = fields
        self.rejectUnknownFields = rejectUnknownFields
    }
}

/// Resource limits applied before a model response is accepted as structured data.
///
/// The defaults are deliberately finite: model output is an untrusted input boundary,
/// even when it came from a local provider. Callers can use a smaller profile for a
/// particular tool, but should not disable these checks by parsing the response first.
public struct BELStructuredOutputLimits: Sendable, Equatable {
    public let maxBytes: Int
    public let maxDepth: Int
    public let maxObjectFields: Int
    public let maxArrayItems: Int
    public let maxStringCharacters: Int

    public init(maxBytes: Int = 128_000,
                maxDepth: Int = 12,
                maxObjectFields: Int = 64,
                maxArrayItems: Int = 256,
                maxStringCharacters: Int = 32_000) {
        self.maxBytes = maxBytes
        self.maxDepth = maxDepth
        self.maxObjectFields = maxObjectFields
        self.maxArrayItems = maxArrayItems
        self.maxStringCharacters = maxStringCharacters
    }

    public static let `default` = BELStructuredOutputLimits()
}

public enum BELStructuredOutputError: Error, Equatable, CustomStringConvertible {
    case invalidJSON
    case inputTooLarge(maxBytes: Int)
    case depthExceeded(maxDepth: Int)
    case objectTooLarge(maxFields: Int)
    case arrayTooLarge(maxItems: Int)
    case stringTooLong(maxCharacters: Int)
    case notAnObject
    case missingField(String)
    case unknownField(String)
    case wrongType(field: String, expected: BELJSONField.Kind)
    case unknownTool(String)
    case invalidToolArguments

    public var description: String {
        switch self {
        case .invalidJSON: "The model returned invalid JSON."
        case .inputTooLarge(let maxBytes): "The model response exceeded the \(maxBytes)-byte limit."
        case .depthExceeded(let maxDepth): "The model response exceeded the \(maxDepth)-level nesting limit."
        case .objectTooLarge(let maxFields): "The model response exceeded the \(maxFields)-field object limit."
        case .arrayTooLarge(let maxItems): "The model response exceeded the \(maxItems)-item array limit."
        case .stringTooLong(let maxCharacters): "The model response exceeded the \(maxCharacters)-character string limit."
        case .notAnObject: "The model returned JSON, but not an object."
        case .missingField(let field): "The model omitted required field \(field)."
        case .unknownField(let field): "The model returned unknown field \(field)."
        case .wrongType(let field, let expected): "The model returned the wrong type for \(field); expected \(expected.rawValue)."
        case .unknownTool(let name): "The model requested an unknown tool \(name)."
        case .invalidToolArguments: "The model returned invalid tool arguments."
        }
    }
}

public enum BELStructuredOutputValidator {
    /// Parses a bounded JSON response. Markdown fences are tolerated because models add them
    /// routinely; prose, unclosed fences, and truncation are rejected rather than repaired.
    public static func validate(_ raw: String, against schema: BELJSONSchema,
                                limits: BELStructuredOutputLimits = .default) throws -> BELJSONValue {
        guard raw.utf8.count <= limits.maxBytes else {
            throw BELStructuredOutputError.inputTooLarge(maxBytes: limits.maxBytes)
        }
        let text = cleaned(raw)
        guard preflightDepth(of: text, maximum: limits.maxDepth) else {
            throw BELStructuredOutputError.depthExceeded(maxDepth: limits.maxDepth)
        }
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(BELJSONValue.self, from: data) else {
            throw BELStructuredOutputError.invalidJSON
        }
        try validateLimits(value, depth: 1, limits: limits)
        guard let object = value.objectValue else { throw BELStructuredOutputError.notAnObject }
        let fields = Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.name, $0) })
        for field in schema.fields where field.required && object[field.name] == nil {
            throw BELStructuredOutputError.missingField(field.name)
        }
        if schema.rejectUnknownFields {
            for name in object.keys where fields[name] == nil {
                throw BELStructuredOutputError.unknownField(name)
            }
        }
        for (name, value) in object {
            guard let field = fields[name] else { continue }
            if !matches(value, field.kind) {
                throw BELStructuredOutputError.wrongType(field: name, expected: field.kind)
            }
        }
        return value
    }

    /// Validates a model tool-call envelope before any handler sees its arguments. The tool name is
    /// checked exactly and the nested argument object is validated with the handler's schema.
    public static func validateToolCall(_ raw: String, toolName: String,
                                        arguments schema: BELJSONSchema,
                                        limits: BELStructuredOutputLimits = .default) throws -> BELJSONValue {
        let envelope = BELJSONSchema(fields: [
            BELJSONField("name", .string, required: true),
            BELJSONField("arguments", .object, required: true),
        ])
        let value = try validate(raw, against: envelope, limits: limits)
        let object = value.objectValue ?? [:]
        guard case .string(let name) = object["name"], name == toolName else {
            let name = object["name"].flatMap { value -> String? in
                if case .string(let name) = value { return name }
                return nil
            } ?? ""
            throw BELStructuredOutputError.unknownTool(name)
        }
        guard case .object(let arguments) = object["arguments"] else {
            throw BELStructuredOutputError.invalidToolArguments
        }
        let checked = try validateObject(arguments, against: schema, limits: limits, depth: 2)
        return .object(checked)
    }

    private static func validateObject(_ object: [String: BELJSONValue],
                                       against schema: BELJSONSchema,
                                       limits: BELStructuredOutputLimits,
                                       depth: Int) throws
        -> [String: BELJSONValue] {
        try validateLimits(.object(object), depth: depth, limits: limits)
        let fields = Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.name, $0) })
        for field in schema.fields where field.required && object[field.name] == nil {
            throw BELStructuredOutputError.missingField(field.name)
        }
        if schema.rejectUnknownFields {
            for key in object.keys where fields[key] == nil {
                throw BELStructuredOutputError.unknownField(key)
            }
        }
        for (name, value) in object {
            guard let field = fields[name] else { continue }
            guard matches(value, field.kind) else {
                throw BELStructuredOutputError.wrongType(field: name, expected: field.kind)
            }
        }
        return object
    }

    private static func cleaned(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first?.hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
            return trimmed
        }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Counts container nesting without decoding. This keeps deeply nested input away from
    /// JSONDecoder and deliberately leaves syntax validation to the decoder itself.
    private static func preflightDepth(of text: String, maximum: Int) -> Bool {
        var depth = 0
        var escaped = false
        var inString = false
        for byte in text.utf8 {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                if depth > maximum { return false }
            } else if byte == 125 || byte == 93 {
                depth = max(0, depth - 1)
            }
        }
        return true
    }

    private static func validateLimits(_ value: BELJSONValue, depth: Int,
                                       limits: BELStructuredOutputLimits) throws {
        guard depth <= limits.maxDepth else {
            throw BELStructuredOutputError.depthExceeded(maxDepth: limits.maxDepth)
        }
        switch value {
        case .object(let object):
            guard object.count <= limits.maxObjectFields else {
                throw BELStructuredOutputError.objectTooLarge(maxFields: limits.maxObjectFields)
            }
            for child in object.values {
                try validateLimits(child, depth: depth + 1, limits: limits)
            }
        case .array(let array):
            guard array.count <= limits.maxArrayItems else {
                throw BELStructuredOutputError.arrayTooLarge(maxItems: limits.maxArrayItems)
            }
            for child in array {
                try validateLimits(child, depth: depth + 1, limits: limits)
            }
        case .string(let string):
            guard string.count <= limits.maxStringCharacters else {
                throw BELStructuredOutputError.stringTooLong(maxCharacters: limits.maxStringCharacters)
            }
        case .number, .bool, .null:
            break
        }
    }

    private static func matches(_ value: BELJSONValue, _ kind: BELJSONField.Kind) -> Bool {
        switch (value, kind) {
        case (.string, .string), (.number, .number), (.bool, .boolean),
             (.object, .object), (.array, .array), (_, .any): true
        default: false
        }
    }
}
