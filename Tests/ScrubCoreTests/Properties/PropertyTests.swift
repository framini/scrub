import Foundation
@testable import ScrubCore
import Testing

@Suite(.serialized)
struct ScrubberProperties {
    private func cases(_ name: String, plain: Bool = false, capitalized: Bool = false, body: (GeneratedDocument, UInt64, Comment) throws -> Void) throws {
        let run = PropertyRun(name)
        defer { run.finish() }
        for index in 0..<run.count {
            var gen = Gen(seed: run.seed(index))
            let doc = try gen.document(format: ["json", "csv", "xml", "txt"][index % 4], plain: plain, capitalized: capitalized, large: index % 24 == 23 || name == "determinism" && index < 3)
            let diagnostic = run.diagnostic(index, doc)
            do { try body(doc, run.seed(index), diagnostic) }
            catch { Issue.record("Unexpected error: \(error). \(diagnostic)") }
        }
    }

    @Test func noLeaks() throws {
        try cases("noLeaks") { doc, seed, diagnostic in
            #expect(doc.plantedLocations.values.allSatisfy { !$0.isEmpty }, diagnostic)
            let output = try doc.scrub(seed: seed).output
            let leaked = try doc.leaks(in: output)
            #expect(leaked.isEmpty, "Leaked \(leaked). \(diagnostic)")
        }
    }

    @Test func structureKept() throws {
        try cases("structureKept") { doc, seed, diagnostic in
            let result = try doc.scrub(seed: seed)
            #expect(try doc.surroundingTextKept(in: result.output), diagnostic)
            let before = try doc.model()
            let after = try DocumentModel(data: result.output, format: doc.format, delimiter: doc.delimiter, quote: doc.quote)
            #expect(before.shape == after.shape, diagnostic)
            #expect(before.leaves.map(\.path) == after.leaves.map(\.path), diagnostic)
            for (a, b) in zip(before.leaves, after.leaves) {
                let containsPlanted = doc.planted.contains { a.value.localizedCaseInsensitiveContains($0.original) }
                if KeyHints.hint(a.key) == nil && !containsPlanted {
                    #expect(a.value == b.value, "Changed plain leaf \(a.path): \(a.value) -> \(b.value). \(diagnostic)")
                }
            }
            if doc.format == "csv" {
                let output = String(decoding: result.output, as: UTF8.self)
                #expect(CSVFile.sniffDelimiter(output) == doc.delimiter, diagnostic)
                #expect(CSVFile.sniffQuote(output, delimiter: doc.delimiter) == doc.quote, diagnostic)
                #expect(output.hasSuffix(doc.newline), diagnostic)
                #expect(output.filter { $0 == "\r\n" }.count == doc.text.filter { $0 == "\r\n" }.count, diagnostic)
            }
            if doc.format == "xml" {
                let output = String(decoding: result.output, as: UTF8.self)
                #expect(output.components(separatedBy: "<![CDATA[").count == doc.text.components(separatedBy: "<![CDATA[").count, diagnostic)
            }
        }
    }

    private func checkPlainVocabulary() {
        let names = Set((Names.first + Names.last).map { $0.lowercased() }).union(Names.ambiguousFirst)
        #expect(names.isDisjoint(with: Gen.vocabulary))
        #expect(Gen.vocabulary.allSatisfy { KeyHints.hint($0) == nil && !$0.hasPrefix("=") && !$0.hasPrefix("+") && !$0.hasPrefix("-") && !$0.hasPrefix("@") })
    }

    @Test func plainLowercase() throws {
        checkPlainVocabulary()
        try cases("plainLowercase", plain: true) { doc, seed, diagnostic in
            let result = try doc.scrub(seed: seed)
            #expect(result.output == doc.data, diagnostic)
            #expect(result.counts.isEmpty, diagnostic)
        }
    }

    // Apple's name model tags some capitalised word runs ("Quiet Table") as a
    // person or place, so random capitalised filler may change, but only into
    // names or places, and never loses its structure.
    @Test func plainCapitalized() throws {
        checkPlainVocabulary()
        try cases("plainCapitalized", plain: true, capitalized: true) { doc, seed, diagnostic in
            let result = try doc.scrub(seed: seed)
            #expect(Set(result.counts.keys).isSubset(of: ["PERSON", "LOCATION"]), diagnostic)
            #expect(try doc.model().shape == DocumentModel(data: result.output, format: doc.format, delimiter: doc.delimiter, quote: doc.quote).shape, diagnostic)
        }
    }

    // The same filler on fixed seeds, so the rate is exact from run to run. A
    // rule that tags capitalised pairs as people changes most documents.
    @Test func capitalizedFalsePositiveRate() throws {
        var changed = 0
        let total = 240
        for index in 0..<total {
            var gen = Gen(seed: 20_260_926 &+ UInt64(index))
            let doc = try gen.document(format: ["json", "csv", "xml", "txt"][index % 4], plain: true, capitalized: true, large: false)
            if try doc.scrub(seed: UInt64(index)).output != doc.data { changed += 1 }
        }
        print("capitalized false positives: \(changed) of \(total)")
        #expect(changed <= Self.capitalizedChangeCeiling, "\(changed) of \(total) capitalised plain documents changed")
    }
    static let capitalizedChangeCeiling = 12

    @Test func consistency() throws {
        try cases("consistency") { doc, seed, diagnostic in
            let before = try doc.model()
            let result = try doc.scrub(seed: seed)
            #expect(try doc.surroundingTextKept(in: result.output), diagnostic)
            let after = try DocumentModel(data: result.output, format: doc.format, delimiter: doc.delimiter, quote: doc.quote)
            let mapped = Dictionary(uniqueKeysWithValues: after.leaves.map { ($0.path, $0.value) })
            var people: [String: String] = [:]
            for planted in doc.planted {
                let fields = before.leaves.filter { !$0.isName && $0.value == planted.original && KeyHints.hint($0.key) != nil }
                guard let field = fields.first, let fake = mapped[field.path] else { continue }
                for field in fields { #expect(mapped[field.path] == fake, "Unequal repeated \(planted.original). \(diagnostic)") }
                for field in before.leaves where !field.isName && KeyHints.hint(field.key) == nil && field.value.contains(planted.original) {
                    #expect(mapped[field.path]?.contains(fake) == true, "Free text disagrees with \(planted.original) -> \(fake) at \(field.path). \(diagnostic)")
                }
                if KeyHints.hint(planted.key) == "PERSON" { people[planted.original] = fake }
            }
            #expect(Set(people.values).count == people.count, "Distinct people collided. \(diagnostic)")
        }
    }

    @Test func determinism() throws {
        try cases("determinism") { doc, seed, diagnostic in
            let fast = try doc.scrub(seed: seed)
            for full in [false, true] {
                let other = try doc.scrub(seed: seed, full: full)
                #expect(fast.output == other.output, diagnostic)
                #expect(fast.counts == other.counts, diagnostic)
                #expect(fast.unresolved == other.unresolved, diagnostic)
            }
        }
    }
}
