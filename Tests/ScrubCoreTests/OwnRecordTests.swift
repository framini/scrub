import Foundation
import ScrubTestSupport
@testable import ScrubCore
import Testing

/// Values read off another value follow the one in their own record: last
/// four digits and a masked number end that record's SSN, an age and a
/// birth year fit that record's birth date, and a date written twice keeps
/// one day. Each document holds two or three people, two of whom share an
/// SSN's last four digits and have birth years an age could fit either way.
///
/// The oracle reads the output by the document's own shape (JSON keys, CSV
/// columns, XML elements, one paragraph a person) and checks each person's
/// values against each other; it calls nothing in ScrubCore to judge.
struct OwnRecordTests {
    struct Person {
        let name: String
        let ssn: String
        let year: Int, month: Int, day: Int
        let age: Int
        var last4: String { String(ssn.suffix(4)) }
        var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
        var written: String { "\(Self.months[month - 1]) \(day), \(year)" }
        static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    }

    static let now = Calendar(identifier: .gregorian).component(.year, from: Date())

    /// Two or three invented people. The first two share an SSN ending, and
    /// their birth years are one apart, so an age of either fits both years.
    static func people(_ seed: UInt64) -> [Person] {
        var rng = SeededGenerator(seed: seed &+ 7_919)
        let names = [["Odalys Ferriter", "Teodoro Quillan", "Brisa Vantongeren"], ["Marisol Okonkwo-Hale", "Ingvar Peltomaa", "Saoirse Delacroix"],
                     ["Thandeka Morrow", "Casimir Ravensworth", "Liesel Ambrosetti"]][Int(seed % 3)]
        let shared = String(format: "%04d", Int.random(in: 1001...9899, using: &rng))
        func ssn(_ ending: String) -> String {
            String(format: "%03d-%02d-", Int.random(in: 101...665, using: &rng), Int.random(in: 10...99, using: &rng)) + ending
        }
        let first = Int.random(in: 1960...1995, using: &rng)
        var result: [Person] = []
        for (index, name) in names.prefix(seed.isMultiple(of: 2) ? 3 : 2).enumerated() {
            let year = index == 2 ? first - 9 : first + index
            let month = Int.random(in: 1...12, using: &rng), day = Int.random(in: 13...28, using: &rng)
            // Born in `year`, so `now - year` or a year less before the birthday.
            let age = now - year - (Bool.random(using: &rng) ? 1 : 0)
            let ending = index < 2 ? shared : String(format: "%04d", Int.random(in: 1001...9899, using: &rng))
            result.append(Person(name: name, ssn: ssn(ending), year: year, month: month, day: day, age: age))
        }
        return result
    }

    enum Path: String, CaseIterable { case json, csv, xml, text }

