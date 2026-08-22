import Foundation

/// A JSON value, as event properties and flag values are exchanged.
///
/// The API types both as free-form JSON (`Record<string, unknown>` for
/// properties, `unknown` for a flag's value), so neither side can be modeled
/// with a concrete Swift type. The literal conformances below keep call sites
/// reading like the dictionaries they replace:
///
/// ```swift
/// ScopeRat.shared.track("client_viewed", properties: ["id": "abc", "tab": 2])
/// ```
public enum TrackerValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([TrackerValue])
    case object([String: TrackerValue])
    case null

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

extension TrackerValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Bool before Double: JSONDecoder will happily read `true` as 1.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([TrackerValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: TrackerValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension TrackerValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension TrackerValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension TrackerValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension TrackerValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension TrackerValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension TrackerValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: TrackerValue...) { self = .array(elements) }
}

extension TrackerValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, TrackerValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
