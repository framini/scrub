import Foundation
@testable import ScrubCore
import Testing

/// A title says whether a person is a woman or a man ("Ms Ferriter", "Mr
/// Vasquelle"), and their stand-in first name says the same, wherever the
/// document writes the title: before the first name, after it, or beside the
/// full name somewhere else. Two titles that disagree make a name given to
/// either. In every case the person keeps one stand-in throughout.
struct StandInGenderTests {
    enum Gender: String { case female, male, either }
    static func gender(of name: Substring) -> Gender? {
        let folded = name.lowercased()
        if Names.female.contains(folded) { return .female }
        if Names.male.contains(folded) { return .male }
        return Names.firstFolded.contains(folded) ? .either : nil
    }

    /// The note from `ConsistencyTests`, and the same shape for a man: the
    /// greeting names him first, the title comes only later, on his surname.
    static let man = """
    Hi Corentin,

    Mr Vasquelle moved to Tacoma last spring and now works at Ferngill Tooling. Corentin said the Tacoma office needs his badge.
    can you ask ifeoma to resend the form? Reach him at corentin.vasquelle@lorvane.test or 253-555-0117.

    Thanks,
    Maelle
    """

    @Test func aTitleAfterTheFirstNameSetsItsGender() throws {
        for (note, title, pronoun, gender, originals) in [
            (ConsistencyTests.note, "Ms", "her", Gender.female, ["Odalys", "Ferriter", "oluwaseun", "Tamsin"]),
            (Self.man, "Mr", "his", Gender.male, ["Corentin", "Vasquelle", "ifeoma", "Maelle"]),
        ] {
            for seed in UInt64(0)..<8 {
                for path in PIIGaps.InputPath.allCases {
                    let (output, result) = try SpreadTests.scrub(note, path, seed: seed)
                    let label = "[\(path) seed \(seed)] \(output)"
                    #expect(SpreadTests.gone(originals, from: output).isEmpty, "\(label)")
                    let greeted = try #require(output.firstMatch(of: /^Hi ([^,\s]+),/)?.1, "\(label)")
                    let said = try #require(output.firstMatch(of: /\. (\S+) said the/)?.1, "\(label)")
                    let surname = try #require(output.firstMatch(of: try Regex("\(title) (\\S+) moved"))?.output[1].substring, "\(label)")
                    let email = try #require(output.firstMatch(of: /at ([^@\s]+)@([a-z0-9.-]+\.[a-z]+) or/), "\(label)")
                    #expect(Self.gender(of: greeted) == gender, "a \(title) gets a \(gender) name: \(label)")
                    #expect(greeted == said && ConsistencyTests.isName(greeted) && ConsistencyTests.isName(surname), "\(label)")
                    #expect(output.contains("needs \(pronoun) badge"), "\(label)")
                    #expect(email.1 == ConsistencyTests.folded(greeted) + "." + ConsistencyTests.folded(surname), "\(label)")
                    let finding = try #require(result.findings.first { $0.original == originals[0] }, "\(result.findings)")
                    #expect(finding.standIn == String(greeted) && finding.occurrences == 2, "\(label) \(result.findings)")
                }
            }
        }
    }

