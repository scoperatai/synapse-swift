import Foundation

/// One analytics event, in the exact shape `POST /api/ingest/track` validates.
///
/// Keys are snake_case to match `ingestTrackEventSchema` on the server; every
/// optional is omitted when absent rather than sent as null, which the schema
/// treats as a type error. `occurredAt` is held as the ISO-8601 string that
/// goes on the wire so a queue that survived a disk round-trip reports the
/// moment the event happened, not the moment it was finally uploaded.
struct TrackEvent: Codable, Hashable, Sendable {
    var event: String
    var properties: [String: SynapseValue]?
    var context: [String: SynapseValue]?
    var occurredAt: String?
    var orgID: String?
    var userID: String?
    var anonymousID: String?
    var sessionID: String?
    var release: String?

    enum CodingKeys: String, CodingKey {
        case event
        case properties
        case context
        case occurredAt = "occurred_at"
        case orgID = "org_id"
        case userID = "user_id"
        case anonymousID = "anonymous_id"
        case sessionID = "session_id"
        case release
    }
}

/// The request body: `{ "events": [...] }`, capped at 100 events server-side.
struct IngestBatch: Encodable, Sendable {
    let events: [TrackEvent]
}

/// The success response: `{ "ingested": n }`.
struct IngestResponse: Decodable, Sendable {
    let ingested: Int
}

enum SessionReason: String, Sendable {
    case initial
    case login
    case logout
    case timeout
}

enum ReservedEvent {
    static let sessionStart = "$session_start"
    static let sessionEnd = "$session_end"
}

/// ISO-8601 with fractional seconds in UTC, matching JavaScript's
/// `toISOString()` — the format the server's `occurred_at` parser expects.
enum WireDate {
    static func string(from date: Date) -> String {
        date.formatted(style)
    }

    // `ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the formatter is
    // a mutable class and can't be shared across threads.
    private static let style = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
}
