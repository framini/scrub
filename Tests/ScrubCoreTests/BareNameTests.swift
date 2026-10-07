import Foundation
@testable import ScrubCore
import Testing

/// A person's name under a plain "name" key, the commonest shape an API
/// returns a record in, with nothing else in the record that says it is a
/// person's: no email key, no list of users around it. It is replaced, or at
/// least put to a person in review; it is never kept unseen. A product's, a
/// plan's or a business's name there is neither replaced nor asked about.
struct BareNameTests {
    /// Names no list of US names holds whole, written as people write them.
    static let people = ["Hamish Olawale", "Thandiwe Mokoena", "Ngozi Adeyemi", "Wojciech Szczepański", "Ysolde Brackenridge",
                         "Tomasz Wierzbicki", "Saoirse Delacroix-Byrne", "Aino Virtanen"]
    /// The records a vendor returns one person in, none of them saying so in a key.
    static let records: [[(String, String)]] = [
        [("id", "0")],
        [("id", "u_5520"), ("role", "member")],
        [("object", "account_holder_ref"), ("created_at", "2026-03-04T10:22:00Z"), ("status", "active")],
    ]
    static let layouts: [FieldLayout] = [.json, .csv, .xml]

    static func scrub(_ fields: [(String, String)], _ layout: FieldLayout, seed: UInt64 = 5) throws -> (ScrubResult, String) {
        let (data, file) = PersonFields.written(fields, layout, record: "record")
        let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: seed)
        return (result, String(decoding: result.output, as: UTF8.self))
    }

    @Test(arguments: layouts)
    func aPersonsNameUnderABareNameIsNeverKeptUnseen(_ layout: FieldLayout) throws {
        for name in Self.people {
            for (index, record) in Self.records.enumerated() {
                let fields = Array(record.prefix(1)) + [("name", name)] + record.dropFirst()
                let (result, output) = try Self.scrub(fields, layout)
                let label = "[\(layout) record \(index)] \(name)"
                let finding = try #require(result.findings.first { $0.original == name }, "\(label) kept unseen:\n\(output)")
                #expect(Review.names.contains(finding.entity) && PersonFields.looksLikeName(finding.standIn), "\(label) → \(finding.entity) \(finding.standIn)")
                if finding.suspected {
                    // Left as written, it waits for a person's choice.
                    #expect(result.uncertain.contains { $0.id == finding.id }, "\(label) left as written but not put to review")
                } else {
                    #expect(!PersonFields.lowerWords(output).contains { PersonFields.lowerWords(name).contains($0) }, "\(label) leaks a word:\n\(output)")
                }
            }
        }
    }

    /// "hamish.olawale@" beside "Hamish Olawale", under any key, says the name is that person's.
    @Test(arguments: layouts)
    func anEmailThatSpellsTheNameSaysItIsAPersons(_ layout: FieldLayout) throws {
        let cases = [("user", "hamish.olawale@example.com", "Hamish Olawale"), ("login", "ysolde.b@example.org", "Ysolde Brackenridge"),
                     ("account", "tmokoena@example.net", "Thandiwe Mokoena")]
        for (key, email, name) in cases {
            let (result, output) = try Self.scrub([(key, email), ("name", name), ("event", "login")], layout)
            let finding = try #require(result.findings.first { $0.original == name }, "[\(layout)] \(name) beside \(email) kept:\n\(output)")
            #expect(!finding.suspected && !output.contains(name), "[\(layout)] \(name) beside \(email) not replaced:\n\(output)")
            #expect(!output.contains(email), "[\(layout)] \(email) kept:\n\(output)")
        }
    }

    /// One event per line, each naming a person and nothing else about them.
    @Test func aLogsEventsNamingPeopleAreNeverKeptUnseen() throws {
        let lines = Self.people.enumerated().map { #"{"ts":"2026-10-0\#($0.offset % 9 + 1)T08:00:00Z","event":"close","name":"\#($0.element)"}"# }
        for ending in ["\n", "\r\n"] {
            let text = lines.joined(separator: ending) + ending
            let result = try Scrubber.scrub(Data(text.utf8), name: "events.jsonl", forceFullDetection: false, seed: 3)
            let output = String(decoding: result.output, as: UTF8.self)
            for name in Self.people {
                let finding = try #require(result.findings.first { $0.original == name }, "\(name) kept unseen:\n\(output)")
                #expect(finding.suspected ? result.uncertain.contains { $0.id == finding.id } : !output.contains(name), "\(name):\n\(output)")
            }
        }
    }

    /// A Chinese, Japanese or Korean name written whole, plainly or escaped, is replaced
    /// as one under "full_name" is; a word that leads with no surname is no one's for sure.
    @Test func anEastAsianNameUnderABareNameIsReplaced() throws {
        let backslash = Character(UnicodeScalar(92))
        func escaped(_ text: String) -> String {
            text.unicodeScalars.map { "\(backslash)u" + String(format: "%04x", $0.value) }.joined()
        }
        for name in ["王秀英", "张伟", "歐陽靜怡", "김민준", "佐藤花子"] {
            for written in [name, escaped(name)] {
                for record in [#"{"name": "\#(written)"}"#, #"{"id": 7, "name": "\#(written)", "email": "member7@example.cn"}"#] {
                    let result = try Scrubber.scrub(Data(record.utf8), name: "profile.json", forceFullDetection: false, seed: 2)
                    let output = String(decoding: result.output, as: UTF8.self)
                    let parsed = try JSONSerialization.jsonObject(with: result.output) as? [String: Any]
                    let standIn = try #require(parsed?["name"] as? String, "\(output)")
                    #expect(standIn != name && !output.contains(written), "\(record) → \(output)")
                    #expect(result.findings.contains { $0.original == name && !$0.suspected }, "\(record): \(result.findings.map(\.original))")
                }
            }
        }
        // "文件" (a file) leads with no surname: kept as written, though asked about.
        let result = try Scrubber.scrub(Data(#"{"name": "文件", "size": 2048}"#.utf8), name: "item.json", forceFullDetection: false, seed: 2)
        #expect(String(decoding: result.output, as: UTF8.self) == #"{"name": "文件", "size": 2048}"#)
    }

    /// What a vendor names under "name" that is no one: an account, a plan, a business,
    /// a product. Kept as written, and not put to review.
    @Test(arguments: layouts)
    func aThingsNameIsNeitherReplacedNorAsked(_ layout: FieldLayout) throws {
        let things: [[(String, String)]] = [
            [("id", "acc_7712"), ("name", "Everyday Checking"), ("mask", "0000")],
            [("id", "plan_gold"), ("name", "Team plan"), ("interval", "month")],
            [("id", "org_31"), ("name", "Halberd Capital"), ("country", "US")],
            [("id", "prod_9"), ("name", "Ledgerly Cloud"), ("active", "true")],
            [("id", "src_4"), ("name", "Sanctions List Screening"), ("type", "watchlist")],
        ]
        for fields in things {
            let (result, output) = try Self.scrub(fields, layout)
            let name = fields[1].1
            #expect(output.contains(name), "[\(layout)] \(name) changed:\n\(output)")
            #expect(!result.findings.contains { $0.original.contains(name) }, "[\(layout)] \(name) found: \(result.findings.map { "\($0.entity) \($0.original)" })")
        }
        // A business's own record names it, whatever its name is written as.
        let nested = try Scrubber.scrub(Data(#"{"merchant": {"id": "m_77", "name": "Okonkwo Ventures"}}"#.utf8), name: "charge.json", forceFullDetection: false, seed: 1)
        #expect(String(decoding: nested.output, as: UTF8.self) == #"{"merchant": {"id": "m_77", "name": "Okonkwo Ventures"}}"#)
        #expect(nested.findings.isEmpty)
    }
}