    /// The full name first, untitled, and the title on the surname later; in
    /// a note, in a CSV whose rows name her in different cells, and in JSON
    /// whose name sits in fields of its own.
    @Test func aTitleBesideTheSurnameFitsTheFullNameElsewhere() throws {
        let text = "Odalys Ferriter opened the ticket on Monday.\nMrs Ferriter called back on Tuesday about the refund.\nHi Odalys, the refund is approved."
        let csv = "ticket,contact,remark\n4471,Odalys Ferriter,opened the ticket on Monday\n4472,,Mrs Ferriter called back on Tuesday about the refund.\n4473,,\"Hi Odalys, the refund is approved.\"\n"
        let json = #"{"tickets": [{"id": 4471, "contact": {"first_name": "Odalys", "last_name": "Ferriter"}, "remark": "opened the ticket on Monday"}, {"id": 4472, "remark": "Mrs Ferriter called back on Tuesday about the refund."}, {"id": 4473, "remark": "Hi Odalys, the refund is approved."}]}"#
        for seed in UInt64(0)..<8 {
            for path in PIIGaps.InputPath.allCases {
                let (output, _) = try SpreadTests.scrub(text, path, seed: seed)
                let full = try #require(output.firstMatch(of: /^(\S+) (\S+) opened the ticket/), "[\(path)] \(output)")
                try Self.expectHers((full.1, full.2), in: output, "[\(path) seed \(seed)]")
            }
            let table = try Scrubber.scrub(Data(csv.utf8), name: "tickets.csv", forceFullDetection: false, seed: seed)
            let rows = try CSVFile.parse(String(decoding: table.output, as: UTF8.self), delimiter: ",")
            #expect(rows.count == 4 && rows.allSatisfy { $0.count == 3 } && rows.dropFirst().map { $0[0] } == ["4471", "4472", "4473"], "\(rows)")
            let contact = try #require(rows[1][1].firstMatch(of: /^(\S+) (\S+)$/), "\(rows)")
            try Self.expectHers((contact.1, contact.2), in: rows.dropFirst().map { $0[2] }.joined(separator: "\n"), "[csv rows, seed \(seed)]")
            let object = try Scrubber.scrub(Data(json.utf8), name: "tickets.json", forceFullDetection: false, seed: seed)
            let tickets = try #require((JSONSerialization.jsonObject(with: object.output) as? [String: Any])?["tickets"] as? [[String: Any]])
            #expect(tickets.map { $0["id"] as? Int } == [4471, 4472, 4473], "\(tickets)")
            let name = try #require(tickets[0]["contact"] as? [String: String])
            let first = try #require(name["first_name"]), last = try #require(name["last_name"])
            #expect(name.count == 2, "\(name)")
            try Self.expectHers((Substring(first), Substring(last)), in: tickets.compactMap { $0["remark"] as? String }.joined(separator: "\n"), "[json fields, seed \(seed)]")
        }
    }

    static func expectHers(_ full: (Substring, Substring), in output: String, _ label: String) throws {
        #expect(SpreadTests.gone(["Odalys", "Ferriter"], from: output).isEmpty, "\(label) \(output)")
        #expect(ConsistencyTests.isName(full.0) && ConsistencyTests.isName(full.1), "\(label) \(output)")
        #expect(gender(of: full.0) == .female, "Mrs makes her first name a woman's: \(label) \(output)")
        #expect(output.contains("Mrs \(full.1) called back"), "\(label) \(output)")
        #expect(output.contains("Hi \(full.0), the refund"), "\(label) \(output)")
    }

    /// A gender written in a field of the record ("title": "Ms") and the name
    /// in fields beside it, in JSON and in a CSV row.
    @Test func aTitleFieldFitsTheRecordsName() throws {
        let json = #"{"customers": [{"title": "Ms", "first_name": "Odalys", "last_name": "Ferriter", "remark": "Odalys asked for a callback."}, {"title": "Mr", "first_name": "Corentin", "last_name": "Vasquelle", "remark": "Corentin paid by transfer."}]}"#
        let csv = "title,first_name,last_name,remark\nMs,Odalys,Ferriter,Odalys asked for a callback.\nMr,Corentin,Vasquelle,Corentin paid by transfer.\n"
        for seed in UInt64(0)..<8 {
            let object = try Scrubber.scrub(Data(json.utf8), name: "customers.json", forceFullDetection: false, seed: seed)
            let customers = try #require((JSONSerialization.jsonObject(with: object.output) as? [String: Any])?["customers"] as? [[String: String]])
            let table = try Scrubber.scrub(Data(csv.utf8), name: "customers.csv", forceFullDetection: false, seed: seed)
            let rows = try CSVFile.parse(String(decoding: table.output, as: UTF8.self), delimiter: ",")
            #expect(rows.count == 3 && rows[0] == ["title", "first_name", "last_name", "remark"], "\(rows)")
            let records = customers.map { [$0["title"] ?? "", $0["first_name"] ?? "", $0["last_name"] ?? "", $0["remark"] ?? ""] } + rows.dropFirst().map(Array.init)
            for (index, record) in records.enumerated() {
                let label = "[seed \(seed) record \(index)] \(records)"
                let (gender, said): (Gender, String) = record[0] == "Ms" ? (.female, "asked for a callback.") : (.male, "paid by transfer.")
                #expect(["Ms", "Mr"].contains(record[0]) && record[0] == (index % 2 == 0 ? "Ms" : "Mr"), "the title stays: \(label)")
                #expect(Self.gender(of: Substring(record[1])) == gender && ConsistencyTests.isName(Substring(record[2])), "\(label)")
                #expect(record[3] == "\(record[1]) \(said)", "\(label)")
            }
        }
    }

