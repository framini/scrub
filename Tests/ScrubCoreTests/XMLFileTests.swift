import Foundation
import ScrubCore
import Testing

@Test(arguments: [
    #"<?xml version="1.0"?><!DOCTYPE r [<!ENTITY who "Robert Mitchell">]><r>&who;</r>"#,
    #"<?xml version="1.0"?><!DOCTYPE r [<!ATTLIST r owner CDATA "alice@example.com">]><r/>"#,
    #"<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>"#,
    #"<?xml version="1.0"?><!DOCTYPE r SYSTEM "https://example.invalid/a.dtd"><r/>"#,
    #"<!DOCTYPE r [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]><r>&b;</r>"#
])
func xmlRefusesEntitiesBeforeParsing(_ input: String) {
    #expect(throws: ScrubError.unsupported("xml_doctype")) {
        try Scrubber.scrub(Data(input.utf8), name: "a.xml")
    }
}

@Test func xmlRefusesUTF16DoctypeBeforeParsing() {
    let text = #"<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>"#
    var data = Data([0xFF, 0xFE])
    for unit in text.utf16 { data.append(UInt8(truncatingIfNeeded: unit)); data.append(UInt8(truncatingIfNeeded: unit >> 8)) }
    #expect(throws: ScrubError.unsupported("xml_doctype")) { try Scrubber.scrub(data, name: "a.xml") }
}

@Test func xmlCommentMentionOfDoctypeIsPlainText() throws {
    let input = #"<r><!-- remove <!DOCTYPE before sharing -->ok</r>"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.xml")
    #expect(String(decoding: result.output, as: UTF8.self).contains("DOCTYPE"))
}

@Test func xmlScrubsTextAndAttributes() throws {
    let result = try Scrubber.scrub(Data(#"<?xml version="1.0"?><r owner="alice@example.com"><name>Robert Mitchell</name></r>"#.utf8), name: "a.xml")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(output.contains(#"<?xml version="1.0"?>"#))
    #expect(!output.contains("alice@example.com"))
    #expect(!output.contains("Robert Mitchell"))
}

@Test func invalidXMLIsRejected() {
    #expect(throws: ScrubError.unsupported("invalid_xml")) {
        try Scrubber.scrub(Data("<r><name>Robert</r>".utf8), name: "a.xml")
    }
}

@Test func xmlScrubsCommentsCDATAAndProcessingInstructions() throws {
    let input = #"<?xml version="1.0"?><r><!-- owner: Robert Mitchell --><note><![CDATA[Robert Mitchell asked]]></note><?audit owner=alice@example.com?></r>"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.xml")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(!output.contains("Robert Mitchell"))
    #expect(!output.contains("alice@example.com"))
    #expect(output.contains("<![CDATA["))
    #expect(output.contains("<?audit"))
}

@Test func xmlNamesAndNamespacesAreScrubbed() throws {
    let input = #"<r xmlns:p="urn:owner:alice@example.com"><customer_2128675309 owner_123456789="active"><p:v>ok</p:v></customer_2128675309></r>"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.xml")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(!output.contains("alice@example.com"))
    #expect(!output.contains("2128675309"))
    #expect(!output.contains("123456789"))
}

@Test func xmlFixturePreservesShapeAndPersona() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "customer", withExtension: "xml")))
    let result = try Scrubber.scrub(data, name: "customer.xml")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(output.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"#))
    #expect(output.contains(#"xmlns:crm="urn:example:crm""#))
    #expect(output.contains(#"currency="USD""#))
    #expect(output.contains("<![CDATA["))
    #expect(output.contains("<crm:LastInvoiceTotal>1840.50</crm:LastInvoiceTotal>"))
    for original in ["Francisco", "Ramini", "framini", "1450 Mission Street"] { #expect(!output.localizedCaseInsensitiveContains(original)) }
}

@Test func xmlKnownPersonInElementNames() throws {
    let input = #"<accounts><owner>Robert Mitchell</owner><RobertMitchell plan="pro"/><robert_mitchell_notes>x</robert_mitchell_notes></accounts>"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.xml")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(!output.localizedCaseInsensitiveContains("Robert"))
    #expect(!output.localizedCaseInsensitiveContains("Mitchell"))
    #expect(output.contains("_notes"))
}

@Test func xmlProcessingInstructionTargetsLoseIdentifiers() throws {
    let input = #"<?customer_2128675309 active?><root><?order_5550123456 open?></root>"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.xml")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(!output.contains("2128675309"))
    #expect(!output.contains("5550123456"))
}

@Test func xmlFixtureMarksPointAtReplacements() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "customer", withExtension: "xml")))
    let result = try Scrubber.scrub(data, name: "customer.xml")
    if case .text(let text, let marks, _) = result.preview {
        #expect(marks.contains { $0.entity == "EMAIL_ADDRESS" && (text as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)).contains("@example.") })
        #expect(marks.contains { $0.entity == "FIRST_NAME" })
    } else { Issue.record("Expected text preview") }
}

