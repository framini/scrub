// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scrub",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ScrubCore", targets: ["ScrubCore"])],
    targets: [
        .target(name: "ScrubCore", resources: [.copy("Resources/NameModel.bin"), .copy("Resources/AddressModel.bin"), .copy("Resources/AddressModelWide.bin"), .copy("Resources/ContextModel.1.bin"), .copy("Resources/ContextModel.2.bin"), .copy("Resources/NameLists.txt")]),
        .executableTarget(name: "Scrub", dependencies: ["ScrubCore"]),
        // Test-only: signed with the app's exact entitlements to prove the OS
        // refuses every network path. Never shipped.
        .executableTarget(name: "NetworkProbe"),
        // Test-only: the leak evaluator both test targets judge output with. It
        // uses Foundation alone, never ScrubCore. Never shipped.
        .target(name: "ScrubTestSupport", path: "Tests/ScrubTestSupport"),
        .testTarget(name: "ScrubCoreTests", dependencies: ["ScrubCore", "ScrubTestSupport"], exclude: ["NameGaps/baseline.json", "PIIGaps/baseline.json", "RealCorpus/baseline.json"], resources: [.process("Fixtures")]),
        .testTarget(name: "ScrubTests", dependencies: ["Scrub", "ScrubTestSupport"]),
    ]
)