    static func render(_ people: [Person], _ path: Path) -> (Data, String) {
        switch path {
        case .json:
            let records = people.map { p in
                #"{"full_name": "\#(p.name)", "ssn": "\#(p.ssn)", "ssn_last4": "\#(p.last4)", "masked_ssn": "***-**-\#(p.last4)", "date_of_birth": "\#(p.iso)", "dob_display": "\#(p.written)", "birth_year": \#(p.year), "birth_month": \#(p.month), "age": \#(p.age)}"#
            }
            return (Data(#"{"applicants": [\#(records.joined(separator: ", "))]}"#.utf8), "applicants.json")
        case .csv:
            let rows = people.map { p in "\(p.name),\(p.ssn),\(p.last4),***-**-\(p.last4),\(p.iso),\"\(p.written)\",\(p.year),\(p.month),\(p.age)" }
            return (Data(("full_name,ssn,ssn_last4,masked_ssn,date_of_birth,dob_display,birth_year,birth_month,age\n" + rows.joined(separator: "\n") + "\n").utf8), "applicants.csv")
        case .xml:
            let records = people.map { p in
                "<applicant><full_name>\(p.name)</full_name><ssn>\(p.ssn)</ssn><ssn_last4>\(p.last4)</ssn_last4><masked_ssn>***-**-\(p.last4)</masked_ssn><date_of_birth>\(p.iso)</date_of_birth><dob_display>\(p.written)</dob_display><birth_year>\(p.year)</birth_year><birth_month>\(p.month)</birth_month><age>\(p.age)</age></applicant>"
            }
            return (Data("<applicants>\(records.joined())</applicants>".utf8), "applicants.xml")
        case .text:
            let paragraphs = people.map { p in
                "\(p.name) (SSN \(p.ssn), born \(p.written)) is \(p.age) years old. The SSN on file ends in \(p.last4)."
            }
            return (Data(paragraphs.joined(separator: "\n\n").utf8), "applicants.txt")
        }
    }

    /// One person's values as the output writes them.
    struct Read {
        var ssn = "", last4 = "", masked = "", iso = "", written = "", year = "", month = "", age = ""
    }

    static func read(_ output: String, _ path: Path) throws -> [Read] {
        switch path {
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            let records = object?["applicants"] as? [[String: Any]] ?? []
            func text(_ value: Any?) -> String { value.map { "\($0)" } ?? "" }
            return records.map { r in
                Read(ssn: text(r["ssn"]), last4: text(r["ssn_last4"]), masked: text(r["masked_ssn"]), iso: text(r["date_of_birth"]), written: text(r["dob_display"]),
                     year: text(r["birth_year"]), month: text(r["birth_month"]), age: text(r["age"]))
            }
        case .csv:
            let rows = try CSVReader.rows(output)
            return rows.dropFirst().map { c in Read(ssn: c[1], last4: c[2], masked: c[3], iso: c[4], written: c[5], year: c[6], month: c[7], age: c[8]) }
        case .xml:
            let document = try XMLDocument(xmlString: output)
            return try document.nodes(forXPath: "//applicant").map { node in
                func text(_ name: String) -> String { ((try? node.nodes(forXPath: name))?.first?.stringValue) ?? "" }
                return Read(ssn: text("ssn"), last4: text("ssn_last4"), masked: text("masked_ssn"), iso: text("date_of_birth"), written: text("dob_display"),
                            year: text("birth_year"), month: text("birth_month"), age: text("age"))
            }
        case .text:
            let pattern = try NSRegularExpression(pattern: #"\(SSN (\d{3}-\d{2}-\d{4}), born ([A-Z][a-z]+ \d{1,2}, (\d{4}))\) is (\d+) years old\. The SSN on file ends in (\d{4})\."#)
            return output.components(separatedBy: "\n\n").map { paragraph in
                let ns = paragraph as NSString
                guard let match = pattern.firstMatch(in: paragraph, range: NSRange(location: 0, length: ns.length)) else { return Read() }
                return Read(ssn: ns.substring(with: match.range(at: 1)), last4: ns.substring(with: match.range(at: 5)), written: ns.substring(with: match.range(at: 2)),
                            year: ns.substring(with: match.range(at: 3)), age: ns.substring(with: match.range(at: 4)))
            }
        }
    }

    /// The relations that must hold within one person's output values.
    static func problems(_ read: Read, _ original: Person, _ path: Path) -> [String] {
        var found: [String] = []
        let ssnDigits = read.ssn.filter(\.isNumber)
        if read.ssn.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) == nil { found.append("ssn \(read.ssn) is no SSN") }
        if read.ssn == original.ssn { found.append("ssn kept") }
        if read.last4 != String(ssnDigits.suffix(4)) { found.append("last4 \(read.last4) does not end \(read.ssn)") }
        if read.last4 == original.last4 { found.append("last4 kept") }
        if path != .text {
            if read.masked != "***-**-" + String(ssnDigits.suffix(4)) { found.append("masked \(read.masked) does not end \(read.ssn)") }
            guard let iso = parse(read.iso) else { found.append("date \(read.iso) unreadable"); return found }
            if read.iso == original.iso { found.append("date kept") }
            if parse(read.written).map({ $0 == iso }) != true { found.append("\(read.written) is not the day \(read.iso)") }
            if Int(read.year) != iso.year { found.append("birth year \(read.year) beside \(read.iso)") }
            if Int(read.month) != iso.month { found.append("birth month \(read.month) beside \(read.iso)") }
        }
        let year = parse(read.written)?.year ?? Int(read.year) ?? 0
        if year == original.year { found.append("birth year kept") }
        if let age = Int(read.age), ![now - year - 1, now - year].contains(age) { found.append("age \(age) beside a birth in \(year)") }
        return found
    }

    static func parse(_ date: String) -> (year: Int, month: Int, day: Int)? {
        let parts = date.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) { return (year, month, day) }
        // "December 7, 1989", or "Dec 07, 1989" where the original month had three letters.
        if parts.count == 3, let month = Person.months.firstIndex(where: { $0.hasPrefix(String(parts[0])) && parts[0].count >= 3 }), let day = Int(parts[1]), let year = Int(parts[2]) { return (year, month + 1, day) }
        return nil
    }

    @Test(arguments: Path.allCases)
    func eachPersonsValuesFollowTheirOwnRecord(_ path: Path) throws {
        var issues: [String] = []
        for seed in UInt64(0)..<8 {
            let people = Self.people(seed)
            let (data, name) = Self.render(people, path)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            let reads = try Self.read(output, path)
            guard reads.count == people.count else { issues.append("[\(seed)] read \(reads.count) of \(people.count): \(output)"); continue }
            for (read, person) in zip(reads, people) {
                issues += Self.problems(read, person, path).map { "[\(seed)] \(person.name): \($0)" }
            }
            // Each owner was certain: nothing to ask about.
            issues += result.findings.filter { $0.doubt == .unclearOwner }.map { "[\(seed)] unclear owner for \($0.original)" }
            if !issues.isEmpty { issues.append("[\(seed)] \(output)"); break }
        }
        #expect(issues.isEmpty, "\(path): \(issues.joined(separator: "\n"))")
    }

    /// Where two people's numbers end alike and nothing says whose "ends in"
    /// it is, the ending still follows one of them, and review asks.
    @Test(arguments: Path.allCases)
    func anEndingTwoPeopleCouldOwnIsAskedAbout(_ path: Path) throws {
        let input: String, name: String
        switch path {
        case .json: (input, name) = (#"{"applicants": [{"full_name": "Odalys Ferriter", "ssn": "536-21-4417"}, {"full_name": "Teodoro Quillan", "ssn": "601-44-4417"}], "audit": {"ssn_last4": "4417"}}"#, "a.json")
        case .csv: (input, name) = ("full_name,ssn,ssn_last4\nOdalys Ferriter,536-21-4417,\nTeodoro Quillan,601-44-4417,\nAudit,,4417\n", "a.csv")
        case .xml: (input, name) = ("<file><applicant><full_name>Odalys Ferriter</full_name><ssn>536-21-4417</ssn></applicant><applicant><full_name>Teodoro Quillan</full_name><ssn>601-44-4417</ssn></applicant><audit><ssn_last4>4417</ssn_last4></audit></file>", "a.xml")
        case .text: (input, name) = ("Odalys Ferriter (SSN 536-21-4417) and Teodoro Quillan (SSN 601-44-4417) both called; the SSN ending in 4417 was verified.", "a.txt")
        }
        for seed in UInt64(0)..<4 {
            let result = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            #expect(!output.contains("4417"), "[\(path) \(seed)] \(output)")
            let unclear = try #require(result.findings.first { $0.doubt == .unclearOwner && $0.original == "4417" }, "[\(path) \(seed)] \(result.findings) \(output)")
            #expect(unclear.needsReview && !unclear.suspected && result.uncertain.contains(unclear))
            // It took one of the two stand-ins' endings.
            let endings = output.matches(of: /\d{3}-\d{2}-(\d{4})/).map { String($0.output.1) }
            #expect(endings.count == 2 && endings.contains(unclear.standIn), "[\(path) \(seed)] \(unclear.standIn) of \(endings): \(output)")
        }
    }
}
