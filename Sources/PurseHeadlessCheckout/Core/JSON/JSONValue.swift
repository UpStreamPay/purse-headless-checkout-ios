// Web: plain JS objects passed around as `Record<string, unknown>`
// Same: free-form JSON at the edges, typed envelopes everywhere else.
// Differs: Android keeps `org.json.JSONObject`; Swift 6 needs a `Sendable` value type.

import Foundation

/// A free-form JSON value. The Payment API's partner-specific bodies (`payment_data`,
/// `partner_data`, `order`, `payment_preferences`) have no fixed shape — only a plugin knows what
/// goes in them — so they stay untyped, exactly as they do on web and Android.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// Kept as the literal source text so a decimal amount never round-trips through `Double`.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Convenience accessors

public extension JSONValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case let .number(text) = self { return Int(text) }
        return nil
    }

    var decimalValue: Decimal? {
        if case let .number(text) = self { return Decimal(string: text) }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(values) = self { return values }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(values) = self { return values }
        return nil
    }

    /// Member lookup that yields `nil` for both "absent" and "explicitly null", the distinction
    /// callers almost never want. Use `objectValue` directly when it matters.
    subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self, let value = members[key], value != .null else { return nil }
        return value
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            // `Decimal`'s description is the shortest exact form of the literal, so `0.01` stays
            // `0.01` rather than becoming `0.010000000000000000208…` via `Double`.
            self = .number(value.description)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrepresentable JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(text):
            // Re-encode as a number, not a string. A literal we could not parse back into `Decimal`
            // would silently become a quoted string on the wire, so fail loudly instead.
            guard let value = Decimal(string: text) else {
                throw EncodingError.invalidValue(
                    text,
                    EncodingError.Context(codingPath: container.codingPath, debugDescription: "Not a JSON number")
                )
            }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(values):
            try container.encode(values)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(String(value)) }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
