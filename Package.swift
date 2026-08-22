// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scoperat-swift",
    // Below the CRM app's iOS 18 floor on purpose: this is the SDK other
    // apps embed, and nothing here needs a recent API.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScopeRatTracker", targets: ["ScopeRatTracker"])
    ],
    targets: [
        .target(name: "ScopeRatTracker"),
        .testTarget(name: "ScopeRatTrackerTests", dependencies: ["ScopeRatTracker"]),
    ]
)
