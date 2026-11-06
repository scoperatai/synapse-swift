import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Bridges app lifecycle to Synapse.
///
/// Backgrounding is this SDK's equivalent of the web's `pagehide`: the last
/// moment to get queued events out before the system may terminate the process.
/// Foregrounding restarts the timers that were stopped on the way out, so a
/// backgrounded app isn't polling flags or waking to flush.
///
/// `NSObject` and selector-based observation rather than block observers: the
/// block API's return token isn't `Sendable`, so holding one would mean an
/// `@unchecked` escape hatch around the token storage instead of just this
/// class.
final class LifecycleObserver: NSObject, @unchecked Sendable {
    private let onBackground: @Sendable () -> Void
    private let onForeground: @Sendable () -> Void

    init(
        onBackground: @escaping @Sendable () -> Void,
        onForeground: @escaping @Sendable () -> Void
    ) {
        self.onBackground = onBackground
        self.onForeground = onForeground
        super.init()
    }

    func start() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func applicationDidEnterBackground() {
        onBackground()
    }

    @objc private func applicationWillEnterForeground() {
        onForeground()
    }

    @objc private func applicationWillTerminate() {
        onBackground()
    }
}
