import Foundation
import Testing

/// A release build holds no switch a test turns: no task-local or shared
/// setting that changes what a scrub finds, and no read of the environment.
/// Tests run the debug build, where such switches sit inside `#if DEBUG`; a
/// release build compiles the `#else` side, a constant.
struct ReleaseBuildTests {
    /// The shipped sources: the core and the app, not the offline probe.
    static func sources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var files: [(String, String)] = []
        for target in ["ScrubCore", "Scrub"] {
            let folder = root.appendingPathComponent(target)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
                files.append(("\(target)/\(name)", try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)))
            }
        }
        return files.sorted { $0.0 < $1.0 }
    }

    /// The lines a release build compiles: those outside every `#if DEBUG`
    /// branch, with the `#else` of one counted as release.
    static func releaseLines(_ source: String) -> [(Int, String)] {
        var stack: [Bool] = [], kept: [(Int, String)] = []
        for (number, line) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") { stack.append(trimmed == "#if DEBUG"); continue }
            // The other side of "#if DEBUG" is what a release build compiles.
            if trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif") { if !stack.isEmpty { stack[stack.count - 1] = false }; continue }
            if trimmed.hasPrefix("#endif") { _ = stack.popLast(); continue }
            if !stack.contains(true) { kept.append((number + 1, line)) }
        }
        return kept
    }

    @Test func releaseBuildsHoldNoTestSwitch() throws {
        let switches = ["@TaskLocal", "ProcessInfo.processInfo.environment", "getenv(", "static let enabled = Atomic", "static let gateFrom = Atomic", "SCRUB_"]
        let files = try Self.sources()
        #expect(files.count > 20, "the sources were found")
        for (name, source) in files {
            for (number, line) in Self.releaseLines(source) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for word in switches where line.contains(word) {
                    Issue.record("\(name):\(number) is compiled into release builds: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    /// The reader of `#if DEBUG` counts what it should, so the test above can fail.
    @Test func debugBranchesAreToldApart() {
        let source = "a\n#if DEBUG\n@TaskLocal static var b = 1\n#else\nstatic var b: Int { 1 }\n#endif\nc"
        #expect(Self.releaseLines(source).map(\.1) == ["a", "static var b: Int { 1 }", "c"])
    }
}
