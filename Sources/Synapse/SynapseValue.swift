import Foundation

/// A JSON value, as event properties and flag values are exchanged.
///
/// The API types both as free-form JSON (`Record<string, unknown>` for
/// properties, `unknown` for a flag's value), so neither side can be modeled
/// with a concrete Swift type. The literal conformances below keep call sites
/// reading like the dictionaries they replace:
///
/// ```swift
/// Synapse.shared.track("client_viewed", properties: ["id": "abc", "tab": 2])
/// ```
public enum SynapseValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([SynapseValue])
    case object([String: SynapseValue])
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

extension SynapseValue: Codable {
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
        if let value = try? container.decode([SynapseValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: SynapseValue].self) {
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

extension SynapseValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension SynapseValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension SynapseValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension SynapseValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension SynapseValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension SynapseValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: SynapseValue...) { self = .array(elements) }
}

extension SynapseValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, SynapseValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
