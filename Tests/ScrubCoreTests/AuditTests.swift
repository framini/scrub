import Foundation
@testable import ScrubCore
import Testing

private func run(_ input: String, name: String) throws -> (String, ScrubResult) {
    let result = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 42)
    return (String(decoding: result.output, as: UTF8.self), result)
}

private func luhn(_ digits: String) -> Bool { Patterns.luhn(digits.compactMap(\.wholeNumberValue)) }

@Test(arguments: ["password,plan\nqzvxmrtplknb,basic\n", "password\nqzvxmrtplknb\nhunter2hunter2\n"])
func pastedSmallCSVWithKnownHeaderIsCSV(_ input: String) throws {
    #expect(try Scrubber.classify(Data(input.utf8), name: "") == "csv")
    let (output, _) = try run(input, name: "")
    #expect(!output.contains("qzvxmrtplknb"))
}

@Test func pastedProseWithCommasStaysText() throws {
    #expect(try Scrubber.classify(Data("Hi, Maria\nThanks, Bob\n".utf8), name: "") == "text")
}

@Test func pastedHTMLIsScrubbedAsText() throws {
    let (output, result) = try run("<!DOCTYPE html><html><body>Mail maria.gonzalez@northwind.io</body></html>", name: "")
    #expect(result.format == "text")
    #expect(!output.contains("maria.gonzalez@northwind.io"))
}

