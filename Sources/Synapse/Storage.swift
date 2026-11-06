import Foundation

/// The `localStorage` seam. `UserDefaults` in an app, an in-memory dictionary
/// in tests, so identity and session persistence can be exercised without
/// leaking state between test cases.
protocol KeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func removeValue(forKey key: String)
}

extension UserDefaults: KeyValueStore {
    func set(_ value: String, forKey key: String) {
        setValue(value, forKey: key)
    }

    func removeValue(forKey key: String) {
        removeObject(forKey: key)
    }
}

/// Storage keys, matching the web SDK's `localStorage` keys so the two
/// implementations stay recognizably the same product.
enum StorageKey {
    static let anonymousID = "__scoperat_anon_id"
    static let sessionID = "__scoperat_session_id"
    static let lastActivity = "__scoperat_last_activity"
    static let userID = "__scoperat_user_id"
}

/// Atomic JSON file storage for the event queue and the flag cache.
///
/// Lives in Application Support rather than Caches: a queue of events the API
/// hasn't accepted yet is not reconstructible, so it shouldn't be first in line
/// when the system reclaims space.
struct DiskStore: Sendable {
    private let fileURL: URL?

    /// A store that discards everything, for tests and for the case where the
    /// container has no Application Support directory.
    static let none = DiskStore()

    private init() {
        fileURL = nil
    }

    init(name: String, directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent(name)
    }

    init(name: String, namespace: String) {
        guard
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            fileURL = nil
            return
        }
        let directory = base
            .appendingPathComponent("Synapse", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent(name)
    }

    func load<T: Decodable>(_ type: T.Type) -> T? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save(_ value: some Encodable) {
        guard let fileURL, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
