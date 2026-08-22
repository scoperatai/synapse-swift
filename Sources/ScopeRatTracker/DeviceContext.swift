import Foundation

/// The `context` object attached to every event — the native counterpart to
/// `getBrowserContext()` in the TypeScript SDK.
///
/// Deliberately built from Foundation alone. `UIDevice` and `UIScreen` are
/// main-actor-bound in recent SDKs, and an event can be tracked from any
/// thread, so reading them here would either hop actors on every call or
/// force the whole SDK onto the main thread. Everything below is available
/// anywhere, and device model comes from `sysctl` rather than `UIDevice`.
///
/// `platform` is how native traffic is told apart from web: the server's
/// `event_source` enum only admits `server`/`browser`/`worker`, and its column
/// defaults to `browser`, so `source` is left off the wire entirely and the
/// distinction lives here instead.
enum DeviceContext {
    /// Computed once — none of it changes over a process lifetime.
    static let current: [String: TrackerValue] = build()

    private static func build() -> [String: TrackerValue] {
        var context: [String: TrackerValue] = [
            "platform": .string(platformName),
            "locale": .string(Locale.current.identifier),
            "timezone": .string(TimeZone.current.identifier),
            "os": .object([
                "name": .string(osName),
                "version": .string(osVersion),
            ]),
            "device": .object([
                "manufacturer": .string("Apple"),
                "model": .string(deviceModel),
            ]),
        ]

        var app: [String: TrackerValue] = [:]
        let info = Bundle.main.infoDictionary
        if let name = (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String {
            app["name"] = .string(name)
        }
        if let identifier = Bundle.main.bundleIdentifier {
            app["namespace"] = .string(identifier)
        }
        if let version = info?["CFBundleShortVersionString"] as? String {
            app["version"] = .string(version)
        }
        if let build = info?["CFBundleVersion"] as? String {
            app["build"] = .string(build)
        }
        if !app.isEmpty {
            context["app"] = .object(app)
        }

        return context
    }

    private static var platformName: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "unknown"
        #endif
    }

    private static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return "unknown"
        #endif
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Hardware identifier such as `iPhone17,1`. Under the simulator `hw.machine`
    /// reports the Mac's architecture, so the simulated device is read from the
    /// environment instead.
    private static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
