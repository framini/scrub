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
    #expect(!json.contains("78701") && !json.contains("Austin"))
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

@Test func qualifiedSecretKeysAreSecrets() throws {
    let keys = ["db_password", "api_token", "secret_access_key", "webhook_secret", "x-api-key", "signingSecret", "password_hash", "encryption_key", "credentials", "otp_code"]
    let input = "{" + keys.enumerated().map { "\"\($1)\":\"qzvx\($0)mrtplknb\"" }.joined(separator: ",") + "}"
    let (output, result) = try run(input, name: "a.json")
    #expect(!output.contains("mrtplknb"))
    #expect(result.counts["SECRET"] == keys.count)
}

@Test func keysThatOnlyMentionASecretWordAreKept() throws {
    let input = #"{"max_tokens":512,"prompt_tokens":88,"sort_key":"created_at","token_type":"Bearer","file_name":"Report Final"}"#
    let (output, result) = try run(input, name: "a.json")
    #expect(output == input)
    #expect(result.counts.isEmpty)
}

@Test func shortNumericSecretStaysAShortNumber() throws {
    let (output, _) = try run(#"{"cvv":"123","pin":"4821"}"#, name: "a.json")
    let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    #expect(object["cvv"] != "123" && object["cvv"]?.count == 3 && object["cvv"]?.allSatisfy(\.isNumber) == true)
    #expect(object["pin"] != "4821" && object["pin"]?.count == 4)
}

@Test func roleKeysReplaceNamesAndKeepOtherValues() throws {
    let (json, _) = try run(#"{"assigned_to":"Priya Raghunathan","manager":"Oluwaseun Adeyemi","created_by":"u_1234","owner":"platform-team"}"#, name: "a.json")
    #expect(!json.contains("Priya") && !json.contains("Raghunathan") && !json.contains("Adeyemi"))
    #expect(json.contains("\"u_1234\"") && json.contains("\"platform-team\""))
    let (csv, _) = try run("name,assigned_to\nEmily Watson,Priya Raghunathan\n", name: "a.csv")
    #expect(!csv.contains("Raghunathan"))
    let (xml, _) = try run("<r><assignee>Priya Raghunathan</assignee></r>", name: "a.xml")
    #expect(!xml.contains("Raghunathan"))
}

@Test func postalCodesKeepTheirShape() throws {
    let (output, result) = try run(#"{"zip":"10016","postcode":"NW1 6XE"}"#, name: "a.json")
    let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    #expect(object["zip"] != "10016" && object["zip"]?.count == 5 && object["zip"]?.allSatisfy(\.isNumber) == true)
    #expect(object["postcode"] != "NW1 6XE" && object["postcode"]?.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 } == Array("AA9 9AA"))
    #expect(result.counts["POSTAL_CODE"] == 2)
}

@Test func unfamiliarDisplayNameBeforeAnEmailIsAPerson() throws {
    let (output, _) = try run("From: Priya Raghunathan <priya.r@northwind.io>\nSubject: refund\n\nPlease loop in Priya.\n\nThanks,\nPriya\n", name: "")
    #expect(!output.contains("Priya") && !output.contains("Raghunathan"))
}

@Test func lowercaseFirstNamesAndHandlesFollowTheFullName() throws {
    let (output, _) = try run("Maria Gonzalez joined.\nmaria, please send it to Daniel Okafor.\ncc @daniel.okafor and @maria_gonzalez, thanks daniel.\nWe will hunt for it.\n", name: "")
    let lowered = output.lowercased()
    #expect(!lowered.contains("maria") && !lowered.contains("daniel") && !lowered.contains("okafor") && !lowered.contains("gonzalez"))
    #expect(output.contains("We will hunt for it."))
    let handle = try #require(output.split(separator: "@").dropFirst().first?.prefix { $0.isLetter || $0 == "." })
    #expect(handle == handle.lowercased() && handle.contains("."))
}

@Test func untouchedJSONKeepsItsByteOrderMark() throws {
    let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"plan":"Team"}"#.utf8)
    let result = try Scrubber.scrub(data, name: "a.json", forceFullDetection: false, seed: 42)
    #expect(result.output == data)
}

@Test func quotedAndReversedDisplayNamesBeforeAnEmailArePeople() throws {
    let (output, _) = try run("From: \"Priya Raghunathan\" <priya.r@northwind.io>\nTo: Adeyemi, Oluwaseun <o.adeyemi@northwind.io>\nCc: Ann Smith, \"Raghunathan, Priya\" <priya.r@northwind.io>\n", name: "")
    #expect(!output.contains("Priya") && !output.contains("Raghunathan") && !output.contains("Adeyemi") && !output.contains("Oluwaseun"))
    #expect(output.contains("To: ") && output.range(of: #"To: \p{Lu}[\p{L}'’-]*, \p{Lu}"#, options: .regularExpression) != nil)
}

@Test func roleColumnsCountWithoutARecognisedHeader() throws {
    let (csv, _) = try run("Ticket,Assigned To,Account Manager,Reporter,Owner,Status\nT-1,Priya Raghunathan,Daniel Okafor,Oluwaseun Adeyemi,Platform Team,Open\n", name: "a.csv")
    #expect(!csv.contains("Raghunathan") && !csv.contains("Okafor") && !csv.contains("Adeyemi"))
    #expect(csv.contains("Platform Team") && csv.contains("T-1") && csv.contains("Open"))
}

@Test func teamNamesUnderRoleKeysStayTeams() throws {
    let (json, _) = try run(#"{"owner":"Platform Team","owner_team":"Data Platform","rep":"Q3 Sales Report","support":"Support Team <support@northwind.io>"}"#, name: "a.json")
    #expect(json.contains("Platform Team") && json.contains("Data Platform") && json.contains("Q3 Sales Report") && json.contains("Support Team"))
}

@Test func roleValuesInOtherNameShapes() throws {
    let (json, _) = try run(#"{"assigned_to":"Raghunathan, Priya","manager":"Oluwaseun Adeyemi (Support)","owner":"Maria","reporter":"u_1234"}"#, name: "a.json")
    #expect(!json.contains("Priya") && !json.contains("Raghunathan") && !json.contains("Adeyemi") && !json.contains("Maria"))
    #expect(json.contains("(Support)") && json.contains("u_1234"))
}
