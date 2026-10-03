import Foundation
@testable import ScrubCore
import Testing

/// Writes what Tools/PersonScorer fits the person scorer on. Both tests do
/// nothing unless their variable is set, and neither reads the real-text
/// evaluation sets.
///
/// SCRUB_PERSON_GAPS_OUT=/file.jsonl writes NameGaps and PIIGaps cases as
/// labelled documents, from SCRUB_PERSON_GAPS_SEED (it must differ from the
/// benchmarks' own seed, 1) with SCRUB_PERSON_GAPS_CASES cases per category.
///
/// SCRUB_PERSON_SIGNALS=/a.jsonl,/b.jsonl reads labelled documents, one a
/// line: {"id", "text", "spans": [[start, end, label]]}, offsets in code
/// points unless "utf16" is true. It runs the detector with the context
/// model on each and writes to SCRUB_PERSON_SIGNALS_OUT one row per person
/// only a model guessed (`C`: its signals, what the hand rules decide and
/// whether it overlaps a labelled person or handle) and one per labelled
/// person (`G`: whether another detector already found it).
@Suite(.serialized)
struct PersonScorerData {
    struct Document: Decodable {
        var id: String?
        let text: String
        let spans: [[Value]]
        let utf16: Bool?
        let source: String?

        enum Value: Decodable {
            case number(Int), label(String)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) { self = .number(number) } else { self = .label(try container.decode(String.self)) }
            }
        }

        /// The labelled spans in UTF-16 offsets.
        func labelled() -> [(range: Range<Int>, label: String)] {
            var units: [Int] = [0]
            if utf16 != true { for scalar in text.unicodeScalars { units.append(units.last! + scalar.utf16.count) } }
            return spans.compactMap { values in
                guard values.count == 3, case let .number(start) = values[0], case let .number(end) = values[1], case let .label(label) = values[2] else { return nil }
                if utf16 == true { return (start..<end, label) }
                guard start < units.count, end < units.count, start < end else { return nil }
                return (units[start]..<units[end], label)
            }
        }
    }

    static let people: Set<String> = ["PERSON", "USERNAME"]

    @Test func generatedCases() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let out = environment["SCRUB_PERSON_GAPS_OUT"] else { return }
        let seed = try #require(environment["SCRUB_PERSON_GAPS_SEED"].flatMap(UInt64.init), "SCRUB_PERSON_GAPS_SEED is required")
        try #require(seed != NameGaps.defaultSeed && seed != PIIGaps.defaultSeed, "the benchmarks' own seed is held out")
        let count = environment["SCRUB_PERSON_GAPS_CASES"].flatMap(Int.init) ?? 40
        var lines: [String] = []
        func write(_ id: String, _ text: String, _ spans: [(Range<Int>, String)]) throws {
            let object: [String: Any] = ["id": id, "source": id.components(separatedBy: "-").first ?? id, "text": text, "utf16": true,
                                         "spans": spans.map { [$0.0.lowerBound, $0.0.upperBound, $0.1] as [Any] }]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        }
        for (position, category) in GapCategory.allCases.enumerated() {
            var cases = GapCaseGen(seed: seed &+ UInt64(position) &* 100_003)
            for index in 0..<count {
                let sample = cases.make(category)
                let label = category == .handles ? "USERNAME" : "PERSON"
                let spans = category.isKeep ? [] : sample.names.flatMap { name in NameGaps.occurrences(of: name, in: sample.prose).map { ($0, label) } }
                try write("namegaps-\(category.rawValue)-\(index)", sample.prose, spans)
            }
        }
        // Only the categories whose people are all labelled: elsewhere a sentence may name someone the case does not list.
        let labelled: [PIIGapCategory: String] = [.mailHeaders: "PERSON", .titledNames: "PERSON", .nonLatinNames: "PERSON", .handlesInProse: "USERNAME",
                                                  .headersWithoutPeople: "", .titlesWithoutPeople: "", .companiesWithoutPeople: "", .nonLatinNotNames: "",
                                                  .yearsNotBirths: "", .addressLookAlikes: "", .datesNotBirths: "", .labelsWithoutValues: "", .secretWordsNotSecrets: ""]
        // Places and employers beside people: the town or company is no one, and the people the generator names are.
        let named: [PIIGapCategory: String] = [.placesInProse: "LOCATION", .employersOfPeople: "ORG"]
        for (position, category) in PIIGapCategory.allCases.enumerated() {
            guard let label = labelled[category] ?? named[category] else { continue }
            var cases = PIIGapCaseGen(seed: seed &+ UInt64(position) &* 100_003)
            for index in 0..<count {
                let sample = cases.make(category)
                var spans = sample.targets.flatMap { target in NameGaps.occurrences(of: target, in: sample.prose).map { ($0, label) } }
                if named[category] != nil {
                    let people = Set(PIIGapCaseGen.people.flatMap { $0.split(separator: " ").map(String.init) } + PIIGapCaseGen.firsts)
                    spans += people.sorted().flatMap { name in NameGaps.occurrences(of: name, in: sample.prose).map { ($0, "PERSON") } }
                }
                try write("piigaps-\(category.rawValue)-\(index)", sample.prose, spans)
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    @Test func signals() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputs = environment["SCRUB_PERSON_SIGNALS"], let out = environment["SCRUB_PERSON_SIGNALS_OUT"] else { return }
        var documents: [Document] = []
        for file in inputs.split(separator: ",") {
            let name = ((String(file) as NSString).lastPathComponent as NSString).deletingPathExtension
            for (index, line) in try String(contentsOfFile: String(file), encoding: .utf8).split(separator: "\n").enumerated() where !line.isEmpty {
                var document = try JSONDecoder().decode(Document.self, from: Data(line.utf8))
                document.id = document.id ?? "\(name)-\(index)"
                documents.append(document)
            }
        }
        var rows = ["kind\tdoc\tsource\tmodel\tstart\tend\thand\tprobability\tlabel\toutside\tfree\tveto\tvalue\t" + PersonScorer.Signals.names.joined(separator: "\t")]
        func clean(_ value: String) -> String { value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        let batch = 256
        for start in stride(from: 0, to: documents.count, by: batch) {
            let slice = Array(documents[start..<min(documents.count, start + batch)])
            let readings = try ContextStage.find(slice.map(\.text), progress: { _, _, _ in }, cancelled: CancellationFlag())
            for (document, reading) in zip(slice, readings) {
                let detector = Detector(isCancelled: { false })
                detector.personLog = PersonLog()
                _ = detector.base(document.text, context: reading)
                let log = detector.personLog!
                let gold = document.labelled()
                let words = RealCorpus.words(document.text)
                let source = document.source ?? (document.id!.components(separatedBy: "-").first ?? "?")
                for candidate in log.candidates {
                    let label = gold.contains { Self.people.contains($0.label) && $0.range.overlaps(candidate.range) }
                    let outside = words.filter { word in word.range.overlaps(candidate.range) && !gold.contains { $0.range.overlaps(word.range) } }.count
                    let value = TextRanges.substring(document.text, candidate.range)
                    let features = candidate.signals.vector.map { String(format: "%.4f", $0) }
                    rows.append((["C", document.id!, source, candidate.source, String(candidate.range.lowerBound), String(candidate.range.upperBound), candidate.hand ? "1" : "0",
                                  String(format: "%.4f", candidate.probability), label ? "1" : "0", String(outside), candidate.free ? "1" : "0", candidate.ordinary ? "1" : "0", clean(value)] + features).joined(separator: "\t"))
                }
                for span in gold where Self.people.contains(span.label) {
                    let found = log.others.contains { $0.overlaps(span.range) }
                    rows.append(["G", document.id!, source, "", String(span.range.lowerBound), String(span.range.upperBound), "", "", span.label, found ? "1" : "0", "", "",
                                 clean(TextRanges.substring(document.text, span.range))].joined(separator: "\t"))
                }
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}
