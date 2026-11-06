import Foundation

/// Synapse options, mirroring `InitOptions` in the TypeScript SDK. Every
/// default matches that client so the same flag rollout and the same session
/// window apply whichever platform a user is on.
public struct Configuration: Sendable {
    /// API origin, no trailing slash. Defaults to ScopeRat's hosted API.
    public var endpoint: URL

    /// Buffered events that trigger an automatic upload.
    public var flushAt: Int

    /// Timer cadence for automatic uploads.
    public var flushInterval: TimeInterval

    /// Per-request timeout, also used for flag fetches.
    public var timeout: TimeInterval

    /// Events retained while the API is unreachable. The oldest is dropped
    /// once full.
    public var maxQueueSize: Int

    /// Inactivity window after which the next event starts a new session.
    public var sessionTimeout: TimeInterval

    /// Environment whose flag overrides apply, e.g. `production`.
    public var environment: String?

    /// Build identifier stamped on every event — a version, build number, or
    /// commit. Clamped to the 250 characters the server accepts.
    public var release: String?

    /// Flag re-fetch cadence.
    public var flagPollInterval: TimeInterval

    /// Called when a batch is dropped or an upload fails, for host-app
    /// logging. The SDK already logs these; this is for surfacing them
    /// somewhere else.
    public var onError: (@Sendable (SynapseError) -> Void)?

    public init(
        endpoint: URL = Configuration.defaultEndpoint,
        flushAt: Int = 10,
        flushInterval: TimeInterval = 3,
        timeout: TimeInterval = 10,
        maxQueueSize: Int = 1000,
        sessionTimeout: TimeInterval = 30 * 60,
        environment: String? = nil,
        release: String? = nil,
        flagPollInterval: TimeInterval = 60,
        onError: (@Sendable (SynapseError) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.flushAt = flushAt
        self.flushInterval = flushInterval
        self.timeout = timeout
        self.maxQueueSize = maxQueueSize
        self.sessionTimeout = sessionTimeout
        self.environment = environment
        self.release = release?.trimmed(to: 250)
        self.flagPollInterval = flagPollInterval
        self.onError = onError
    }

    public static let defaultEndpoint = URL(string: "https://api.scoperat.ai")!

    /// The server caps a batch at 100 events regardless of `flushAt`.
    static let maxBatchSize = 100

    /// Ceiling on the exponential retry backoff.
    static let maxRetryBackoff: TimeInterval = 60
}

public enum SynapseError: Error, Sendable {
    /// The API rejected or could not be reached for this many events.
    case uploadFailed(events: Int, underlying: String)
    /// The queue was full and the oldest event was discarded.
    case queueOverflow(dropped: Int)
}

extension String {
    func trimmed(to limit: Int) -> String {
        count <= limit ? self : String(prefix(limit))
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
