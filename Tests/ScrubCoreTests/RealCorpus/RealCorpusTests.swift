import Foundation
@testable import ScrubCore
import Testing

/// Measures Scrub on real, human-labelled text kept outside the repository.
/// SCRUB_REAL_CORPUS names a directory of JSONL files, one document a line:
/// {"id", "set", "text", "spans": [{"start", "end", "label", "must"}]}, with
/// offsets in UTF-16 units. Spans marked `must` have to be gone from the
/// output; the others are informational and count for nothing either way.
///
/// Each document goes through a text file, a JSON field and a CSV cell. A
/// span is caught when every word in it changed on all three; titles such
/// as "Mr", initials and "com" may stay. Over-redaction is the share of words
/// outside any labelled span that changed. Without the variable the test
/// does nothing, and it only reports: real text never sets a baseline.
///
/// SCRUB_REAL_CORPUS_GATE=on or off forces the context model's gate either
/// way. SCRUB_REAL_CORPUS_SETS=a,b limits the sets, SCRUB_REAL_CORPUS_LIMIT the
/// documents per set, and SCRUB_REAL_CORPUS_PATHS=text the input paths.
/// SCRUB_REAL_CORPUS_DUMP=/file writes every miss and changed word, not
/// only the first ten of each; SCRUB_REAL_CORPUS_SHOW=id,id prints those
/// documents' text output.
@Suite(.serialized)
struct RealCorpus {
    struct LabelledSpan: Decodable {
        let start: Int
        let end: Int
        let label: String
        let must: Bool
    }

    struct Document: Decodable {
        let id: String
        let set: String
        let text: String
        let spans: [LabelledSpan]
    }

    struct Tally {
        var spans = 0
        var caught = 0
        /// Caught on the text path alone.
        var caughtAsText = 0
    }

    struct SetScore {
        var documents = 0
        var labels: [String: Tally] = [:]
        var plainWords = 0
        var changedWords = 0
        var misses: [String] = []
        var falsePositives: [String] = []
    }

