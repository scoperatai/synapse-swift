import Foundation
import os

public struct FlushResult: Sendable, Equatable {
    public let success: Bool
    public let ingested: Int
}

/// Buffers events, stamps them with identity and session, and uploads them in
/// batches to `POST /api/ingest/track`.
///
/// State is guarded by a lock rather than an actor so `track` stays
/// synchronous and order-preserving. An actor would make every call site
/// either `await` or spawn a `Task`, and separate tasks hitting an actor have
/// no defined arrival order — meaning two events tracked in sequence could be
/// stamped with sessions out of order. Uploads happen off the lock; only the
/// buffer hand-off is guarded.
final class EventPipeline: Sendable {
    private struct State {
        var buffer: [TrackEvent] = []
        var identity: Identity
        var sessionID: String?
        /// Consecutive upload failures, driving the retry backoff.
        var flushFailures = 0
        /// Automatic flushes are suppressed until this moment.
        var nextFlushAllowedAt = Date.distantPast
        var isFlushing = false
        var timerTask: Task<Void, Never>?
    }

    private let writeKey: String
    private let configuration: Configuration
    private let transport: Transport
    private let disk: DiskStore
    private let identityStore: IdentityStore
    private let sessionStore: SessionStore
    private let now: @Sendable () -> Date
    private let state: OSAllocatedUnfairLock<State>

