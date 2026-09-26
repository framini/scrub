import Foundation
@testable import ScrubCore
import Testing

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil)))
}

private func scrubFixture(_ name: String) throws -> ScrubResult {
    try Scrubber.scrub(fixture(name), name: name)
}

private func output(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

@Test func xmlSiblingCommentsAndInstructions() throws {
    let text = try output(scrubFixture("xml-sibling-comment-and-pi.xml"))
    #expect(!text.contains("alice@example.com"))
}

@Test func csvCRLFRows() throws {
    let result = try scrubFixture("csv-crlf.csv")
    let text = output(result)
    #expect(!text.contains("hunter2"))
    #expect(text.contains("\r\n"))
    if case .table(_, let rows, let count, _) = result.preview {
        #expect(count == 1)
        #expect(rows.count == 1)
    } else { Issue.record("Expected table preview") }
}

@Test func csvDelimiterIgnoresQuotedCells() throws {
    let result = try scrubFixture("csv-quoted-semicolons.csv")
    let text = output(result)
    #expect(!text.contains("hunter2"))
    #expect(!text.contains("swordfish"))
    if case .table(let columns, let rows, _, _) = result.preview {
        #expect(columns == ["password", "note"])
        #expect(rows.map { $0[1] } == ["a;b;c;d", "e;f;g;h"])
    } else { Issue.record("Expected table preview") }
}

@Test func xmlHiddenDoctypeIsRefused() throws {
    #expect(throws: ScrubError.unsupported("xml_doctype")) { try Scrubber.scrub(fixture("xml-encoding-hides-doctype.xml"), name: "xml-encoding-hides-doctype.xml") }
}

@Test func xmlOrdinaryEncodingAttributeSurvives() throws {
    #expect(try output(scrubFixture("xml-encoding-attribute.xml")).contains("encoding=\"base64\""))
}

@Test func xmlDeclarationKeepsVersionAndStandalone() throws {
    let text = #"<?xml version="1.1" standalone="yes"?><r/>"#
    let result = try Scrubber.scrub(Data(text.utf8), name: "r.xml")
    #expect(output(result).hasPrefix(#"<?xml version="1.1" standalone="yes"?>"#))
}

@Test func latePasswordObservationScrubsEarlierNote() throws {
    let text = try output(scrubFixture("json-password-after-note.json"))
    #expect(!text.contains("hunter2"))
}

@Test func freeTextPersonDoesNotBorrowRecordPersona() throws {
    let text = try output(scrubFixture("json-other-person-in-note.json"))
    let value = try OrderedJSON.parse(text)
    guard case .object(let pairs) = value,
          case .string(let owner)? = pairs.first(where: { $0.0 == "name" })?.1,
          case .string(let note)? = pairs.first(where: { $0.0 == "note" })?.1 else {
        Issue.record("Expected JSON object")
        return
    }
    #expect(!note.contains("Ana Pereira"))
    #expect(note.contains("called."))
    #expect(!note.contains(owner))
    let repeated = #"{"name":"Robert Mitchell","note":"Robert Mitchell called Ana Pereira."}"#
    let repeatedText = output(try Scrubber.scrub(Data(repeated.utf8), name: "people.json"))
    let repeatedValue = try OrderedJSON.parse(repeatedText)
    guard case .object(let repeatedPairs) = repeatedValue,
          case .string(let repeatedOwner)? = repeatedPairs.first(where: { $0.0 == "name" })?.1,
          case .string(let repeatedNote)? = repeatedPairs.first(where: { $0.0 == "note" })?.1 else {
        Issue.record("Expected repeated JSON object")
        return
    }
    #expect(repeatedNote.contains(repeatedOwner))
}

@Test func untouchedJSONNumbersKeepLexemes() throws {
    let text = try output(scrubFixture("json-precise-numbers.json"))
    #expect(text.contains("9007199254740993.0"))
    #expect(text.contains("1e-400"))
}

@Test func xmlGeneratedNamesAlwaysParse() throws {
    let input = Data("<r><name>Robert Mitchell</name><RobertMitchell/></r>".utf8)
    for _ in 0..<200 {
        let result = try Scrubber.scrub(input, name: "r.xml")
        #expect(try XMLFile.parses(result.output))
        #expect(!output(result).contains("RobertMitchell"))
    }
}

@Test func ambiguousWordsAndUppercaseName() throws {
    let source = try fixture("text-ambiguous-names.txt")
    let result = try Scrubber.scrub(source, name: "text-ambiguous-names.txt")
    let text = output(result)
    #expect(text.contains("Please tell mark to remain unchanged."))
    #expect(text.contains("Remove the mark from this page."))
    #expect(!text.contains("ROBERT"))
    let informal = try Scrubber.scrub(Data("hey its liam, can u send the invoice".utf8), name: "note.txt")
    #expect(!output(informal).contains("liam"))
}

@Test func xmlAttributeRecordSharesPersona() throws {
    let text = try output(scrubFixture("xml-attribute-persona.xml"))
    guard let document = try? XMLDocument(data: Data(text.utf8)), let element = document.rootElement() else {
        Issue.record("Expected XML")
        return
    }
    let first = try #require(element.attribute(forName: "firstName")?.stringValue)
    let last = try #require(element.attribute(forName: "lastName")?.stringValue)
    let email = try #require(element.attribute(forName: "email")?.stringValue)
    #expect(email.hasPrefix("\(first.lowercased()).\(last.lowercased())@example."))
}

@Test func csvPreviewIncludesExtraColumn() throws {
    let result = try scrubFixture("csv-row-wider-than-header.csv")
    if case .table(let columns, let rows, _, _) = result.preview {
        #expect(columns.count == 2)
        #expect(columns[1] == "")
        #expect(rows[0].count == 2)
    } else { Issue.record("Expected table preview") }
}

@Test(arguments: ["Ana Pereira called.", "{\"note\":\"Ana Pereira called.\"}"])
func verbAfterCapitalisedNameSurvives(_ input: String) throws {
    for _ in 0..<20 {
        let result = try Scrubber.scrub(Data(input.utf8), name: input.hasPrefix("{") ? "a.json" : "a.txt")
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(output.contains(" called.") && !output.contains("Ana") && !output.contains("Pereira"), "\(output)")
    }
}

@Test func particleInsideNameIsKept() throws {
    let result = try Scrubber.scrub(Data("Maria de la Cruz wrote back.".utf8), name: "a.txt")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(!output.contains("Cruz") && !output.contains(" de la ") && output.hasSuffix(" wrote back."), "\(output)")
}
