import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// The shapes that hide a value, combined rather than one at a time: a name
/// found in prose with its surname alone percent-encoded in a link or split
/// by a hidden character, a hinted field inside a record's own text inside
/// another hinted record, and several people in one record. Each case is
/// judged by one oracle: no piece of an original (a word of three letters or
/// more, read decoded and without hidden characters) is left unless review
/// asks about it, each stand-in looks like its kind, and the output parses.
@Suite struct CombinedShapesTests {
    enum Shape: String, CaseIterable, Sendable { case text, json, csv, xml }

    static func output(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

    /// Text as a reader reads it, judged without Scrub's own readers: every
    /// "%XX" run decoded as UTF-8, "+" a space, characters no one sees and
    /// markup gone, in lowercase.
    static func read(_ text: String) -> String {
        var bytes: [UInt8] = []
        var units = Array(text.utf8)[...]
        while let byte = units.popFirst() {
            if byte == 37, units.count >= 2, let value = UInt8(String(decoding: units.prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(value)
                units = units.dropFirst(2)
            } else {
                bytes.append(byte == 43 ? 32 : byte)
            }
        }
        let decoded = String(decoding: bytes, as: UTF8.self)
        let hidden: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{2063}"]
        return String(decoded.filter { !hidden.contains($0) && $0 != "*" })
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression).lowercased()
    }

    /// The pieces of `originals` the output still reads, other than those a
    /// finding left for review holds.
    static func leftovers(_ originals: [String], in result: ScrubResult) -> [String] {
        let text = read(output(result))
        let asked = Set(result.uncertain.flatMap { words(read($0.original)) })
        var left: [String] = []
        for original in originals {
            for word in words(read(original)) where word.count >= 3 && !asked.contains(word) {
                let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}])"#
                if text.range(of: pattern, options: .regularExpression) != nil { left.append(word) }
            }
        }
        return left
    }
    static func words(_ text: String) -> [String] { text.split { !$0.isLetter && !$0.isNumber }.map(String.init) }

    static func parses(_ result: ScrubResult, _ shape: Shape) -> Bool {
        switch shape {
        case .json: return (try? JSONSerialization.jsonObject(with: result.output)) != nil
        case .xml: return XMLParser(data: result.output).parse()
        case .csv: return (try? CSVReader.rows(output(result))).map { Set($0.map(\.count)).count == 1 } ?? false
        case .text: return true
        }
    }

    // Type oracles: what each kind's stand-in must look like.
    static func isName(_ value: String) -> Bool {
        let words = value.split(separator: " ")
        return (2...3).contains(words.count) && words.allSatisfy { $0.first?.isLetter == true && $0.allSatisfy { $0.isLetter || "'-.".contains($0) } }
    }
    static func isEmail(_ value: String) -> Bool { value.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil }
    static func isPhone(_ value: String) -> Bool { value.filter(\.isNumber).count >= 10 && !value.contains(where: \.isLetter) }
    static func isSSN(_ value: String) -> Bool { value.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) != nil }
    static func shape(_ value: String) -> String { String(value.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 }) }

    /// The values under `key` wherever the output holds them, as the format reads them.
    static func values(_ key: String, in result: ScrubResult, _ shape: Shape) throws -> [String] {
        switch shape {
        case .xml:
            let document = try XMLDocument(data: result.output, options: [])
            return try document.nodes(forXPath: "//*[local-name()='\(key)']").compactMap(\.stringValue)
        case .json:
            func walk(_ value: Any) -> [String] {
                if let object = value as? [String: Any] { return object.flatMap { name, inner in name == key ? [inner as? String].compactMap { $0 } : walk(inner) } }
                if let array = value as? [Any] { return array.flatMap(walk) }
                return []
            }
            return walk(try JSONSerialization.jsonObject(with: result.output))
        case .csv:
            let rows = try CSVReader.rows(output(result))
            guard let header = rows.first, let column = header.firstIndex(of: key) else { return [] }
            return rows.dropFirst().compactMap { $0.indices.contains(column) ? $0[column] : nil }
        case .text:
            return []
        }
    }

    static func name(_ shape: Shape, _ base: String) -> String { base + "." + (shape == .text ? "txt" : shape.rawValue) }

    // MARK: A name found in prose, its surname encoded or split elsewhere

    /// A name found in prose, with its surname alone in a link's query
    /// percent-encoded, in a link's path encoded around a hidden character,
    /// and split by a hidden character in prose: found or marked, no form is left.
    static func encodedFragments(_ shape: Shape) -> String {
        let search = "https://desk.corvane.test/find?q=%4Cisk&page=2", profile = "https://desk.corvane.test/people/%4Ci%E2%80%8Bsk"
        let note = "Spoke with Harrowgate Lisk (harrowgate.lisk@corvane.test) about the refund; Li\u{200B}sk will call back"
        switch shape {
        case .text: return "\(note).\nSearch: \(search)\nProfile: \(profile)\nPhone: +1 (415) 867-2290\n"
        case .json: return #"{"ticket": {"customer": "Harrowgate Lisk", "email": "harrowgate.lisk@corvane.test", "note": "\#(note)", "search": "\#(search)", "profile": "\#(profile)"}}"#
        case .csv: return "customer,email,note,search,profile\nHarrowgate Lisk,harrowgate.lisk@corvane.test,\(note),\(search),\(profile)\n"
        case .xml:
            return "<tickets><ticket><customer>Harrowgate Lisk</customer><email>harrowgate.lisk@corvane.test</email><note>\(note)</note>"
                + "<search>\(search.replacingOccurrences(of: "&", with: "&amp;"))</search><profile>\(profile)</profile></ticket></tickets>"
        }
    }

    @Test(arguments: Shape.allCases)
    func aFoundNamesEncodedAndSplitFragmentsAreReplaced(_ shape: Shape) throws {
        let input = Self.encodedFragments(shape)
        for seed in UInt64(0)..<3 {
            let result = try Scrubber.scrub(Data(input.utf8), name: Self.name(shape, "ticket"), forceFullDetection: false, seed: seed)
            let after = Self.output(result)
            #expect(Self.leftovers(["Harrowgate Lisk", "harrowgate.lisk"], in: result).isEmpty, "[\(shape) \(seed)] \(Self.leftovers(["Harrowgate Lisk"], in: result)): \(after)")
            #expect(Self.parses(result, shape), "[\(shape) \(seed)] \(after)")
            #expect(!after.contains("%E2%80%8B") && !after.contains("\u{200B}"), "[\(shape) \(seed)] \(after)")
            // The surname's stand-in in the links is the name's, written as each link needs.
            let person = try #require(result.findings.first { $0.entity == "PERSON" && $0.original == "Harrowgate Lisk" }, "[\(shape) \(seed)] \(after)")
            #expect(Self.isName(person.standIn), "\(person.standIn)")
            let surname = try #require(person.standIn.split(separator: " ").last.map(String.init))
            let q = try #require(after.range(of: #"\?q=[^&\s"<,]*"#, options: .regularExpression).map { String(after[$0].dropFirst(3)) })
            #expect(Self.read(q) == surname.lowercased() && q.allSatisfy { $0.isLetter || $0.isNumber || "%+-._~".contains($0) }, "[\(shape) \(seed)] \(q) vs \(person.standIn)")
            let segment = try #require(after.range(of: #"/people/[^\s"<,]*"#, options: .regularExpression).map { String(after[$0].dropFirst(8)) })
            #expect(Self.read(segment) == surname.lowercased() && !segment.contains(" "), "[\(shape) \(seed)] \(segment) vs \(person.standIn)")
            if shape != .text {
                for email in try Self.values("email", in: result, shape) { #expect(Self.isEmail(email) && !email.contains("lisk"), "\(email)") }
                for customer in try Self.values("customer", in: result, shape) { #expect(Self.isName(customer) && customer == person.standIn, "\(customer)") }
            }
        }
    }

    /// The same text with the name marked by hand as well: marking a found
    /// name keeps its stand-in and leaves no fragment either.
    @Test(arguments: Shape.allCases)
    func aMarkedNamesEncodedAndSplitFragmentsAreReplaced(_ shape: Shape) throws {
        let input = Self.encodedFragments(shape).replacingOccurrences(of: "Harrowgate Lisk", with: "harrowgate lisk").replacingOccurrences(of: "Spoke with ", with: "Rota: ")
        let result = try Scrubber.scrub(Data(input.utf8), name: Self.name(shape, "rota"), forceFullDetection: false, seed: 5)
        let (choices, marks) = result.marking(["harrowgate lisk"], as: "PERSON", choices: result.choices, marks: Marks())
        let marked = try result.applying(choices, marks: marks)
        let after = Self.output(marked)
        #expect(Self.leftovers(["harrowgate lisk", "harrowgate.lisk"], in: marked).isEmpty, "[\(shape)] \(Self.leftovers(["harrowgate lisk"], in: marked)): \(after)")
        #expect(Self.parses(marked, shape), "[\(shape)] \(after)")
        #expect(!after.contains("%E2%80%8B") && !after.contains("\u{200B}"), "[\(shape)] \(after)")
        let standIn = try #require(marked.byHand.first?.standIn)
        #expect(Self.isName(standIn), "\(standIn)")
    }

    // MARK: Nested field hints

    /// A hinted field inside a record's own text, inside another hinted
    /// record, itself inside text of its parent's.
    static let nested = """
        <accounts><customer>Active since 2019 <name>Odalys Ferriter</name>\
        <contact>Primary <email>odalys.ferriter@corvane.test</email> or <phone>+1 (415) 867-2290</phone> after six</contact>\
        <identity>Checked <b>twice</b>: <data name="national_id">ZX4829137</data> and <field key="ssn">536-21-7784</field> on file</identity>\
        <emergency_contact>Spouse <name>Bram Quillmere</name>, reach at <phone>+1 (628) 555-0147</phone></emergency_contact>\
        <note>Spoke with <i>Odal</i>ys about Bram's <span name="password">Tamsel!Brook-2291</span> reset</note></customer></accounts>
        """

    @Test func aHintedFieldInMixedContentInsideAHintedRecordKeepsItsKey() throws {
        for seed in UInt64(0)..<3 {
            let result = try Scrubber.scrub(Data(Self.nested.utf8), name: "accounts.xml", forceFullDetection: false, seed: seed)
            let after = Self.output(result)
            #expect(XMLParser(data: result.output).parse(), "[\(seed)] \(after)")
            let left = Self.leftovers(["Odalys Ferriter", "odalys.ferriter", "Bram Quillmere"], in: result)
            #expect(left.isEmpty, "[\(seed)] \(left): \(after)")
            for original in ["ZX4829137", "536-21-7784", "Tamsel!Brook-2291", "867-2290", "555-0147"] {
                #expect(!after.contains(original) || result.uncertain.contains { $0.original.contains(original) }, "[\(seed)] \(original): \(after)")
            }
            let names = try Self.values("name", in: result, .xml)
            #expect(names.count == 2 && names.allSatisfy(Self.isName) && Set(names).count == 2, "[\(seed)] \(names)")
            for email in try Self.values("email", in: result, .xml) { #expect(Self.isEmail(email), "\(email)") }
            for phone in try Self.values("phone", in: result, .xml) { #expect(Self.isPhone(phone), "\(phone)") }
            let document = try XMLDocument(data: result.output, options: [])
            let id = try #require(try document.nodes(forXPath: "//data[@name='national_id']").first?.stringValue)
            #expect(id != "ZX4829137" && Self.shape(id) == Self.shape("ZX4829137"), "\(id)")
            let ssn = try #require(try document.nodes(forXPath: "//field[@key='ssn']").first?.stringValue)
            #expect(ssn != "536-21-7784" && Self.isSSN(ssn), "\(ssn)")
            let password = try #require(try document.nodes(forXPath: "//span[@name='password']").first?.stringValue)
            #expect(password != "Tamsel!Brook-2291" && !password.isEmpty && !password.contains(where: \.isWhitespace), "\(password)")
            // The records' own words stay.
            for words in ["Active since 2019", "Primary", "after six", "Checked", "on file", "Spouse", "reset"] { #expect(after.contains(words), "[\(seed)] \(words): \(after)") }
        }
    }

    // MARK: Several people in one record

    /// Two people in one record, each with their own fields, and a note that
    /// names both, one surname alone percent-encoded in a link.
    static func twoPeople(_ shape: Shape) -> String {
        let note = "Odalys Ferriter and Bram Quillmere signed; see https://files.corvane.test/find?who=%51uillmere"
        switch shape {
        case .text:
            return """
            Applicant: Odalys Ferriter <odalys.ferriter@corvane.test>, SSN 536-21-7784
            Guarantor: Bram Quillmere, phone +1 (628) 555-0147, bram.quillmere@corvane.test
            \(note)

            """
        case .json:
            return #"{"case": {"applicant": {"name": "Odalys Ferriter", "email": "odalys.ferriter@corvane.test", "ssn": "536-21-7784"}, "#
                + #""guarantor": {"name": "Bram Quillmere", "phone": "+1 (628) 555-0147", "email": "bram.quillmere@corvane.test"}, "note": "\#(note)"}}"#
        case .csv:
            return "applicant_name,applicant_email,applicant_ssn,guarantor_name,guarantor_phone,guarantor_email,note\n"
                + "Odalys Ferriter,odalys.ferriter@corvane.test,536-21-7784,Bram Quillmere,+1 (628) 555-0147,bram.quillmere@corvane.test,\(note)\n"
        case .xml:
            return "<cases><case><applicant>Signed <name>Odalys Ferriter</name><email>odalys.ferriter@corvane.test</email><ssn>536-21-7784</ssn></applicant>"
                + "<guarantor>Pending <name>Bram Quillmere</name><phone>+1 (628) 555-0147</phone><email>bram.quillmere@corvane.test</email></guarantor>"
                + "<note>\(note)</note></case></cases>"
        }
    }

    @Test(arguments: Shape.allCases)
    func severalPeopleInOneRecordEachKeepTheirOwnStandIns(_ shape: Shape) throws {
        let input = Self.twoPeople(shape)
        for seed in UInt64(0)..<3 {
            let result = try Scrubber.scrub(Data(input.utf8), name: Self.name(shape, "case"), forceFullDetection: false, seed: seed)
            let after = Self.output(result)
            #expect(Self.parses(result, shape), "[\(shape) \(seed)] \(after)")
            let left = Self.leftovers(["Odalys Ferriter", "odalys.ferriter", "Bram Quillmere", "bram.quillmere"], in: result)
            #expect(left.isEmpty, "[\(shape) \(seed)] \(left): \(after)")
            for original in ["536-21-7784", "555-0147"] { #expect(!after.contains(original), "[\(shape) \(seed)] \(original): \(after)") }
            let first = try #require(result.findings.first { $0.entity == "PERSON" && $0.original == "Odalys Ferriter" }, "[\(shape) \(seed)] \(after)")
            let second = try #require(result.findings.first { $0.entity == "PERSON" && $0.original == "Bram Quillmere" }, "[\(shape) \(seed)] \(after)")
            #expect(Self.isName(first.standIn) && Self.isName(second.standIn) && first.standIn != second.standIn, "\(first.standIn) / \(second.standIn)")
            // The encoded surname is the guarantor's.
            let who = try #require(after.range(of: #"who=[^&\s"<,]*"#, options: .regularExpression).map { String(after[$0].dropFirst(4)) })
            #expect(Self.read(who) == second.standIn.split(separator: " ").last.map { $0.lowercased() }, "[\(shape) \(seed)] \(who) vs \(second.standIn)")
            switch shape {
            case .text:
                #expect(after.range(of: #"SSN \d{3}-\d{2}-\d{4}"#, options: .regularExpression) != nil, "\(after)")
            case .csv:
                for (key, fits) in [("applicant_name", Self.isName), ("guarantor_name", Self.isName), ("applicant_email", Self.isEmail), ("guarantor_email", Self.isEmail),
                                    ("applicant_ssn", Self.isSSN), ("guarantor_phone", Self.isPhone)] as [(String, (String) -> Bool)] {
                    let found = try Self.values(key, in: result, shape)
                    #expect(found.count == 1 && found.allSatisfy(fits), "\(key): \(found)")
                }
            case .json, .xml:
                let names = try Self.values("name", in: result, shape)
                #expect(Set(names) == [first.standIn, second.standIn], "\(names)")
                let emails = try Self.values("email", in: result, shape)
                #expect(emails.count == 2 && emails.allSatisfy(Self.isEmail) && Set(emails).count == 2, "\(emails)")
                for ssn in try Self.values("ssn", in: result, shape) { #expect(Self.isSSN(ssn), "\(ssn)") }
                for phone in try Self.values("phone", in: result, shape) { #expect(Self.isPhone(phone), "\(phone)") }
            }
        }
    }
}
