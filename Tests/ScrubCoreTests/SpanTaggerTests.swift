import Foundation
@testable import ScrubCore
import Testing

/// The span tagger reads as the reference does: the same pieces for every
/// word in any script, and the same scores within the half-precision weights'
/// tolerance. Its weights ship apart from the code, so without them these skip.
@Suite(.serialized, .enabled(if: SpanTagger.shared != nil))
struct SpanTaggerTests {
    static let labels = ["person", "email", "phone_number", "address", "postal_code", "date_of_birth", "passport_number", "national_id_number",
                         "drivers_license_number", "tax_id", "bank_account", "iban", "card_number", "ip_address", "username", "account_id",
                         "medical_record_number", "organization", "date", "request_id", "ticket_id", "software_version"]

    struct Reference: Decodable {
        let text: String
        let ids: [Int32]
        /// Label, start and end in scalars, and the reference's confidence.
        let hits: [[Hit]]
        enum Hit: Decodable {
            case text(String), number(Double)
            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let number = try? single.decode(Double.self) { self = .number(number) } else { self = .text(try single.decode(String.self)) }
            }
            var text: String { if case .text(let t) = self { t } else { "" } }
            var number: Double { if case .number(let n) = self { n } else { 0 } }
        }
    }

    static func references() throws -> [Reference] {
        let url = try #require(Bundle.module.url(forResource: "span-tagger-parity", withExtension: "json"))
        return try JSONDecoder().decode([Reference].self, from: Data(contentsOf: url))
    }

    /// The reference ends every text with a stop before it reads it.
    static func stopped(_ text: String) -> [Unicode.Scalar] {
        let scalars = Array(text.unicodeScalars)
        return [".", "!", "?"].contains(scalars.last ?? " ") ? scalars : scalars + ["."]
    }

    @Test func piecesMatchTheReferenceInEveryScript() throws {
        let tagger = try #require(SpanTagger.shared)
        for reference in try Self.references() {
            #expect(tagger.input(Self.stopped(reference.text), labels: Self.labels).ids == reference.ids, "\(reference.text)")
        }
    }

    @Test func scoresMatchTheReference() throws {
        let tagger = try #require(SpanTagger.shared)
        for reference in try Self.references() {
            let hits = tagger.hits(Array(reference.text.unicodeScalars), labels: Self.labels, threshold: 0.3)
            let mine = Dictionary(hits.map { ("\($0.label) \($0.range.lowerBound) \($0.range.upperBound)", Double($0.score)) }, uniquingKeysWith: max)
            let theirs = Dictionary(reference.hits.map { ("\($0[0].text) \(Int($0[1].number)) \(Int($0[2].number))", $0[3].number) }, uniquingKeysWith: max)
            for (key, score) in theirs where score >= 0.31 {
                let found = try #require(mine[key], "\(reference.text): \(key) \(score) missing; got \(mine)")
                #expect(abs(found - score) < 0.01, "\(reference.text): \(key) \(found) vs \(score)")
            }
            for (key, score) in mine where score >= 0.31 { #expect(theirs[key] != nil, "\(reference.text): \(key) \(score) not in the reference") }
        }
    }

    @Test func readingIsDeterministic() throws {
        let tagger = try #require(SpanTagger.shared)
        let text = Array("Spoke with Naeru Okwuosa-Thill this morning; call 555-0142 or odalys.fenwright@example.com.".unicodeScalars)
        let first = tagger.hits(text, labels: Self.labels, threshold: 0.2)
        for _ in 0..<3 { #expect(tagger.hits(text, labels: Self.labels, threshold: 0.2) == first) }
    }

    /// Writes the pieces and hits for each item in SCRUB_TAGGER_ITEMS (a JSON
    /// array of {iid, text}, kept outside the repo) to SCRUB_TAGGER_OUT, for
    /// comparison with the reference's own run.
    @Test func referenceRun() throws {
        let env = ProcessInfo.processInfo.environment
        guard let itemsPath = env["SCRUB_TAGGER_ITEMS"], let outPath = env["SCRUB_TAGGER_OUT"] else { return }
        let tagger = try #require(SpanTagger.shared)
        let items = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: itemsPath))) as? [[String: Any]])
        var lines: [String] = []
        for item in items {
            let text = item["text"] as? String ?? ""
            let scalars = Array(text.unicodeScalars)
            let start = Date()
            let hits = tagger.hits(scalars, labels: Self.labels, threshold: 0.2)
            let seconds = Date().timeIntervalSince(start)
            let chunkIDs = scalars.count <= SpanTagger.chunk ? [tagger.input(Self.stopped(text), labels: Self.labels).ids.map(Int.init)] : []
            let row: [String: Any] = ["iid": item["iid"] ?? "", "sec": seconds, "ids": chunkIDs,
                                      "spans": hits.map { ["s": $0.range.lowerBound, "e": $0.range.upperBound, "label": $0.label, "conf": Double($0.score)] }]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}

/// Without its weights, or with other bytes than the expected ones, there is no tagger.
struct SpanTaggerWeightsTests {
    @Test func otherBytesOrNoneAreNotLoaded() throws {
        #expect(SpanTagger.verified(Data("STG1".utf8)) == nil)
        #expect(SpanTagger.load(from: [URL(fileURLWithPath: "/nonexistent/SpanTagger.bin")]) == nil)
    }
}
