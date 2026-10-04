import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// One value is one value however it is written, and two people are two
/// people however alike their names. A name's apostrophe straight, curly or
/// left out, and its hyphen as a space or nothing, read the same when a
/// replacement is checked, whichever way the original wrote it. A value
/// selected encoded or split in the preview is marked as the value it reads,
/// so the mark reaches it plainly too, and taking the mark off undoes every
/// place. An edit to one person's first name never reaches another person
/// who shares it.
@Suite struct EditEquivalenceTests {
    typealias Finding = ScrubCore::Finding
    enum Shape: String, CaseIterable, Sendable { case text, json, csv, xml }

    static func scrub(_ text: String, _ shape: Shape, name: String, seed: UInt64 = 41) throws -> ScrubResult {
        try Scrubber.scrub(Data(text.utf8), name: name + "." + (shape == .text ? "txt" : shape.rawValue), forceFullDetection: false, seed: seed)
    }

    static func output(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

    static func refused(_ result: ScrubResult, _ typed: String, for finding: Finding) -> Bool {
        guard result.refusal(typed, for: [finding]) != nil else { return false }
        do {
            _ = try result.editing([finding], kind: nil, replacement: typed, choices: result.choices, marks: result.marks, edits: result.edits)
            return false
        } catch { return error is Refusal }
    }

    /// What a selection of `needle` in the preview picks, inside the first
    /// place `context` is written (a table's cell that is `context`, or else
    /// holds it); with `click`, a click inside it.
    static func pick(_ result: ScrubResult, _ needle: String, in context: String? = nil, click: Bool = false) -> Pick? {
        func at(_ text: String, _ marks: [Mark]) -> Pick? {
            let ns = text as NSString
            let around = context.map { ns.range(of: $0) } ?? NSRange(location: 0, length: ns.length)
            guard around.location != NSNotFound else { return nil }
            let found = ns.range(of: needle, range: around)
            guard found.location != NSNotFound else { return nil }
            let range = click ? (found.location + 1)..<(found.location + 1) : found.location..<NSMaxRange(found)
            return result.pick(in: text, marks: marks, range: range)
        }
        switch result.preview {
        case .text(let text, let marks, _): return at(text, marks)
        case .table(_, let rows, _, let marks):
            let cells = rows.enumerated().flatMap { row, cells in cells.enumerated().map { (row, $0.offset, $0.element) } }
            let wanted = context ?? needle
            guard let cell = cells.first(where: { $0.2 == wanted }) ?? cells.first(where: { $0.2.contains(wanted) }) else { return nil }
            return at(cell.2, marks.filter { $0.row == cell.0 && $0.column == cell.1 }.map { Mark(range: $0.range, entity: $0.entity) })
        }
    }

    // MARK: An apostrophe or a hyphen hides nothing

    /// A tenancy whose tenant's surname has an apostrophe, written with
    /// `apostrophe`, and whose co-signer, named in its notes, has a hyphen.
    static func tenancy(_ shape: Shape, apostrophe: String) -> String {
        let tenant = "Tomasz O\(apostrophe)Sullivan", email = "tomasz.osullivan@kestrel.example"
        let notes = "Co-signed by Brisa Smith-Jones. Tomasz called on Monday about the boiler."
        switch shape {
        case .text: return "Tenancy for \(tenant) (\(email)). \(notes)\n"
        case .json: return #"{"tenant_name":"\#(tenant)","email":"\#(email)","notes":"\#(notes)"}"#
        case .csv: return "tenant_name,email,notes\n\(tenant),\(email),\(notes)\n"
        case .xml: return "<tenancy><tenant_name>\(tenant)</tenant_name><email>\(email)</email><notes>\(notes)</notes></tenancy>"
        }
    }

    /// Straight in the file and curly typed, curly in the file and straight
    /// typed, or left out: one surname.
    @Test(arguments: Shape.allCases, ["'", "\u{2019}"])
    func anApostropheReadsTheSameEveryWay(_ shape: Shape, _ apostrophe: String) throws {
        let result = try Self.scrub(Self.tenancy(shape, apostrophe: apostrophe), shape, name: "tenancy")
        let tenant = try #require(result.findings.first { Review.names.contains($0.entity) && $0.original.hasSuffix("Sullivan") && $0.original.hasPrefix("Tomasz") }, "\(shape): \(result.findings.map(\.original))")
        let cosigner = try #require(result.findings.first { Review.names.contains($0.entity) && $0.original == "Brisa Smith-Jones" }, "\(shape): \(result.findings.map(\.original))")
        for written in ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "\u{2032}", "`", "\u{FF07}", "", " "] {
            // Her surname kept, whichever apostrophe it is typed with, or none.
            for typed in ["Jane O\(written)Sullivan", "JANE O\(written)SULLIVAN", "Jane Roe-O\(written)Sullivan", "Tomasz O\(written)Sullivan", "o\(written)sullivan.jane"] {
                #expect(Self.refused(result, typed, for: tenant), "\(shape) \(apostrophe): \(typed)")
            }
            // Another person's surname is no one else's replacement either.
            #expect(Self.refused(result, "Jane O\(written)Sullivan", for: cosigner), "\(shape) \(apostrophe): \(written)")
        }
        // Her own name, written another way, is the value it replaces.
        #expect(result.refusal("Tomasz OSullivan", for: [tenant]) == .original, "\(shape) \(apostrophe)")
        #expect(result.refusal(apostrophe == "'" ? "Tomasz O\u{2019}Sullivan" : "Tomasz O'Sullivan", for: [tenant]) == .original, "\(shape) \(apostrophe)")
        // Her names joined as a handle is, apostrophe or not.
        for typed in ["tosullivan", "osullivan99", "tomaszosullivan", "osullivantomasz", "tomaszo\(apostrophe)sullivan"] { #expect(Self.refused(result, typed, for: tenant), "\(shape) \(apostrophe): \(typed)") }
        // A short word of hers alone is no match: "O" is anyone's.
        for typed in ["Jane O. Roe", "Jane O'Brien", "Jane Olsen", "Jane Sully", "O Roe"] {
            #expect(result.refusal(typed, for: [tenant]) == nil, "\(shape) \(apostrophe): \(typed) → \(String(describing: result.refusal(typed, for: [tenant])))")
        }
    }

    /// A hyphen read as a space or as nothing, both ways: the co-signer's
    /// "Smith-Jones" is "Smith Jones" and "SmithJones".
    @Test(arguments: Shape.allCases)
    func aHyphenReadsAsASpaceOrNothing(_ shape: Shape) throws {
        let result = try Self.scrub(Self.tenancy(shape, apostrophe: "'"), shape, name: "tenancy")
        let tenant = try #require(result.findings.first { Review.names.contains($0.entity) && $0.original == "Tomasz O'Sullivan" }, "\(shape): \(result.findings.map(\.original))")
        let cosigner = try #require(result.findings.first { Review.names.contains($0.entity) && $0.original == "Brisa Smith-Jones" }, "\(shape): \(result.findings.map(\.original))")
        for typed in ["Jane SmithJones", "Jane Smith Jones", "Jane Smith\u{2013}Jones", "Jane SMITHJONES", "jane.smithjones", "Jane Jones"] {
            #expect(Self.refused(result, typed, for: tenant), "\(shape): \(typed)")
        }
        for typed in ["Brisa SmithJones", "Brisa Smith Jones", "brisa smith\u{2011}jones"] {
            #expect(result.refusal(typed, for: [cosigner]) == .original, "\(shape): \(typed) → \(String(describing: result.refusal(typed, for: [cosigner])))")
        }
        #expect(result.refusal("Jane Smithson", for: [tenant]) == nil && result.refusal("Jane Roe-Hart", for: [cosigner]) == nil, "\(shape)")
    }

    /// The reading itself: an apostrophe and a hyphen only between letters.
    @Test func aNameIsReadWithoutItsApostropheOrHyphen() {
        #expect(Set(Review.readings("O\u{2019}Sullivan")) == ["o\u{2019}sullivan", "osullivan", "o sullivan"])
        #expect(Set(Review.readings("Smith-Jones")) == ["smith-jones", "smithjones", "smith jones"])
        #expect(Review.readings("GRV-88213") == ["grv-88213"])
        #expect(Review.readings("rock 'n' roll") == ["rock 'n' roll"])
        #expect(Review.nameWords("Tomasz O\u{02BC}Sullivan") == ["Tomasz", "O\u{02BC}Sullivan"])
        #expect(Review.nameWords("Brisa Smith\u{2010}Jones") == ["Brisa", "Smith", "Jones"])
    }

    // MARK: A selection encoded in a link is marked as the value it reads

    /// A depot's notes: its name written plainly, split by a hidden
    /// character, and in two links, one of them holding `selected` (as the
    /// person selects it) and the other written another way. A lowercase name
    /// no detector reads sits beside it, and in a link's query with "+" for a space.
    static func depot(_ shape: Shape, selected: String, other: String) -> String {
        let map = "https://maps.corvane.test/find?q=\(selected)&who=harrowgate+lisk", hours = "https://corvane.test/depots/\(other)/hours"
        let note = "the quillmere depot opens at six; harrowgate lisk holds the keys."
        switch shape {
        case .text: return "\(note)\nMap: \(map)\nHours: \(hours)\nthe slip says quill\u{200B}mere.\n"
        case .json: return #"{"note":"\#(note)","map":"\#(map)","hours":"\#(hours)","slip":"the slip says quill\#u{200B}mere."}"#
        case .csv: return "note,map,hours,slip\n\(note),\(map),\(hours),the slip says quill\u{200B}mere.\n"
        case .xml: return "<depot><note>\(note)</note><map>\(map.replacingOccurrences(of: "&", with: "&amp;"))</map><hours>\(hours)</hours><slip>the slip says quill<em>mere</em>.</slip></depot>"
        }
    }

    /// The output as a reader reads it: links decoded, hidden characters and markup gone, in lowercase.
    static func read(_ result: ScrubResult) -> String {
        let text = output(result).replacingOccurrences(of: "&amp;", with: "&")
        let decoded = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
        return Visible.plain(decoded).replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression).lowercased()
    }

