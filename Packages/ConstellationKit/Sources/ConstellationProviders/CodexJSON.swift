import Foundation

/// An untyped JSON value, used for JSON-RPC envelopes and for payloads Codex expects echoed back.
enum CodexJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodexJSON])
    case object([String: CodexJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CodexJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> CodexJSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// Decodes this value as a typed payload.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(CodexJSON.self, from: JSONEncoder().encode(value))
    }
}

/// A JSON-RPC request id. Codex sends integers but the schema allows strings.
enum CodexRequestID: Hashable, Sendable, Codable, CustomStringConvertible {
    case int(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var description: String {
        switch self {
        case .int(let value): String(value)
        case .string(let value): value
        }
    }
}