    /// "Mr Ferriter" and "Mrs Ferriter", taken for one person, in either
    /// order: a first name given to either, kept the same everywhere. That
    /// holds where the first name could be either sex's ("Quinn"); a first
    /// name clearly a woman's ("Odalys") is Mrs Ferriter's alone, and Mr
    /// Ferriter is another person of the same stand-in surname (TitleGenderTests).
    @Test func titlesThatDisagreeGiveANameForEither() throws {
        for (first, expected) in [("Quinn", Gender.either), ("Odalys", Gender.female)] {
            let notes = [
                "Hi \(first),\n\nMr Ferriter phoned on Monday and Mrs Ferriter phoned on Tuesday. \(first) said the refund can wait.",
                "Hi \(first),\n\nMrs Ferriter phoned on Monday and Mr Ferriter phoned on Tuesday. \(first) said the refund can wait.",
            ]
            for note in notes {
                for seed in UInt64(0)..<6 {
                    for path in PIIGaps.InputPath.allCases {
                        let (output, _) = try SpreadTests.scrub(note, path, seed: seed)
                        let label = "[\(first) \(path) seed \(seed)] \(output)"
                        #expect(SpreadTests.gone([first, "Ferriter"], from: output).isEmpty, "\(label)")
                        let greeted = try #require(output.firstMatch(of: /^Hi ([^,\s]+),/)?.1, "\(label)")
                        let surnames = output.matches(of: /Mr?s? (\S+) phoned/).map(\.1)
                        #expect(Self.gender(of: greeted) == expected, "\(label)")
                        #expect(output.contains(". \(greeted) said"), "\(label)")
                        #expect(surnames.count == 2 && Set(surnames).count == 1, "\(label)")
                    }
                }
            }
        }
    }

    /// The rules on their own: a later title redraws a name not yet written;
    /// one already written stays; a disagreement stays whatever follows.
    @Test func aWrittenFirstNameStaysAndDisagreementStays() {
        for seed in UInt64(0)..<40 {
            let people = People(rng: SeededGenerator(seed: seed))
            let odalys = people.register("Odalys", nil)
            #expect(people.registerFull("Ms Ferriter").0 === odalys)
            #expect(Self.gender(of: Substring(odalys.first)) == .female, "seed \(seed): \(odalys.full)")

            let shown = People(rng: SeededGenerator(seed: seed))
            let written = shown.register("Corentin", nil).first
            let corentin = shown.registerFull("Ms Vasquelle").0
            #expect(corentin.first == written, "a name already written stays: seed \(seed)")

            // A first name either sex is given: the two titles disagree, and stay so.
            let both = People(rng: SeededGenerator(seed: seed))
            let person = both.register("Quinn", nil)
            _ = both.registerFull("Mr Ferriter")
            _ = both.registerFull("Mrs Ferriter")
            _ = both.register("Quinn", "Ferriter", gender: "female")
            #expect(person.gender == "either" && Self.gender(of: Substring(person.first)) == .either, "seed \(seed): \(person.full)")

            // A woman's first name: "Mr Ferriter" is someone else, of the same stand-in surname.
            let family = People(rng: SeededGenerator(seed: seed))
            let her = family.register("Odalys", nil)
            let him = family.registerFull("Mr Ferriter").0
            #expect(family.registerFull("Mrs Ferriter").0 === her && him !== her && him.last == her.last, "seed \(seed)")
            #expect(Self.gender(of: Substring(her.first)) == .female && Self.gender(of: Substring(him.first)) == .male, "seed \(seed): \(her.full), \(him.full)")
        }
    }
}