    static func parses(_ result: ScrubResult, _ shape: Shape) -> Bool {
        switch shape {
        case .json: return (try? JSONSerialization.jsonObject(with: result.output)) != nil
        case .xml: return XMLParser(data: result.output).parse()
        case .csv: return (try? CSVReader.rows(output(result))).map { Set($0.map(\.count)).count == 1 } ?? false
        case .text: return true
        }
    }

    static func query(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: #"[?&;]"# + key + #"=[^&\s"<,]*"#, options: .regularExpression) else { return nil }
        return String(text[range].drop { $0 != "=" }.dropFirst())
    }

    /// Selected encoded in a link (one letter, some letters, every letter), the mark reaches the value plainly,
    /// split, and encoded otherwise, each written as its place needs.
    @Test(arguments: Shape.allCases, ["%51uillmere", "Quill%6Dere", "%51%75%69%6C%6C%6D%65%72%65"])
    func anEncodedSelectionMarksTheValueItReads(_ shape: Shape, _ selected: String) throws {
        let other = selected == "Quill%6Dere" ? "%51uillmere" : "Quill%6Dere"
        let result = try Self.scrub(Self.depot(shape, selected: selected, other: other), shape, name: "depot")
        try #require(Self.read(result).components(separatedBy: "quillmere").count >= 5, "\(shape): every form must be left to mark: \(Self.output(result))")
        let picked = try #require(Self.pick(result, selected), "\(shape)")
        #expect(picked.missed == ["Quillmere"], "\(shape) \(selected): \(picked.missed)")
        let (choices, marks) = result.marking(picked.missed, as: "LOCATION", choices: result.choices, marks: result.marks)
        let marked = try result.applying(choices, marks: marks)
        let after = Self.output(marked)
        #expect(!Self.read(marked).contains("quillmere") && !after.contains(selected) && !after.contains(other), "\(shape) \(selected): \(after)")
        #expect(Self.parses(marked, shape), "\(shape): \(after)")
        // Type oracle: a place's name, the same in every place, encoded in the links as they need.
        let finding = try #require(marked.byHand.first)
        #expect(finding.standIn.allSatisfy { $0.isLetter || " .'-".contains($0) } && finding.places.count >= 4, "\(shape): \(finding.standIn) \(finding.places.count)")
        let q = try #require(Self.query("q", in: after), "\(after)")
        #expect(URLs.decode(q, .query).lowercased() == finding.standIn.lowercased() && q.allSatisfy { $0.isLetter || $0.isNumber || "%+-._~".contains($0) }, "\(q) vs \(finding.standIn)")
        let hours = try #require(after.range(of: #"/depots/[^/]+/hours"#, options: .regularExpression).map { String(after[$0].dropFirst(8).dropLast(6)) })
        #expect(URLs.decode(hours, .path).lowercased() == finding.standIn.lowercased() && !hours.contains(" "), "\(hours)")
        // Marking the plain word reaches the same places: one value either way.
        let plain = result.marking(["Quillmere"], as: "LOCATION", choices: result.choices, marks: Marks())
        #expect(try result.applying(plain.0, marks: plain.1).output == marked.output, "\(shape) \(selected)")
        // Taken off, every place is back as made: by the mark's own finding, or by a click on its stand-in.
        let unmarked = marked.keeping([finding], choices: marked.choices, marks: marked.marks)
        #expect(unmarked.1.isEmpty, "\(shape)")
        #expect(try marked.applying(unmarked.0, marks: unmarked.1).output == result.output, "\(shape)")
        let onStandIn = try #require(Self.pick(marked, finding.standIn, click: true), "\(shape)")
        #expect(onStandIn.marked.count == 1, "\(shape): \(onStandIn)")
        let kept = marked.keeping(onStandIn, choices: marked.choices, marks: marked.marks)
        #expect(try marked.applying(kept.0, marks: kept.1).output == result.output, "\(shape)")
        // The same scrub and selection write the same bytes; undone and redone, the same again.
        let again = try Self.scrub(Self.depot(shape, selected: selected, other: other), shape, name: "depot")
        let repicked = try #require(Self.pick(again, selected))
        let remarked = again.marking(repicked.missed, as: "LOCATION", choices: again.choices, marks: again.marks)
        #expect(try again.applying(remarked.0, marks: remarked.1).output == marked.output)
        let undone = try marked.applying(result.choices, marks: Marks())
        #expect(undone.output == result.output)
        #expect(try undone.applying(choices, marks: marks).output == marked.output)
    }

