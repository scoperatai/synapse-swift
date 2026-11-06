import Foundation
import Testing
import os

@testable import Synapse

@Suite("Feature flags")
struct FlagStoreTests {
    private func makeStore(
        transport: MockTransport,
        disk: DiskStore = .none,
        identity: Identity = Identity(anonymousID: "anon_1"),
        configure: (inout Configuration) -> Void = { _ in }
    ) -> FlagStore {
        var configuration = Configuration(endpoint: URL(string: "https://example.test")!)
        configure(&configuration)
        return FlagStore(
            writeKey: "wk_test",
            configuration: configuration,
            transport: transport,
            disk: disk,
            identityProvider: { identity }
        )
    }

    private let payload = """
        {"flags":{
          "new_checkout":{"key":"new_checkout","value":true,"type":"boolean","source":"rollout"},
          "banner_copy":{"key":"banner_copy","value":"Hello","type":"string","source":"override"},
          "page_size":{"key":"page_size","value":25,"type":"number","source":"default"},
          "layout":{"key":"layout","value":{"columns":3},"type":"json","source":"targeted"}
        }}
        """

    @Test("evaluated flags are decoded and read back by type")
    func decodesFlags() async throws {
        let transport = MockTransport()
        transport.enqueue(.json(payload))
        let store = makeStore(transport: transport)

        await store.refresh()

        #expect(store.hasLoaded)
        #expect(store.flag("new_checkout")?.value.boolValue == true)
        #expect(store.flag("new_checkout")?.source == .rollout)
        #expect(store.flag("banner_copy")?.value.stringValue == "Hello")
        #expect(store.flag("page_size")?.value.doubleValue == 25)
        #expect(store.flag("layout")?.value == .object(["columns": .number(3)]))
        #expect(store.flag("missing") == nil)
    }

    @Test("the request targets the current identity and environment")
    func requestShape() async throws {
        let transport = MockTransport()
        transport.enqueue(.json(payload))
        let store = makeStore(
            transport: transport,
            identity: Identity(anonymousID: "anon_1", userID: "user_1", orgID: "org_1")
        ) { $0.environment = "production" }

        await store.refresh()

        let request = try #require(transport.requests.last)
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        #expect(components.path == "/api/flags")
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        #expect(query["environment"] == "production")
        // Identified users target on the user id so a rollout follows them
        // across devices; before login the anonymous id keeps the bucket stable.
        #expect(query["identifier"] == "user_1")
        #expect(query["orgId"] == "org_1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer wk_test")
    }

    @Test("an anonymous visitor targets on the anonymous id")
    func anonymousIdentifier() async throws {
        let transport = MockTransport()
        transport.enqueue(.json(payload))
        let store = makeStore(transport: transport)

        await store.refresh()

        let components = try #require(
            URLComponents(url: transport.requests.last!.url!, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        #expect(query["identifier"] == "anon_1")
        #expect(query["environment"] == nil)
    }

    @Test("a failed fetch keeps the previous values")
    func failureKeepsCache() async throws {
        let transport = MockTransport()
        transport.enqueue(.json(payload))
        let store = makeStore(transport: transport)
        await store.refresh()

        transport.enqueue(.status(500))
        await store.refresh()

        #expect(store.flag("new_checkout")?.value.boolValue == true)
    }

    @Test("an unrecognized type or source decodes rather than failing the batch")
    func unknownEnumCases() async throws {
        let transport = MockTransport()
        transport.enqueue(
            .json(
                """
                {"flags":{"f":{"key":"f","value":1,"type":"decimal","source":"experiment"}}}
                """
            )
        )
        let store = makeStore(transport: transport)

        await store.refresh()

        #expect(store.flag("f")?.type == .unknown)
        #expect(store.flag("f")?.source == .unknown)
    }

    @Test("listeners fire on a change and stay quiet on an identical poll")
    func listenerFiresOnChange() async throws {
        let transport = MockTransport()
        let store = makeStore(transport: transport)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let subscription = store.addListener { calls.withLock { $0 += 1 } }

        transport.enqueue(.json(payload))
        await store.refresh()
        #expect(calls.withLock { $0 } == 1)

        transport.enqueue(.json(payload))
        await store.refresh()
        #expect(calls.withLock { $0 } == 1)

        transport.enqueue(
            .json(
                """
                {"flags":{"new_checkout":{"key":"new_checkout","value":false,"type":"boolean","source":"rollout"}}}
                """
            )
        )
        await store.refresh()
        #expect(calls.withLock { $0 } == 2)

        subscription.cancel()
        transport.enqueue(.json(payload))
        await store.refresh()
        #expect(calls.withLock { $0 } == 2)
    }

    @Test("waiting for flags resumes on the first response")
    func waitUntilLoaded() async throws {
        let transport = MockTransport()
        transport.enqueue(.json(payload))
        let store = makeStore(transport: transport)

        async let wait: Void = store.waitUntilLoaded()
        await store.refresh()
        await wait

        #expect(store.hasLoaded)
        // Already loaded, so this must not suspend.
        await store.waitUntilLoaded()
    }

    @Test("the last response is cached so a cold start has real values")
    func diskCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskStore(name: "flags.json", directory: directory)

        let transport = MockTransport()
        transport.enqueue(.json(payload))
        await makeStore(transport: transport, disk: disk).refresh()

        let relaunched = makeStore(transport: MockTransport(), disk: disk)
        #expect(relaunched.flag("new_checkout")?.value.boolValue == true)
        // Values are available but not yet confirmed by the server this launch.
        #expect(relaunched.hasLoaded == false)
    }
}

@Suite("Facade")
struct SynapseFacadeTests {
    @Test("calls before start are inert and flag reads fall back to defaults")
    func uninitialized() async {
        let synapse = Synapse()

        synapse.track("nothing")
        synapse.identify("user_1")
        synapse.reset()

        #expect(synapse.isStarted == false)
        #expect(synapse.isEnabled("anything") == false)
        #expect(synapse.isEnabled("anything", default: true))
        #expect(synapse.string("copy", default: "fallback") == "fallback")
        #expect(synapse.number("size", default: 10) == 10)
        #expect(synapse.flag("anything") == nil)
        #expect(synapse.allFlags.isEmpty)
        #expect(synapse.flagsHaveLoaded == false)
        #expect(synapse.sessionID == nil)
        #expect(await synapse.flush() == FlushResult(success: true, ingested: 0))
    }

    @Test("a blank write key leaves Synapse disabled")
    func blankWriteKey() {
        let synapse = Synapse()
        synapse.start(writeKey: "   ")
        #expect(synapse.isStarted == false)
    }
}
