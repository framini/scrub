import Foundation
@testable import ScrubCore
import Testing

struct Gen {
    var rng: SeededGenerator
    init(seed: UInt64) { rng = SeededGenerator(seed: seed) }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(rng.next() % UInt64(range.count)) }
    mutating func choose<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
    mutating func string(_ alphabet: String, count: Int) -> String {
        let letters = Array(alphabet)
        return String((0..<count).map { _ in choose(letters) })
    }
    mutating func shuffled<T>(_ values: [T]) -> [T] {
        var result = values
        for i in result.indices.reversed() where i > 0 { result.swapAt(i, int(0...i)) }
        return result
    }
    mutating func token() -> String { "Qz7" + string("abcdefghijklmnopqrstuvwxyz0123456789", count: 13) }
    static let vocabulary = ["quiet", "simple", "useful", "report", "table", "page", "item", "total", "pending", "complete", "weekly", "summary"]
    mutating func filler(capitalized: Bool = false) -> String {
        let words = (0..<int(1...4)).map { _ in choose(Self.vocabulary) }
        let text = words.joined(separator: " ")
        return capitalized ? (int(0...1) == 0 ? text.capitalized : text.prefix(1).uppercased() + text.dropFirst()) : text
    }
}

struct PropertyRun {
    static let defaultCases = 24
    static let baseSeed = ProcessInfo.processInfo.environment["SCRUB_PROPERTY_SEED"].flatMap(UInt64.init)
        ?? UInt64.random(in: .min ... .max)
    let name: String
    let count: Int
    let start = ContinuousClock.now
    init(_ name: String) {
        self.name = name
        count = ProcessInfo.processInfo.environment["SCRUB_PROPERTY_CASES"].flatMap(Int.init) ?? Self.defaultCases
        precondition(count > 0)
        print("PROPERTY \(name) baseSeed=\(Self.baseSeed) cases=\(count)")
    }
    func seed(_ index: Int) -> UInt64 { Self.baseSeed &+ UInt64(index) }
    func finish() { print("PROPERTY \(name) baseSeed=\(Self.baseSeed) duration=\(start.duration(to: .now))") }
    func diagnostic(_ index: Int, _ doc: GeneratedDocument) -> Comment {
        Comment(rawValue: "property=\(name) baseSeed=\(Self.baseSeed) case=\(index) format=\(doc.format)\nINPUT:\n\(doc.text)\nBYTES(base64):\(doc.data.base64EncodedString())")
    }
}

struct PlantedValue {
    let original: String
    let key: String
}

struct GeneratedDocument {
    let text: String
    let format: String
    let planted: [PlantedValue]
    let delimiter: Character
    let quote: Character
    let newline: String
    var structure: DocumentModel?
    var plantedRanges: [String: [PlantedRange]] = [:]
    var plantedLocations: [String: [String]] {
        Dictionary(grouping: planted, by: \.original).mapValues { values in
            structure?.leaves.filter { $0.value.localizedCaseInsensitiveContains(values[0].original) }.map(\.path) ?? []
        }
    }
    var data: Data { Data(text.utf8) }
    var filename: String { "property." + format }
    func scrub(seed: UInt64, full: Bool = false) throws -> ScrubResult {
        try Scrubber.scrub(data, name: filename, forceFullDetection: full, seed: seed)
    }
    func model() throws -> DocumentModel { try structure ?? DocumentModel(data: data, format: format, delimiter: delimiter, quote: quote) }
}
