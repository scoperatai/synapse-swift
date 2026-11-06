# Synapse for Swift

Analytics events and feature flags for Apple platforms — the Swift counterpart
to ScopeRat's TypeScript `@scoperat/synapse`.

Requires iOS 17+ / macOS 14+ and Swift 6.

## Install

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/scoperatai/synapse-swift.git", from: "1.0.0")
]
```

In Xcode: **File → Add Package Dependencies…** and paste the repository URL.

## Use

Start Synapse once, as early as the app has its configuration:

```swift
import Synapse

Synapse.shared.start(
    writeKey: "wk_live_...",
    configuration: Configuration(
        environment: "production",
        release: "1.4.2"
    )
)
```

A blank write key leaves the SDK inert — every call becomes a no-op and flag
reads return the default you pass — so builds without a key need no conditionals.

### Events

```swift
Synapse.shared.track("client_viewed", properties: ["client_id": id, "tab": 2])
```

`track` returns immediately and is safe from any thread. Events are batched and
uploaded when 10 accumulate, every 3 seconds, and when the app backgrounds.

### Identity

```swift
Synapse.shared.identify(session.userID, traits: [
    "email": .string(session.email),
    "name": .string(session.name),
    "orgId": .string(session.organizationID),
])

Synapse.shared.reset()  // on logout
```

`identify` backfills events that are queued but not yet uploaded, so activity
from before login is attributed to the user. `orgId` becomes the event's
`org_id`; everything else lands under `context.traits`. `reset` ends the
session and mints a new anonymous id.

### Feature flags

Reads are synchronous and never fail — usable directly in a SwiftUI `body`:

```swift
if Synapse.shared.isEnabled("new_checkout") { ... }

let copy = Synapse.shared.string("banner_copy", default: "Welcome")
let size = Synapse.shared.number("page_size", default: 25)
```

Flags are evaluated server-side for the current identity, fetched at launch,
re-fetched every 60 seconds and on `identify`. To re-render when they change:

```swift
subscription = Synapse.shared.observeFlags {
    Task { @MainActor in revision += 1 }
}
```

Hold the returned subscription; releasing it unsubscribes. The listener runs off
the main actor.

To hold a screen back rather than render a default and flip a moment later:

```swift
await Synapse.shared.waitForFlags()
```

## Sessions

A session covers a run of activity and ends after 30 minutes of inactivity, on
logout, or on an account switch. `$session_start` and `$session_end` are emitted
automatically, carrying a `reason` of `initial`, `login`, `logout`, or
`timeout`. A timed-out session's end event is backdated to the last activity, so
its duration describes the visit rather than the time away.

## Differences from the TypeScript SDK

Event shape, batching thresholds, retry backoff, and session semantics all
match. Four things differ, all because the platform does:

- **The queue and the last flag response are cached to disk.** A backgrounded
  iOS app can be terminated without warning, and a cold start would otherwise
  answer every flag read with a default until the network replied. The queue is
  cleared as it's loaded, so events are never sent twice.
- **A session survives relaunch.** On the web the session id lives in
  `sessionStorage`, which a closed tab discards; iOS has no tab, and the system
  terminates backgrounded apps routinely. A relaunch inside the inactivity
  window resumes the session.
- **`source` is not sent.** The server's `event_source` enum admits only
  `server`, `browser`, and `worker`. Native traffic is identified by
  `context.platform` (`ios`, `macos`, …) instead.
- **No error capture and no widgets.** Crash reporting on iOS is a different
  problem than `window.onerror`, and the ticket/announce widgets are DOM UI.

## Development

```bash
swift build
swift test
```
