import AppKit
@testable import Scrub
import ScrubCore
import ScrubTestSupport
import Testing

/// The whole way out, on every input path: paste, scrub, choose in review
/// (leave a value in one record only, leave another everywhere, replace the
/// rest), and copy through the app's one export gate. What reaches the
/// clipboard must still parse, keep related values agreeing, hold no part
/// of any value the person did not choose to leave, and hold each value
/// they chose to leave exactly where they chose.
struct Acceptance {
    struct Person { let id, name, email, ssn, dob, written: String; let age: Int }
    static let now = Calendar(identifier: .gregorian).component(.year, from: Date())
    static let people = [
        Person(id: "cus_4TUvJhQkMeNW", name: "Odalys Ferriter", email: "odalys.ferriter@kestrel.example", ssn: "536-21-4417", dob: "1987-03-14", written: "March 14, 1987", age: now - 1987 - 1),
        Person(id: "cus_9QzRwLpXcVbN", name: "Teodoro Quillan", email: "teodoro.quillan@marrowmail.example", ssn: "601-44-4417", dob: "1990-11-02", written: "November 2, 1990", age: now - 1990 - 1),
    ]
    /// A word only the system tagger reads, as a place: always asked about.
    static let doubtful = "Brightwater"

    enum Path: String, CaseIterable { case json, csv, xml, text }

    static func document(_ path: Path) -> String {
        let p = people
        func note(_ person: Person) -> String { "\(doubtful) from billing called back, and \(doubtful) wants the invoice." }
        switch path {
        case .json:
            let rows = p.enumerated().map { index, person in
                #"{"customer_id": "\#(person.id)", "full_name": "\#(person.name)", "email": "\#(person.email)", "ssn": "\#(person.ssn)", "ssn_last4": "\#(person.ssn.suffix(4))", "date_of_birth": "\#(person.dob)", "age": \#(person.age), "referred_by": "\#(p[1 - index].id)", "note": "\#(note(person))"}"#
            }
            return #"{"customers": [\#(rows.joined(separator: ", "))], "plan": "Team", "seats": 12}"#
        case .csv:
            let rows = p.enumerated().map { index, person in "\(person.id),\(person.name),\(person.email),\(person.ssn),\(person.ssn.suffix(4)),\(person.dob),\(person.age),\(p[1 - index].id),\"\(note(person))\"" }
            return "customer_id,full_name,email,ssn,ssn_last4,date_of_birth,age,referred_by,note\n" + rows.joined(separator: "\n") + "\n"
        case .xml:
            let rows = p.enumerated().map { index, person in
                "<customer><customer_id>\(person.id)</customer_id><full_name>\(person.name)</full_name><email>\(person.email)</email><ssn>\(person.ssn)</ssn><ssn_last4>\(person.ssn.suffix(4))</ssn_last4><date_of_birth>\(person.dob)</date_of_birth><age>\(person.age)</age><referred_by>\(p[1 - index].id)</referred_by><note>\(note(person))</note></customer>"
            }
            return "<customers>\(rows.joined())</customers>"
        case .text:
            return p.enumerated().map { index, person in
                "\(person.name) (customer \(person.id), \(person.email), SSN \(person.ssn), born \(person.written)) is \(person.age) years old and was referred by \(p[1 - index].id). \(note(person)) The SSN on file ends in \(person.ssn.suffix(4))."
            }.joined(separator: "\n\n")
        }
    }

    /// One customer's values as the copied output writes them.
    struct Read { var id = "", name = "", email = "", ssn = "", last4 = "", dob = "", age = "", referredBy = "", note = "" }

