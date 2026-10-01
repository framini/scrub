import Foundation
import NaturalLanguage
@testable import ScrubCore
import Testing

/// Measures where names slip through, by kind of gap, at three levels:
/// Apple's name tagger alone, Scrub's detector, and the full scrub. A case
/// passes when every name in it is gone (or, for keep cases, every
/// name-like word survives).
///
/// The default run is fixed and guards `baseline.json`: no category may score
/// lower than it did. SCRUB_GAPS_RECORD=1 rewrites the baseline after an
/// improvement. SCRUB_GAPS_SEED and SCRUB_GAPS_CASES explore other corpora
/// (the baseline is only checked on the default one). SCRUB_GAPS_DUMP=<path>
/// writes every case and its outcome as JSON lines.
@Suite(.serialized)
struct NameGaps {
    static let defaultSeed: UInt64 = 1
    static let defaultCases = 40
    static let personEntities: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "USERNAME"]
    static let baselineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("baseline.json")

    struct Outcome: Codable {
        let category: GapCategory
        let prose: String
        let names: [String]
        let keep: [String]
        let apple: Bool
        let detector: Bool
        let scrub: Bool
        let output: String
        let entities: [String: Int]
    }

    struct Score: Codable, Equatable {
        var cases = 0
        var apple = 0
        var detector = 0
        var scrub = 0
    }

    @Test func nameGaps() throws {
        let environment = ProcessInfo.processInfo.environment
        let seed = environment["SCRUB_GAPS_SEED"].flatMap(UInt64.init) ?? Self.defaultSeed
        let count = environment["SCRUB_GAPS_CASES"].flatMap(Int.init) ?? Self.defaultCases
        let isDefault = seed == Self.defaultSeed && count == Self.defaultCases
        var outcomes: [Outcome] = []
        for (position, category) in GapCategory.allCases.enumerated() {
            var cases = GapCaseGen(seed: seed &+ UInt64(position) &* 100_003)
            for index in 0..<count {
                let sample = cases.make(category)
                outcomes.append(try Self.judge(sample, seed: seed &+ UInt64(index)))
            }
        }
        var scores: [GapCategory: Score] = [:]
        for outcome in outcomes {
            scores[outcome.category, default: Score()].cases += 1
            if outcome.apple { scores[outcome.category]!.apple += 1 }
            if outcome.detector { scores[outcome.category]!.detector += 1 }
            if outcome.scrub { scores[outcome.category]!.scrub += 1 }
        }
        print(Self.report(scores, outcomes: outcomes, seed: seed, count: count))
        if let path = environment["SCRUB_GAPS_DUMP"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let lines = try outcomes.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        guard isDefault else { return }
        let named = Dictionary(uniqueKeysWithValues: scores.map { ($0.key.rawValue, $0.value) })
        if environment["SCRUB_GAPS_RECORD"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(named).write(to: Self.baselineURL)
            return
        }
        let baseline = try JSONDecoder().decode([String: Score].self, from: Data(contentsOf: Self.baselineURL))
        for category in GapCategory.allCases {
            let was = try #require(baseline[category.rawValue], "\(category.rawValue) has no baseline; run with SCRUB_GAPS_RECORD=1")
            let now = named[category.rawValue]!
            #expect(now.scrub >= was.scrub, "\(category.rawValue): scrub passed \(now.scrub)/\(now.cases), baseline \(was.scrub)/\(was.cases)")
        }
    }

    static func judge(_ sample: GapCase, seed: UInt64) throws -> Outcome {
        let prose = sample.prose
        let wanted = sample.category.isKeep ? sample.keep : sample.names
        let targets = wanted.flatMap { occurrences(of: $0, in: prose) }
        precondition(!targets.isEmpty, "\(sample.category): \(wanted) not in \(prose)")
        let tagged = appleNames(prose)
        let detected = Detector(isCancelled: { false }).find(prose).filter { $0.entity == "PERSON" }.map(\.range)
        let result = try Scrubber.scrub(sample.data, name: sample.filename, forceFullDetection: false, seed: seed)
        let output = readable(result.output, filename: sample.filename)
        let apple: Bool, detector: Bool, scrub: Bool
        if sample.category.isKeep {
            apple = targets.allSatisfy { target in !tagged.contains { $0.overlaps(target) } }
            detector = targets.allSatisfy { target in !detected.contains { $0.overlaps(target) } }
            // A city or country may be replaced as a place; only reading it as a person is wrong.
            let people = result.counts.filter { Self.personEntities.contains($0.key) }.values.reduce(0, +)
            scrub = people == 0 || sample.keep.allSatisfy { occurrences(of: $0, in: output).count == occurrences(of: $0, in: prose).count }
        } else {
            apple = targets.allSatisfy { covered($0, by: tagged) }
            detector = targets.allSatisfy { covered($0, by: detected) }
            scrub = sample.names.allSatisfy { occurrences(of: $0, in: output).isEmpty }
        }
        return Outcome(category: sample.category, prose: prose, names: sample.names, keep: sample.keep, apple: apple, detector: detector, scrub: scrub, output: output, entities: result.counts)
    }

    /// Where `word` appears as a whole word, in UTF-16 offsets, matching case.
    static func occurrences(of word: String, in text: String) -> [Range<Int>] {
        let pattern = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_.-])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}_])")
        return pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { $0.range.location..<NSMaxRange($0.range) }
    }

    static func covered(_ target: Range<Int>, by ranges: [Range<Int>]) -> Bool {
        ranges.contains { $0.lowerBound <= target.lowerBound && $0.upperBound >= target.upperBound }
    }

    /// What Apple's tagger alone calls a person, before any of Scrub's rules.
    static func appleNames(_ text: String) -> [Range<Int>] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var ranges: [Range<Int>] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName {
                let nsRange = NSRange(range, in: text)
                ranges.append(nsRange.location..<NSMaxRange(nsRange))
            }
            return true
        }
        return ranges
    }

    /// The text a reader sees: JSON string values unescaped, anything else as is.
    static func readable(_ data: Data, filename: String) -> String {
        guard filename.hasSuffix(".json"), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data, as: UTF8.self)
        }
        return object.keys.sorted().map { "\($0): \(object[$0]!)" }.joined(separator: "\n")
    }

    static func report(_ scores: [GapCategory: Score], outcomes: [Outcome], seed: UInt64, count: Int) -> String {
        func percent(_ part: Int, _ whole: Int) -> String { String(format: "%3.0f%%", Double(part) / Double(max(whole, 1)) * 100) }
        var lines = ["NAME GAPS seed=\(seed) cases=\(count) per category", "", "| category | apple | detector | scrub | what it covers |", "|---|---|---|---|---|"]
        for category in GapCategory.allCases {
            let score = scores[category] ?? Score()
            lines.append("| \(category.rawValue) | \(percent(score.apple, score.cases)) | \(percent(score.detector, score.cases)) | \(percent(score.scrub, score.cases)) | \(category.summary) |")
        }
        lines.append("")
        for category in GapCategory.allCases {
            let misses = Set(outcomes.filter { $0.category == category && !$0.scrub }.map(\.prose)).sorted().prefix(4)
            guard !misses.isEmpty else { continue }
            lines.append("\(category.rawValue) misses:")
            lines += misses.map { "  " + $0.replacingOccurrences(of: "\n", with: "⏎") }
        }
        return lines.joined(separator: "\n")
    }
}
