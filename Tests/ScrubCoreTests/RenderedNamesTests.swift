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

    // MARK: Numbers in names

    /// A key's or a tag's own number, written again in the text around it,
    /// before the name or after it, in each place a file can name a node.
    static let numbered: [(ext: String, text: String, name: String)] = [
        ("json", #"{"order_48213907":{"customer":"Odalys Ferriter","note":"Archived under 48213907"}}"#, "order_"),
        ("json", #"{"note":"Archived under 48213907","order_48213907":{"customer":"Odalys Ferriter"}}"#, "order_"),
        ("xml", "<orders><order_48213907><customer>Odalys Ferriter</customer><note>Archived under 48213907</note></order_48213907></orders>", "<order_"),
        ("xml", #"<orders><note>Archived under 48213907</note><order ref_48213907="open"><customer>Odalys Ferriter</customer></order></orders>"#, " ref_"),
    ]

    static func parses(_ result: ScrubResult, _ ext: String) -> Bool {
        ext == "xml" ? XMLParser(data: result.output).parse() : (try? JSONSerialization.jsonObject(with: result.output)) != nil
    }

    @Test func aNumberInANameIsReplacedWhereverTheFileWritesIt() throws {
        for (ext, text, name) in Self.numbered {
            let result = try Self.scrub(text, ext)
            let output = Self.output(result)
            #expect(!output.contains("48213907"), "\(ext): \(output)")
            let number = try #require(result.findings.first { $0.original == "48213907" }, "\(ext): \(result.findings.map(\.original)) \(output)")
            // One stand-in, in the name and in the text.
            #expect(output.contains(name + number.standIn), "\(ext): \(output)")
            #expect(output.contains("Archived under \(number.standIn)"), "\(ext): \(output)")
            #expect(Self.parses(result, ext))
            // Typed back for another value, it is refused; a fresh one is not.
            let customer = try #require(result.findings.first { $0.original == "Odalys Ferriter" })
            #expect(result.refusal("48213907", for: [customer]) != nil, "\(ext)")
            #expect(result.refusal("Order 48213907", for: [customer]) != nil, "\(ext)")
            #expect(result.refusal("Jane Roe", for: [customer]) == nil, "\(ext)")
            // Clicked where the name holds it, it is the number's finding.
            guard case .text(let preview, let marks, _) = result.preview else { Issue.record("\(ext): no text preview"); continue }
            let at = (preview as NSString).range(of: name + number.standIn)
            let click = at.location + (name as NSString).length + 1
            #expect(result.pick(in: preview, marks: marks, range: click..<click).replaced.map(\.id) == [number.id], "\(ext)")
            // Kept as written, it is the original everywhere again; edited, the edit everywhere.
            let kept = try result.applying(Choices(left: [number.id]))
            #expect(Self.output(kept).contains(name + "48213907") && Self.output(kept).contains("Archived under 48213907"), "\(ext): \(Self.output(kept))")
            let edited = try Self.edit(result, number, replacement: "55501234")
            #expect(Self.output(edited).contains(name + "55501234") && Self.output(edited).contains("Archived under 55501234"), "\(ext): \(Self.output(edited))")
            #expect(Self.parses(edited, ext))
            // The same scrub, the same bytes.
            #expect(try Self.scrub(text, ext).output == result.output)
        }
    }

    @Test func aNumberInACSVHeaderIsReplacedWhereverTheFileWritesIt() throws {
        for text in ["order_48213907,customer,note\n1,Odalys Ferriter,Archived under 48213907\n",
                     "customer,note,ref 48213907\nOdalys Ferriter,Archived under 48213907,open\n"] {
            let result = try Self.scrub(text, "csv")
            let output = Self.output(result)
            #expect(!output.contains("48213907"), "\(output)")
            let number = try #require(result.findings.first { $0.original == "48213907" }, "\(result.findings.map(\.original)) \(output)")
            #expect(output.components(separatedBy: number.standIn).count == 3, "\(output)")
            let customer = try #require(result.findings.first { $0.original == "Odalys Ferriter" })
            #expect(result.refusal("48213907", for: [customer]) != nil)
            #expect(result.refusal("Jane Roe", for: [customer]) == nil)
            let kept = try result.applying(Choices(left: [number.id]))
            #expect(Self.output(kept).components(separatedBy: "48213907").count == 3, "\(Self.output(kept))")
            let edited = try Self.edit(result, number, replacement: "55501234")
            #expect(Self.output(edited).components(separatedBy: "55501234").count == 3, "\(Self.output(edited))")
            #expect(try Self.scrub(text, "csv").output == result.output)
        }
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

    @Test func anEditedNameWrittenIntoAnElementNameIsStillItsFindingWhenClicked() throws {
        let result = try Self.scrub(Self.tagged, "xml")
        let name = try #require(result.findings.first { $0.original == "Odalys" })
        for typed in ["Jane Roe", "Jane"] {
            let edited = try Self.edit(result, name, replacement: typed)
            let squeezed = typed.replacingOccurrences(of: " ", with: "")
            #expect(Self.output(edited).contains("<\(squeezed)>hello</\(squeezed)>"), "\(Self.output(edited))")
            guard case .text(let preview, let marks, _) = edited.preview else { Issue.record("no text preview"); continue }
            // On the element's name, and in the field's text, the same finding.
            for place in [(preview as NSString).range(of: "<" + squeezed + ">").location + 2, (preview as NSString).range(of: ">" + typed + "<").location + 2] {
                let picked = edited.pick(in: preview, marks: marks, range: place..<place)
                #expect(picked.replaced.map(\.id) == [name.id], "\(typed) at \(place): \(picked)")
            }
        }
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