@Test func nestedValueUnderSecretKeyIsReplaced() throws {
    let (json, _) = try run(#"{"password":{"value":"qzvxmrtplknb"},"token":["abcDEF123xyz"]}"#, name: "a.json")
    #expect(!json.contains("qzvxmrtplknb"))
    #expect(!json.contains("abcDEF123xyz"))
    let (xml, _) = try run("<root><password><value>qzvxmrtplknb</value></password><password>zzqq<em>zxcvmnbq</em></password></root>", name: "a.xml")
    #expect(!xml.contains("qzvxmrtplknb"))
    #expect(!xml.contains("zxcvmnbq"))
}

@Test func nestedValuesUnderNameKeyKeepTheirOwnMeaning() throws {
    let (json, _) = try run(#"{"address":{"city":"Austin","country":"US","zip":"78701"}}"#, name: "a.json")
    #expect(json.contains("\"US\""))
    #expect(json.contains("78701"))
}

@Test func recheckRespectsWordBoundaries() throws {
    let (a, _) = try run(#"{"name":"Ann","note":"annual summary"}"#, name: "a.json")
    #expect(a.contains("annual summary"))
    let (b, _) = try run(#"{"username":"sam","note":"sample results"}"#, name: "a.json")
    #expect(b.contains("sample results"))
    let (c, _) = try run(#"{"password":"a","note":"basic plan"}"#, name: "a.json")
    #expect(c.contains("basic plan"))
    #expect(c.contains("\"password\""))
}

@Test func recheckStillCatchesARepeatedOriginal() throws {
    let (output, _) = try run(#"{"password":"qzvxmrtplknb","note":"it was qzvxmrtplknb, then (qzvxmrtplknb)"}"#, name: "a.json")
    #expect(!output.contains("qzvxmrtplknb"))
}

@Test func numericCardKeepsLengthIssuerAndChecksum() throws {
    let (output, _) = try run(#"{"card":5555555555554444,"amex":{"card":378282246310005}}"#, name: "a.json")
    let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    let card = String(try #require(object["card"] as? Int))
    #expect(card != "5555555555554444" && card.count == 16 && card.hasPrefix("5") && luhn(card))
    let amex = String(try #require((object["amex"] as? [String: Any])?["card"] as? Int))
    #expect(amex != "378282246310005" && amex.count == 15 && amex.hasPrefix("37") && luhn(amex))
}

@Test func numericBirthDateStaysAValidDate() throws {
    let (output, _) = try run(#"{"dob":19801231}"#, name: "a.json")
    let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Int])
    let value = try #require(object["dob"])
    #expect(value != 19801231)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    formatter.isLenient = false
    let date = try #require(formatter.date(from: String(value)))
    #expect((1940...1999).contains(Calendar(identifier: .gregorian).component(.year, from: date)))
}

@Test(arguments: [("5555 5555 5555 4444", "5", 16), ("3782-822463-10005", "37", 15), ("4111111111111111", "4", 16)])
func stringCardKeepsIssuerLengthAndGrouping(_ input: String, _ issuer: String, _ length: Int) throws {
    let (output, _) = try run("card \(input) on file", name: "notes.txt")
    #expect(!output.contains(input))
    let fake = String(output.dropFirst(5).dropLast(8))
    let digits = fake.filter(\.isNumber)
    #expect(digits.count == length && digits.hasPrefix(issuer) && luhn(digits))
    #expect(fake.map { $0.isNumber ? "0" : $0 } == input.map { $0.isNumber ? "0" : $0 })
}

@Test(arguments: ["password: qzvxmrtplknb", "DB_PASSWORD=qzvxmrtplknb", #"login ok, "api_key": "qzvxmrtplknb""#, "session_id=qzvxmrtplknb; path=/"])
func pastedKeyedSecretIsReplaced(_ input: String) throws {
    let (output, result) = try run(input, name: "")
    #expect(result.format == "text")
    #expect(!output.contains("qzvxmrtplknb"))
}

@Test func secretWordInProseLeavesTheSentence() throws {
    let (output, _) = try run("The token is valid for an hour and the password policy changed.", name: "")
    #expect(output == "The token is valid for an hour and the password policy changed.")
}

private let ticket = "From: Maria Gonzalez <maria.gonzalez@northwind.io>\nSent: Tuesday, 3 March\n\nHi,\n\nI was double charged. You can reach me on +1 (415) 555-0132.\n\nThanks,\nMaria\n"

@Test func signOffFirstNameFollowsTheFullName() throws {
    let (output, _) = try run(ticket, name: "")
    #expect(!output.contains("Maria"))
    let header = try #require(output.split(separator: "\n").first?.dropFirst("From: ".count).split(separator: " ").first)
    #expect(output.hasSuffix("Thanks,\n\(header)\n"))
}

@Test(arguments: ["Best,\nKevin\n", "Hi,\nThe invoice is late.\n\nCheers,\nDaniel"])
func knownFirstNameAloneOnASignOffIsReplaced(_ input: String) throws {
    let (output, _) = try run(input, name: "")
    #expect(!output.contains("Kevin") && !output.contains("Daniel"))
}

@Test func greetingStaysAGreeting() throws {
    let (output, _) = try run(ticket, name: "")
    #expect(output.contains("\n\nHi,\n\n"))
}

@Test func namePartsOnlyMatchWhenCapitalised() throws {
    let (output, _) = try run("Daniel Hunt called about the refund. We will hunt for the invoice.\n", name: "")
    #expect(!output.contains("Hunt"))
    #expect(output.contains("We will hunt for the invoice."))
}

@Test func originalJoinedToAnotherWordIsCaughtAtCaseAndDigitEdges() throws {
    let (output, _) = try run(#"{"name":"Maria Gonzalez","username":"sam","note":"user mariaGonzalez, sam42 and annual sample"}"#, name: "a.json")
    let note = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])["note"]
    #expect(note?.lowercased().contains("maria") == false)
    #expect(note?.contains("Gonzalez") == false)
    #expect(note?.contains("sam42") == false)
    #expect(note?.hasSuffix("annual sample") == true)
}

@Test func oneCharacterSecretLeavesProseAlone() throws {
    let (output, _) = try run(#"{"password":"a","note":"a basic plan, a"}"#, name: "a.json")
    #expect(output.contains("\"a basic plan, a\""))
    #expect(!output.contains("\"password\": \"a\""))
}

@Test func numericPhoneKeepsNotationAndSharesItsStandIn() throws {
    let (output, _) = try run(#"{"phone":2128675309.0,"mobile":2.128675309e9,"cell":2128675309}"#, name: "a.json")
    let lines = output.split(separator: "\n").map { $0.split(separator: ":").last?.trimmingCharacters(in: CharacterSet(charactersIn: " ,")) ?? "" }
    let phone = try #require(lines.first { $0.hasSuffix(".0") }), mobile = try #require(lines.first { $0.hasSuffix("e9") })
    let cell = try #require(lines.first { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    #expect(cell != "2128675309" && cell.count == 10)
    #expect(phone == cell + ".0")
    #expect(mobile == String(cell.prefix(1)) + "." + String(cell.dropFirst()) + "e9")
}

@Test func jsonWithNothingToReplaceComesBackUnchanged() throws {
    let input = #"{"plan":"Team",  "seats":12}"#
    let (output, result) = try run(input, name: "a.json")
    #expect(output == input)
    #expect(result.counts.isEmpty)
}

@Test func replacedHeaderCellIsMarked() throws {
    let (_, result) = try run("name,notes for maria.gonzalez@northwind.io\nMaria Gonzalez,Team\nDaniel Okafor,Pro\n", name: "a.csv")
    guard case .table(let columns, _, _, let marks) = result.preview else { Issue.record("not a table"); return }
    #expect(!columns[1].contains("maria.gonzalez"))
    #expect(marks.contains { $0.row == TableMark.header && $0.column == 1 && $0.entity == "EMAIL_ADDRESS" })
}