    static func read(_ output: String, _ path: Path) throws -> [Read] {
        switch path {
        case .json:
            let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            return ((object?["customers"] as? [[String: Any]]) ?? []).map { r in
                func s(_ key: String) -> String { r[key].map { "\($0)" } ?? "" }
                return Read(id: s("customer_id"), name: s("full_name"), email: s("email"), ssn: s("ssn"), last4: s("ssn_last4"), dob: s("date_of_birth"), age: s("age"), referredBy: s("referred_by"), note: s("note"))
            }
        case .csv:
            let rows = try CSVReader.rows(output).dropFirst()
            return rows.map { c in Read(id: c[0], name: c[1], email: c[2], ssn: c[3], last4: c[4], dob: c[5], age: c[6], referredBy: c[7], note: c[8]) }
        case .xml:
            let document = try XMLDocument(xmlString: output)
            return try document.nodes(forXPath: "//customer").map { node in
                func s(_ name: String) -> String { ((try? node.nodes(forXPath: name))?.first?.stringValue) ?? "" }
                return Read(id: s("customer_id"), name: s("full_name"), email: s("email"), ssn: s("ssn"), last4: s("ssn_last4"), dob: s("date_of_birth"), age: s("age"), referredBy: s("referred_by"), note: s("note"))
            }
        case .text:
            let pattern = try NSRegularExpression(pattern: #"^(.+?) \(customer (\S+), (\S+@\S+), SSN (\d{3}-\d{2}-\d{4}), born ([A-Z][a-z]+ \d{1,2}, (\d{4}))\) is (\d+) years old and was referred by (\S+)\. (.+?) The SSN on file ends in (\d{4})\.$"#)
            return output.components(separatedBy: "\n\n").map { paragraph in
                let ns = paragraph as NSString
                guard let m = pattern.firstMatch(in: paragraph, range: NSRange(location: 0, length: ns.length)) else { return Read() }
                func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
                return Read(id: g(2), name: g(1), email: g(3), ssn: g(4), last4: g(10), dob: g(6), age: g(7), referredBy: g(8), note: g(9))
            }
        }
    }

    @MainActor
    static func finished(_ text: String) async throws -> (AppModel, NSPasteboard) {
        let board = NSPasteboard(name: NSPasteboard.Name("scrub-acceptance-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(text, forType: .string)
        let model = AppModel(board: board)
        model.paste()
        for _ in 0..<600 {
            if case .finished = model.state { return (model, board) }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("paste never finished")
        throw CancellationError()
    }

    @MainActor
    @Test(arguments: Path.allCases)
    func whatIsCopiedIsWhatThePersonChose(_ path: Path) async throws {
        let input = Self.document(path)
        let (model, board) = try await Self.finished(input)
        guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
        let label = "[\(path)]"

        // Leave the doubtful word in the first customer's record only, leave any
        // other uncertain finding everywhere, and replace every other.
        let place = try #require(done.result.uncertain.first { $0.original == Self.doubtful }, "\(label) \(done.result.findings)")
        try #require(place.occurrences == 4, "\(label) \(place)")
        var choices = Choices()
        let ordered = place.places.sorted { $0.id < $1.id }
        // The first customer's two mentions: their record, or in prose their two places.
        if let record = ordered[0].record { choices.set(place, leave: true, inRecord: record) } else { for one in ordered.prefix(2) { choices.set(one, leave: true) } }
        let everywhere = done.result.uncertain.first { $0.id != place.id && !$0.suspected }
        if let everywhere { choices.set(everywhere, leave: true) }

        // Copy goes through the gate: it asks first, then copies what was chosen.
        board.clearContents()
        model.copy()
        #expect(model.reviewing && board.string(forType: .string) == nil, "\(label) copied before review")
        model.finishReview(choices)
        for _ in 0..<400 where model.applyingReview || board.string(forType: .string) == nil { try await Task.sleep(for: .milliseconds(25)) }
        let output = try #require(board.string(forType: .string), "\(label) nothing copied")

        // It still parses, and each customer's values agree.
        let reads = try Self.read(output, path)
        try #require(reads.count == 2, "\(label) \(output)")
        for (read, person) in zip(reads, Self.people) {
            #expect(read.last4 == String(read.ssn.suffix(4)) && read.ssn != person.ssn, "\(label) \(read.last4) does not end \(read.ssn)")
            let year = Int(read.dob.prefix(4)) ?? Int(read.dob.suffix(4)) ?? 0
            #expect(year != 0 && [Self.now - year - 1, Self.now - year].contains(Int(read.age) ?? -1), "\(label) age \(read.age) beside \(read.dob)")
            // An address writes a surname's letters only ("O'Brien" is obrien).
            let surname = read.name.split(separator: " ").last.map { $0.lowercased().filter(\.isLetter) } ?? "?"
            #expect(read.email.lowercased().contains(surname), "\(label) \(read.email) does not follow \(read.name)")
            #expect(read.id.hasPrefix("cus_") && read.id.count == person.id.count && read.id != person.id, "\(label) record ID \(read.id)")
        }
        // A reference to a customer takes that customer's stand-in ID.
        #expect(reads[0].referredBy == reads[1].id && reads[1].referredBy == reads[0].id, "\(label) \(reads.map(\.id)) referred \(reads.map(\.referredBy))")

        // The chosen value is left in the first record only.
        #expect(reads[0].note.components(separatedBy: Self.doubtful).count == 3 && !reads[1].note.contains(Self.doubtful), "\(label) \(reads.map(\.note))")
        if let everywhere {
            #expect(output.components(separatedBy: everywhere.original).count - 1 >= everywhere.occurrences, "\(label) \(everywhere.original) not left everywhere: \(output)")
        }
        // Nothing else of anyone's: no part of a name, email, number or ID.
        let planted = Self.people.flatMap { p in
            [ComponentLeaks.Planted(p.name, kind: .name), .init(p.email, kind: .email), .init(p.ssn, kind: .number), .init(p.id, kind: .other)]
        }.filter { planted in everywhere.map { !$0.original.contains(planted.value) && !planted.value.contains($0.original) } ?? true }
        let leaked = ComponentLeaks.leaks(planted, input: input, output: output)
        #expect(leaked.isEmpty, "\(label) leaked \(leaked): \(output)")
    }
}
