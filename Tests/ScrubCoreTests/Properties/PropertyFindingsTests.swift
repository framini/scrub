import Foundation
@testable import ScrubCore
import Testing

private func propertyFixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil)))
}

@Test(arguments: ["csv-multiline-quote-shifts-secret.csv", "csv-single-quote-shifts-secret.csv"])
func multilineCSVQuoteDoesNotShiftSecretColumn(_ fixture: String) throws {
    let data = try propertyFixture(fixture)
    let quote = CSVFile.sniffQuote(String(decoding: data, as: UTF8.self), delimiter: ",")
    let result = try Scrubber.scrub(data, name: "input.csv", forceFullDetection: false, seed: 7366703340863372610)
    let text = String(decoding: result.output, as: UTF8.self)
    #expect(!text.contains("Qz7t8x5jh4bpqciy"))
    let rows = try CSVFile.parse(text, delimiter: ",", quoteCharacter: quote)
    #expect(rows.allSatisfy { $0.count == rows.first?.count })
    if fixture.contains("single") { return }
    #expect(rows.count == 3)
    #expect(rows[1][0] == "quiet, useful \(quote)table\(quote)\nsummary")
    #expect(rows[1][1] == rows[2][1])
}

@Test func unchangedXMLReferencesKeepTheirValues() throws {
    let data = try propertyFixture("xml-plain-character-references.xml")
    let result = try Scrubber.scrub(data, name: "input.xml", forceFullDetection: false, seed: 7366703340863372611)
    let document = try XMLDocument(data: result.output, options: [.nodePreserveAll])
    #expect(document.rootElement()?.elements(forName: "description").first?.stringValue == "quiet\r\nsummary")
    #expect(!String(decoding: result.output, as: UTF8.self).contains("Qz75g2o2ukttqlgx"))
}

@Test func plainXMLKeepsSourceBytes() throws {
    let data = try propertyFixture("xml-plain-no-changes.xml")
    let result = try Scrubber.scrub(data, name: "input.xml", forceFullDetection: false, seed: 7366703340863372611)
    #expect(result.output == data)
    #expect(result.counts.isEmpty)
}

@Test(arguments: ["json-depth-256.json", "xml-depth-512.xml", "xml-depth-5000.xml"])
func recursiveDocumentsRefuseBeforeBuildingTrees(_ name: String) throws {
    let data = try propertyFixture(name)
    #expect(throws: ScrubError.unsupported("too_deep")) {
        try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 1531337837754027439)
    }
}

@Test(arguments: [63, 64, 65, 5_000])
func nestingBoundary(_ depth: Int) throws {
    for (format, input) in [("json", String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)),
                            ("xml", String(repeating: "<r>", count: depth) + "quiet" + String(repeating: "</r>", count: depth))] {
        if depth > 64 {
            #expect(throws: ScrubError.unsupported("too_deep")) { try Scrubber.scrub(Data(input.utf8), name: "input." + format) }
        } else {
            let result = try Scrubber.scrub(Data(input.utf8), name: "input." + format)
            #expect(result.counts.isEmpty)
        }
    }
}

@Test(arguments: [
    ("json-numeric-repeat-consistency.json", "clientSecret", "password", "70732746", UInt64(7366703340863372637)),
    ("json-numeric-phone-repeat-consistency.json", "telephone", "mobile", "36749497", UInt64(7366703340863372685))
])
func numericFieldsShareStandInsWithStringsAndNotes(_ fixture: String, _ numericKey: String, _ arrayKey: String, _ original: String, _ seed: UInt64) throws {
    let data = try propertyFixture(fixture)
    let result = try Scrubber.scrub(data, name: "input.json", forceFullDetection: false, seed: seed)
    let object = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let number = try #require(object[numericKey] as? NSNumber).stringValue
    #expect(object["note"] as? String == "item \(number) complete")
    #expect(object[arrayKey] as? [String] == [number, number])
    #expect(number != original)
}

@Test func unrelatedEmailStandInsRespectReservedNameParts() throws {
    let data = try propertyFixture("json-unrelated-email-reserved-name.json")
    for seed in UInt64(0)..<300 {
        let result = try Scrubber.scrub(data, name: "input.json", forceFullDetection: false, seed: seed)
        #expect(!String(decoding: result.output, as: UTF8.self).lowercased().contains("robert"), "seed=\(seed)")
    }
}

@Test func hintedNameOverridesModelLabelInMarkupAndNotes() throws {
    let data = try propertyFixture("xml-hinted-name-in-markup.xml")
    let result = try Scrubber.scrub(data, name: "input.xml", forceFullDetection: false, seed: 7366703340863372627)
    let root = try #require(XMLDocument(data: result.output, options: [.nodePreserveAll]).rootElement())
    let first = try #require(root.elements(forName: "firstName").first?.stringValue)
    #expect(root.elements(forName: "note").first?.stringValue == "item \(first) complete")
    let renamed = try #require(root.children?.last as? XMLElement)
    #expect(renamed.attributes?.first?.stringValue == first)
    #expect(!String(decoding: result.output, as: UTF8.self).contains("Patricia"))
}

@Test func distinctPeopleCannotDrawTheSameFullName() throws {
    let data = try propertyFixture("json-distinct-people-collision.json")
    let result = try Scrubber.scrub(data, name: "input.json", forceFullDetection: false, seed: 41301)
    let rows = try #require(JSONSerialization.jsonObject(with: result.output) as? [[String: String]])
    #expect(rows.count == 2)
    #expect(rows[0]["name"] != rows[1]["name"])
}

@Test(arguments: ["xml-attribute-whitespace.xml", "xml-preserved-escaped-text.xml"])
func xmlSerializationPreservesDecodedPlainValues(_ fixture: String) throws {
    let data = try propertyFixture(fixture)
    let before = try DocumentModel(data: data, format: "xml")
    let result = try Scrubber.scrub(data, name: fixture, forceFullDetection: false, seed: 12316281535911190151)
    let after = try DocumentModel(data: result.output, format: "xml")
    #expect(before.shape == after.shape)
    for (a, b) in zip(before.leaves, after.leaves) {
        if a.value == "canaryvalue" { #expect(b.value != a.value) }
        else { #expect(b.value == a.value) }
    }
}

@Test func escapedPasswordAfterCharacterReferenceIsReplacedInNotes() throws {
    let data = try propertyFixture("xml-escaped-password-after-reference.xml")
    let result = try Scrubber.scrub(data, name: "input.xml", forceFullDetection: false, seed: 12316281535911190383)
    let root = try #require(XMLDocument(data: result.output, options: [.nodeLoadExternalEntitiesNever]).rootElement())
    let password = try #require(root.elements(forName: "password").first?.stringValue)
    #expect(!password.contains("Qz7nwsgydtlekmwf"))
    #expect(root.elements(forName: "note").first?.stringValue == "item \(password) complete")
}

@Test func nestedEmailKeepsOwnerNameSpelling() throws {
    let data = try propertyFixture("json-nested-email-name-shape.json")
    for seed: UInt64 in [86, 12316281535911190145] {
        let result = try Scrubber.scrub(data, name: "input.json", forceFullDetection: false, seed: seed)
        let object = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        let first = try #require(object["firstName"] as? String), last = try #require(object["lastName"] as? String)
        let contact = try #require(object["contact"] as? [String: String])
        if contact["email"]?.hasPrefix("\(first.lowercased()).\(last.lowercased())@") != true {
            Issue.record("Nested email differs: \(first) \(last), \(contact); seed=\(seed)")
            break
        }
    }
}
