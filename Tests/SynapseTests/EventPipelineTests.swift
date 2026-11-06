import Foundation
import Testing
import os

@testable import Synapse

@Suite("Event wire format")
struct EventWireFormatTests {
    @Test("track produces the snake_case shape the ingest schema validates")
    func wireShape() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport) { $0.release = "1.4.2" }

        pipeline.track("client_viewed", properties: ["client_id": "abc", "tab": 2])
        await pipeline.flush()

        let event = try #require(
            transport.allEvents.first { $0["event"] as? String == "client_viewed" }
        )
        #expect(event["occurred_at"] is String)
        #expect(event["anonymous_id"] is String)
        #expect(event["session_id"] is String)
        #expect(event["release"] as? String == "1.4.2")

        let properties = try #require(event["properties"] as? [String: Any])
        #expect(properties["client_id"] as? String == "abc")
        #expect(properties["tab"] as? Double == 2)

        // Absent optionals are omitted rather than sent as null, which the
        // schema treats as a type error.
        #expect(event["user_id"] == nil)
        #expect(event["org_id"] == nil)
        // `event_source` has no mobile member, so platform carries the
        // distinction instead and `source` is left off entirely.
        #expect(event["source"] == nil)
    }

    @Test("context identifies the platform and the app build")
    func contextShape() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)

        pipeline.track("opened")
        await pipeline.flush()

        let event = try #require(transport.allEvents.first { $0["event"] as? String == "opened" })
        let context = try #require(event["context"] as? [String: Any])
        #expect(["ios", "macos", "tvos", "watchos"].contains(context["platform"] as? String ?? ""))
        #expect(context["locale"] is String)
        #expect(context["timezone"] is String)
        let os = try #require(context["os"] as? [String: Any])
        #expect(os["version"] is String)
        let device = try #require(context["device"] as? [String: Any])
        #expect(device["manufacturer"] as? String == "Apple")
    }

    @Test("occurred_at is UTC ISO-8601 with fractional seconds")
    func timestampFormat() {
        let formatted = WireDate.string(from: Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(formatted == "2023-11-14T22:13:20.500Z")
    }

    @Test("identify traits ride along under context.traits")
    func traitsInContext() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)

        pipeline.identify(userID: "user_1", traits: ["email": "a@b.co", "orgId": "org_9"])
        pipeline.track("viewed")
        await pipeline.flush()

        let event = try #require(transport.allEvents.first { $0["event"] as? String == "viewed" })
        #expect(event["user_id"] as? String == "user_1")
        #expect(event["org_id"] as? String == "org_9")
        let context = try #require(event["context"] as? [String: Any])
        let traits = try #require(context["traits"] as? [String: Any])
        #expect(traits["email"] as? String == "a@b.co")
    }

    @Test("caller-supplied context wins over the automatic values")
    func contextOverride() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)

        pipeline.track("viewed", properties: nil, context: ["locale": "xx_YY"])
        await pipeline.flush()

        let event = try #require(transport.allEvents.first { $0["event"] as? String == "viewed" })
        let context = try #require(event["context"] as? [String: Any])
        #expect(context["locale"] as? String == "xx_YY")
    }
}

