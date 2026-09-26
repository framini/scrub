import Foundation
@testable import ScrubCore
import Testing

private func blockerFixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil)))
}

@Test(arguments: ["csv-apostrophe-tie.csv", "csv-apostrophe-unmatched.csv", "csv-apostrophe-records.csv"])
func literalApostrophesDoNotMergeRecords(_ name: String) throws {
    let data = try blockerFixture(name)
    let input = String(decoding: data, as: UTF8.self)
    #expect(CSVFile.sniffQuote(input, delimiter: ",") == "\"")
    let result = try Scrubber.scrub(data, name: name)
    let rows = try CSVFile.parse(String(decoding: result.output, as: UTF8.self), delimiter: ",")
    let before = try CSVFile.parse(input, delimiter: ",")
    #expect(rows.count == before.count)
    #expect(rows.map { $0[0] } == before.map { $0[0] })
    for (a, b) in zip(before.dropFirst(), rows.dropFirst()) { #expect(a[1] != b[1]) }
}

@Test(arguments: ["json-depth-canary.json", "xml-depth-canary.xml"])
func sniffingPropagatesDepthRefusal(_ fixture: String) throws {
    let data = try blockerFixture(fixture)
    for name in [fixture, "export"] {
        #expect(throws: ScrubError.unsupported("too_deep")) { try Scrubber.scrub(data, name: name) }
    }
}

@Test func middleNamesIdentifyDistinctPeopleAndMentions() throws {
    let data = try blockerFixture("json-middle-identities.json")
    let result = try Scrubber.scrub(data, name: "input.json")
    let rows = try #require(JSONSerialization.jsonObject(with: result.output) as? [[String: String]])
    let first = try #require(rows[0]["name"]), second = try #require(rows[1]["name"])
    #expect(first != second)
    #expect(rows[0]["note"] == "item \(first) complete; item \(second) summary; \(rows[2]["name"]!) pending")
    #expect(rows[2]["name"] != first)
    #expect(rows[2]["name"] != second)
}

@Test func escapedLeakOracleRejectsUnchangedDocuments() throws {
    for (format, text, original) in [
        ("xml", "<root><password>a&amp;b</password></root>", "a&b"),
        ("json", #"{"password":"a\"b"}"#, "a\"b"),
        ("csv", "password\n\"a\"\"b\"\n", "a\"b")
    ] {
        let doc = GeneratedDocument(text: text, format: format, planted: [PlantedValue(original: original, key: "password")], delimiter: ",", quote: "\"", newline: "\n")
        #expect(!text.contains(original))
        #expect(try doc.leaks(in: doc.data) == [original])
    }
}

@Test func surroundingTextOracleRejectsDeletedContext() throws {
    let doc = GeneratedDocument(text: #"{"password":"canaryvalue","note":"prefix canaryvalue between canaryvalue suffix"}"#, format: "json", planted: [PlantedValue(original: "canaryvalue", key: "password")], delimiter: ",", quote: "\"", newline: "\n")
    func output(_ note: String) -> Data {
        Data(OrderedJSON.render(.object([("password", .string("fake")), ("note", .string(note))])).0.utf8)
    }
    #expect(try doc.surroundingTextKept(in: output("prefix fake between fake suffix")))
    for note in ["fake between fake suffix", "prefix fake fake suffix", "prefix fake between fake"] {
        #expect(try !doc.surroundingTextKept(in: output(note)))
    }
}

@Test func generatedMiddleIdentitiesKeepRecordOwnership() throws {
    let run = PropertyRun("middleIdentities")
    defer { run.finish() }
    for index in 0..<run.count {
        var gen = Gen(seed: run.seed(index))
        let first = gen.choose(["Robert", "Jennifer", "Patricia", "Christopher"])
        let last = gen.choose(["Mitchell", "Sullivan", "Reynolds", "Bennett"])
        let middles = gen.shuffled(["James", "David", "Anne", "Jane"])
        let input = middles.map { middle in
            let full = "\(first) \(middle) \(last)"
            return ["firstName": first, "lastName": last, "name": full, "email": "\(first).\(middle).\(last)@private.invalid", "note": "item \(full) complete"]
        }
        let data = try JSONSerialization.data(withJSONObject: input, options: .sortedKeys)
        let result = try Scrubber.scrub(data, name: "people.json", forceFullDetection: false, seed: run.seed(index))
        let rows = try #require(JSONSerialization.jsonObject(with: result.output) as? [[String: String]])
        #expect(Set(rows.compactMap { $0["name"] }).count == middles.count, "seed=\(run.seed(index))")
        #expect(Set(rows.compactMap { $0["email"] }).count == middles.count, "seed=\(run.seed(index))")
        for row in rows {
            let full = try #require(row["name"])
            #expect(full == "\(row["firstName"]!) \(row["lastName"]!)")
            #expect(row["note"] == "item \(full) complete", "seed=\(run.seed(index))")
            let emailName = full.lowercased().split(separator: " ").joined(separator: ".")
            #expect(row["email"]?.hasPrefix(emailName + "@") == true, "seed=\(run.seed(index))")
        }
    }
}

@Test func fullNamesWithDifferentMiddlesNeverShareStandIns() throws {
    let data = Data(#"[{"name":"Robert James Mitchell"},{"name":"Robert David Mitchell"}]"#.utf8)
    let result = try Scrubber.scrub(data, name: "people.json")
    let rows = try #require(JSONSerialization.jsonObject(with: result.output) as? [[String: String]])
    #expect(rows[0]["name"] != rows[1]["name"])
}

@Test func ambiguousMiddlelessMentionGetsItsOwnStandIn() throws {
    let data = try blockerFixture("json-middle-ambiguous-note.json")
    let result = try Scrubber.scrub(data, name: "people.json")
    let object = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let people = try #require(object["people"] as? [[String: String]])
    let note = try #require(object["note"] as? String)
    #expect(!note.contains("Robert Mitchell"))
    for person in people { #expect(!note.contains(try #require(person["name"]))) }
    let start = "item ", end = " complete; repeat "
    let separator = try #require(note.range(of: end))
    let standIn = String(note[note.index(note.startIndex, offsetBy: start.count)..<separator.lowerBound])
    #expect(note == "item \(standIn) complete; repeat \(standIn) summary")
}
