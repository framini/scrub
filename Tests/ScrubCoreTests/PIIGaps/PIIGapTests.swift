import Foundation
@testable import ScrubCore
import Testing

/// Measures personal values written in prose that rules should catch: dates
/// of birth, labelled IDs, secrets and post office boxes, beside ordinary text
/// that only looks like them. Each case goes through a text file, a JSON
/// field and a CSV column, and passes only when all three do: the value gone
/// and replaced as its type, or (for keep cases) the text unchanged.
///
/// The default run guards `baseline.json`: no category may score lower than
/// it did. SCRUB_PII_GAPS_RECORD=1 rewrites the baseline after an
/// improvement; SCRUB_PII_GAPS_SEED and SCRUB_PII_GAPS_CASES explore other
/// corpora.
@Suite(.serialized)
struct PIIGaps {
    static let defaultSeed: UInt64 = 1
    static let defaultCases = 40
    static let baselineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("baseline.json")

    enum InputPath: String, CaseIterable { case text, json, csv }

    struct Score: Codable, Equatable {
        var cases = 0
        var passed = 0
    }

    @Test func piiGaps() throws {
        // SCRUB_PII_GAPS_ADDRESS=off measures Scrub without the address model.
        // SCRUB_PII_GAPS_SCORER=off measures the hand rules in place of the person scorer.
        try PersonScorer.$learned.withValue(ProcessInfo.processInfo.environment["SCRUB_PII_GAPS_SCORER"] != "off") {
            if ProcessInfo.processInfo.environment["SCRUB_PII_GAPS_ADDRESS"] == "off" {
                try AddressModel.$active.withValue(false) { try measure() }
            } else {
                try measure()
            }
        }
    }

    private func measure() throws {
        let environment = ProcessInfo.processInfo.environment
        let seed = environment["SCRUB_PII_GAPS_SEED"].flatMap(UInt64.init) ?? Self.defaultSeed
        let count = environment["SCRUB_PII_GAPS_CASES"].flatMap(Int.init) ?? Self.defaultCases
        // SCRUB_PII_GAPS_CONTEXT=off measures Scrub without the context model.
        if environment["SCRUB_PII_GAPS_CONTEXT"] == "off" { ContextStage.enabled.store(false, ordering: .relaxed) }
        defer { ContextStage.enabled.store(true, ordering: .relaxed) }
        let isDefault = seed == Self.defaultSeed && count == Self.defaultCases && environment["SCRUB_PII_GAPS_CONTEXT"] == nil && environment["SCRUB_PII_GAPS_ADDRESS"] == nil && environment["SCRUB_PII_GAPS_SCORER"] == nil
        var scores: [PIIGapCategory: Score] = [:]
        var misses: [PIIGapCategory: [String]] = [:]
        for (position, category) in PIIGapCategory.allCases.enumerated() {
            var cases = PIIGapCaseGen(seed: seed &+ UInt64(position) &* 100_003)
            for index in 0..<count {
                let sample = cases.make(category)
                let failures = try InputPath.allCases.compactMap { try Self.failure(sample, path: $0, seed: seed &+ UInt64(index)) }
                scores[category, default: Score()].cases += 1
                if failures.isEmpty { scores[category]!.passed += 1 }
                else if misses[category, default: []].count < 4 { misses[category, default: []].append(failures[0]) }
            }
        }
        print(Self.report(scores, misses: misses, seed: seed, count: count))
        guard isDefault else { return }
        let named = Dictionary(uniqueKeysWithValues: scores.map { ($0.key.rawValue, $0.value) })
        if environment["SCRUB_PII_GAPS_RECORD"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(named).write(to: Self.baselineURL)
            return
        }
        let baseline = try JSONDecoder().decode([String: Score].self, from: Data(contentsOf: Self.baselineURL))
        for category in PIIGapCategory.allCases {
            let was = try #require(baseline[category.rawValue], "\(category.rawValue) has no baseline; run with SCRUB_PII_GAPS_RECORD=1")
            let now = named[category.rawValue]!
            #expect(now.passed >= was.passed, "\(category.rawValue): passed \(now.passed)/\(now.cases), baseline \(was.passed)/\(was.cases)")
        }
    }

    /// Why `sample` fails on `path`, or nil when it passes.
    static func failure(_ sample: PIIGapCase, path: InputPath, seed: UInt64) throws -> String? {
        let (data, name) = wrap(sample.prose, path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
        let output = readable(result.output, path)
        let shown = "[\(path.rawValue)] \(sample.prose)  →  \(output)".replacingOccurrences(of: "\n", with: "⏎")
        if sample.category.isKeep { return output == sample.prose ? nil : shown }
        if let left = sample.targets.first(where: { contains(output, word: $0) }) { return "kept \(left): " + shown }
        if let lost = sample.cues.first(where: { !output.localizedCaseInsensitiveContains($0) }) { return "lost cue \(lost): " + shown }
        if let entity = sample.category.entity, result.counts[entity, default: 0] == 0 {
            return "not as \(entity) \(result.counts): " + shown
        }
        return nil
    }

    /// Whether `word` is in `text` on its own, not as part of a longer number ("701" in "85701").
    static func contains(_ text: String, word: String) -> Bool {
        text.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
    }

    static func wrap(_ text: String, _ path: InputPath) -> (Data, String) {
        switch path {
        case .text: return (Data(text.utf8), "note.txt")
        case .json:
            let object: [String: Any] = ["ticket": 4471, "status": "open", "note": text]
            return (try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), "ticket.json")
        case .csv:
            let quoted = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return (Data("ticket,status,remark\n4471,open,\(quoted)\n".utf8), "tickets.csv")
        }
    }

