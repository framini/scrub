import Foundation
@testable import ScrubCore
import Testing

// Fields that real API responses carry and that came out as written: one case
// per fault, each sent as a file, as pasted text, in a curl command and in a
// log line. Every value below is invented.

private struct LeakCase: Sendable, CustomTestStringConvertible {
    let name: String
    let json: String
    /// Words or values that must be gone from every rendering's output.
    let gone: [String]
    /// Text that must come out as written.
    var kept: [String] = []
    var testDescription: String { name }
}

private let renderings: [(String, String, @Sendable (String) -> String)] = [
    ("file", "doc.json", { $0 }),
    ("pasted", "doc.txt", { $0 }),
    ("curl", "doc.txt", { "curl -X POST https://api.example.com/v1/check -H 'Content-Type: application/json' -d '\($0.replacingOccurrences(of: "'", with: "'\\''"))'\n" }),
    ("log", "doc.txt", { "2026-01-12T10:04:11Z INFO http - response body=\($0)\n" }),
]

private func body(_ output: String, _ rendering: String) -> String {
    guard rendering == "curl" || rendering == "log", let open = output.firstIndex(where: { $0 == "{" || $0 == "[" }),
          let close = output.lastIndex(where: { $0 == "}" || $0 == "]" }) else { return output }
    let text = String(output[open...close])
    return rendering == "curl" ? text.replacingOccurrences(of: "'\\''", with: "'") : text
}

