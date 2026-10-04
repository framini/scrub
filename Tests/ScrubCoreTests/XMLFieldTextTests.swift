import Foundation
@testable import ScrubCore
import Testing

/// An XML record with text of its own beside its fields ("<account>Active
/// <password>…</password></account>") reads each field under its own name,
/// wherever the text sits; text split by formatting is still read as one.
@Suite struct XMLFieldTextTests {
    /// A sensitive field, and what its stand-in must look like.
    struct Field: Sendable {
        let names: [String]
        let original: String
        let fits: @Sendable (String) -> Bool
    }

    static func shape(_ value: String) -> String { String(value.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 }) }

    static let fields: [Field] = [
        Field(names: ["password", "Password", "user_password", "loginPassword"], original: "Tamsel!Brook-2291",
              fits: { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }),
        Field(names: ["national_id", "nationalId", "NationalID", "national-id"], original: "QX-55102938",
              fits: { shape($0) == shape("QX-55102938") }),
        Field(names: ["email", "emailAddress", "contact_email", "EMAIL"], original: "odalys.ferriter@corvane.test",
              fits: { $0.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil }),
        Field(names: ["phone", "phone_number", "mobilePhone", "Telephone"], original: "+1 (415) 867-2290",
              fits: { $0.filter(\.isNumber).count >= 10 && !$0.contains(where: \.isLetter) }),
        Field(names: ["ssn", "SSN", "social_security_number", "socialSecurityNumber"], original: "536-21-7784",
              fits: { $0.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) != nil }),
    ]

    /// The text of the first element called `name`, as the output holds it.
    static func element(_ name: String, in output: Data) throws -> String? {
        let document = try XMLDocument(data: output, options: [])
        return try document.nodes(forXPath: "//*[local-name()='\(name)']").first?.stringValue
    }

    /// Every field, under each of its names, with the record's own text
    /// before, between and after the fields.
    @Test(arguments: 0..<4)
    func aFieldBesideTheRecordsOwnTextKeepsItsName(_ style: Int) throws {
        let placements: [(String, String) -> String] = [
            { fields, _ in "<account>Active \(fields)</account>" },
            { fields, _ in "<account>\(fields) since 2019</account>" },
            { fields, separator in "<account>Active\(separator)\(fields)\(separator)until further notice</account>" },
            { fields, _ in "<account>Status: <b>Active</b> \(fields) reviewed.</account>" },
        ]
        for (index, place) in placements.enumerated() {
            let elements = Self.fields.map { field in
                let name = field.names[style]
                return "<\(name)>\(field.original.replacingOccurrences(of: "&", with: "&amp;"))</\(name)>"
            }
            let input = "<accounts>" + place(elements.joined(separator: " and "), " ") + "</accounts>"
            let result = try Scrubber.scrub(Data(input.utf8), name: "accounts.xml", forceFullDetection: false, seed: UInt64(style * 10 + index))
            let output = String(decoding: result.output, as: UTF8.self)
            #expect(XMLParser(data: result.output).parse(), "\(output)")
            for field in Self.fields {
                let name = field.names[style]
                #expect(!output.contains(field.original), "\(name) left as written: \(output)")
                let standIn = try #require(try Self.element(name, in: result.output), "\(name) missing: \(output)")
                // Type oracle: the stand-in reads as the kind it replaces.
                #expect(standIn != field.original && field.fits(standIn), "\(name): \(standIn)")
            }
            // The record's own text is no field and stays.
            #expect(output.contains(index == 1 ? "since 2019" : "Active"), "\(output)")
        }
    }

    /// The same fields with no text beside them come out the same kinds.
    @Test func theSameFieldsAloneAreReplacedAsBefore() throws {
        let elements = Self.fields.map { "<\($0.names[0])>\($0.original)</\($0.names[0])>" }.joined()
        let result = try Scrubber.scrub(Data("<accounts><account>\(elements)</account></accounts>".utf8), name: "accounts.xml", forceFullDetection: false, seed: 3)
        for field in Self.fields {
            let standIn = try #require(try Self.element(field.names[0], in: result.output))
            #expect(standIn != field.original && field.fits(standIn), "\(field.names[0]): \(standIn)")
        }
    }

    /// A field named by an attribute (<field name="ssn">) is a field too.
    @Test func aFieldNamedByItsAttributeKeepsItsName() throws {
        let input = #"<form><entry>Submitted <field name="ssn">536-21-7784</field> and <field name="password">Tamsel!Brook-2291</field></entry></form>"#
        let result = try Scrubber.scrub(Data(input.utf8), name: "form.xml", forceFullDetection: false, seed: 4)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(!output.contains("536-21-7784") && !output.contains("Tamsel!Brook-2291"), "\(output)")
        #expect(output.range(of: #"<field name="ssn">\d{3}-\d{2}-\d{4}</field>"#, options: .regularExpression) != nil, "\(output)")
        #expect(XMLParser(data: result.output).parse())
    }

    /// Formatting inside a word is still read through: the name it splits is
    /// found as one, and replaced in pieces that keep the markup valid.
    @Test(arguments: [
        ("<note>Spoke with Odalys <b>Ferriter</b> about the refund.</note>", ["ferriter", "odalys"]),
        ("<note>Ask Bram Quill<em>mere</em> to sign the lease.</note>", ["quillmere", "quill"]),
        ("<note>Per <i>Odal</i>ys Ferriter, the parcel is late.</note>", ["odalys", "ferriter"]),
    ])
    func aNameSplitByFormattingIsStillReadAsOne(_ note: String, _ gone: [String]) throws {
        let input = "<customers><customer><name>Odalys Ferriter</name><contact>Bram Quillmere</contact>\(note)</customer></customers>"
        let result = try Scrubber.scrub(Data(input.utf8), name: "customers.xml", forceFullDetection: false, seed: 8)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(XMLParser(data: result.output).parse(), "\(output)")
        // Read as the document reads, its markup gone, no form of the name is left.
        let read = try XMLDocument(data: result.output, options: []).rootElement()?.stringValue?.lowercased() ?? ""
        for name in gone { #expect(!read.contains(name), "\(name) left in \(output)") }
        let standIn = try #require(try Self.element("name", in: result.output))
        #expect(standIn.split(separator: " ").count == 2 && standIn.allSatisfy { $0.isLetter || " '-".contains($0) }, "\(standIn)")
    }

    @Test func formattingAndPlainElementsJoinAndFieldsDoNot() throws {
        func element(_ xml: String) throws -> XMLElement { try #require(try XMLDocument(xmlString: xml, options: []).rootElement()) }
        #expect(XMLFile.inline(try element("<note>Odal<b>ys</b> wrote</note>")) != nil)
        #expect(XMLFile.inline(try element("<note>Odal<flag>ys</flag> wrote</note>")) != nil)
        #expect(XMLFile.inline(try element("<account>Active<password>x</password></account>")) == nil)
        #expect(XMLFile.inline(try element("<account>Active<span><nationalId>QX-1</nationalId></span></account>")) == nil)
        #expect(XMLFile.inline(try element(#"<entry>Sent <field name="email">a@corvane.test</field></entry>"#)) == nil)
    }
}