@Suite("Batching and retry")
struct FlushTests {
    @Test("a batch is uploaded to the ingest endpoint with the write key")
    func requestShape() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)

        pipeline.track("a")
        await pipeline.flush()

        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString == "https://example.test/api/ingest/track")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer wk_test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("no request is made when nothing is queued")
    func emptyFlush() async {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)
        // The launch session-start event is queued by `start()`, not by the
        // pipeline, so a fresh pipeline really is empty.
        let result = await pipeline.flush()
        #expect(result == FlushResult(success: true, ingested: 0))
        #expect(transport.requestCount == 0)
    }

    @Test("a batch is capped at the 100 events the server accepts")
    func batchCap() async {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport) { $0.flushAt = 1_000 }
        await primeSession(pipeline, on: transport)

        for index in 0..<150 {
            pipeline.track("event_\(index)")
        }
        await pipeline.flush()

        #expect(transport.batch(0).count == Configuration.maxBatchSize)
        #expect(pipeline.pendingCount == 50)
    }

    @Test("a 500 keeps the batch for the next attempt")
    func retriesServerError() async {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)
        await primeSession(pipeline, on: transport)

        transport.enqueue(.status(503))
        pipeline.track("a")
        pipeline.track("b")
        let result = await pipeline.flush()

        #expect(result.success == false)
        #expect(pipeline.pendingCount == 2)
    }

    @Test("a rejected key drops the batch instead of retrying forever")
    func dropsUnauthorized() async {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)
        await primeSession(pipeline, on: transport)

        transport.enqueue(.status(401))
        pipeline.track("a")
        let result = await pipeline.flush()

        #expect(result.success == false)
        #expect(pipeline.pendingCount == 0)
    }

    @Test("a network error keeps the batch")
    func retriesNetworkError() async {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)
        await primeSession(pipeline, on: transport)

        transport.failNext(URLError(.notConnectedToInternet))
        pipeline.track("a")
        let result = await pipeline.flush()

        #expect(result.success == false)
        #expect(pipeline.pendingCount == 1)
    }

    @Test("requeued events retain their original order")
    func retryPreservesOrder() async {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport)
        await primeSession(pipeline, on: transport)

        transport.enqueue(.status(503))
        pipeline.track("first")
        pipeline.track("second")
        await pipeline.flush()
        await pipeline.flush()

        #expect(transport.batch(1).names == ["first", "second"])
    }

    @Test("a full queue drops the oldest event and reports it")
    func queueOverflow() async {
        let transport = MockTransport()
        let reported = OSAllocatedUnfairLock(initialState: 0)
        let pipeline = makePipeline(transport: transport) { configuration in
            configuration.maxQueueSize = 3
            configuration.flushAt = 1_000
            configuration.onError = { error in
                if case let .queueOverflow(dropped) = error {
                    reported.withLock { $0 += dropped }
                }
            }
        }
        await primeSession(pipeline, on: transport)

        for name in ["a", "b", "c", "d", "e"] {
            pipeline.track(name)
        }
        await pipeline.flush()

        #expect(pipeline.pendingCount == 0)
        #expect(transport.batch(0).names == ["c", "d", "e"])
        #expect(reported.withLock { $0 } == 2)
    }

    @Test("an upload failure is reported to the host app")
    func reportsUploadFailure() async {
        let transport = MockTransport()
        let failures = OSAllocatedUnfairLock(initialState: [Int]())
        let pipeline = makePipeline(transport: transport) { configuration in
            configuration.onError = { error in
                if case let .uploadFailed(events, _) = error {
                    failures.withLock { $0.append(events) }
                }
            }
        }
        await primeSession(pipeline, on: transport)

        transport.enqueue(.status(503))
        pipeline.track("a")
        await pipeline.flush()

        #expect(failures.withLock { $0 } == [1])
    }
}

@Suite("Sessions")
struct SessionTests {
    @Test("the first event opens a session")
    func initialSession() async {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport) { $0.flushAt = 1_000 }

        pipeline.track("a")
        await pipeline.flush()

