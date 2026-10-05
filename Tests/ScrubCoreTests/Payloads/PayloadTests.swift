import Foundation
@testable import ScrubCore
import Testing

/// Realistic API payloads, each rendered every way it reaches the app, judged
/// field by field against what the generator knows each value to be.
/// SCRUB_PROPERTY_CASES sets how many payloads; SCRUB_PROPERTY_SEED replays a run;
/// SCRUB_PAYLOAD_SHAPE keeps one shape.
@Suite(.serialized)
struct PayloadProperties {

    struct Outcome {
        var findings: [Finding] = []
        var examples: [String: String] = [:]
        var documents = 0
    }

    static func run(_ name: String, renderings: [Rendering]) -> Outcome {
        let run = PropertyRun(name)
        defer { run.finish() }
        var outcome = Outcome()
        for index in 0..<run.count {
            var payloads = PayloadGen(seed: run.seed(index))
            let shape = PayloadGen.shapes[index % PayloadGen.shapes.count]
            // SCRUB_PAYLOAD_SHAPE=identity runs one shape alone.
            if let only = ProcessInfo.processInfo.environment["SCRUB_PAYLOAD_SHAPE"], only != shape { continue }
            let payload = payloads.payload(shape)
            for rendering in renderings {
                guard let rendered = Render.render(payload, as: rendering, gen: &payloads.gen) else { continue }
                outcome.documents += 1
                let found: [Finding]
                do {
                    let result = try Scrubber.scrub(Data(rendered.text.utf8), name: rendering.filename, forceFullDetection: false, seed: run.seed(index))
                    found = Judge.judge(payload, rendered, output: result.output) + Judge.componentLeaks(payload, rendered, output: result.output)
                } catch {
                    found = [Finding(problem: "error", rendering: rendering.rawValue, truth: "-", key: "-", parent: "-", detail: "\(error)")]
                }
                for finding in found where outcome.examples[finding.group] == nil {
                    outcome.examples[finding.group] = "case=\(index) shape=\(shape) seed=\(run.seed(index)) \(finding.rendering): \(finding.detail)\nINPUT:\n\(rendered.text.prefix(1500))"
                }
                outcome.findings += found.map { Finding(problem: $0.problem, rendering: $0.rendering, truth: $0.truth, key: $0.key, parent: $0.parent, detail: "\(shape): \($0.detail)") }
            }
        }
        return outcome
    }

    static func report(_ outcome: Outcome) -> String {
        var lines = ["\(outcome.documents) documents, \(outcome.findings.count) findings"]
        let byProblem = Dictionary(grouping: outcome.findings, by: \.problem)
        for problem in byProblem.keys.sorted() {
            let findings = byProblem[problem]!
            lines.append("== \(problem): \(findings.count)")
            let groups = Dictionary(grouping: findings) { "\($0.truth) key=\($0.key) parent=\($0.parent)" }
            for (group, members) in groups.sorted(by: { $0.value.count > $1.value.count }) {
                let renderings = Set(members.map(\.rendering)).sorted().joined(separator: ",")
                lines.append("  \(members.count)× \(group) [\(renderings)] e.g. \(members[0].detail.prefix(160))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Every hard finding fails: a personal value left in, a stand-in of the
    /// wrong type, a kept value changed, or output that no longer parses.
    /// Values either reading could defend (a company name, a ten-digit order
    /// number) are reported, not failed. SCRUB_PAYLOAD_REPORT=/path writes one
    /// example input per finding group.
    @Test func realisticPayloads() {
        let outcome = Self.run("payloads", renderings: Rendering.allCases)
        let report = Self.report(outcome)
        print(report)
        if let path = ProcessInfo.processInfo.environment["SCRUB_PAYLOAD_REPORT"], path.hasPrefix("/") {
            let examples = outcome.examples.sorted { $0.key < $1.key }.map { "### \($0.key)\n\($0.value)" }.joined(separator: "\n\n")
            try? (report + "\n\n" + examples).write(toFile: path, atomically: true, encoding: .utf8)
        }
        let hard = outcome.findings.filter { $0.problem != "softChanged" }
        let example = hard.first.flatMap { outcome.examples[$0.group] } ?? ""
        #expect(hard.isEmpty, "baseSeed=\(PropertyRun.baseSeed)\n\(report)\n\nFIRST EXAMPLE:\n\(example)")
    }
}

/// Replays one payload: SCRUB_PAYLOAD_REPLAY=<seed>:<shape>:<rendering> prints input and output.
@Test func replayPayload() throws {
    guard let spec = ProcessInfo.processInfo.environment["SCRUB_PAYLOAD_REPLAY"]?.split(separator: ":").map(String.init), spec.count == 3,
          let seed = UInt64(spec[0]), let rendering = Rendering(rawValue: spec[2]) else { return }
    var payloads = PayloadGen(seed: seed)
    let payload = payloads.payload(spec[1])
    let rendered = try #require(Render.render(payload, as: rendering, gen: &payloads.gen))
    let result = try Scrubber.scrub(Data(rendered.text.utf8), name: rendering.filename, forceFullDetection: false, seed: seed)
    print("INPUT:\n\(rendered.text)\nOUTPUT:\n\(String(decoding: result.output, as: UTF8.self))")
    for finding in Judge.judge(payload, rendered, output: result.output) { print("FINDING \(finding.problem): \(finding.detail)") }
}