@Test func xmlFixtureUsesOnePersonaAcrossFieldsAndNotes() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "customer", withExtension: "xml")))
    let result = try Scrubber.scrub(data, name: "customer.xml")
    let output = String(decoding: result.output, as: UTF8.self)
    func content(_ tag: String) throws -> String {
        let pattern = "<crm:\(tag)>([^<]+)</crm:\(tag)>"
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try #require(regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)))
        return (output as NSString).substring(with: match.range(at: 1))
    }
    let first = try content("FirstName")
    let last = try content("LastName")
    let email = try content("Email")
    #expect(email == "\(first.lowercased()).\(last.lowercased())@example.com")
    #expect(output.contains("Record owner: \(first) \(last),"))
    #expect(output.contains("<![CDATA[\(first) \(last) asked"))
}

@Test(arguments: [
    #"<?x <!-- ?><!DOCTYPE a [<!ENTITY e "boom">]><a>&e;</a><!-- -->"#,
    #"<!-- a --><?x <!-- ?><!DOCTYPE a SYSTEM "file:///etc/passwd"><a/><!-- -->"#,
])
func xmlDoctypeHiddenBehindCommentLookalikesIsRefused(_ xml: String) {
    #expect(throws: ScrubError.unsupported("xml_doctype")) { try Scrubber.scrub(Data(xml.utf8), name: "a.xml") }
}

@Test func xmlValueUnderHintedElementTakesItsHint() throws {
    let input = #"<user><id_number><value>123456789</value><type>us_ssn</type></id_number><passport value="X1234567"/></user>"#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.xml").output, as: UTF8.self)
    #expect(!output.contains("123456789"))
    #expect(output.range(of: #"<value>\d{9}</value>"#, options: .regularExpression) != nil)
    #expect(output.contains("<type>us_ssn</type>"))
    #expect(!output.contains("X1234567"))
}

@Test func xmlBareNameNeedsAPersonRecord() throws {
    let input = #"<r><account><name>Everyday Checking</name><mask>0000</mask></account><owner email="p@example.org"><name>Priya Raghunathan</name></owner></r>"#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.xml").output, as: UTF8.self)
    #expect(output.contains("<name>Everyday Checking</name>"))
    #expect(!output.contains("Priya"))
}

/// An element's name is renamed only for what it holds itself, never because a note reads a name spelled alike ("Garante Moretti").
@Test(arguments: 1...3)
func xmlElementSpelledLikeANameReadElsewhereStays(_ run: Int) throws {
    let input = "<pratica><richiedente><nome>Odalys</nome><cognome>Ferriter</cognome></richiedente><garante><nome>Tavish</nome><cognome>Moretti</cognome></garante><note>Odalys preferisce la posta. Garante Moretti pensionato.</note></pratica>"
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "pratica.xml").output, as: UTF8.self)
    #expect(output.contains("<garante><nome>") && output.contains("</cognome></garante>"), "\(output)")
    #expect(!output.contains("Moretti") && !output.contains("Odalys"), "\(output)")
}