        #expect(transport.batch(0).names == [ReservedEvent.sessionStart, "a"])
        let start = transport.batch(0)[0]
        #expect((start["properties"] as? [String: Any])?["reason"] as? String == "initial")
    }

    @Test("events inside the window share one session")
    func sessionContinues() async throws {
        let transport = MockTransport()
        let clock = TestClock()
        let pipeline = makePipeline(transport: transport, clock: clock) { $0.flushAt = 1_000 }

        pipeline.track("a")
        clock.advance(by: 5 * 60)
        pipeline.track("b")
        await pipeline.flush()

        let events = transport.batch(0)
        #expect(events.names == [ReservedEvent.sessionStart, "a", "b"])
        let sessions = Set(events.compactMap { $0["session_id"] as? String })
        #expect(sessions.count == 1)
    }

    @Test("inactivity past the timeout rotates the session")
    func sessionTimesOut() async throws {
        let transport = MockTransport()
        let clock = TestClock()
        let pipeline = makePipeline(transport: transport, clock: clock) { $0.flushAt = 1_000 }

        pipeline.track("a")
        let lastActivity = clock.now
        clock.advance(by: 31 * 60)
        pipeline.track("b")
        await pipeline.flush()

        let events = transport.batch(0)
        #expect(
            events.names == [
                ReservedEvent.sessionStart, "a", ReservedEvent.sessionEnd,
                ReservedEvent.sessionStart, "b",
            ]
        )

        let ended = events[2]
        #expect((ended["properties"] as? [String: Any])?["reason"] as? String == "timeout")
        // Backdated to the last activity, so the session's duration describes
        // the visit rather than how long the user stayed away.
        #expect(ended["occurred_at"] as? String == WireDate.string(from: lastActivity))
        #expect(ended["session_id"] as? String == events[0]["session_id"] as? String)
        #expect(events[3]["session_id"] as? String == events[4]["session_id"] as? String)
        #expect(events[3]["session_id"] as? String != events[0]["session_id"] as? String)
    }

    @Test("a session survives a relaunch inside the window")
    func sessionSurvivesRelaunch() async throws {
        let transport = MockTransport()
        let store = InMemoryStore()
        let clock = TestClock()

        let first = makePipeline(transport: transport, store: store, clock: clock) {
            $0.flushAt = 1_000
        }
        first.track("a")
        await first.flush()
        let originalSession = transport.batch(0)[0]["session_id"] as? String

        clock.advance(by: 60)
        let second = makePipeline(transport: transport, store: store, clock: clock) {
            $0.flushAt = 1_000
        }
        second.track("b")
        await second.flush()

        let resumed = transport.batch(1)
        #expect(resumed.names == ["b"])
        #expect(resumed[0]["session_id"] as? String == originalSession)
    }

    @Test("logging in starts a fresh session")
    func loginStartsSession() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport) { $0.flushAt = 1_000 }

        pipeline.track("browsing")
        let isNewUser = pipeline.identify(userID: "user_1", traits: nil)
        pipeline.track("after_login")
        await pipeline.flush()

        #expect(isNewUser)
        let events = transport.batch(0)
        #expect(
            events.names == [
                ReservedEvent.sessionStart, "browsing", ReservedEvent.sessionEnd,
                ReservedEvent.sessionStart, "after_login",
            ]
        )
        #expect((events[2]["properties"] as? [String: Any])?["reason"] as? String == "login")
        // The pre-login events are backfilled so the whole visit is attributed.
        #expect(events[1]["user_id"] as? String == "user_1")
        #expect(events[4]["user_id"] as? String == "user_1")
    }

    @Test("re-identifying the same user at launch keeps the session")
    func reidentifyKeepsSession() async throws {
        let transport = MockTransport()
        let store = InMemoryStore()
        let clock = TestClock()

        let first = makePipeline(transport: transport, store: store, clock: clock) {
            $0.flushAt = 1_000
        }
        first.identify(userID: "user_1", traits: nil)
        first.track("a")
        await first.flush()

        clock.advance(by: 60)
        let second = makePipeline(transport: transport, store: store, clock: clock) {
            $0.flushAt = 1_000
        }
        let isNewUser = second.identify(userID: "user_1", traits: nil)
        second.track("b")
        await second.flush()

        #expect(isNewUser == false)
        #expect(transport.batch(1).names == ["b"])
    }

    @Test("switching accounts starts a new session")
    func accountSwitch() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport) { $0.flushAt = 1_000 }

        pipeline.identify(userID: "user_1", traits: nil)
        pipeline.track("a")
        let isNewUser = pipeline.identify(userID: "user_2", traits: nil)
        await pipeline.flush()

        #expect(isNewUser)
        #expect(transport.allEvents.names.filter { $0 == ReservedEvent.sessionStart }.count == 2)
    }

    @Test("reset ends the session and rotates the anonymous id")
    func resetEndsSession() async throws {
        let transport = MockTransport()
        let pipeline = makePipeline(transport: transport) { $0.flushAt = 1_000 }

        pipeline.identify(userID: "user_1", traits: ["orgId": "org_1"])
        pipeline.track("a")
        let anonymousBefore = pipeline.identity.anonymousID
        pipeline.reset()
        await pipeline.flush()

        let events = transport.allEvents
        let ends = events.filter { $0["event"] as? String == ReservedEvent.sessionEnd }
        #expect((ends.last?["properties"] as? [String: Any])?["reason"] as? String == "logout")
        #expect(pipeline.identity.userID == nil)
        #expect(pipeline.identity.orgID == nil)
        #expect(pipeline.identity.anonymousID != anonymousBefore)

        // A post-logout event belongs to a new session, not the old one.
        pipeline.track("after_logout")
        await pipeline.flush()
        let after = try #require(
            transport.allEvents.first { $0["event"] as? String == "after_logout" }
        )
        #expect(after["user_id"] == nil)
        #expect(after["session_id"] as? String != ends.last?["session_id"] as? String)
    }
}

@Suite("Offline persistence")
struct PersistenceTests {
    @Test("events that couldn't be delivered are reloaded after a relaunch")
    func pendingEventsSurviveTermination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskStore(name: "events.json", directory: directory)
        let store = InMemoryStore()

        let offline = MockTransport()
        let first = makePipeline(transport: offline, store: store, disk: disk) {
            $0.flushAt = 1_000
        }
        await primeSession(first, on: offline)

        offline.failNext(URLError(.notConnectedToInternet))
        first.track("queued_offline")
        await first.drainForBackground()
        #expect(first.pendingCount == 1)

        let online = MockTransport()
        let second = makePipeline(transport: online, store: store, disk: disk) {
            $0.flushAt = 1_000
        }
        #expect(second.pendingCount == 1)
        await second.flush()
        #expect(online.allEvents.names.contains("queued_offline"))

        // Cleared once loaded, so a later relaunch can't send them twice.
        let third = makePipeline(transport: MockTransport(), store: store, disk: disk)
        #expect(third.pendingCount == 0)
    }

    @Test("a delivered queue leaves nothing behind on disk")
    func deliveredEventsAreNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskStore(name: "events.json", directory: directory)
        let store = InMemoryStore()

        let first = makePipeline(transport: MockTransport(), store: store, disk: disk)
        first.track("delivered")
        await first.drainForBackground()

        let second = makePipeline(transport: MockTransport(), store: store, disk: disk)
        #expect(second.pendingCount == 0)
    }
}