    /// A name selected as a query writes it, "+" for the space: marked as the name, it reaches the name in prose.
    @Test(arguments: Shape.allCases)
    func aPlusJoinedSelectionMarksTheNameItReads(_ shape: Shape) throws {
        let result = try Self.scrub(Self.depot(shape, selected: "%51uillmere", other: "Quill%6Dere"), shape, name: "depot")
        try #require(Self.output(result).contains("harrowgate lisk") && Self.output(result).contains("harrowgate+lisk"), "\(shape): \(Self.output(result))")
        let picked = try #require(Self.pick(result, "harrowgate+lisk"), "\(shape)")
        #expect(picked.missed == ["harrowgate lisk"], "\(shape): \(picked.missed)")
        let (choices, marks) = result.marking(picked.missed, as: "PERSON", choices: result.choices, marks: result.marks)
        let marked = try result.applying(choices, marks: marks)
        let after = Self.output(marked)
        for gone in ["harrowgate", "lisk"] { #expect(!Self.read(marked).contains(gone), "\(shape) \(gone): \(after)") }
        #expect(Self.parses(marked, shape), "\(shape): \(after)")
        // Type oracle: two words of a name, written into the query with "+" for the space.
        let finding = try #require(marked.byHand.first)
        #expect(finding.standIn.split(separator: " ").count == 2 && finding.standIn.allSatisfy { $0.isLetter || " '-".contains($0) }, "\(finding.standIn)")
        let who = try #require(Self.query("who", in: after), "\(after)")
        #expect(URLs.decode(who, .query).lowercased() == finding.standIn.lowercased() && who.contains("+") && !who.contains(" "), "\(who)")
        #expect(after.lowercased().contains(finding.standIn.lowercased() + " holds"), "\(after)")
        let unmarked = marked.keeping([finding], choices: marked.choices, marks: marked.marks)
        #expect(try marked.applying(unmarked.0, marks: unmarked.1).output == result.output)
    }

    /// A selection that only looks encoded, outside any link, is marked as written.
    @Test func aPercentOrAPlusInProseIsMarkedAsWritten() throws {
        let result = try Self.scrub("Ticket KX+4471 is 50%41 done.\n", .text, name: "ticket")
        let review = try #require(result.review)
        #expect(review.identity("KX+4471") == "KX+4471" && review.identity("50%41") == "50%41")
        #expect(review.identity("Quill\u{200B}mere") == "Quillmere" && review.identity("Quill**mere**") == "Quillmere")
    }

    // MARK: Two people who share a first name stay two

    enum Layout: String, CaseIterable, Sendable { case separate, together }

    /// An applicant and a spouse both called Odalys, in records of their own
    /// or in one record, each with a full name, a first name and an email.
    static func householdText(_ shape: Shape, _ layout: Layout) -> String {
        let people = [("applicant", "Odalys Ferriter", "odalys.ferriter@kestrel.example"), ("spouse", "Odalys Quillmere", "odalys.quillmere@kestrel.example")]
        switch (shape, layout) {
        case (.text, _):
            return "Applicant: Odalys Ferriter <odalys.ferriter@kestrel.example> signed the lease.\n\nSpouse: Odalys Quillmere <odalys.quillmere@kestrel.example> co-signs it.\n"
        case (.json, .separate):
            return "[" + people.map { #"{"role":"\#($0.0)","name":"\#($0.1)","first_name":"Odalys","email":"\#($0.2)"}"# }.joined(separator: ",") + "]"
        case (.json, .together):
            return "{" + people.map { #""\#($0.0)":{"name":"\#($0.1)","first_name":"Odalys","email":"\#($0.2)"}"# }.joined(separator: ",") + "}"
        case (.csv, .separate):
            return "role,name,first_name,email\n" + people.map { "\($0.0),\($0.1),Odalys,\($0.2)\n" }.joined()
        case (.csv, .together):
            return people.map { "\($0.0).name,\($0.0).first_name,\($0.0).email" }.joined(separator: ",") + "\n" + people.map { "\($0.1),Odalys,\($0.2)" }.joined(separator: ",") + "\n"
        case (.xml, .separate):
            return "<cases>" + people.map { "<case><role>\($0.0)</role><name>\($0.1)</name><first_name>Odalys</first_name><email>\($0.2)</email></case>" }.joined() + "</cases>"
        case (.xml, .together):
            return "<case>" + people.map { "<\($0.0)><name>\($0.1)</name><first_name>Odalys</first_name><email>\($0.2)</email></\($0.0)>" }.joined() + "</case>"
        }
    }

    /// The finding edited for the applicant: her first name alone, or in
    /// prose (where no first name stands alone) her full name; her email,
    /// and the spouse's findings, all as made.
    struct Household {
        let result: ScrubResult
        let target: Finding
        let applicantEmail: Finding
        let spouse: [Finding]
        let spouseEmail: Finding
    }

    static func household(_ shape: Shape, _ layout: Layout, seed: UInt64 = 41) throws -> Household {
        let result = try scrub(householdText(shape, layout), shape, name: "household", seed: seed)
        let review = try #require(result.review)
        let email = try #require(result.findings.first { $0.original == "odalys.ferriter@kestrel.example" }, "\(shape) \(layout): \(result.findings.map(\.original))")
        let spouseEmail = try #require(result.findings.first { $0.original == "odalys.quillmere@kestrel.example" })
        let applicant = try #require(review.personOf[email.id], "\(shape) \(layout): her email is hers"), spouse = try #require(review.personOf[spouseEmail.id])
        try #require(applicant != spouse, "\(shape) \(layout): two people: \(output(result))")
        let target = try #require(result.findings.first { review.personOf[$0.id] == applicant && $0.original == (shape == .text ? "Odalys Ferriter" : "Odalys") }, "\(shape) \(layout): \(result.findings.map(\.original))")
        let theirs = result.findings.filter { review.personOf[$0.id] == spouse }
        if shape != .text {
            // The shared first name is two findings, one each.
            try #require(theirs.contains { $0.original == "Odalys" } && target.standIn != theirs.first { $0.original == "Odalys" }?.standIn, "\(shape) \(layout): \(result.findings.map { "\($0.original)→\($0.standIn)" })")
        }
        return Household(result: result, target: target, applicantEmail: email, spouse: theirs, spouseEmail: spouseEmail)
    }

    /// The spouse's findings, and her email, read as written after `edited`: as made, and her email still built from her first name.
    static func spouseUntouched(_ house: Household, _ edited: ScrubResult, _ label: String) {
        for finding in house.spouse {
            let revised = edited.revised(finding)
            #expect(revised.standIn == finding.standIn && revised.entity == finding.entity, "\(label): \(finding.original) became \(revised.standIn)")
        }
        let after = output(edited)
        let first = house.spouse.first { $0.original == "Odalys Quillmere" }?.standIn.split(separator: " ").first.map { $0.lowercased() } ?? ""
        #expect(after.contains(house.spouseEmail.standIn) && house.spouseEmail.standIn.hasPrefix(first + "."), "\(label): \(house.spouseEmail.standIn) for \(first): \(after)")
        for finding in house.spouse { #expect(after.contains(finding.standIn), "\(label): \(finding.standIn) gone: \(after)") }
    }

    @Test(arguments: Shape.allCases, Layout.allCases)
    func aNameTypedForOnePersonLeavesAnotherWhoSharesIt(_ shape: Shape, _ layout: Layout) throws {
        if shape == .text, layout == .together { return }
        let house = try Self.household(shape, layout)
        let result = house.result
        let typed = shape == .text ? "Jane Hughes" : "Jane"
        let (choices, marks, edits) = try result.editing([house.target], kind: nil, replacement: typed, choices: result.choices, marks: result.marks, edits: result.edits)
        let edited = try result.applying(choices, marks: marks, edits: edits)
        #expect(Self.parses(edited, shape), "\(shape): \(Self.output(edited))")
        // Hers: the name typed, and her email renamed with it on its own domain.
        #expect(edited.revised(house.target).standIn == typed)
        let mail = edited.revised(house.applicantEmail).standIn
        let domain = try #require(house.applicantEmail.standIn.split(separator: "@").last)
        #expect(mail.hasPrefix("jane.") && mail.hasSuffix("@" + domain), "\(shape) \(layout): \(mail)")
        // The spouse's: as made.
        Self.spouseUntouched(house, edited, "\(shape) \(layout)")
        // The same edits write the same bytes; undone, the scrub as made; redone, the same again.
        let twin = try Self.household(shape, layout)
        #expect(try twin.result.applying(choices, marks: marks, edits: edits).output == edited.output)
        let undone = try edited.applying(result.choices, marks: result.marks, edits: Edits())
        #expect(undone.output == result.output)
        #expect(try undone.applying(choices, marks: marks, edits: edits).output == edited.output)
        // Typed for the spouse after her, each keeps her own.
        let spouseFirst = try #require(house.spouse.first { $0.original == (shape == .text ? "Odalys Quillmere" : "Odalys") })
        let both = try edited.editing([edited.revised(spouseFirst)], kind: nil, replacement: shape == .text ? "Alice Morris" : "Alice", choices: choices, marks: marks, edits: edits)
        let twice = try result.applying(both.0, marks: both.1, edits: both.2)
        #expect(twice.revised(house.target).standIn == typed && twice.revised(spouseFirst).standIn == (shape == .text ? "Alice Morris" : "Alice"), "\(shape) \(layout)")
        #expect(twice.revised(house.spouseEmail).standIn.hasPrefix("alice.") && twice.revised(house.applicantEmail).standIn.hasPrefix("jane."), "\(shape) \(layout)")
    }

    /// A kind changed for one person's first name is hers alone, as a typed name is.
    @Test(arguments: Shape.allCases, Layout.allCases)
    func aKindChangedForOnePersonLeavesAnother(_ shape: Shape, _ layout: Layout) throws {
        if shape == .text, layout == .together { return }
        let house = try Self.household(shape, layout)
        let result = house.result
        let edited = try EditsTests.edit(result, [house.target.id], kind: "USERNAME")
        let revised = edited.revised(house.target)
        #expect(revised.entity == "USERNAME" && EditsTests.fits(revised.standIn, "USERNAME", like: house.target.original), "\(shape) \(layout): \(revised.standIn)")
        #expect(Self.output(edited).contains(revised.standIn) && Self.parses(edited, shape), "\(shape) \(layout): \(Self.output(edited))")
        Self.spouseUntouched(house, edited, "\(shape) \(layout)")
    }

    /// Keep original on one person's first name, picked in the preview,
    /// keeps hers alone: the spouse's stand-in stays, and her name is no one's original again.
    @Test(arguments: Shape.allCases, Layout.allCases)
    func keepingOnePersonsOriginalLeavesAnother(_ shape: Shape, _ layout: Layout) throws {
        if shape == .text, layout == .together { return }
        let house = try Self.household(shape, layout)
        let result = house.result
        let context: String? = switch shape {
        case .json: #""first_name": "\#(house.target.standIn)""#
        case .xml: "<first_name>\(house.target.standIn)</first_name>"
        case .csv: house.target.standIn
        case .text: nil
        }
        let picked = try #require(Self.pick(result, house.target.standIn, in: context, click: true), "\(shape) \(layout)")
        #expect(picked.replaced.contains { $0.id == house.target.id } && !picked.replaced.contains { finding in house.spouse.contains { $0.id == finding.id } }, "\(shape) \(layout): \(picked.replaced.map { "\($0.original)→\($0.standIn)" })")
        let (choices, marks) = result.keeping(picked, choices: result.choices, marks: result.marks)
        let kept = try result.applying(choices, marks: marks)
        #expect(Self.output(kept).contains("Odalys") && Self.parses(kept, shape), "\(shape) \(layout): \(Self.output(kept))")
        Self.spouseUntouched(house, kept, "\(shape) \(layout)")
        // The editor opened on it edits hers alone.
        let edited = try result.editing(picked.replaced, kind: nil, replacement: shape == .text ? "Jane Hughes" : "Jane", choices: result.choices, marks: result.marks, edits: result.edits)
        Self.spouseUntouched(house, try result.applying(edited.0, marks: edited.1, edits: edited.2), "\(shape) \(layout) editor")
        // Undone, as made.
        #expect(try kept.applying(result.choices, marks: result.marks).output == result.output)
    }

    /// A value no one owns follows an edit to the same value only where no other person owns that text.
    @Test func aValueNoOneOwnsFollowsOnlyWhereOnePersonOwnsTheText() throws {
        func value(_ text: String, _ marks: [(String, String, String)]) -> DocumentValue {
            let ns = text as NSString
            return DocumentValue(text: text, marks: marks.map { standIn, entity, original in
                let range = ns.range(of: standIn)
                return Mark(range: range.location..<NSMaxRange(range), entity: entity, original: original, confidence: 1)
            }, unresolved: [])
        }
        let render: ([DocumentValue], [String: Int]) throws -> ScrubResult = { values, counts in
            ScrubResult(format: "text", output: Data(values.map(\.text).joined(separator: "\n").utf8), preview: .text("", marks: [], truncated: false), counts: counts, unresolved: [])
        }
        func review(spouse: Bool) -> Review {
            var people = PersonLinks()
            people.names = [PersonLinks.Names(first: "Kathryn", last: "Hughes"), PersonLinks.Names(first: "Rachel", last: "Morris")]
            people.link("Odalys Ferriter", "Kathryn Hughes", to: 0)
            people.link("Odalys", "Kathryn", to: 0)
            var values = [value("Kathryn Hughes; Kathryn", [("Kathryn Hughes", "PERSON", "Odalys Ferriter"), ("Kathryn", "FIRST_NAME", "Odalys")])]
            if spouse {
                people.link("Odalys Quillmere", "Rachel Morris", to: 1)
                people.link("Odalys", "Rachel", to: 1)
                values.append(value("Rachel Morris; Rachel", [("Rachel Morris", "PERSON", "Odalys Quillmere"), ("Rachel", "FIRST_NAME", "Odalys")]))
            }
            // A form no one was linked to: the first name with a stand-in of its own.
            values.append(value("Wren", [("Wren", "FIRST_NAME", "Odalys")]))
            return Review(values: values, counts: [:], records: values.indices.map { $0 }, people: people, render: render)
        }
        for spouse in [false, true] {
            let review = review(spouse: spouse)
            let hers = try #require(review.findings.first { $0.standIn == "Kathryn" }), loose = try #require(review.findings.first { $0.standIn == "Wren" })
            try #require(review.personOf[hers.id] == 0 && review.personOf[loose.id] == nil)
            var edits = Edits()
            edits.setReplacement("Jane", of: hers.id)
            let revisions = review.revised(edits)
            #expect(revisions[hers.id]?.standIn == "Jane")
            // With one Odalys, the loose form is hers; with two, it could be either, and keeps its own.
            #expect((revisions[loose.id]?.standIn == "Jane") == !spouse, "spouse \(spouse): \(String(describing: revisions[loose.id]))")
            if spouse, let theirs = review.findings.first(where: { $0.standIn == "Rachel" }) { #expect(revisions[theirs.id] == nil) }
            // Kept from a pick on her stand-in, the same.
            let owners = review.owners(ofStandIn: "Kathryn", marks: Marks()).findings.map(\.id)
            #expect(owners.contains(hers.id) && owners.contains(loose.id) == !spouse && !owners.contains { review.personOf[$0] == 1 }, "spouse \(spouse): \(owners)")
        }
    }
}