    /// The prose as it reads after scrubbing, whatever held it.
    static func readable(_ data: Data, _ path: InputPath) -> String {
        switch path {
        case .text: return String(decoding: data, as: UTF8.self)
        case .json: return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["note"] as? String ?? ""
        case .csv: return (try? CSVFile.parse(String(decoding: data, as: UTF8.self), delimiter: ","))?.dropFirst().first?.last ?? ""
        }
    }

    static func report(_ scores: [PIIGapCategory: Score], misses: [PIIGapCategory: [String]], seed: UInt64, count: Int) -> String {
        var lines = ["PII GAPS seed=\(seed) cases=\(count) per category, all three paths", "", "| category | passed | what it covers |", "|---|---|---|"]
        for category in PIIGapCategory.allCases {
            let score = scores[category] ?? Score()
            lines.append("| \(category.rawValue) | " + String(format: "%3.0f%%", Double(score.passed) / Double(max(score.cases, 1)) * 100) + " | \(category.summary) |")
        }
        for category in PIIGapCategory.allCases {
            guard let list = misses[category], !list.isEmpty else { continue }
            lines.append("\(category.rawValue) misses:")
            lines += list.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}

@Test func proseLabelPatternsCompile() {
    // A pattern that fails to compile finds nothing, silently.
    let found = ProseLabels.scan("born on March 5, 1971; passport number A1234567; the password is velvet-Cobalt-47; PO Box 4872")
    #expect(Set(found.spans.map(\.entity)) == ["DATE_OF_BIRTH", "ID_NUMBER", "SECRET", "ADDRESS"])
    let url = "clone https://deploy:velvet-Cobalt-47@git.corvane.test/app.git"
    #expect(ProseLabels.scan(url).spans.map { TextRanges.substring(url, $0.range) } == ["velvet-Cobalt-47"])
}

@Test func proseLabelsStayInsideOneLineOfProse() {
    // Keys of a YAML record, a form schema and code: no label meets a value.
    for text in ["resourceType: Patient\nid: 61e3629b-b8e2-0d92-8dcd-ac1655ff8d1d", "fields:\n  - key: dateOfBirth\n    type: date", "- key: DATE_OF_BIRTH",
                 "const q = { password: sql`SELECT 1` };", "token:\n  ttl: 3600", "Passport\nA1234567 is not a label"] {
        #expect(ProseLabels.scan(text).spans.isEmpty, "\(text)")
    }
}

@Test func aTitleIsNoNamePartAndInitialsStayInitials() throws {
    // A titled name teaches the document its surname, never its title: every
    // other "Mr" and "Ms" stays, and the same person keeps the same initials.
    let text = "Ms E. Gravenor represented the applicant. Mr Okonkwo-Lind objected.\nLater Ms E. Gravenor withdrew; Mr and Ms Fenwright-style titles stay."
    let output = String(decoding: try Scrubber.scrub(Data(text.utf8), name: "n.txt", forceFullDetection: false, seed: 5).output, as: UTF8.self)
    #expect(!output.contains("Gravenor") && !output.contains("Okonkwo"), "\(output)")
    #expect(output.components(separatedBy: "Ms ").count == text.components(separatedBy: "Ms ").count, "\(output)")
    #expect(output.contains("Mr and Ms"), "\(output)")
    let initials = output.matches(of: /Ms ([A-Z]\.) ([A-Z][a-z]+)/).map { "\($0.1) \($0.2)" }
    #expect(initials.count == 2 && Set(initials).count == 1, "\(output)")
}

@Test func aStackedAddressKeepsItsLinesAndOnePlace() throws {
    let text = "Regards,\nOren Halloway\n2200 Kessler Avenue, Suite 410\nBoise, ID  83702\nPhone: (208) 555-0143"
    for seed in UInt64(0)..<20 {
        let output = String(decoding: try Scrubber.scrub(Data(text.utf8), name: "n.txt", forceFullDetection: false, seed: seed).output, as: UTF8.self)
        let lines = output.components(separatedBy: "\n")
        #expect(lines.count == 5 && !output.contains("Kessler") && !output.contains("83702"), "\(output)")
        // The city line names a real place whose region and postcode agree.
        let city = try #require(lines.count == 5 ? lines[3] : nil)
        let parts = try #require(AddressParts.line(city)?.parts, "\(city)")
        let place = Places.all.first { $0.city == parts.city }
        #expect(place.map { $0.region == parts.region && $0.postal.contains(String(parts.postal?.prefix(5) ?? "")) } == true, "\(output)")
    }
}
