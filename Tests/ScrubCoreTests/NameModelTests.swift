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
