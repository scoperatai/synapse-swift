import Foundation

/// Who the events are attributed to. `anonymousID` always exists; `userID` and
/// `orgID` appear once the host app calls `identify`.
struct Identity: Sendable, Equatable {
    var anonymousID: String
    var userID: String?
    var orgID: String?
    var traits: [String: TrackerValue] = [:]

    /// The value the flag API targets on: the real user when known, otherwise
    /// the anonymous id, so a rollout percentage stays stable for a given
    /// install even before login.
    var flagIdentifier: String? {
        userID ?? anonymousID
    }
}

/// Reads and writes the anonymous id and the last-identified user id.
///
/// The anonymous id survives reinstall-free app launches, matching the web
/// SDK's `localStorage` lifetime. The last-identified user id is what lets
/// `identify` tell a real login from the same user being re-identified at
/// launch: only the former starts a new session.
struct IdentityStore: Sendable {
    let store: KeyValueStore

    func loadOrCreateAnonymousID() -> String {
        if let existing = store.string(forKey: StorageKey.anonymousID)?.nilIfBlank {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        store.set(created, forKey: StorageKey.anonymousID)
        return created
    }

    /// Mint a fresh anonymous id, discarding the previous one. Called on
    /// `reset` so a logged-out device isn't linked to the user who just left.
    func rotateAnonymousID() -> String {
        let created = UUID().uuidString.lowercased()
        store.set(created, forKey: StorageKey.anonymousID)
        return created
    }

    var storedUserID: String? {
        store.string(forKey: StorageKey.userID)?.nilIfBlank
    }

    func setStoredUserID(_ userID: String) {
        store.set(userID, forKey: StorageKey.userID)
    }

    func clearStoredUserID() {
        store.removeValue(forKey: StorageKey.userID)
    }
}

/// Session id plus the last-activity stamp used to expire it.
///
/// Diverges from the web SDK on purpose: there the session id lives in
/// `sessionStorage`, which a closed tab discards. iOS has no tab — the system
/// terminates backgrounded apps routinely, and treating every relaunch as a
/// new session would shred one visit into several. Both values are persisted,
/// so a relaunch inside `sessionTimeout` resumes the session and only real
/// inactivity ends it. This is how mobile analytics SDKs generally behave.
struct SessionStore: Sendable {
    let store: KeyValueStore

    var sessionID: String? {
        store.string(forKey: StorageKey.sessionID)?.nilIfBlank
    }

    var lastActivity: Date? {
        guard
            let raw = store.string(forKey: StorageKey.lastActivity),
            let seconds = Double(raw)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func persist(sessionID: String, activityAt date: Date) {
        store.set(sessionID, forKey: StorageKey.sessionID)
        touch(at: date)
    }

    func touch(at date: Date) {
        store.set(String(date.timeIntervalSince1970), forKey: StorageKey.lastActivity)
    }

    func clear() {
        store.removeValue(forKey: StorageKey.sessionID)
        store.removeValue(forKey: StorageKey.lastActivity)
    }
}
