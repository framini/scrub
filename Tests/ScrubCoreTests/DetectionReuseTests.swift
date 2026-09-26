import Foundation
@testable import ScrubCore
import Testing

private struct CorpusEntry: Decodable {
    let text: String
}

private func sameResult(_ data: Data, name: String) throws {
    let reused = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 42)
    let full = try Scrubber.scrub(data, name: name, forceFullDetection: true, seed: 42)
    #expect(reused.output == full.output, "\(name)" )
    #expect(reused.counts == full.counts, "\(name)" )
    #expect(reused.unresolved == full.unresolved, "\(name)" )
    switch (reused.preview, full.preview) {
    case let (.text(a, am, at), .text(b, bm, bt)):
        #expect(a == b && am == bm && at == bt, "\(name)" )
    case let (.table(ac, ar, an, am), .table(bc, br, bn, bm)):
        #expect(ac == bc && ar == br && an == bn && am == bm, "\(name)" )
    default:
        Issue.record("Preview format differs: \(name)")
    }
}

@Test func reusedDetectionMatchesFullDetection() throws {
    let fixtures = try #require(Bundle.module.url(forResource: "customers", withExtension: "json"))
        .deletingLastPathComponent()
    for file in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
        where ["json", "csv", "xml", "txt"].contains(file.pathExtension) && !file.lastPathComponent.contains("expected") {
        if file.lastPathComponent == "corpus.json" { continue }
        let data = try Data(contentsOf: file)
        if (try? Scrubber.scrub(data, name: file.lastPathComponent, forceFullDetection: false, seed: 42)) != nil {
            try sameResult(data, name: file.lastPathComponent)
        }
    }
    let corpus = try Data(contentsOf: fixtures.appendingPathComponent("corpus.json"))
    for entry in try JSONDecoder().decode([CorpusEntry].self, from: corpus) {
        try sameResult(Data(entry.text.utf8), name: "sample.txt")
    }
}