/// Whether `value` is still in `text`: a word of letters on its own, anything else anywhere.
private func holds(_ text: String, _ value: String) -> Bool {
    guard value.allSatisfy({ $0.isLetter || $0 == " " }) else { return text.range(of: value, options: .caseInsensitive) != nil }
    return text.range(of: #"(?<!\p{L})"# + NSRegularExpression.escapedPattern(for: value) + #"(?!\p{L})"#, options: [.regularExpression, .caseInsensitive]) != nil
}

private let cases: [LeakCase] = [
    LeakCase(name: "a bare name holding a name from the long lists", json: #"{"relationships": [{"name": "Jim Halvorsen", "type": "member"}, {"name": "Ian Penhale", "type": "owner"}]}"#,
             gone: ["Halvorsen", "Penhale", "Jim", "Ian"], kept: [#""type": "member""#]),
    LeakCase(name: "keys a generated class writes with Field", json: #"{"directorsField": [{"nameField": "Ian Penhale", "address2Field": "PADDINGTON", "dateOfBirthField": "1971-03-09"}]}"#,
             gone: ["Penhale", "PADDINGTON", "1971-03-09"], kept: ["nameField", "address2Field"]),
    LeakCase(name: "name keys in other languages", json: #"{"nombre": "ROSALIA", "apellidoPaterno": "QUINTERO", "apellidoMaterno": "VELARDE", "vorname": "Ottilie", "nachname": "Brandauer"}"#,
             gone: ["ROSALIA", "QUINTERO", "VELARDE", "Ottilie", "Brandauer"]),
    LeakCase(name: "a field written in a script of its own", json: #"{"firstName": {"latin": "TOBIAS"}, "lastName": {"latin": "HALVORSEN"}, "lastNameEn": "HALVORSEN", "dateOfBirth": {"originalString": {"latin": "09 NOV 1984"}}}"#,
             gone: ["TOBIAS", "HALVORSEN", "09 NOV 1984"]),
    LeakCase(name: "other names in other scripts and of one word", json: #"{"name": "Corvin Ashdown", "aka": [{"name": "Корвин Эшдаун"}, {"name": "Ashdowne"}]}"#,
             gone: ["Ashdown", "Корвин", "Эшдаун", "Ashdowne"]),
    LeakCase(name: "a birth year in a record of its own", json: #"{"events": [{"type": "BIRTH", "fullDate": "14 Feb 1976", "year": 1976}], "searchTerm": {"name": "Lucan Brierly", "year": "1952"}}"#,
             gone: [#""year": 1976"#, #""year": "1952""#, "14 Feb 1976", "Brierly"], kept: [#""type": "BIRTH""#]),
    LeakCase(name: "a card's and a document's expiry", json: #"{"card": {"last4": "7731", "exp_month": 6, "exp_year": 2031, "expiry": "04/29", "expiration": {"month": "01", "year": "2028"}}, "personal_ids": [{"type": "passport", "number": "X81726354", "expiry_date": "2033-09-14"}], "session": {"expires_at": "2026-11-02T10:00:00Z"}}"#,
             gone: [#""exp_year": 2031"#, #""exp_month": 6,"#, "04/29", #""year": "2028""#, "2033-09-14", "X81726354"], kept: ["2026-11-02T10:00:00Z"]),
    LeakCase(name: "an address's further lines and places", json: #"{"address": {"line1": "12 Elm Road", "line2": "Paddington", "county": "WESTMORLAND", "flat": "7B"}, "user_pob": "Tartu", "address_line2": "Flat 12"}"#,
             gone: ["Paddington", "WESTMORLAND", "Tartu", "Flat 12"]),
    LeakCase(name: "answers, hashes and devices", json: #"{"secret_answer": "my first dog was rufus", "username_md5": "c9e1f0a7b3d58e2f4a6c0b1d9e7f3a28", "device": {"id": "6f1c2a9e-4b7d-4e3a-9c1f-2d8b7a6e5c40"}, "email": {"address": "5d2a9e0f7c13b48e6a0f9d21c7b3e845"}, "imsi": "310150123456789"}"#,
             gone: ["rufus", "c9e1f0a7b3d58e2f4a6c0b1d9e7f3a28", "6f1c2a9e-4b7d-4e3a-9c1f-2d8b7a6e5c40", "5d2a9e0f7c13b48e6a0f9d21c7b3e845", "310150123456789"]),
    LeakCase(name: "a person written into links", json: #"{"first_name": "Corvin", "last_name": "Ashdown", "url": "https://news.example.org/local/ashdowns-garden-wins-county-prize/", "avatar": "https://avatars.example.org/avatar/3b7e0c19d4a65f28e1c9b0a7d3f46e52?s=64", "host": "198-51-100-23.cust.example.net", "query": {"email": "jo.pratt%40example.org"}}"#,
             gone: ["ashdowns", "3b7e0c19d4a65f28e1c9b0a7d3f46e52", "198-51-100-23", "jo.pratt"], kept: ["https://news.example.org/local/", "-garden-wins-county-prize/", ".cust.example.net"]),
    LeakCase(name: "a masked number written again", json: #"{"account_number": "*********7731", "reference": "SAVINGS *********7731"}"#, gone: ["7731"], kept: ["SAVINGS *********"]),
    LeakCase(name: "a party to a case", json: #"{"case_name": "NORTHWIND COLLECTIONS LLC Et Al VS NELL TORVIK"}"#, gone: ["NELL TORVIK"], kept: ["NORTHWIND COLLECTIONS LLC Et Al VS "]),
    LeakCase(name: "contact fields qualified after", json: #"{"consumer": {"phoneHome": 3035550144, "phoneCell": "7205550187", "emailWork": "o.fenwick@example.org"}}"#,
             gone: ["3035550144", "7205550187", "o.fenwick"]),
]

@Test(arguments: cases)
private func responseFieldsAreReplaced(_ leakCase: LeakCase) throws {
    for (rendering, file, render) in renderings {
        let output = String(decoding: try Scrubber.scrub(Data(render(leakCase.json).utf8), name: file, forceFullDetection: false, seed: 7).output, as: UTF8.self)
        let json = body(output, rendering)
        #expect((try? OrderedJSON.parse(json)) != nil, "[\(rendering)] no longer parses: \(output)")
        for value in leakCase.gone { #expect(!holds(output, value), "[\(rendering)] \(value) left in \(output)") }
        for value in leakCase.kept { #expect(output.contains(value), "[\(rendering)] \(value) changed in \(output)") }
    }
}

/// What must come out byte for byte: an ID a middle initial's letter is part of, a key a
/// word of a name is part of, a document's labels for its own parts, a country in a body's
/// name, and a sample's value that writes its own key.
@Test(arguments: renderings.map(\.0))
func valuesNamingNoOneStay(_ rendering: String) throws {
    let json = #"{"consumer": {"firstName": "Orrin", "middleName": "A", "lastName": "Fenwick", "middle": "The"}, "trackId": "4c1e7a90-2b6d-4f13-a8e5-91d0c37b6f2a", "code": "A114", "lengthOfTheCurrentLease": "24 months", "parties": [{"id": "PRIMARYPARTY_1", "documents": [{"id": "proofDoc-1"}]}], "borrowers": [{"id": "BORROWER_1", "partyId": "PRIMARYPARTY_1"}], "issuer_full_name": "Office of Financial Oversight of Norway", "program": "Danish Export Controls", "transaction": {"accountRef": "ACCOUNTREF"}}"#
    let (_, file, render) = try #require(renderings.first { $0.0 == rendering })
    let output = String(decoding: try Scrubber.scrub(Data(render(json).utf8), name: file, forceFullDetection: false, seed: 7).output, as: UTF8.self)
    for kept in ["4c1e7a90-2b6d-4f13-a8e5-91d0c37b6f2a", #""A114""#, "lengthOfTheCurrentLease", "PRIMARYPARTY_1", "BORROWER_1", "proofDoc-1", "Office of Financial Oversight of Norway", "Danish Export Controls", #""accountRef": "ACCOUNTREF""#] {
        #expect(output.contains(kept), "[\(rendering)] \(kept) changed in \(output)")
    }
    #expect(!holds(output, "Orrin") && !holds(output, "Fenwick"), "\(output)")
}

/// A name written in capitals takes a stand-in in capitals, and a middle initial a letter.
@Test func capitalsAndInitialsKeepTheirForm() throws {
    let output = String(decoding: try Scrubber.scrub(Data(#"{"firstName": "TOBIAS", "middleName": "Q", "lastName": "HALVORSEN"}"#.utf8), name: "a.json", forceFullDetection: false, seed: 7).output, as: UTF8.self)
    guard case .object(let pairs) = try OrderedJSON.parse(output) else { Issue.record("\(output)"); return }
    let fields = Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in pair.1.stringValue.map { (pair.0, $0) } })
    #expect(fields["firstName"].map { $0 == $0.uppercased() && $0 != "TOBIAS" } == true, "\(output)")
    #expect(fields["lastName"].map { $0 == $0.uppercased() && $0 != "HALVORSEN" } == true, "\(output)")
    #expect(fields["middleName"].map { $0.count == 1 && $0 != "Q" } == true, "\(output)")
}

/// A row may run past its header; its extra cells have no column to read them under.
@Test func aRowLongerThanItsHeaderIsRead() throws {
    let csv = "aka.0.name,email\nКорвин Эшдаун,c.ashdown@example.org,extra,cells\n"
    let output = String(decoding: try Scrubber.scrub(Data(csv.utf8), name: "a.csv", forceFullDetection: false, seed: 7).output, as: UTF8.self)
    #expect(!output.contains("Эшдаун") && !output.contains("c.ashdown"), "\(output)")
}
