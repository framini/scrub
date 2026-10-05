import Foundation
@testable import ScrubCore
import Testing

/// An ID whose type prefix is also the first name of someone the document
/// names ("pat-quillmere1987" beside Pat Quillmere) starts with that name:
/// the prefix is replaced with the rest, wherever the ID is written and
/// whether it comes before the name or after it. A prefix nobody in the
/// document is called stays a type.
struct NamedPrefixTests {
    typealias Path = IdentifierLeakTests.Path

    /// Where the ID sits: a link's path, its query, a route in its fragment, or on its own.
    enum Spot: String, CaseIterable, Sendable { case path, query, fragment, bare }

    static let person = "Pat Quillmere"
    static let id = "pat-quillmere1987"

    static func written(_ spot: Spot) -> String {
        switch spot {
        case .path: "https://crm.corvane.test/people/\(id)"
        case .query: "https://crm.corvane.test/lookup?customer_id=\(id)&tab=2"
        case .fragment: "https://crm.corvane.test/#/people/\(id)"
        case .bare: id
        }
    }

    /// The ID as the scrubbed text writes it, read the way it was written.
    static func standIn(_ output: String, _ spot: Spot) throws -> String {
        guard spot != .bare else {
            let token = try #require(output.matches(of: /[A-Za-z]+-[A-Za-z]+[0-9]+/).first, "\(output)")
            return String(token.output)
        }
        let link = try #require(IdentifierLeakTests.links(in: output).first, "no link in \(output)")
        let components = try #require(URLComponents(string: link), "not a link: \(link)")
        #expect(components.host == "crm.corvane.test", "\(link)")
        switch spot {
        case .path: return try #require(components.path.split(separator: "/").last.map(String.init), "\(link)")
        case .query: return try #require(components.queryItems?.first { $0.name == "customer_id" }?.value, "\(link)")
        case .fragment: return try #require(components.fragment?.split(separator: "/").last.map(String.init), "\(link)")
        case .bare: return ""
        }
    }

