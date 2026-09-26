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
