import CryptoKit
import Foundation
import os

/// ScopeRat Synapse: analytics events and feature flags.
///
/// Start it once, early — typically as the app's model is constructed:
///
/// ```swift
/// Synapse.shared.start(
///     writeKey: AppConfig.scopeRatWriteKey,
///     configuration: Configuration(environment: "production", release: AppConfig.version)
/// )
/// ```
///
/// Then track events and read flags from anywhere, on any thread. Every call
/// before `start` is a no-op, and flag reads fall back to the default you pass,
/// so a build without a write key behaves like a build without the SDK.
///
/// This is a port of `@scoperat/synapse`, matching it on event shape, batching,
/// retry, and session semantics. Two capabilities are deliberately absent:
/// error capture (iOS crash reporting is a different problem than
/// `window.onerror`) and the ticket/announce widgets (DOM-bound UI).
public final class Synapse: Sendable {
    public static let shared = Synapse()

    private struct Runtime: Sendable {
        let pipeline: EventPipeline
        let flags: FlagStore
        let lifecycle: LifecycleObserver
    }

    private let runtime = OSAllocatedUnfairLock<Runtime?>(initialState: nil)

    init() {}

    // MARK: - Lifecycle

    /// Configure and start Synapse. A blank write key is ignored, which is
    /// how a debug build opts out without conditional call sites.
    ///
    /// Calling this again replaces the previous configuration; any events still
    /// queued from it are flushed first.
    public func start(writeKey: String, configuration: Configuration = Configuration()) {
        guard let writeKey = writeKey.nilIfBlank else {
            Log.events.info("No write key — tracking disabled")
            return
        }

        let previous = runtime.withLock { $0 }
        if previous != nil {
            Task { await previous?.pipeline.shutdown() }
            previous?.flags.stopPolling()
            previous?.lifecycle.stop()
        }

        let namespace = Self.namespace(for: writeKey)
        let transport = URLSessionTransport(timeout: configuration.timeout)
        let pipeline = EventPipeline(
            writeKey: writeKey,
            configuration: configuration,
            transport: transport,
            keyValueStore: UserDefaults.standard,
            disk: DiskStore(name: "events.json", namespace: namespace)
        )
        let flags = FlagStore(
            writeKey: writeKey,
            configuration: configuration,
            transport: transport,
            disk: DiskStore(name: "flags.json", namespace: namespace),
            identityProvider: { pipeline.identity }
        )
        let lifecycle = LifecycleObserver(
            onBackground: {
                flags.stopPolling()
                Task { await pipeline.drainForBackground() }
            },
            onForeground: {
                flags.startPolling()
                pipeline.startTimer()
            }
        )

        runtime.withLock {
            $0 = Runtime(pipeline: pipeline, flags: flags, lifecycle: lifecycle)
        }

        pipeline.startTimer()
        flags.startPolling()
        lifecycle.start()
        // Opens the session (or resumes an unexpired one) at launch rather than
        // waiting for the first tracked event.
        pipeline.currentSessionID()
    }

    /// Flush, stop timers, and release the runtime. Rarely needed in an app;
    /// useful in tests and app extensions.
    public func shutdown() async {
        let previous = runtime.withLock { runtime -> Runtime? in
            let previous = runtime
            runtime = nil
            return previous
        }
        previous?.flags.stopPolling()
        previous?.lifecycle.stop()
        await previous?.pipeline.shutdown()
    }

    public var isStarted: Bool {
        runtime.withLock { $0 != nil }
    }

    // MARK: - Events

    /// Queue an event. Returns immediately; delivery is batched.
    public func track(_ event: String, properties: [String: SynapseValue]? = nil) {
        pipeline?.track(event, properties: properties)
    }

    /// Attribute subsequent events to a user, and re-evaluate flags for them.
    ///
    /// `traits` is free-form and lands under the event's `context.traits`;
    /// `orgId` is special-cased into the event's `org_id` column, and `email`
    /// and `name` are the conventional keys the dashboard displays.
    public func identify(_ userID: String, traits: [String: SynapseValue]? = nil) {
        guard let runtime = runtime.withLock({ $0 }) else { return }
        runtime.pipeline.identify(userID: userID, traits: traits)
        // Flags target on user id, so the cached evaluation is stale the moment
        // identity changes — refresh whether or not this was a new login.
        Task { await runtime.flags.refresh() }
    }

    /// Clear the identified user on logout: ends their session, rotates the
    /// anonymous id, and re-evaluates flags anonymously.
    public func reset() {
        guard let runtime = runtime.withLock({ $0 }) else { return }
        runtime.pipeline.reset()
        Task { await runtime.flags.refresh() }
    }

    /// Upload everything queued. Awaiting this is only necessary before the
    /// process goes away; normal operation flushes on its own.
    @discardableResult
    public func flush() async -> FlushResult {
        guard let pipeline else { return FlushResult(success: true, ingested: 0) }
        return await pipeline.flush()
    }

    public var sessionID: String? {
        pipeline?.currentSessionID()
    }

    public var anonymousID: String? {
        pipeline?.identity.anonymousID
    }

    // MARK: - Feature flags

    /// Read a boolean flag. Returns `defaultValue` when the flag is unknown,
    /// isn't a boolean, or hasn't been fetched yet.
    public func isEnabled(_ key: String, default defaultValue: Bool = false) -> Bool {
        flags?.flag(key)?.value.boolValue ?? defaultValue
    }

    public func string(_ key: String, default defaultValue: String) -> String {
        flags?.flag(key)?.value.stringValue ?? defaultValue
    }

    public func number(_ key: String, default defaultValue: Double) -> Double {
        flags?.flag(key)?.value.doubleValue ?? defaultValue
    }

    /// A JSON-valued flag, for structured configuration.
    public func json(_ key: String) -> SynapseValue? {
        flags?.flag(key)?.value
    }

    /// The full evaluation, including which rule produced the value.
    public func flag(_ key: String) -> EvaluatedFlag? {
        flags?.flag(key)
    }

    public var allFlags: [String: EvaluatedFlag] {
        flags?.all ?? [:]
    }

    /// Whether the server has answered yet. Useful for holding a screen back
    /// rather than rendering the default and flipping a moment later.
    public var flagsHaveLoaded: Bool {
        flags?.hasLoaded ?? false
    }

    public func waitForFlags() async {
        await flags?.waitUntilLoaded()
    }

    public func refreshFlags() async {
        await flags?.refresh()
    }

    /// Observe flag changes — a poll returning different values, or a
    /// re-evaluation after `identify`. The listener runs off the main actor;
    /// hop before touching UI state. Retain the subscription for as long as you
    /// want the callback: releasing it unsubscribes.
    public func observeFlags(_ listener: @escaping @Sendable () -> Void) -> FlagSubscription? {
        flags?.addListener(listener)
    }

    // MARK: - Internals

    private var pipeline: EventPipeline? {
        runtime.withLock { $0?.pipeline }
    }

    private var flags: FlagStore? {
        runtime.withLock { $0?.flags }
    }

    /// Per-write-key directory for the on-disk queue and flag cache, so
    /// pointing a build at a different project can't replay the old one's
    /// events. SHA-256 because `hashValue` is seeded per process and would
    /// produce a different directory on every launch.
    private static func namespace(for writeKey: String) -> String {
        let digest = SHA256.hash(data: Data(writeKey.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
