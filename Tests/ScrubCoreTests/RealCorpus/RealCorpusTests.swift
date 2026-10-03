import Foundation
@testable import ScrubCore
import Testing

/// Measures Scrub on real, human-labelled text kept outside the repository,
/// and gates releases on it. SCRUB_REAL_CORPUS names a directory of JSONL
/// files, one document a line: {"id", "set", "text", "spans": [{"start",
/// "end", "label", "must"}]}, with offsets in UTF-16 units. Spans marked
/// `must` have to be gone from the output; the others are informational and
/// count for nothing either way. Without the variable, or when the directory
/// is absent, the test does nothing (`scripts/eval-gate.sh` runs it).
///
/// Each document goes through a text file, a JSON field and a CSV cell. A
/// span is caught when every word in it changed on all three; titles such
/// as "Mr", initials and "com" may stay. Per set it measures recall by
/// label, the documents with any labelled value left, over-redaction (the
/// share of words outside any labelled span that changed) and the review
/// burden (findings a person is asked about per 1,000 words).
///
/// The gate: `baseline.json` beside this file holds those aggregate numbers,
/// and nothing else, per corpus directory (its last path component) and
/// slice; no evaluation text enters the repository. A run fails when a
/// number is worse than its baseline beyond a small tolerance (`regressions`).
/// SCRUB_REAL_CORPUS_RECORD=1 writes the run's numbers as the new baseline,
/// for after a deliberate change. Real text is never used to tune anything.
///
/// The holdout: a fixed fifth of each set, chosen by a hash of the set and
/// the document's id (`holdout`), is left out of every ordinary run, so it
/// stays untouched by whatever the ordinary runs lead to. It is for release
/// checks only: SCRUB_REAL_CORPUS_HOLDOUT=only runs it alone, against its
/// own baseline.
///
/// SCRUB_REAL_CORPUS_GATE=on or off forces the context model's gate either
/// way. SCRUB_REAL_CORPUS_SETS=a,b limits the sets, SCRUB_REAL_CORPUS_LIMIT the
/// documents per set, and SCRUB_REAL_CORPUS_PATHS=text the input paths.
/// SCRUB_REAL_CORPUS_REPORT=/file also writes the report to a file.
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
        /// Documents with any labelled value not caught on every path.
        var documentsWithLeft = 0
        /// Every word of the documents, once, and the findings review asks about, over every path.
        var words = 0
        var reviewFindings = 0
        var misses: [String] = []
        var falsePositives: [String] = []
        var changedShare: Double { plainWords == 0 ? 0 : Double(changedWords) / Double(plainWords) }
    }

    /// Whether a document is in the holdout fifth of its set: a fixed hash
    /// (FNV-1a) of the set and the id, the same on every machine and run.
    static func holdout(_ set: String, _ id: String) -> Bool {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (set + "/" + id).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash % 5 == 0
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
        guard let directory = environment["SCRUB_REAL_CORPUS"], FileManager.default.fileExists(atPath: directory) else { return }
        let onlyHoldout = environment["SCRUB_REAL_CORPUS_HOLDOUT"] == "only"
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
                guard sets?.contains(document.set) ?? true, Self.holdout(document.set, document.id) == onlyHoldout, taken[document.set, default: 0] < limit else { continue }
                taken[document.set, default: 0] += 1
                try Self.score(document, paths: paths, seed: UInt64(index) &+ 1, into: &scores[document.set, default: SetScore()])
            }
        }
        var report = Self.report(scores, paths: paths)
        // The gate compares whole sets only: a run limited to some sets, documents or paths is a probe.
        let slice = onlyHoldout ? "holdout" : "main"
        let corpus = ((directory as NSString).standardizingPath as NSString).lastPathComponent
        let complete = sets == nil && limit == .max && paths.count == PIIGaps.InputPath.allCases.count && environment["SCRUB_REAL_CORPUS_GATE"] == nil
        var failures: [String] = []
        if complete {
            var baseline = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.baselineURL))) as? [String: Any] ?? [:]
            let measured = Self.aggregate(scores, paths: paths.count)
            if environment["SCRUB_REAL_CORPUS_RECORD"] == "1" {
                var slices = baseline[corpus] as? [String: Any] ?? [:]
                slices[slice] = measured
                baseline[corpus] = slices
                try JSONSerialization.data(withJSONObject: baseline, options: [.prettyPrinted, .sortedKeys]).write(to: Self.baselineURL)
                report += "\n\nRECORDED baseline \(corpus)/\(slice)"
            } else if let recorded = (baseline[corpus] as? [String: Any])?[slice] as? [String: Any] {
                failures = Self.regressions(measured, against: recorded)
                report += "\n\nGATE \(corpus)/\(slice): " + (failures.isEmpty ? "within tolerance of the baseline" : "\(failures.count) regressions\n  " + failures.joined(separator: "\n  "))
            } else {
                report += "\n\nGATE \(corpus)/\(slice): no baseline recorded"
            }
        }
        print(report)
        // A long report can miss the log; SCRUB_REAL_CORPUS_REPORT=/file keeps it whole.
        if let file = environment["SCRUB_REAL_CORPUS_REPORT"] { try report.write(toFile: file, atomically: true, encoding: .utf8) }
        if let dump = environment["SCRUB_REAL_CORPUS_DUMP"] {
            let all = scores.sorted { $0.key < $1.key }.flatMap { set, score in score.misses.map { "MISS \(set) " + $0 } + score.falsePositives.map { "CHANGED \(set) " + $0 } }
            try all.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
        }
        #expect(failures.isEmpty, "\(corpus)/\(slice) regressed:\n\(failures.joined(separator: "\n"))")
    }

    static let baselineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("baseline.json")

    /// The numbers the gate keeps per set: counts only, no text.
    static func aggregate(_ scores: [String: SetScore], paths: Int) -> [String: Any] {
        var result: [String: Any] = [:]
        for (set, score) in scores {
            var labels: [String: Any] = [:]
            for (label, tally) in score.labels { labels[label] = ["spans": tally.spans, "caught": tally.caught] }
            result[set] = ["documents": score.documents, "documentsWithLeft": score.documentsWithLeft, "plainWords": score.plainWords, "changedWords": score.changedWords,
                           "words": score.words, "reviewFindings": score.reviewFindings, "paths": paths, "labels": labels]
        }
        return result
    }

    /// What got worse than the baseline beyond its tolerance:
    /// - a label's caught spans: down by more than one span or 0.5% of them;
    /// - documents with a labelled value left: up by more than one or 1% of the set;
    /// - words changed outside labels: up by more than 0.03 points or 5% of the rate;
    /// - review findings per 1,000 words: up by more than 0.25 or 10%.
    static func regressions(_ measured: [String: Any], against recorded: [String: Any]) -> [String] {
        var found: [String] = []
        func int(_ object: Any?, _ key: String) -> Int { (object as? [String: Any])?[key] as? Int ?? 0 }
        for set in recorded.keys.sorted() {
            guard let before = recorded[set] as? [String: Any] else { continue }
            guard let after = measured[set] as? [String: Any] else { found.append("\(set): missing from this run"); continue }
            let beforeLabels = before["labels"] as? [String: Any] ?? [:], afterLabels = after["labels"] as? [String: Any] ?? [:]
            for label in beforeLabels.keys.sorted() {
                let spans = int(beforeLabels[label], "spans"), was = int(beforeLabels[label], "caught"), now = int(afterLabels[label], "caught")
                if was - now > max(1, Int((Double(spans) * 0.005).rounded(.down))) { found.append("\(set) \(label): caught \(now) of \(spans), baseline \(was)") }
            }
            let documents = int(before, "documents")
            let left = (int(before, "documentsWithLeft"), int(after, "documentsWithLeft"))
            if left.1 - left.0 > max(1, documents / 100) { found.append("\(set): \(left.1) documents with a labelled value left, baseline \(left.0)") }
            func rate(_ object: [String: Any], _ part: String, _ whole: String) -> Double { Double(int(object, part)) / Double(max(1, int(object, whole))) }
            let changed = (rate(before, "changedWords", "plainWords"), rate(after, "changedWords", "plainWords"))
            if changed.1 - changed.0 > max(0.0003, changed.0 * 0.05) { found.append(String(format: "%@: %.3f%% of other words changed, baseline %.3f%%", set, changed.1 * 100, changed.0 * 100)) }
            // Findings are counted on every path; per 1,000 words of one.
            let review = (rate(before, "reviewFindings", "words") * 1000 / Double(max(1, int(before, "paths"))), rate(after, "reviewFindings", "words") * 1000 / Double(max(1, int(after, "paths"))))
            if review.1 - review.0 > max(0.25, review.0 * 0.1) { found.append(String(format: "%@: %.2f review findings per 1,000 words, baseline %.2f", set, review.1, review.0)) }
        }
        return found
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
        score.words += input.count
        for path in paths {
            let (data, name) = PIIGaps.wrap(document.text, path)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            // Review asks about each uncertain finding once; spread over the paths, as words are.
            score.reviewFindings += result.uncertain.count
            let output = PIIGaps.readable(result.output, path)
            changedOn[path] = changed(input, output)
            if path == .text, show.contains(document.id) { print("SHOW \(document.id):\n\(output)\n") }
        }
        score.documents += 1
        var left = false
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
                left = true
                let missedOn = paths.filter { !caughtOn.contains($0) }
                // The words that stayed, on the first path that kept any.
                let stayed = missedOn.first.map { path in inside.filter { !changedOn[path]!.contains($0) }.map { input[$0].word } } ?? []
                score.misses.append("\(span.label) [\(missedOn.map(\.rawValue).joined(separator: ","))] \(document.id): " + context(span.start..<span.end) + " ‖kept: " + stayed.joined(separator: " "))
            }
        }
        if left { score.documentsWithLeft += 1 }
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
        lines += ["", "| set | documents | with a labelled value left | plain words | changed (over-redaction) | review findings / 1k words |", "|---|---|---|---|---|---|"]
        for (set, score) in scores.sorted(by: { $0.key < $1.key }) {
            let review = String(format: "%.2f", Double(score.reviewFindings) / Double(max(1, paths.count)) / Double(max(1, score.words)) * 1000)
            lines.append("| \(set) | \(score.documents) | \(score.documentsWithLeft) (\(percent(score.documentsWithLeft, score.documents))) | \(score.plainWords / max(paths.count, 1)) | \(percent(score.changedWords, score.plainWords)) | \(review) |")
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
