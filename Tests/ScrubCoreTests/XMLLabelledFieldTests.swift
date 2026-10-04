import Foundation
@testable import ScrubCore
import Testing

/// A value named by an element beside it (<name>password</name><value>…</value>)
/// keeps that field's kind inside a record with text of its own
/// ("<record>Active<field>…</field></record>"), as it does with none.
@Suite struct XMLLabelledFieldTests {
    /// A sensitive field as a form labels it, and what its stand-in must look like.
    struct Field: Sendable {
        let label: String
        let original: String
        let fits: @Sendable (String) -> Bool
    }

    static func shape(_ value: String) -> String { String(value.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 }) }

    static let fields: [Field] = [
        Field(label: "password", original: "quillharbor", fits: { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }),
        Field(label: "national_id", original: "QX-55102938", fits: { shape($0) == shape("QX-55102938") }),
        Field(label: "ssn", original: "536-21-7784", fits: { $0.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) != nil }),
        Field(label: "email", original: "odalys.ferriter@corvane.test",
              fits: { $0.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil }),
        Field(label: "phone_number", original: "+1 (415) 867-2290", fits: { $0.filter(\.isNumber).count >= 10 && !$0.contains(where: \.isLetter) }),
        Field(label: "full_name", original: "Odalys Ferriter",
              fits: { $0.split(separator: " ").count == 2 && $0.allSatisfy { $0.isLetter || " '-".contains($0) } }),
        Field(label: "date_of_birth", original: "1984-03-17", fits: { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }),
    ]

    /// Where the field sits: built from the label element and the value
    /// element, already written.
    static let placements: [@Sendable (String, String) -> String] = [
        // No text of the record's own: the shape every other placement must match.
        { label, value in "<record><field>\(label)\(value)</field></record>" },
        { label, value in "<record>Active<field>\(label)\(value)</field></record>" },
        { label, value in "<record><field>\(value)\(label)</field> on file since 2019</record>" },
        { label, value in "<record>Active <field>\(label)\(value)</field> until review</record>" },
        { label, value in "<record>Active <b>now</b> \(label) set to \(value) until review</record>" },
        { label, value in "<record>Status <group><entry><field>\(label)\(value)</field></entry></group> checked</record>" },
        { label, value in "<record>Status <span>primary <section><field>\(value)\(label)</field></section></span> checked</record>" },
    ]

    static let labels = ["name", "key", "label", "field"]
    static let values = ["value", "answer", "data"]

    static func scrub(_ xml: String, seed: UInt64) throws -> (output: String, result: ScrubResult) {
        let result = try Scrubber.scrub(Data("<records>\(xml)</records>".utf8), name: "records.xml", forceFullDetection: false, seed: seed)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(XMLParser(data: result.output).parse(), "\(output)")
        return (output, result)
    }

    /// The text of the first element called `name`, as the output holds it.
    static func element(_ name: String, in output: Data) throws -> String? {
        try XMLDocument(data: output, options: []).nodes(forXPath: "//*[local-name()='\(name)']").first?.stringValue
    }

    /// Each kind, under each label element and value element, in every
    /// placement, plain and as CDATA: the original is gone, nothing asks for
    /// review, and the value element holds a stand-in of its kind.
    @Test(arguments: 0..<2)
    func aValueNamedByItsSiblingKeepsItsKind(_ cdata: Int) throws {
        for (fieldIndex, field) in Self.fields.enumerated() {
            for (placeIndex, place) in Self.placements.enumerated() {
                let labelName = Self.labels[(fieldIndex + placeIndex) % Self.labels.count]
                // "field" as the label would share its name with the wrapping element.
                let label = labelName == "field" && place("", "").contains("<field>") ? "key" : labelName
                let valueName = Self.values[(fieldIndex + placeIndex) % Self.values.count]
                func wrap(_ text: String) -> String { cdata == 1 ? "<![CDATA[\(text)]]>" : text.replacingOccurrences(of: "&", with: "&amp;") }
                let xml = place("<\(label)>\(wrap(field.label))</\(label)>", "<\(valueName)>\(wrap(field.original))</\(valueName)>")
                let (output, result) = try Self.scrub(xml, seed: UInt64(fieldIndex * 10 + placeIndex))
                let read = try XMLDocument(data: result.output, options: []).rootElement()?.stringValue ?? ""
                #expect(!output.contains(field.original) && !read.contains(field.original), "\(field.label) left as written: \(output)")
                if field.label == "full_name" {
                    for part in ["odalys", "ferriter"] { #expect(!read.lowercased().contains(part), "\(part) left in \(output)") }
                }
                #expect(!result.uncertain.contains { $0.original == field.original }, "\(field.label) asked for review: \(output)")
                // Type oracle: the value element holds a stand-in of the labelled kind.
                let standIn = try #require(try Self.element(valueName, in: result.output), "\(valueName) missing: \(output)")
                #expect(standIn != field.original && field.fits(standIn), "\(field.label) in \(xml): \(standIn)")
                // The label and the record's own words stay.
                #expect(read.contains(field.label), "\(output)")
                for word in ["Active", "on file since 2019", "until review", "checked"] where xml.contains(word) { #expect(output.contains(word), "\(output)") }
            }
        }
    }

    /// The reported shape, and the same with a national ID.
    @Test(arguments: [
        ("<record>Active<field><name>password</name><value>quillharbor</value></field></record>", "quillharbor"),
        ("<record>Active<field><name>national_id</name><value>QX-55102938</value></field></record>", "QX-55102938"),
    ])
    func theReportedRecordIsReplaced(_ xml: String, _ original: String) throws {
        let (output, result) = try Self.scrub(xml, seed: 1)
        #expect(!output.contains(original), "\(output)")
        #expect(output.contains("Active"), "\(output)")
        #expect(result.counts.values.reduce(0, +) > 0, "\(output)")
    }

    /// A label that names no personal field leaves its value as written,
    /// wherever it sits.
    @Test(arguments: [("status", "pending"), ("plan", "Everyday Checking"), ("color", "teal"), ("priority", "high")])
    func aValueLabelledAsNoPersonalFieldStays(_ label: String, _ value: String) throws {
        for (index, place) in Self.placements.enumerated() {
            let xml = place("<name>\(label)</name>", "<value>\(value)</value>")
            let (output, _) = try Self.scrub(xml, seed: UInt64(index))
            #expect(output.contains("<value>\(value)</value>"), "\(output)")
            #expect(output.contains("<name>\(label)</name>"), "\(output)")
        }
    }

    /// Free text beside a labelled field is still read for what it holds:
    /// a person and their details in it are replaced, a plain label's value stays.
    @Test(arguments: [
        "<record>Spoke with Odalys Ferriter at odalys.ferriter@corvane.test <field><name>status</name><value>pending</value></field> today</record>",
        "<record>Called Odalys Ferriter on +1 (415) 867-2290 <field><key>password</key><value>quillharbor</value></field> after the reset</record>",
        "<record><field><value>pending</value><label>status</label></field> per Odalys Ferriter, odalys.ferriter@corvane.test</record>",
    ])
    func freeTextBesideALabelledFieldIsStillRead(_ xml: String) throws {
        let (output, _) = try Self.scrub(xml, seed: 9)
        let read = try XMLDocument(data: Data(output.utf8), options: []).rootElement()?.stringValue?.lowercased() ?? ""
        for gone in ["odalys", "ferriter", "corvane.test", "867-2290", "quillharbor"] { #expect(!read.contains(gone), "\(gone) left in \(output)") }
        if xml.contains("pending") { #expect(output.contains("<value>pending</value>"), "\(output)") }
        for word in ["Spoke with", "Called", "today", "after the reset", "per "] where xml.contains(word) { #expect(output.contains(word), "\(output)") }
    }

    @Test func aLabelledValueIsAFieldAndAPlainOneIsNot() throws {
        func element(_ xml: String) throws -> XMLElement { try #require(try XMLDocument(xmlString: xml, options: []).rootElement()) }
        #expect(XMLFile.inline(try element("<record>Active<field><name>password</name><value>quillharbor</value></field></record>")) == nil)
        #expect(XMLFile.inline(try element("<record>Active<field><value>QX-1</value><key>national_id</key></field></record>")) == nil)
        #expect(XMLFile.inline(try element("<record>Active <label>ssn</label> is <data>536-21-7784</data></record>")) == nil)
        #expect(XMLFile.inline(try element("<record>Active<a><b><field><name>email</name><answer>x</answer></field></b></a></record>")) == nil)
        // A label naming no personal field, or a value with no label, is read with the text.
        #expect(XMLFile.inline(try element("<record>Active<field><name>status</name><value>pending</value></field></record>")) != nil)
        #expect(XMLFile.inline(try element("<record>Active<field><value>pending</value></field></record>")) != nil)
    }
}
