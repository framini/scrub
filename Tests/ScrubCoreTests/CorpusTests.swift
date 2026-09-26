import Foundation
import ScrubCore
import Testing

private struct CorpusSample: Decodable {
    let id: String
    let text: String
    let pii: [String]
    let keep: [String]
}

@Test func informalCueDoesNotScrubCommonPhrase() throws {
    let text = "Tell the team we ship with grace period rules"
    let result = try Scrubber.scrub(Data(text.utf8), name: "note.txt")
    #expect(String(decoding: result.output, as: UTF8.self) == text)
}

@Test func corpusScrubsPIIAndKeepsPlainText() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "corpus", withExtension: "json")))
    let samples = try JSONDecoder().decode([CorpusSample].self, from: data)
    for sample in samples {
        let result = try Scrubber.scrub(Data(sample.text.utf8), name: "sample.txt")
        let output = try #require(String(data: result.output, encoding: .utf8))
        for value in sample.pii { #expect(!output.localizedCaseInsensitiveContains(value), "\(sample.id): \(value)") }
        for value in sample.keep { #expect(output.contains(value), "\(sample.id): \(value)") }
    }
}