    init(
        writeKey: String,
        configuration: Configuration,
        transport: Transport,
        keyValueStore: KeyValueStore,
        disk: DiskStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.writeKey = writeKey
        self.configuration = configuration
        self.transport = transport
        self.disk = disk
        identityStore = IdentityStore(store: keyValueStore)
        sessionStore = SessionStore(store: keyValueStore)
        self.now = now

        var initial = State(identity: Identity(anonymousID: ""))
        initial.identity.anonymousID = identityStore.loadOrCreateAnonymousID()
        // Events the last run couldn't deliver. Taken off disk immediately so a
        // crash can't replay them a second time.
        if let pending = disk.load([TrackEvent].self), !pending.isEmpty {
            initial.buffer = Array(pending.suffix(configuration.maxQueueSize))
            disk.clear()
        }
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    var identity: Identity {
        state.withLock { $0.identity }
    }

    var pendingCount: Int {
        state.withLock { $0.buffer.count }
    }

    // MARK: - Tracking

    func track(
        _ name: String,
        properties: [String: SynapseValue]? = nil,
        context: [String: SynapseValue]? = nil
    ) {
        let timestamp = now()
        let outcome = state.withLock { state -> (shouldFlush: Bool, dropped: Int) in
            var dropped = ensureSession(at: timestamp, into: &state)
            let event = makeEvent(
                name: name,
                properties: properties,
                context: context,
                occurredAt: timestamp,
                sessionID: state.sessionID,
                state: state
            )
            dropped += enqueue(event, into: &state)
            return (state.buffer.count >= configuration.flushAt, dropped)
        }

        report(dropped: outcome.dropped)
        if outcome.shouldFlush {
            maybeFlush()
        }
    }

    /// Attribute subsequent events to `userID`, and backfill the ones already
    /// buffered but not yet uploaded.
    ///
    /// Returns whether this was a real login (or an account switch), which the
    /// facade uses to decide whether to re-evaluate flags for the new identity.
    @discardableResult
    func identify(userID: String, traits: [String: SynapseValue]?) -> Bool {
        let timestamp = now()
        let outcome = state.withLock { state -> (isNewUser: Bool, dropped: Int) in
            // In-memory first, falling back to the persisted id so being
            // re-identified at launch doesn't look like a fresh login.
            let previousUserID = state.identity.userID ?? identityStore.storedUserID
            state.identity.userID = userID
            if let traits {
                state.identity.traits = traits
                if let orgID = traits["orgId"]?.stringValue {
                    state.identity.orgID = orgID
                }
            }

            let orgID = state.identity.orgID
            for index in state.buffer.indices {
                if state.buffer[index].userID == nil {
                    state.buffer[index].userID = userID
                }
                if state.buffer[index].orgID == nil {
                    state.buffer[index].orgID = orgID
                }
            }

            guard userID != previousUserID else { return (false, 0) }
            identityStore.setStoredUserID(userID)
            let dropped = startSession(reason: .login, at: timestamp, into: &state)
            return (true, dropped)
        }

        report(dropped: outcome.dropped)
        return outcome.isNewUser
    }

    /// Forget the current user: end their session, drop their traits, and mint
    /// a new anonymous id so later events aren't tied back to them.
    func reset() {
        let timestamp = now()
        let dropped = state.withLock { state -> Int in
            let dropped = endSession(reason: .logout, at: timestamp, into: &state)
            state.identity.userID = nil
            state.identity.orgID = nil
            state.identity.traits = [:]
            state.identity.anonymousID = identityStore.rotateAnonymousID()
            identityStore.clearStoredUserID()
            return dropped
        }

        report(dropped: dropped)
        // The `$session_end` just queued is the last thing this user will
        // produce — get it out before the app moves on.
        Task { _ = await flush() }
    }

    /// The current session id, rotating it first if the session has lapsed.
    @discardableResult
    func currentSessionID() -> String? {
        let timestamp = now()
        let outcome = state.withLock { state -> (sessionID: String?, dropped: Int) in
            let dropped = ensureSession(at: timestamp, into: &state)
            return (state.sessionID, dropped)
        }
        report(dropped: outcome.dropped)
        return outcome.sessionID
    }

    // MARK: - Sessions

    /// Adopt the stored session, or start a new one when none exists or the
    /// last activity is older than `sessionTimeout`. Returns dropped-event
    /// count so the caller can report overflow after releasing the lock.
    private func ensureSession(at timestamp: Date, into state: inout State) -> Int {
        let lastActivity = sessionStore.lastActivity
        let existingID = state.sessionID ?? sessionStore.sessionID
        let expired =
            lastActivity == nil
            || timestamp.timeIntervalSince(lastActivity!) > configuration.sessionTimeout

        if let existingID, !expired {
            state.sessionID = existingID
            sessionStore.touch(at: timestamp)
            return 0
        }

        var dropped = 0
        if let existingID {
            // The previous session lapsed. Close it as of the last activity we
            // saw, not now, so its duration reflects the visit rather than how
            // long the user stayed away.
            dropped += emitSessionEvent(
                ReservedEvent.sessionEnd,
                sessionID: existingID,
                reason: .timeout,
                occurredAt: lastActivity ?? timestamp,
                into: &state
            )
        }
        dropped += beginSession(
            reason: existingID == nil ? .initial : .timeout,
            at: timestamp,
            into: &state
        )
        return dropped
    }

    private func startSession(
        reason: SessionReason,
        at timestamp: Date,
        into state: inout State
    ) -> Int {
        var dropped = 0
        if let existingID = state.sessionID ?? sessionStore.sessionID {
            dropped += emitSessionEvent(
                ReservedEvent.sessionEnd,
                sessionID: existingID,
                reason: reason,
                occurredAt: timestamp,
                into: &state
            )
        }
        dropped += beginSession(reason: reason, at: timestamp, into: &state)
        return dropped
    }

    private func beginSession(
        reason: SessionReason,
        at timestamp: Date,
        into state: inout State
    ) -> Int {
        let sessionID = UUID().uuidString.lowercased()
        state.sessionID = sessionID
        sessionStore.persist(sessionID: sessionID, activityAt: timestamp)
        return emitSessionEvent(
            ReservedEvent.sessionStart,
            sessionID: sessionID,
            reason: reason,
            occurredAt: timestamp,
            into: &state
        )
    }

    private func endSession(
        reason: SessionReason,
        at timestamp: Date,
        into state: inout State
    ) -> Int {
        var dropped = 0
        if let existingID = state.sessionID ?? sessionStore.sessionID {
            dropped += emitSessionEvent(
                ReservedEvent.sessionEnd,
                sessionID: existingID,
                reason: reason,
                occurredAt: timestamp,
                into: &state
            )
        }
        state.sessionID = nil
        sessionStore.clear()
        return dropped
    }

    /// Queue a lifecycle event already stamped with its session id, so it can
    /// never re-enter session resolution and recurse.
    private func emitSessionEvent(
        _ name: String,
        sessionID: String,
        reason: SessionReason,
        occurredAt: Date,
        into state: inout State
    ) -> Int {
        let event = makeEvent(
            name: name,
            properties: ["reason": .string(reason.rawValue)],
            context: nil,
            occurredAt: occurredAt,
            sessionID: sessionID,
            state: state
        )
        return enqueue(event, into: &state)
    }

    // MARK: - Queue

    private func makeEvent(
        name: String,
        properties: [String: SynapseValue]?,
        context: [String: SynapseValue]?,
        occurredAt: Date,
        sessionID: String?,
        state: State
    ) -> TrackEvent {
        var merged = DeviceContext.current
        if !state.identity.traits.isEmpty {
            merged["traits"] = .object(state.identity.traits)
        }
        if let context {
            merged.merge(context) { _, explicit in explicit }
        }

        return TrackEvent(
            event: name,
            properties: properties,
            context: merged,
            occurredAt: WireDate.string(from: occurredAt),
            orgID: state.identity.orgID,
            userID: state.identity.userID,
            anonymousID: state.identity.anonymousID,
            sessionID: sessionID,
            release: configuration.release
        )
    }

    /// Append, evicting the oldest event when the queue is full. Returns how
    /// many were dropped, for reporting once the lock is released.
    private func enqueue(_ event: TrackEvent, into state: inout State) -> Int {
        var dropped = 0
        while state.buffer.count >= configuration.maxQueueSize {
            state.buffer.removeFirst()
            dropped += 1
        }
        state.buffer.append(event)
        return dropped
    }

    private func report(dropped: Int) {
        guard dropped > 0 else { return }
        Log.events.warning("Event queue full — dropped \(dropped, privacy: .public) event(s)")
        configuration.onError?(.queueOverflow(dropped: dropped))
    }

    // MARK: - Flushing

    /// Flush unless a retry backoff is in effect or an upload is already in
    /// flight. Explicit `flush()` ignores both.
    private func maybeFlush() {
        let timestamp = now()
        let allowed = state.withLock { state in
            !state.isFlushing && timestamp >= state.nextFlushAllowedAt
        }
        guard allowed else { return }
        Task { _ = await flush() }
    }

    @discardableResult
    func flush() async -> FlushResult {
        let batch = state.withLock { state -> [TrackEvent] in
            guard !state.buffer.isEmpty else { return [] }
            let batch = Array(state.buffer.prefix(Configuration.maxBatchSize))
            state.buffer.removeFirst(batch.count)
            state.isFlushing = true
            return batch
        }
        guard !batch.isEmpty else {
            return FlushResult(success: true, ingested: 0)
        }
        defer { state.withLock { $0.isFlushing = false } }

        do {
            let (data, response) = try await transport.send(makeIngestRequest(for: batch))
            guard response.isSuccess else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if response.isRetryable {
                    requeue(batch)
                }
                recordFailure(
                    events: batch.count,
                    reason: "API returned \(response.statusCode): \(body)"
                )
                return FlushResult(success: false, ingested: 0)
            }
            state.withLock { state in
                state.flushFailures = 0
                state.nextFlushAllowedAt = .distantPast
            }
            let ingested = (try? JSONDecoder().decode(IngestResponse.self, from: data))?.ingested
            return FlushResult(success: true, ingested: ingested ?? batch.count)
        } catch {
            requeue(batch)
            recordFailure(events: batch.count, reason: error.localizedDescription)
            return FlushResult(success: false, ingested: 0)
        }
    }

