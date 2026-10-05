import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// A value that stands as a JSON key or an XML element or attribute name is
/// written there as the review reports it: its stand-in as made, the
/// replacement typed for it, a new kind's stand-in, or its original where a
/// person keeps it. The output follows the final edits and choices alone,
/// never the order earlier edits were made in.
@Suite struct RenderedNamesTests {
    typealias Finding = ScrubCore::Finding

    static func output(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

    static func scrub(_ text: String, _ ext: String, seed: UInt64 = 9) throws -> ScrubResult {
        try Scrubber.scrub(Data(text.utf8), name: "record." + ext, forceFullDetection: false, seed: seed)
    }

    static func edit(_ result: ScrubResult, _ finding: Finding, kind: String? = nil, replacement: String? = nil) throws -> ScrubResult {
        let target = result.current.first { $0.id == finding.id } ?? finding
        let (choices, marks, edits) = try result.editing([target], kind: kind, replacement: replacement, choices: result.choices, marks: result.marks, edits: result.edits)
        return try result.applying(choices, marks: marks, edits: edits)
    }

    static func keys(_ result: ScrubResult) throws -> [String] {
        let object = try #require(try JSONSerialization.jsonObject(with: result.output) as? [String: Any], "\(output(result))")
        return object.keys.sorted()
    }

    // MARK: JSON keys

    @Test func aTypedReplacementForAKeyIsWrittenAsTyped() throws {
        let result = try Self.scrub(#"{"odalys.ferriter@kestrel.example":"ok"}"#, "json")
        let email = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" }, "\(Self.output(result))")
        // As made, the key holds the stand-in the review reports.
        #expect(try Self.keys(result) == [email.standIn])
        let typed = "ticket7654321@corvane.test"
        let edited = try Self.edit(result, email, replacement: typed)
        #expect(try Self.keys(edited) == [typed], "\(Self.output(edited))")
        #expect(edited.revised(email).standIn == typed)
        #expect(edited.current.contains { $0.standIn == typed })
    }

    @Test func aKeyIsWrittenFromTheFinalEditsWhateverCameBefore() throws {
        let text = #"{"odalys.ferriter@kestrel.example":"ok"}"#
        let result = try Self.scrub(text, "json")
        let email = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" })
        let direct = try Self.edit(result, email, replacement: "Ticket7654321")
        #expect(try Self.keys(direct) == ["Ticket7654321"], "\(Self.output(direct))")
        // On an identical scrub, another replacement typed first leaves no trace.
        let again = try Self.scrub(text, "json")
        let first = try Self.edit(again, email, replacement: "Ticket1234567")
        #expect(try Self.keys(first) == ["Ticket1234567"], "\(Self.output(first))")
        let second = try Self.edit(first, email, replacement: "Ticket7654321")
        #expect(second.output == direct.output, "\(Self.output(second)) vs \(Self.output(direct))")
        // Undone, the scrub is as made; redone, the same bytes again.
        let undone = try second.applying(again.choices, marks: Marks(), edits: Edits())
        #expect(undone.output == again.output)
        #expect(try undone.applying(direct.choices, marks: direct.marks, edits: direct.edits).output == direct.output)
        // The same scrub writes the same key, however often it is written.
        #expect(try result.applying(result.choices).output == result.output)
    }

    @Test func aKeyWithLongDigitsAndNoFindingKeepsItsStandIn() throws {
        let text = #"{"order_48213907":{"customer":"Odalys Ferriter","email":"odalys.ferriter@kestrel.example"}}"#
        let result = try Self.scrub(text, "json")
        let key = try #require(try Self.keys(result).first)
        #expect(key.hasPrefix("order_") && key != "order_48213907" && key.filter(\.isNumber).count == 8, "\(key)")
        let customer = try #require(result.findings.first { $0.original == "Odalys Ferriter" })
        let edited = try Self.edit(result, customer, replacement: "Jane Roe")
        #expect(try Self.keys(edited) == [key], "\(Self.output(edited))")
        #expect(try Self.scrub(text, "json").output == result.output)
    }

    @Test func aNameEditedElsewhereIsWrittenInAKey() throws {
        let text = #"{"Odalys":"hello","first_name":"Odalys"}"#
        let result = try Self.scrub(text, "json")
        let name = try #require(result.findings.first { $0.original == "Odalys" }, "\(Self.output(result))")
        #expect(try Self.keys(result) == ["first_name", name.standIn].sorted())
        let edited = try Self.edit(result, name, replacement: "Jane")
        #expect(try Self.keys(edited) == ["Jane", "first_name"], "\(Self.output(edited))")
        let object = try #require(try JSONSerialization.jsonObject(with: edited.output) as? [String: Any])
        #expect(object["first_name"] as? String == "Jane")
        // Kept as written, the key is the original again.
        let kept = try edited.applying(Choices(left: [name.id]), marks: edited.marks, edits: edited.edits)
        #expect(try Self.keys(kept) == ["Odalys", "first_name"], "\(Self.output(kept))")
    }

    // MARK: XML names

    static let tagged = "<root><Odalys>hello</Odalys><first_name>Odalys</first_name></root>"

    @Test func aTypedNameIsWrittenInAnElementName() throws {
        let result = try Self.scrub(Self.tagged, "xml")
        let name = try #require(result.findings.first { $0.original == "Odalys" }, "\(Self.output(result))")
        #expect(Self.output(result).contains("<\(name.standIn)>hello</\(name.standIn)>"), "\(Self.output(result))")
        let edited = try Self.edit(result, name, replacement: "Jane")
        #expect(Self.output(edited) == "<root><Jane>hello</Jane><first_name>Jane</first_name></root>", "\(Self.output(edited))")
        #expect(edited.revised(name).standIn == "Jane")
        #expect(XMLParser(data: edited.output).parse())
        // Undone and redone, byte for byte.
        let undone = try edited.applying(result.choices, marks: Marks(), edits: Edits())
        #expect(undone.output == result.output, "\(Self.output(undone))")
        #expect(try undone.applying(edited.choices, marks: edited.marks, edits: edited.edits).output == edited.output)
    }

    @Test func keptAsWrittenAnElementNameIsItsOwnAgain() throws {
        let result = try Self.scrub(Self.tagged, "xml")
        let name = try #require(result.findings.first { $0.original == "Odalys" })
        let kept = try result.applying(Choices(left: [name.id]))
        #expect(Self.output(kept) == Self.tagged, "\(Self.output(kept))")
        let edited = try Self.edit(result, name, replacement: "Jane")
        let keptAfter = try edited.applying(Choices(left: [name.id]), marks: edited.marks, edits: edited.edits)
        #expect(Self.output(keptAfter) == Self.tagged, "\(Self.output(keptAfter))")
        #expect(try keptAfter.applying(result.choices, marks: Marks(), edits: Edits()).output == result.output)
    }

    @Test func aNewKindIsWrittenInAnElementName() throws {
        let result = try Self.scrub(Self.tagged, "xml")
        let name = try #require(result.findings.first { $0.original == "Odalys" })
        let edited = try Self.edit(result, name, kind: "LOCATION")
        let revised = edited.revised(name)
        #expect(revised.entity == "LOCATION" && revised.standIn != name.standIn)
        let document = try XMLDocument(data: edited.output, options: [])
        let first: XMLNode? = document.rootElement()?.children?.first
        let tag = try #require(first?.name)
        // The element is named after the new stand-in, made a valid XML name.
        let valid = String(revised.standIn.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        #expect(tag == valid, "\(Self.output(edited))")
        #expect(document.rootElement()?.elements(forName: "first_name").first?.stringValue == revised.standIn)
    }

    @Test func aTypedNameIsMadeAValidNameThatNoOtherTagHolds() throws {
        let text = "<root><Odalys>hello</Odalys><Report>bye</Report><first_name>Odalys</first_name></root>"
        let result = try Self.scrub(text, "xml")
        let name = try #require(result.findings.first { $0.original == "Odalys" }, "\(Self.output(result))")
        func tags(_ result: ScrubResult) throws -> [String] {
            try XMLDocument(data: result.output, options: []).rootElement()?.children?.compactMap { $0.name } ?? []
        }
        // A space is no part of an XML name.
        let spaced = try Self.edit(result, name, replacement: "Jane Roe")
        #expect(try tags(spaced) == ["JaneRoe", "Report", "first_name"], "\(Self.output(spaced))")
        // A tag the replacement would meet is told apart from it.
        let met = try Self.edit(result, name, replacement: "Report")
        #expect(try tags(met) == ["Report2", "Report", "first_name"], "\(Self.output(met))")
        #expect(XMLParser(data: met.output).parse())
        // Written from the final edits alone: the same bytes whichever was typed first.
        let other = try Self.edit(met, name, replacement: "Jane Roe")
        #expect(other.output == spaced.output, "\(Self.output(other))")
    }

    @Test func anAttributeNameFollowsAnEdit() throws {
        let text = #"<root><person Odalys="yes"><first_name>Odalys</first_name></person></root>"#
        let result = try Self.scrub(text, "xml")
        let name = try #require(result.findings.first { $0.original == "Odalys" }, "\(Self.output(result))")
        let edited = try Self.edit(result, name, replacement: "Jane")
        #expect(Self.output(edited).contains(#"Jane="yes""#), "\(Self.output(edited))")
        let kept = try edited.applying(Choices(left: [name.id]), marks: edited.marks, edits: edited.edits)
        #expect(Self.output(kept) == text, "\(Self.output(kept))")
    }
}