    static func render(_ value: String, nameFirst: Bool, _ path: Path) -> (Data, String) {
        let xmlValue = value.replacingOccurrences(of: "&", with: "&amp;")
        switch path {
        case .text:
            let note = nameFirst ? "\(person) uses \(value) for the renewal." : "The renewal is on \(value), which belongs to \(person)."
            return (Data(note.utf8), "note.txt")
        case .json:
            let fields = [#""full_name": "\#(person)""#, #""profile": "\#(value)""#]
            return (Data(#"{"contacts": [{\#((nameFirst ? fields : fields.reversed()).joined(separator: ", ")), "status": "active"}]}"#.utf8), "contacts.json")
        case .csv:
            let columns = nameFirst ? ["full_name", "profile"] : ["profile", "full_name"], cells = nameFirst ? [person, value] : [value, person]
            return (Data(((columns + ["status"]).joined(separator: ",") + "\n" + (cells + ["active"]).joined(separator: ",") + "\n").utf8), "contacts.csv")
        case .xml:
            let fields = ["<full_name>\(person)</full_name>", "<profile>\(xmlValue)</profile>"]
            return (Data("<contacts><contact>\((nameFirst ? fields : fields.reversed()).joined())<status>active</status></contact></contacts>".utf8), "contacts.xml")
        }
    }

    @Test(arguments: Path.allCases, Spot.allCases)
    func aFirstNameIsNoTypePrefix(_ path: Path, _ spot: Spot) throws {
        for nameFirst in [true, false] {
            for seed in UInt64(0)..<3 {
                let (data, name) = Self.render(Self.written(spot), nameFirst: nameFirst, path)
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let output = String(decoding: result.output, as: UTF8.self)
                let label = "[\(path) \(spot) nameFirst=\(nameFirst) \(seed)]"
                let left = IdentifierLeakTests.words(output)
                for piece in ["pat", "quillmere"] { #expect(!left.contains(piece), "\(label) \(piece) left in \(output)") }
                // Type oracle: an ID of the same length and kinds of character, or one
                // built as the original is from the stand-in name ("pat-quillmere1987" → "maren-holt5521").
                let standIn = try Self.standIn(output, spot)
                #expect(standIn != Self.id && (IdentifierLeakTests.shaped(standIn, like: Self.id) || standIn.wholeMatch(of: /[a-z]+-[a-z]+[0-9]{4}/) != nil),
                        "\(label) \(Self.id) → \(standIn) in \(output)")
                if path == .json { #expect((try? JSONSerialization.jsonObject(with: result.output)) != nil, "\(label)") }
                if path == .xml { #expect((try? XMLDocument(data: result.output)) != nil, "\(label)") }
            }
        }
    }

    /// The rule reads the person, not the string: with someone else named, a
    /// listed type keeps its prefix, and the same ID loses it beside a Pat.
    @Test(arguments: Path.allCases)
    func aTypeNoOneIsCalledStays(_ path: Path) throws {
        let ids = [("pat_ZqybnpAzukkun", "pat_"), ("cus_4TUvJhQkMeNW", "cus_"), ("usr-19f3a8b2", "usr-")]
        for (person, kept) in [("Odalys Ferriter", true), ("Pat Ferriter", false)] {
            let text: String
            switch path {
            case .text: text = "name: \(person)\npatient_id: \(ids[0].0)\ncustomer_id: \(ids[1].0)\nuser_id: \(ids[2].0)\n"
            case .json: text = #"{"owner": {"name": "\#(person)", "patient_id": "\#(ids[0].0)", "customer_id": "\#(ids[1].0)", "user_id": "\#(ids[2].0)"}}"#
            case .csv: text = "name,patient_id,customer_id,user_id\n\(person),\(ids.map(\.0).joined(separator: ","))\n"
            case .xml: text = "<owner><name>\(person)</name><patient_id>\(ids[0].0)</patient_id><customer_id>\(ids[1].0)</customer_id><user_id>\(ids[2].0)</user_id></owner>"
            }
            let name = "owner." + (path == .text ? "txt" : path.rawValue)
            let result = try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 3)
            for (id, prefix) in ids {
                let label = "[\(path) \(person)] \(id)"
                let finding = try #require(result.findings.first { $0.original == id }, "\(label) not found: \(result.findings.map(\.original))")
                #expect(finding.entity == "RECORD_ID" && IdentifierLeakTests.shaped(finding.standIn, like: id), "\(label) → \(finding.entity) \(finding.standIn)")
                // Only "pat_" names Pat; "cus_" and "usr-" name no one in either document.
                let keeps = kept || prefix != "pat_"
                #expect(finding.standIn.hasPrefix(prefix) == keeps, "\(label) → \(finding.standIn)")
            }
        }
    }
}

/// Several people's birth dates and parts in one record: a CSV row of
/// flattened objects ("applicant.dob", "spouse.birth_month"), a JSON record
/// with an object per person or a list of people, an XML record with a
/// child element per person. Each person's month and day follow their own
/// stand-in date, even when both were born in the same month.
struct SeveralBirthPartsTests {
    enum Shape: String, CaseIterable, Sendable { case csv, json, jsonList, xml }

    struct Person {
        let role: String, name: String, iso: String
        var month: Int { Int(iso.split(separator: "-")[1])! }
        var day: Int { Int(iso.split(separator: "-")[2])! }
    }
    /// Born in the same month, on the same day and on another.
    static let couples = [
        [Person(role: "applicant", name: "Odalys Ferriter", iso: "1988-03-14"), Person(role: "spouse", name: "Corwin Ferriter", iso: "1990-03-27")],
        [Person(role: "applicant", name: "Ysolde Varrick", iso: "1979-03-09"), Person(role: "spouse", name: "Tamsin Varrick", iso: "1983-03-09")],
    ]

    static func input(_ shape: Shape, _ couple: [Person]) -> (Data, String) {
        let fields = ["name", "dob", "birth_month", "birth_day"]
        func values(_ p: Person) -> [String] { [p.name, p.iso, String(p.month), String(p.day)] }
        switch shape {
        case .csv:
            let header = couple.flatMap { p in fields.map { "\(p.role).\($0)" } }
            let text = (["case_id"] + header).joined(separator: ",") + "\nA-1001," + couple.flatMap(values).joined(separator: ",") + "\n"
            return (Data(text.utf8), "cases.csv")
        case .json:
            let people = couple.map { p in #""\#(p.role)": {"name": "\#(p.name)", "dob": "\#(p.iso)", "birth_month": \#(p.month), "birth_day": \#(p.day)}"# }
            return (Data(#"{"case": {"case_id": "A-1001", \#(people.joined(separator: ", "))}}"#.utf8), "case.json")
        case .jsonList:
            let people = couple.map { p in #"{"role": "\#(p.role)", "name": "\#(p.name)", "dob": "\#(p.iso)", "birth_month": \#(p.month), "birth_day": \#(p.day)}"# }
            return (Data(#"{"case_id": "A-1001", "people": [\#(people.joined(separator: ", "))]}"#.utf8), "case.json")
        case .xml:
            let people = couple.map { p in "<person role=\"\(p.role)\"><name>\(p.name)</name><dob>\(p.iso)</dob><birth_month>\(p.month)</birth_month><birth_day>\(p.day)</birth_day></person>" }
            return (Data("<case><case_id>A-1001</case_id>\(people.joined())</case>".utf8), "case.xml")
        }
    }

    /// Each person's stand-in date, month and day, in the order written.
    static func read(_ output: Data, _ shape: Shape, _ couple: [Person]) throws -> [(date: String, month: String, day: String)] {
        switch shape {
        case .csv:
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            try #require(lines.count == 2)
            let header = lines[0], row = lines[1]
            return try couple.map { p in
                func cell(_ field: String) throws -> String { row[try #require(header.firstIndex(of: "\(p.role).\(field)"))] }
                return (try cell("dob"), try cell("birth_month"), try cell("birth_day"))
            }
        case .json, .jsonList:
            let root = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
            let people: [[String: Any]]
            if shape == .json {
                let record = try #require(root["case"] as? [String: Any])
                people = try couple.map { try #require(record[$0.role] as? [String: Any]) }
            } else { people = try #require(root["people"] as? [[String: Any]]) }
            return people.map { ("\($0["dob"] ?? "")", "\($0["birth_month"] ?? "")", "\($0["birth_day"] ?? "")") }
        case .xml:
            let document = try XMLDocument(data: output, options: [])
            return try document.nodes(forXPath: "//person").map { node in
                func text(_ name: String) throws -> String { try node.nodes(forXPath: name).first?.stringValue ?? "" }
                return (try text("dob"), try text("birth_month"), try text("birth_day"))
            }
        }
    }

    @Test(arguments: Shape.allCases)
    func eachPersonsPartsFollowTheirOwnDate(_ shape: Shape) throws {
        for couple in Self.couples {
            for seed in UInt64(0)..<6 {
                let (data, name) = Self.input(shape, couple)
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let rows = try Self.read(result.output, shape, couple)
                let context = "[\(shape) \(couple[0].name) \(seed)] \(String(decoding: result.output, as: UTF8.self))"
                try #require(rows.count == couple.count, "\(context)")
                for (person, row) in zip(couple, rows) {
                    let date = row.date.split(separator: "-").compactMap { Int($0) }
                    try #require(date.count == 3 && row.date.count == 10, "\(person.role): \(context)")
                    let month = try #require(Int(row.month), "\(person.role): \(context)"), day = try #require(Int(row.day), "\(person.role): \(context)")
                    #expect(month == date[1] && day == date[2], "\(person.role) parts \(month)/\(day) vs \(row.date): \(context)")
                    #expect(row.date != person.iso && month != person.month && day != person.day, "\(person.role) kept a real part: \(context)")
                }
                #expect(rows[0].date != rows[1].date, "two people share a stand-in date: \(context)")
                // Nothing to doubt: each part has one date of its own to follow.
                #expect(!result.findings.contains { $0.entity == "DATE_OF_BIRTH" && $0.needsReview }, "\(context)")
            }
        }
    }
}

/// Several people in each record, as CSV with flattened headers, JSON and
/// XML: each with a name, an ID and a profile link built from that name, a
/// birth date and its month and day, and an email. One is called Pat, a
/// first name that is also a listed ID type. No piece of anyone's name is
/// left, each person's parts agree with their own stand-in date, no two
/// people share a stand-in, each stand-in looks like what it replaces, and
/// the output parses.
struct SeveralPeopleTests {
    enum Shape: String, CaseIterable, Sendable { case csv, json, xml }

    struct Person {
        let first: String, last: String, iso: String
        var name: String { "\(first) \(last)" }
        var year: String { String(iso.prefix(4)) }
        var month: Int { Int(iso.split(separator: "-")[1])! }
        var day: Int { Int(iso.split(separator: "-")[2])! }
        var id: String { "\(first.lowercased())-\(last.lowercased())\(year)" }
        var profile: String { "https://crm.corvane.test/people/\(first.lowercased())_\(last.lowercased())" }
        var email: String { "\(first.lowercased()).\(last.lowercased())@corvane.test" }
    }
    static let roles = ["applicant", "co_applicant"]
    /// Two records of two people. Both in a record share a month of birth.
    static let records = [
        [Person(first: "Pat", last: "Quillmere", iso: "1988-03-14"), Person(first: "Odalys", last: "Ferriter", iso: "1990-03-27")],
        [Person(first: "Ysolde", last: "Varrick", iso: "1979-07-09"), Person(first: "Corwin", last: "Halloway", iso: "1983-07-21")],
    ]
    static var everyone: [Person] { records.flatMap { $0 } }
    static let fields = ["name", "customer_id", "profile_url", "dob", "birth_month", "birth_day", "email"]

    static func values(_ p: Person) -> [String] { [p.name, p.id, p.profile, p.iso, String(p.month), String(p.day), p.email] }

    static func input(_ shape: Shape) -> (Data, String) {
        switch shape {
        case .csv:
            let header = roles.flatMap { role in fields.map { "\(role).\($0)" } }
            let rows = records.map { $0.flatMap(values).joined(separator: ",") }
            return (Data((([header.joined(separator: ",")] + rows).joined(separator: "\n") + "\n").utf8), "applications.csv")
        case .json:
            let body = records.enumerated().map { index, people in
                let objects = zip(roles, people).map { role, p in
                    "\"\(role)\": {" + zip(fields, values(p)).map { key, value in
                        ["birth_month", "birth_day"].contains(key) ? "\"\(key)\": \(value)" : "\"\(key)\": \"\(value)\""
                    }.joined(separator: ", ") + "}"
                }
                return "{\"application_id\": \"APP-\(4100 + index)\", " + objects.joined(separator: ", ") + "}"
            }
            return (Data("{\"applications\": [\(body.joined(separator: ", "))]}".utf8), "applications.json")
        case .xml:
            let body = records.enumerated().map { index, people in
                "<application><application_id>APP-\(4100 + index)</application_id>" + zip(roles, people).map { role, p in
                    "<person role=\"\(role)\">" + zip(fields, values(p)).map { "<\($0)>\($1)</\($0)>" }.joined() + "</person>"
                }.joined() + "</application>"
            }
            return (Data("<applications>\(body.joined())</applications>".utf8), "applications.xml")
        }
    }

    /// Each person's fields as the output writes them, in the order written.
    static func read(_ output: Data, _ shape: Shape) throws -> [[String: String]] {
        switch shape {
        case .csv:
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            let header = try #require(lines.first)
            try #require(lines.count == records.count + 1 && lines.allSatisfy { $0.count == header.count }, "\(lines)")
            return lines.dropFirst().flatMap { row in
                roles.map { role in Dictionary(uniqueKeysWithValues: fields.compactMap { field in header.firstIndex(of: "\(role).\(field)").map { (field, row[$0]) } }) }
            }
        case .json:
            let root = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
            let applications = try #require(root["applications"] as? [[String: Any]])
            return try applications.flatMap { application in
                try roles.map { role in
                    let person = try #require(application[role] as? [String: Any])
                    return person.mapValues { "\($0)" }
                }
            }
        case .xml:
            let document = try XMLDocument(data: output, options: [])
            return try document.nodes(forXPath: "//person").map { node in
                Dictionary(uniqueKeysWithValues: try fields.map { ($0, try node.nodes(forXPath: $0).first?.stringValue ?? "") })
            }
        }
    }

    static func isName(_ value: String) -> Bool {
        let words = value.split(separator: " ")
        return words.count == 2 && words.allSatisfy { $0.first?.isUppercase == true && $0.allSatisfy { $0.isLetter || "'-".contains($0) } }
    }

    @Test(arguments: Shape.allCases)
    func everyoneKeepsTheirOwnStandIns(_ shape: Shape) throws {
        for seed in UInt64(0)..<4 {
            let (data, name) = Self.input(shape)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            let text = String(decoding: result.output, as: UTF8.self)
            let label = "[\(shape) \(seed)]"
            // The output parses, with every person where they were.
            if shape == .json { try #require((try? JSONSerialization.jsonObject(with: result.output)) != nil, "\(label) \(text)") }
            if shape == .xml { try #require((try? XMLDocument(data: result.output)) != nil, "\(label) \(text)") }
            let people = try Self.read(result.output, shape)
            try #require(people.count == Self.everyone.count, "\(label) \(text)")
            // No piece of anyone's name, three letters or more, is left anywhere.
            let left = IdentifierLeakTests.words(text)
            for person in Self.everyone {
                for piece in [person.first, person.last].map({ $0.lowercased() }) where piece.count >= 3 {
                    #expect(!left.contains(piece), "\(label) \(piece) left in \(text)")
                }
            }
            for (person, fields) in zip(Self.everyone, people) {
                let who = "\(label) \(person.name)"
                // Each stand-in looks like what it replaces.
                let name = fields["name"] ?? "", id = fields["customer_id"] ?? "", email = fields["email"] ?? "", link = fields["profile_url"] ?? ""
                #expect(Self.isName(name) && name != person.name, "\(who) name → \(name)")
                // An ID made of the name takes the stand-in name's words or fresh letters: two words and four digits either way.
                #expect(id != person.id && id.wholeMatch(of: /[a-z]+-[a-z]+[0-9]{4}/) != nil, "\(who) \(person.id) → \(id)")
                #expect(IdentifierLeakTests.isEmail(email) && email != person.email, "\(who) email → \(email)")
                let components = try #require(URLComponents(string: link), "\(who) not a link: \(link)")
                let segment = components.path.split(separator: "/").map(String.init)
                #expect(components.host == "crm.corvane.test" && segment.count == 2 && segment[0] == "people" && IdentifierLeakTests.isHandle(segment[1]), "\(who) link → \(link)")
                // The month and day are those of the person's own stand-in date.
                let date = (fields["dob"] ?? "").split(separator: "-").compactMap { Int($0) }
                try #require(date.count == 3 && (fields["dob"] ?? "").count == 10, "\(who) dob → \(fields["dob"] ?? "")")
                let month = try #require(fields["birth_month"].flatMap { Int($0) }, "\(who)"), day = try #require(fields["birth_day"].flatMap { Int($0) }, "\(who)")
                #expect((1...12).contains(month) && (1...31).contains(day), "\(who) \(month)/\(day)")
                #expect(month == date[1] && day == date[2], "\(who) parts \(month)/\(day) vs \(fields["dob"] ?? "")")
                #expect(fields["dob"] != person.iso && month != person.month && day != person.day, "\(who) kept a real part")
            }
            // No two people share a stand-in.
            for field in Self.fields where !["birth_month", "birth_day"].contains(field) {
                let made = people.map { $0[field] ?? "" }
                #expect(Set(made).count == made.count, "\(label) \(field) shared: \(made)")
            }
        }
    }
}
