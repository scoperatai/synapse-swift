import Foundation

/// A flag as `GET /api/flags` resolved it for the current identity.
///
/// Evaluation is entirely server-side — the client never sees targeting rules
/// or rollout percentages, only the answer — so this is the whole model.
public struct EvaluatedFlag: Codable, Hashable, Sendable {
    public let key: String
    public let value: SynapseValue
    public let type: ValueType
    public let source: Source

    public enum ValueType: String, Codable, Sendable {
        case boolean, string, number, json
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ValueType(rawValue: raw) ?? .unknown
        }
    }

    /// Why the flag resolved the way it did: the flag's default, an
    /// environment override, a targeting-rule match, or the rollout bucket.
    public enum Source: String, Codable, Sendable {
        case `default`, override, targeted, rollout
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .unknown
        }
    }
}

/// The `GET /api/flags` response body.
struct FlagsResponse: Codable, Sendable {
    let flags: [String: EvaluatedFlag]
}

/// Handle returned by flag-change subscriptions. Dropping it — or calling
/// `cancel()` — removes the listener; SwiftUI hosts usually just hold it for
/// the lifetime of an observable object.
public final class FlagSubscription: Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel()
    }

    deinit {
        onCancel()
    }
}
