import Foundation
@testable import ScrubCore
import Testing

/// Values a record holds beside one another, read as a record in JSON, CSV
/// and XML alike: an address line with no number goes with the city and
/// postcode replaced beside it, an age moves with the birth date in its own
/// record whenever the file was written, and text split by inline elements
/// in XML is read whole. Every person, address and number here is invented.
@Suite(.serialized)
struct RecordFieldTests {
    enum Format: CaseIterable { case json, csv, xml }

    struct Row { var fields: [(String, String)] }

    /// The rows written as the format writes a list of records, scrubbed, and read back as rows of fields.
    static func scrub(_ rows: [Row], _ format: Format, seed: UInt64) throws -> [[String: String]] {
        let keys = rows[0].fields.map(\.0)
        let data: Data, name: String
        switch format {
        case .json:
            let records = rows.map { row in "{" + row.fields.map { "\"\($0.0)\": \"\($0.1)\"" }.joined(separator: ", ") + "}" }
            (data, name) = (Data("{\"staff\": [\(records.joined(separator: ", "))]}".utf8), "staff.json")
        case .csv:
            let lines = rows.map { row in row.fields.map { "\"\($0.1)\"" }.joined(separator: ",") }
            (data, name) = (Data((keys.joined(separator: ",") + "\n" + lines.joined(separator: "\n") + "\n").utf8), "staff.csv")
        case .xml:
            let records = rows.map { row in "<member>" + row.fields.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined() + "</member>" }
            (data, name) = (Data("<staff>\(records.joined())</staff>".utf8), "staff.xml")
        }
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
        switch format {
        case .json:
            let object = try JSONSerialization.jsonObject(with: result.output) as? [String: Any]
            return (object?["staff"] as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
        case .csv:
            let table = try CSVFile.parse(String(decoding: result.output, as: UTF8.self), delimiter: ",")
            return table.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(table[0], $0)) }
        case .xml:
            let document = try XMLDocument(data: result.output)
            return try document.nodes(forXPath: "/staff/member").map { member in
                Dictionary(uniqueKeysWithValues: ((member as? XMLElement)?.children ?? []).compactMap { node in node.name.map { ($0, node.stringValue ?? "") } })
            }
        }
    }

    // MARK: An address line with no number

    @Test(arguments: Format.allCases) func aNumberlessLineGoesWithTheAddressBesideIt(format: Format) throws {
        let rows = [Row(fields: [("staff_ref", "E-2231"), ("home_line1", "the old rectory, church lane"), ("home_city", "Ledbury"), ("home_postcode", "HR8 1DW"), ("home_country", "GB")]),
                    Row(fields: [("staff_ref", "E-2232"), ("home_line1", "Pear Tree Cottage, Sallow Lane"), ("home_city", "Long Compton"), ("home_postcode", "CV36 5JS"), ("home_country", "GB")]),
                    Row(fields: [("staff_ref", "E-2233"), ("home_line1", "same as billing"), ("home_city", "Ledbury"), ("home_postcode", "HR8 2EQ"), ("home_country", "GB")])]
        for seed in UInt64(0)..<3 {
            let out = try Self.scrub(rows, format, seed: seed)
            try #require(out.count == 3, "[\(format)] \(out)")
            for (index, words) in [["old", "church"], ["Pear", "Sallow"]].enumerated() {
                let original = rows[index].fields[1].1, line = out[index]["home_line1"] ?? ""
                #expect(line != original && SpreadTests.gone(words, from: line).isEmpty, "[\(format) \(seed)] \(line)")
                // Of the same kind: no number where there was none, as many pieces, and lowercase kept.
                #expect(!line.contains(where: \.isNumber) && AddressBlock.pieces(line).count == AddressBlock.pieces(original).count, "[\(format) \(seed)] \(line)")
                #expect((original == original.lowercased()) == (line == line.lowercased()), "[\(format) \(seed)] \(line)")
                #expect(out[index]["home_city"] != rows[index].fields[2].1 && out[index]["home_postcode"] != rows[index].fields[3].1, "[\(format) \(seed)] \(out[index])")
            }
            // A note where the line should be is no address.
            #expect(out[2]["home_line1"] == "same as billing", "[\(format) \(seed)] \(out[2])")
            #expect(out.map { $0["staff_ref"] } == rows.map { $0.fields[0].1 }, "[\(format) \(seed)] \(out)")
        }
    }

    // MARK: An age in its record

    @Test(arguments: Format.allCases) func anAgeMovesWithItsOwnRecordsBirthDate(format: Format) throws {
        // Ages taken a couple of years before the scrub, as an export keeps them.
        let rows = [Row(fields: [("customer_id", "cus_bram_teodorescu"), ("full_name", "Bram Teodorescu"), ("email", "bram.t@example.net"), ("date_of_birth", "1994-11-02"), ("age", "30"), ("plan", "pro")]),
                    Row(fields: [("customer_id", "cus_ines_valcourt"), ("full_name", "Ines Valcourt"), ("email", "ines.v@example.net"), ("date_of_birth", "1988-05-19"), ("age", "36"), ("plan", "team")])]
        for seed in UInt64(0)..<3 {
            let out = try Self.scrub(rows, format, seed: seed)
            try #require(out.count == 2, "[\(format)] \(out)")
            for (row, record) in zip(rows, out) {
                let realYear = Int(row.fields[3].1.prefix(4))!, realAge = Int(row.fields[4].1)!
                let date = record["date_of_birth"] ?? "", age = record["age"] ?? ""
                let madeYear = try #require(Int(date.prefix(4)), "[\(format) \(seed)] \(record)")
                #expect(madeYear != realYear && date.count == 10, "[\(format) \(seed)] \(record)")
                #expect(Int(age) == realAge + realYear - madeYear, "[\(format) \(seed)] age \(age) beside \(date) for \(row.fields[3].1), \(realAge)")
                #expect(record["plan"] == row.fields[5].1)
            }
        }
    }

    // MARK: Text split by inline elements

    @Test func textSplitByInlineElementsIsReadWhole() throws {
        let xml = "<notes><note>Spoke with <b>Odal</b>ys Ferriter today about the refund.</note>"
            + "<note>Escalated by <i>Teo</i>doro <b>Quillan</b>; reply to <em>teodoro.quillan</em>@kestrel.example</note>"
            + "<note>Ms <name><b>Bri</b>sa Vantongeren</name> called back about <i>ticket</i> 4471.</note>"
            + "<contact><name>Casimir Ambrosetti</name><phone>415-555-0143</phone></contact></notes>"
        for seed in UInt64(0)..<3 {
            let result = try Scrubber.scrub(Data(xml.utf8), name: "notes.xml", forceFullDetection: false, seed: seed)
            let document = try XMLDocument(data: result.output, options: XMLSerialization.parseOptions)
            let notes = try document.nodes(forXPath: "/notes/note").compactMap(\.stringValue)
            let all = notes.joined(separator: "\n")
            #expect(SpreadTests.gone(["Odalys", "Odal", "Ferriter", "Teodoro", "Teo", "Quillan", "teodoro.quillan", "Brisa", "Bri", "Vantongeren"], from: all).isEmpty, "[\(seed)] \(all)")
            // The inline elements stay where they were, around the stand-ins.
            let output = String(decoding: result.output, as: UTF8.self)
            for tag in ["<b>", "<i>", "<em>"] { #expect(output.components(separatedBy: tag).count == xml.components(separatedBy: tag).count, "[\(seed)] \(tag): \(output)") }
            #expect(notes[0].hasPrefix("Spoke with ") && notes[0].hasSuffix(" today about the refund."), "[\(seed)] \(notes[0])")
            #expect(notes[0].firstMatch(of: #/^Spoke with [A-Z][a-z]+ [A-Z][a-z'-]+ today/#) != nil, "[\(seed)] \(notes[0])")
            #expect(notes[1].firstMatch(of: #/reply to [a-z]+\.[a-z]+@[a-z0-9.-]+$/#) != nil, "[\(seed)] \(notes[1])")
            #expect(notes[2].firstMatch(of: #/^Ms [A-Z][a-z]+ [A-Z][a-z'-]+ called back about ticket 4471\.$/#) != nil, "[\(seed)] \(notes[2])")
            // Each stand-in word sits in the element its original's first piece did.
            #expect(output.firstMatch(of: #/<note>Escalated by <i>[A-Z][a-z]+</i> <b>[A-Z][a-z'-]+</b>; reply to <em>[a-z]+\.[a-z]+@[a-z0-9.-]+</em></note>/#) != nil, "[\(seed)] \(output)")
            // A record's fields are still each read under their own name.
            let contact = try document.nodes(forXPath: "/notes/contact/name").first?.stringValue ?? ""
            #expect(!contact.contains("Ambrosetti") && contact.firstMatch(of: #/^[A-Z][a-z]+ [A-Z][a-z'-]+$/#) != nil, "[\(seed)] \(contact)")
        }
        // A text holding the joint itself is read as written, piece by piece, and comes back whole.
        let joint = "<note>Spoke with <b>Odal</b>ys\u{2063} today.</note>"
        let result = try Scrubber.scrub(Data(joint.utf8), name: "joint.xml", forceFullDetection: false, seed: 1)
        #expect((try? XMLDocument(data: result.output)) != nil)
    }
}