    private func makeIngestRequest(for batch: [TrackEvent]) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint.appending(path: "/api/ingest/track"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(IngestBatch(events: batch))
        return request
    }

    /// Put a failed batch back at the head of the queue, trimming the oldest if
    /// that overshoots the cap.
    private func requeue(_ batch: [TrackEvent]) {
        let dropped = state.withLock { state -> Int in
            state.buffer.insert(contentsOf: batch, at: 0)
            let overflow = max(0, state.buffer.count - configuration.maxQueueSize)
            if overflow > 0 {
                state.buffer.removeFirst(overflow)
            }
            return overflow
        }
        report(dropped: dropped)
    }

    /// Push the next automatic flush out exponentially so an unreachable
    /// endpoint isn't retried on every timer tick.
    private func recordFailure(events: Int, reason: String) {
        let timestamp = now()
        state.withLock { state in
            state.flushFailures += 1
            let delay = min(
                configuration.flushInterval * pow(2, Double(state.flushFailures)),
                Configuration.maxRetryBackoff
            )
            state.nextFlushAllowedAt = timestamp.addingTimeInterval(delay)
        }
        Log.events.error("Failed to upload \(events, privacy: .public) event(s): \(reason, privacy: .public)")
        configuration.onError?(.uploadFailed(events: events, underlying: reason))
    }

    // MARK: - Timer and lifecycle

    func startTimer() {
        let task = Task { [weak self] in
            guard let self else { return }
            let interval = UInt64(configuration.flushInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                if pendingCount > 0 {
                    maybeFlush()
                }
            }
        }
        let previous = state.withLock { state -> Task<Void, Never>? in
            let previous = state.timerTask
            state.timerTask = task
            return previous
        }
        previous?.cancel()
    }

    func stopTimer() {
        let task = state.withLock { state -> Task<Void, Never>? in
            let task = state.timerTask
            state.timerTask = nil
            return task
        }
        task?.cancel()
    }

    /// Called when the app backgrounds. Uploads what it can, then writes the
    /// rest to disk in case the process is terminated before the next launch.
    ///
    /// Flush first, persist second: the reverse would leave a copy on disk of
    /// events that were also delivered, and a relaunch would send them twice.
    func drainForBackground() async {
        await flush()
        persistPending()
    }

    private func persistPending() {
        let pending = state.withLock { $0.buffer }
        if pending.isEmpty {
            disk.clear()
        } else {
            disk.save(pending)
        }
    }

    func shutdown() async {
        stopTimer()
        while pendingCount > 0 {
            let result = await flush()
            // A failure either re-queued the batch or dropped it; either way
            // looping again can't make progress.
            if !result.success { break }
        }
        persistPending()
    }
}
