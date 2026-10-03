// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scrub",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ScrubCore", targets: ["ScrubCore"])],
    targets: [
        .target(name: "ScrubCore", resources: [.copy("Resources/NameModel.bin"), .copy("Resources/AddressModel.bin"), .copy("Resources/ContextModel.1.bin"), .copy("Resources/ContextModel.2.bin"), .copy("Resources/NameLists.txt")]),
        .executableTarget(name: "Scrub", dependencies: ["ScrubCore"]),
        // Test-only: signed with the app's exact entitlements to prove the OS
        // refuses every network path. Never shipped.
        .executableTarget(name: "NetworkProbe"),
        .testTarget(name: "ScrubCoreTests", dependencies: ["ScrubCore"], exclude: ["NameGaps/baseline.json", "PIIGaps/baseline.json"], resources: [.process("Fixtures")]),
        .testTarget(name: "ScrubTests", dependencies: ["Scrub"]),
    ]
)
