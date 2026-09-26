// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scrub",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ScrubCore", targets: ["ScrubCore"])],
    targets: [
        .target(name: "ScrubCore"),
        .executableTarget(name: "Scrub", dependencies: ["ScrubCore"]),
        // Test-only: signed with the app's exact entitlements to prove the OS
        // refuses every network path. Never shipped.
        .executableTarget(name: "NetworkProbe"),
        .testTarget(name: "ScrubCoreTests", dependencies: ["ScrubCore"]),
    ]
)