    /// Words a span may keep: a title, a joining word, an initial or the
    /// scaffolding of an address ("com" in a stand-in's example.com) is no
    /// one's name.
    static let kept: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "prof", "sir", "madam", "the", "of", "and", "de", "van", "von",
                                    "com", "net", "org", "edu", "gov", "www", "http", "https", "mailto"]
    static func mayStay(_ word: String) -> Bool { word.count == 1 || kept.contains(word.lowercased()) }
    static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    @Test func realCorpus() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SCRUB_REAL_CORPUS"] else { return }
        let sets = environment["SCRUB_REAL_CORPUS_SETS"].map { Set($0.split(separator: ",").map(String.init)) }
        let limit = environment["SCRUB_REAL_CORPUS_LIMIT"].flatMap(Int.init) ?? .max
        // SCRUB_REAL_CORPUS_GATE=on reads only the windows the gate picks, =off reads all.
        if let gate = environment["SCRUB_REAL_CORPUS_GATE"] { ContextStage.gateFrom.store(gate == "on" ? 0 : .max, ordering: .relaxed) }
        let paths = environment["SCRUB_REAL_CORPUS_PATHS"].map { $0.split(separator: ",").compactMap { PIIGaps.InputPath(rawValue: String($0)) } } ?? PIIGaps.InputPath.allCases
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".jsonl") }.sorted()
        var scores: [String: SetScore] = [:]
        for file in files {
            let lines = try String(contentsOfFile: (directory as NSString).appendingPathComponent(file), encoding: .utf8).split(separator: "\n")
            var taken: [String: Int] = [:]
            for (index, line) in lines.enumerated() {
                let document = try JSONDecoder().decode(Document.self, from: Data(line.utf8))
                guard sets?.contains(document.set) ?? true, taken[document.set, default: 0] < limit else { continue }
                taken[document.set, default: 0] += 1
                try Self.score(document, paths: paths, seed: UInt64(index) &+ 1, into: &scores[document.set, default: SetScore()])
            }
        }
        print(Self.report(scores, paths: paths))
        if let dump = environment["SCRUB_REAL_CORPUS_DUMP"] {
            let all = scores.sorted { $0.key < $1.key }.flatMap { set, score in score.misses.map { "MISS \(set) " + $0 } + score.falsePositives.map { "CHANGED \(set) " + $0 } }
            try all.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
        }
    }

    /// Words of `text` with their UTF-16 ranges.
    static func words(_ text: String) -> [(word: String, range: Range<Int>)] {
        let ns = text as NSString
        return word.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range), $0.range.location..<NSMaxRange($0.range)) }
    }

    /// Which input words the output no longer has in place.
    static func changed(_ input: [(word: String, range: Range<Int>)], _ output: String) -> Set<Int> {
        let after = words(output).map(\.word)
        var gone: Set<Int> = []
        for change in after.difference(from: input.map(\.word)) {
            if case let .remove(offset, _, _) = change { gone.insert(offset) }
        }
        return gone
    }

    static let show = Set((ProcessInfo.processInfo.environment["SCRUB_REAL_CORPUS_SHOW"] ?? "").split(separator: ",").map(String.init))

    static func score(_ document: Document, paths: [PIIGaps.InputPath], seed: UInt64, into score: inout SetScore) throws {
        let input = words(document.text)
        let ns = document.text as NSString
        var changedOn: [PIIGaps.InputPath: Set<Int>] = [:]
        for path in paths {
            let (data, name) = PIIGaps.wrap(document.text, path)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            let output = PIIGaps.readable(result.output, path)
            changedOn[path] = changed(input, output)
            if path == .text, show.contains(document.id) { print("SHOW \(document.id):\n\(output)\n") }
        }
        score.documents += 1
        func context(_ range: Range<Int>) -> String {
            let from = max(0, range.lowerBound - 40), to = min(ns.length, range.upperBound + 40)
            return (ns.substring(with: NSRange(location: from, length: range.lowerBound - from)) + "[" + ns.substring(with: NSRange(location: range.lowerBound, length: range.count)) + "]" + ns.substring(with: NSRange(location: range.upperBound, length: to - range.upperBound)))
                .replacingOccurrences(of: "\n", with: "⏎")
        }
        for span in document.spans where span.must {
            let inside = input.indices.filter { input[$0].range.overlaps(span.start..<span.end) && !mayStay(input[$0].word) }
            guard !inside.isEmpty else { continue }
            let caughtOn = paths.filter { path in inside.allSatisfy { changedOn[path]!.contains($0) } }
            score.labels[span.label, default: Tally()].spans += 1
            if caughtOn.count == paths.count { score.labels[span.label]!.caught += 1 }
            if caughtOn.contains(.text) { score.labels[span.label]!.caughtAsText += 1 }
            if caughtOn.count < paths.count {
                let missedOn = paths.filter { !caughtOn.contains($0) }.map(\.rawValue).joined(separator: ",")
                score.misses.append("\(span.label) [\(missedOn)] \(document.id): " + context(span.start..<span.end))
            }
        }
        let labelled = document.spans.map { $0.start..<$0.end }
        for index in input.indices where !labelled.contains(where: { $0.overlaps(input[index].range) }) {
            let hits = paths.filter { changedOn[$0]!.contains(index) }
            score.plainWords += paths.count
            score.changedWords += hits.count
            if !hits.isEmpty {
                score.falsePositives.append("[\(hits.map(\.rawValue).joined(separator: ","))] \(document.id): " + context(input[index].range))
            }
        }
    }

    static func report(_ scores: [String: SetScore], paths: [PIIGaps.InputPath]) -> String {
        func percent(_ part: Int, _ whole: Int) -> String { whole == 0 ? "—" : String(format: "%.1f%%", Double(part) / Double(whole) * 100) }
        var lines = ["REAL CORPUS paths=\(paths.map(\.rawValue).joined(separator: ","))", "", "| set | label | spans | caught on all paths | caught as text |", "|---|---|---|---|---|"]
        for (set, score) in scores.sorted(by: { $0.key < $1.key }) {
            for (label, tally) in score.labels.sorted(by: { $0.key < $1.key }) {
                lines.append("| \(set) | \(label) | \(tally.spans) | \(percent(tally.caught, tally.spans)) | \(percent(tally.caughtAsText, tally.spans)) |")
            }
        }
        lines += ["", "| set | documents | plain words | changed (over-redaction) |", "|---|---|---|---|"]
        for (set, score) in scores.sorted(by: { $0.key < $1.key }) {
            lines.append("| \(set) | \(score.documents) | \(score.plainWords / max(paths.count, 1)) | \(percent(score.changedWords, score.plainWords)) |")
        }
        for (set, score) in scores.sorted(by: { $0.key < $1.key }) {
            lines.append("")
            lines.append("\(set) misses:")
            lines += score.misses.prefix(10).map { "  " + $0 }
            lines.append("\(set) changed plain words:")
            lines += score.falsePositives.prefix(10).map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}
