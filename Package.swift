// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "synapse-swift",
    // Kept low on purpose: this is an SDK other apps embed, and nothing
    // here needs a recent API.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Synapse", targets: ["Synapse"])
    ],
    targets: [
        .target(name: "Synapse"),
        .testTarget(name: "SynapseTests", dependencies: ["Synapse"]),
    ]
)
