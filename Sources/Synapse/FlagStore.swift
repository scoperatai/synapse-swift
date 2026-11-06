import Foundation
import os

/// Holds the evaluated flags and keeps them fresh.
///
/// Reads are synchronous and lock-guarded rather than actor-isolated, because
/// the callers are SwiftUI `body` and `if` conditions — an `await` there would
/// force every flag check to become a loading state. Fetching is async and
/// happens on a polling task; only the cache swap takes the lock.
///
/// Two mobile-specific behaviors, both absent from the web SDK: the last
/// response is cached to disk and loaded at launch, so flags are correct on the
/// first frame after a cold start instead of falling back to defaults until the
/// network answers; and polling suspends while the app is backgrounded.
final class FlagStore: Sendable {
    private struct State {
        var flags: [String: EvaluatedFlag] = [:]
        var hasLoaded = false
        var readyContinuations: [CheckedContinuation<Void, Never>] = []
        var listeners: [UUID: @Sendable () -> Void] = [:]
        var pollTask: Task<Void, Never>?
    }

    private let writeKey: String
    private let endpoint: URL
    private let environment: String?
    private let pollInterval: TimeInterval
    private let transport: Transport
    private let disk: DiskStore
    private let identityProvider: @Sendable () -> Identity
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        writeKey: String,
        configuration: Configuration,
        transport: Transport,
        disk: DiskStore,
        identityProvider: @escaping @Sendable () -> Identity
    ) {
        self.writeKey = writeKey
        endpoint = configuration.endpoint
        environment = configuration.environment
        pollInterval = configuration.flagPollInterval
        self.transport = transport
        self.disk = disk
        self.identityProvider = identityProvider

        if let cached = disk.load([String: EvaluatedFlag].self) {
            state.withLock { $0.flags = cached }
        }
    }

    // MARK: - Reads

    func flag(_ key: String) -> EvaluatedFlag? {
        state.withLock { $0.flags[key] }
    }

    var all: [String: EvaluatedFlag] {
        state.withLock { $0.flags }
    }

    /// Whether a server response has been applied yet. False means reads are
    /// answered from the disk cache or from caller-supplied defaults.
    var hasLoaded: Bool {
        state.withLock { $0.hasLoaded }
    }

    /// Suspends until the first successful fetch. Returns immediately if one
    /// already happened.
    func waitUntilLoaded() async {
        await withCheckedContinuation { continuation in
            let alreadyLoaded = state.withLock { state -> Bool in
                if state.hasLoaded { return true }
                state.readyContinuations.append(continuation)
                return false
            }
            if alreadyLoaded {
                continuation.resume()
            }
        }
    }

    func addListener(_ listener: @escaping @Sendable () -> Void) -> FlagSubscription {
        let id = UUID()
        state.withLock { $0.listeners[id] = listener }
        return FlagSubscription { [weak self] in
            self?.state.withLock { $0.listeners[id] = nil }
        }
    }

    // MARK: - Refresh

    func startPolling() {
        let task = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await refresh()
            }
        }
        let previous = state.withLock { state -> Task<Void, Never>? in
            let previous = state.pollTask
            state.pollTask = task
            return previous
        }
        previous?.cancel()
    }

    func stopPolling() {
        let task = state.withLock { state -> Task<Void, Never>? in
            let task = state.pollTask
            state.pollTask = nil
            return task
        }
        task?.cancel()
    }

    /// Fetch and apply the current evaluation. Failures are swallowed: a flag
    /// read must always answer, so the previous values (or the caller's
    /// default) stand in until the next poll succeeds.
    func refresh() async {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return
        }
        components.path = "/api/flags"

        var query: [URLQueryItem] = []
        if let environment {
            query.append(URLQueryItem(name: "environment", value: environment))
        }
        let identity = identityProvider()
        if let identifier = identity.flagIdentifier {
            query.append(URLQueryItem(name: "identifier", value: identifier))
        }
        if let orgID = identity.orgID {
            query.append(URLQueryItem(name: "orgId", value: orgID))
        }
        components.queryItems = query.isEmpty ? nil : query

        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await transport.send(request)
            guard response.isSuccess else {
                Log.flags.debug("Flag fetch returned \(response.statusCode, privacy: .public)")
                return
            }
            let decoded = try JSONDecoder().decode(FlagsResponse.self, from: data)
            apply(decoded.flags)
        } catch {
            Log.flags.debug("Flag fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ flags: [String: EvaluatedFlag]) {
        let (listeners, continuations, changed) = state.withLock {
            state -> ([@Sendable () -> Void], [CheckedContinuation<Void, Never>], Bool) in
            let changed = state.flags != flags
            state.flags = flags
            state.hasLoaded = true
            let continuations = state.readyContinuations
            state.readyContinuations = []
            return (Array(state.listeners.values), continuations, changed)
        }

        disk.save(flags)

        for continuation in continuations {
            continuation.resume()
        }
        // Only notify on an actual change: listeners drive SwiftUI
        // invalidation, and a poll that returns identical values every minute
        // shouldn't redraw the app.
        guard changed else { return }
        for listener in listeners {
            listener()
        }
    }
}
