import Foundation
@testable import ScrubCore
import Testing

private func fixture(_ name: String, _ ext: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext)))
}

private func output(_ data: Data, _ name: String) throws -> String {
    String(decoding: try Scrubber.scrub(data, name: name).output, as: UTF8.self)
}

@Test func leadingXMLStylesheetIsScrubbedOnce() throws {
    let result = try output(fixture("xml-leading-stylesheet", "xml"), "input.xml")
    #expect(!result.contains("alice@example.com"))
    #expect(result.components(separatedBy: "xml-stylesheet").count == 2)
    #expect(result.contains("encoding=\"base64\""))
}

@Test(arguments: [false, true])
func numericPasswordCorrectsOtherFields(_ reversed: Bool) throws {
    let data = try reversed ? Data(#"{"note":"246813","password":246813}"#.utf8) : fixture("json-numeric-password", "json")
    let result = try output(data, "input.json")
    #expect(!result.contains("246813"))
    let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    #expect(object["password"] is NSNumber)
}

@Test func hugeExponentPasswordIsReplaced() throws {
    let result = try output(fixture("json-huge-exponent", "json"), "input.json")
    #expect(!result.contains("1e400"))
    #expect(try OrderedJSON.parse(result).isNumberObject)
}

private extension JSONValue {
    var isNumberObject: Bool {
        if case .object(let pairs) = self, case .number = pairs.first?.1 { return true }
        return false
    }
}

@Test func longQuotedCSVDialect() throws {
    let result = try output(fixture("csv-long-quoted-semicolon", "csv"), "input.csv")
    #expect(!result.contains("hunter2"))
    #expect(result.contains(String(repeating: "a", count: 70_000)))
    #expect(result.hasPrefix("password;note\n"))
}

@Test func namespacePrefixIsScrubbedConsistently() throws {
    let original = try String(decoding: fixture("xml-name-namespace", "xml"), as: UTF8.self)
    let source = original.replacingOccurrences(of: "</r>", with: "<RobertMitchell:x/></r>")
    let result = try output(Data(source.utf8), "input.xml")
    #expect(!result.contains("RobertMitchell"))
    #expect(try XMLFile.parses(Data(result.utf8)))
    let prefix = try #require(result.range(of: #"xmlns:([A-Za-z_][A-Za-z0-9_.-]*)="#, options: .regularExpression))
    let declaration = String(result[prefix]).dropFirst(6).dropLast()
    #expect(result.contains("<\(declaration):x"))
}

@Test func arrayIdentitiesStayDistinct() throws {
    let result = try Scrubber.scrub(fixture("json-identity-array", "json"), name: "input.json")
    let object = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let names = try #require(object["name"] as? [String])
    let note = try #require(object["note"] as? String)
    #expect(names.count == 2)
    #expect(names[0] != names[1])
    #expect(note.contains(names[0]))
    #expect(!note.contains("Ana Pereira"))
}

@Test func generatedXMLNamesAlwaysParse() throws {
    let source = Data(#"<r><password>qzxv</password><qzxv/></r>"#.utf8)
    for _ in 0..<200 {
        let result = try Scrubber.scrub(source, name: "input.xml")
        #expect(try XMLFile.parses(result.output))
    }
}

@Test func organisationNameInsideWordStays() throws {
    let mac = try output(fixture("text-macarthur-foundation", "txt"), "input.txt")
    #expect(mac.trimmingCharacters(in: .whitespacesAndNewlines) == "MacArthur Foundation")
    #expect(!(try output(Data("Ana Pereira signed the form.".utf8), "input.txt")).contains("Ana Pereira"))
}

@Test func csvCorrectionBudget() throws {
    func measure(_ rows: Int) throws -> Duration {
        let input = "password,note\n" + (0..<rows).map { index in
            let value = String(String(format: "%010d", index).map { Character(UnicodeScalar(97 + (Int(String($0)) ?? 0))!) })
            return "\(value),\(String(repeating: "x", count: 90))"
        }.joined(separator: "\n") + "\n"
        let start = ContinuousClock.now
        let result = try Scrubber.scrub(Data(input.utf8), name: "input.csv")
        #expect(result.counts["SECRET"] == rows)
        return start.duration(to: .now)
    }
    // Other suites run in parallel and their load changes between two runs, so
    // the sizes alternate and the fastest run of each is compared.
    var half = Duration.seconds(3600), full = Duration.seconds(3600)
    for _ in 0..<2 {
        half = min(half, try measure(2_500))
        full = min(full, try measure(5_000))
    }
    #expect(full < half * 3)
}

@Test func standInsNeverReuseRealNamesFromTheDocument() throws {
    let text = "Dear Mr. Johnson,\nThanks for meeting Emily Chen and me last Thursday. Emily will send the draft to emily.chen@contoso.com.\nBest, Kevin"
    for seed in UInt64(1)...1000 {
        let output = String(decoding: try Scrubber.scrub(Data(text.utf8), name: "note.txt", forceFullDetection: false, seed: seed).output, as: UTF8.self)
        for real in ["Johnson", "Emily", "Chen", "Kevin"] { #expect(!output.localizedCaseInsensitiveContains(real), "seed \(seed): \(output)") }
    }
}

@Test func initialsDoNotExhaustStandInNames() {
    let people = People(rng: SeededGenerator(seed: 7))
    people.reserve(["J. Smith", "E. Li", "Al Jones"])
    let firsts = Set((0..<300).map { people.register("real\($0)", "person\($0)").first })
    #expect(firsts.count >= 150)
}

@Test func mentionWithoutMiddleNameIsAKnownPerson() {
    let people = People(rng: SeededGenerator(seed: 3))
    _ = people.registerFull("Robert James Mitchell")
    #expect(people.knows("Robert Mitchell"))
    #expect(people.knows("Robert James Mitchell"))
    #expect(!people.knows("Robert David Mitchell"))
}
