import Foundation
@testable import ScrubCore
import Testing

private struct ParityCase: Decodable {
    let text: String
    let tokens: [[Int]]
    let logits: [Float]
}

@Test func nameModelLoads() throws {
    #expect(NameModel.shared != nil)
}

/// The Swift port splits and scores text exactly as the trained model does,
/// including a long text that spans several windows.
@Test func nameModelMatchesTraining() throws {
    let model = try #require(NameModel.shared)
    // `@testable` makes Bundle.module mean ScrubCore's bundle here, so read the fixture from source.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/name-model-parity.json")
    let cases = try JSONDecoder().decode([ParityCase].self, from: Data(contentsOf: url))
    for sample in cases {
        let tokens = NameModel.tokens(sample.text)
        #expect(tokens.map { [$0.range.lowerBound, $0.range.upperBound] } == sample.tokens, "\(sample.text.prefix(60))")
        let logits = tokens.isEmpty ? [] : model.logits(tokens)
        #expect(logits.count == sample.logits.count)
        for (index, (swift, python)) in zip(logits, sample.logits).enumerated() {
            #expect(abs(swift - python) < 1e-3 * max(1, abs(python)), "\(sample.text.prefix(60)) token \(index): \(swift) vs \(python)")
        }
    }
}

@Test func nameModelRejectsDamagedWeights() {
    #expect(NameModel(Data("SNM1".utf8)) == nil)
    #expect(NameModel(Data()) == nil)
}

@Test func nameModelFindsSignOffAndHandle() throws {
    let model = try #require(NameModel.shared)
    let text = "Hi Arjun,\n\nping @maria.gonzalez please.\n\nThanks,\nTariq"
    let found = model.find(text).map { (TextRanges.substring(text, $0.range), $0.entity) }
    #expect(found.contains { $0 == ("Arjun", "PERSON") })
    #expect(found.contains { $0 == ("maria.gonzalez", "USERNAME") })
    #expect(found.contains { $0 == ("Tariq", "PERSON") })
}

/// The weights load only as shipped: a file whose bytes differ from the
/// checksum in code is refused, even one that still parses as a model, and
/// Scrub then runs without it, as it does without the context model or the name lists.
@Test func nameModelLoadsOnlyWithItsChecksum() throws {
    #expect(NameModel.shared != nil)
    let url = try #require(ModelResources.bundle?.url(forResource: "NameModel", withExtension: "bin"))
    var data = try Data(contentsOf: url)
    #expect(NameModel.verified(data) != nil)
    // One weight changed: still a well-formed model, but not the shipped one.
    data[data.count - 8] ^= 0x01
    #expect(NameModel(data) != nil)
    #expect(NameModel.verified(data) == nil, "an altered file is refused")
    #expect(NameModel.verified(try Data(contentsOf: url), checksum: String(repeating: "0", count: 64)) == nil)
}

/// A word written with a combining accent is scored as written, whichever spelling was read first.
@Test func nameModelScoresEachSpellingOfAnAccentAsWritten() throws {
    let url = try #require(ModelResources.bundle?.url(forResource: "NameModel", withExtension: "bin"))
    let data = try Data(contentsOf: url)
    let composed = NameModel.tokens("Ren\u{E9}e Dub\u{E9} wrote"), decomposed = NameModel.tokens("Rene\u{301}e Dube\u{301} wrote")
    let alone = try #require(NameModel(data)), warmed = try #require(NameModel(data))
    _ = warmed.logits(composed)
    #expect(warmed.logits(decomposed) == alone.logits(decomposed))
}
