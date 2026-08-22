import Foundation
import os

@testable import ScopeRatTracker

/// Records outgoing requests and replays canned responses.
final class MockTransport: Transport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data

        static func ok(ingested: Int) -> Reply {
            Reply(status: 200, body: Data(#"{"ingested":\#(ingested)}"#.utf8))
        }

        static func json(_ raw: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(raw.utf8))
        }

        static func status(_ status: Int) -> Reply {
            Reply(status: status, body: Data("error".utf8))
        }
    }

    private struct State {
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        var replies: [Reply] = []
        var fallback = Reply.ok(ingested: 0)
        var thrownError: Error?
    }

    private let lock = NSLock()
    private var state = State()

    init(fallback: Reply = .ok(ingested: 0)) {
        state.fallback = fallback
    }

    func enqueue(_ reply: Reply) {
        lock.withLock { state.replies.append(reply) }
    }

    func failNext(_ error: Error) {
        lock.withLock { state.thrownError = error }
    }

    var requestCount: Int {
        lock.withLock { state.requests.count }
    }

    var requests: [URLRequest] {
        lock.withLock { state.requests }
    }

    func clearRecordings() {
        lock.withLock {
            state.requests = []
            state.bodies = []
        }
    }

    /// The events of the nth uploaded batch, as loosely-typed JSON so tests can
    /// assert on the wire format rather than on Swift types.
    func batch(_ index: Int = 0) -> [[String: Any]] {
        let bodies = lock.withLock { state.bodies }
        guard index < bodies.count,
            let json = try? JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any],
            let events = json["events"] as? [[String: Any]]
        else { return [] }
        return events
    }

    /// Every event uploaded so far, in order.
    var allEvents: [[String: Any]] {
        let count = lock.withLock { state.bodies.count }
        return (0..<count).flatMap { batch($0) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = try lock.withLock {
            if let error = state.thrownError {
                state.thrownError = nil
                state.requests.append(request)
                state.bodies.append(request.httpBody ?? Data())
                throw error
            }
            state.requests.append(request)
            state.bodies.append(request.httpBody ?? Data())
            return state.replies.isEmpty ? state.fallback : state.replies.removeFirst()
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (reply.body, response)
    }
}

/// `UserDefaults` stand-in that starts empty for every test.
final class InMemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    func removeValue(forKey key: String) {
        lock.withLock { values[key] = nil }
    }
}

/// Advanceable clock, so session expiry can be tested without waiting.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }

    var provider: @Sendable () -> Date {
        { [self] in now }
    }
}

extension [[String: Any]] {
    var names: [String] {
        compactMap { $0["event"] as? String }
    }
}

/// Opens the session and delivers the `$session_start` it emits, then forgets
/// the request, so a test can assert on its own events without the lifecycle
/// event in front of them.
func primeSession(_ pipeline: EventPipeline, on transport: MockTransport) async {
    pipeline.currentSessionID()
    await pipeline.flush()
    transport.clearRecordings()
}

func makePipeline(
    transport: MockTransport,
    store: KeyValueStore = InMemoryStore(),
    disk: DiskStore = .none,
    clock: TestClock = TestClock(),
    configure: (inout Configuration) -> Void = { _ in }
) -> EventPipeline {
    var configuration = Configuration(endpoint: URL(string: "https://example.test")!)
    configure(&configuration)
    return EventPipeline(
        writeKey: "wk_test",
        configuration: configuration,
        transport: transport,
        keyValueStore: store,
        disk: disk,
        now: clock.provider
    )
}
