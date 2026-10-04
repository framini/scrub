import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// A person changes the kind of a value Scrub found, or types its replacement,
/// on top of the scrub as made: every place takes it, written as the place
/// writes a value, a typed name reaches the person's other forms, an unsafe
/// replacement is refused, and the same scrub and edits write the same bytes.
@Suite struct EditsTests {
    enum Shape: String, CaseIterable, Sendable { case text, json, csv, xml, link }

    /// A courier's handover in each shape a file comes in: the customer's
    /// name, a title with her surname, her first name alone, her email, and
    /// a link to her account page that carries her name in its query.
    static func handover(_ shape: Shape) -> (name: String, data: Data) {
        let link = "https://portal.corvane.test/parcels?name=Odalys+Ferriter&ref=48213"
        let text: String
        switch shape {
        case .text:
            text = """
            Handover for Odalys Ferriter (odalys.ferriter@kestrel.example).
            Ms Ferriter asked us to call before noon. Odalys said the side gate is open.
            Track it at \(link)
            """
        case .link:
            text = "Parcel page: \(link)\nCustomer: Odalys Ferriter, odalys.ferriter@kestrel.example\n"
        case .json:
            text = #"{"customer":"Odalys Ferriter","email":"odalys.ferriter@kestrel.example","page":"\#(link)","notes":"Ms Ferriter asked us to call before noon. Odalys said the side gate is open."}"#
        case .csv:
            text = "customer,email,page,notes\nOdalys Ferriter,odalys.ferriter@kestrel.example,\(link),\"Ms Ferriter asked us to call before noon. Odalys said the side gate is open.\"\n"
        case .xml:
            text = "<handover><customer>Odalys Ferriter</customer><email>odalys.ferriter@kestrel.example</email><page>\(link.replacingOccurrences(of: "&", with: "&amp;"))</page><notes>Ms Ferriter asked us to call before noon. Odalys said the side gate is open.</notes></handover>"
        }
        let ext = ["text": "txt", "link": "txt", "json": "json", "csv": "csv", "xml": "xml"][shape.rawValue] ?? "txt"
        return ("handover." + ext, Data(text.utf8))
    }

    static func scrubbed(_ shape: Shape, seed: UInt64 = 41) throws -> ScrubResult {
        let input = handover(shape)
        return try Scrubber.scrub(input.data, name: input.name, forceFullDetection: false, seed: seed)
    }

    static func output(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

    /// The output as a reader reads it: JSON and XML as their values, links decoded.
    static func read(_ result: ScrubResult, _ shape: Shape) -> String {
        var text = output(result)
        if shape == .xml, let document = try? XMLDocument(data: result.output, options: []) { text = document.rootElement()?.stringValue ?? text }
        if shape == .json, let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] {
            text = object.values.compactMap { $0 as? String }.joined(separator: "\n")
        }
        if shape == .csv, let rows = try? CSVReader.rows(text) { text = rows.map { $0.joined(separator: "\n") }.joined(separator: "\n") }
        return text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }

    static func parses(_ result: ScrubResult, _ shape: Shape) -> Bool {
        switch shape {
        case .json: return (try? JSONSerialization.jsonObject(with: result.output)) != nil
        case .xml: return XMLParser(data: result.output).parse()
        case .csv: return (try? CSVReader.rows(output(result))).map { rows in Set(rows.map(\.count)).count == 1 } ?? false
        case .text, .link: return true
        }
    }

    /// The query value under `key` in the first link that has one, as written.
    static func query(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: #"[?&;]"# + key + #"=[^&\s"<,]*"#, options: .regularExpression) else { return nil }
        return String(text[range].drop { $0 != "=" }.dropFirst())
    }

    /// Whether a stand-in can pass for a value of `entity`.
    static func fits(_ standIn: String, _ entity: String, like original: String) -> Bool {
        func mask(_ s: String) -> String { String(s.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 }) }
        switch entity {
        case "PERSON", "LOCATION": return !standIn.isEmpty && standIn.allSatisfy { $0.isLetter || " .'-’".contains($0) }
        case "USERNAME": return !standIn.isEmpty && !standIn.contains(" ") && !standIn.contains("@") || standIn.hasPrefix("@") && standIn.count > 1
        case "ID_NUMBER": return mask(standIn) == mask(original)
        case "EMAIL_ADDRESS": return standIn.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
        case "PHONE_NUMBER": return standIn.filter(\.isNumber).count >= 7 && !standIn.contains(where: \.isLetter)
        case "SECRET": return standIn.count >= 8 && !standIn.contains(" ")
        default: return !standIn.isEmpty && standIn.lowercased() != original.lowercased()
        }
    }

    static func customer(_ result: ScrubResult) throws -> Int {
        try #require(result.findings.firstIndex { $0.original == "Odalys Ferriter" }, "Scrub must find the customer: \(output(result))")
    }

    static func edit(_ result: ScrubResult, _ ids: [Int], kind: String? = nil, replacement: String? = nil, edits: Edits? = nil, choices: Choices? = nil, marks: Marks? = nil) throws -> ScrubResult {
        let targets = result.current.filter { ids.contains($0.id) }
        let (choices, marks, edits) = try result.editing(targets, kind: kind, replacement: replacement, choices: choices ?? result.choices, marks: marks ?? result.marks, edits: edits ?? result.edits)
        return try result.applying(choices, marks: marks, edits: edits)
    }

    // MARK: Every input path

    @Test(arguments: Shape.allCases)
    func aTypedReplacementIsWrittenEverywhereInEveryShape(_ shape: Shape) throws {
        let result = try Self.scrubbed(shape)
        let customer = result.findings[try Self.customer(result)]
        let edited = try Self.edit(result, [customer.id], replacement: "Jane Roe")
        let read = Self.read(edited, shape)
        #expect(Self.parses(edited, shape), "\(shape): \(Self.output(edited))")
        #expect(read.contains("Jane Roe"), "\(shape): \(read)")
        #expect(!read.lowercased().contains("odalys") && !read.lowercased().contains("ferriter"), "\(shape): \(read)")
        // The stand-in it replaced is gone from every place, the link's included.
        let old = customer.standIn.split(separator: " ").map { $0.lowercased() }
        for part in old { #expect(!read.lowercased().contains(part), "\(shape): \(part) in \(read)") }
        let name = try #require(Self.query("name", in: Self.output(edited)), "\(shape): \(Self.output(edited))")
        #expect(URLs.decode(name, .query) == "Jane Roe" && !name.contains(" "), "\(shape): \(name)")
        // Type oracle: the finding reads as the name typed, still a name.
        let revised = edited.revised(customer)
        #expect(revised.standIn == "Jane Roe" && revised.entity == customer.entity)
    }

    @Test(arguments: Shape.allCases)
    func aChangedKindIsWrittenEverywhereInEveryShape(_ shape: Shape) throws {
        let result = try Self.scrubbed(shape)
        let customer = result.findings[try Self.customer(result)]
        let edited = try Self.edit(result, [customer.id], kind: "USERNAME")
        let revised = edited.revised(customer)
        #expect(revised.entity == "USERNAME" && Self.fits(revised.standIn, "USERNAME", like: customer.original), "\(shape): \(revised.standIn)")
        #expect(Self.parses(edited, shape), "\(shape): \(Self.output(edited))")
        let read = Self.read(edited, shape)
        #expect(read.contains(revised.standIn) && !read.contains(customer.standIn), "\(shape): \(read)")
        #expect(!read.lowercased().contains("ferriter"), "\(shape): \(read)")
        // Its own variants keep their stand-ins: the person's email still reads as before.
        let email = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" })
        #expect(Self.output(edited).contains(email.standIn), "\(shape): \(Self.output(edited))")
        // Counted as its new kind, not its old.
        #expect((edited.counts["USERNAME"] ?? 0) >= customer.places.count, "\(edited.counts)")
    }

    @Test(arguments: Shape.allCases)
    func aKindAndATypedReplacementCombine(_ shape: Shape) throws {
        let result = try Self.scrubbed(shape)
        let customer = result.findings[try Self.customer(result)]
        let edited = try Self.edit(result, [customer.id], kind: "EMPLOYER", replacement: "Larkspur Freight")
        let revised = edited.revised(customer)
        #expect(revised.entity == "EMPLOYER" && revised.standIn == "Larkspur Freight")
        #expect(Self.read(edited, shape).contains("Larkspur Freight") && Self.parses(edited, shape), "\(shape): \(Self.output(edited))")
        // An employer is no person: the name typed renames no one else.
        #expect(!Self.read(edited, shape).contains("Ms Freight"), "\(Self.read(edited, shape))")
    }

    /// Characters each format must escape: written so the file still parses
    /// and reads back as typed.
    @Test(arguments: Shape.allCases)
    func aTypedReplacementIsEscapedAsEachFormatNeeds(_ shape: Shape) throws {
        let result = try Self.scrubbed(shape)
        let customer = result.findings[try Self.customer(result)]
        let typed = #"Roe, Jane "J" <&> 50%"#
        let edited = try Self.edit(result, [customer.id], replacement: typed)
        #expect(Self.parses(edited, shape), "\(shape): \(Self.output(edited))")
        #expect(Self.read(edited, shape).contains(typed), "\(shape): \(Self.read(edited, shape))")
        let name = try #require(Self.query("name", in: Self.output(edited)))
        #expect(URLs.decode(name, .query) == typed && !name.contains("\"") && !name.contains(" ") && !name.contains("&"), "\(name)")
    }

    // MARK: Variants follow a typed name

    @Test(arguments: [Shape.text, .json, .csv, .xml])
    func aTypedNameReachesTheFirstNameTheTitleAndTheEmail(_ shape: Shape) throws {
        let result = try Self.scrubbed(shape)
        let customer = result.findings[try Self.customer(result)]
        let email = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" && $0.original.hasPrefix("odalys.ferriter") })
        let domain = try #require(email.standIn.split(separator: "@").last).description
        let edited = try Self.edit(result, [customer.id], replacement: "Jane Roe")
        let read = Self.read(edited, shape)
        #expect(read.contains("Ms Roe asked"), "\(shape): title with the surname: \(read)")
        #expect(read.contains("Jane said"), "\(shape): the first name alone: \(read)")
        #expect(read.contains("jane.roe@" + domain), "\(shape): the email's local part, on its own stand-in domain: \(read)")
        let old = customer.standIn.split(separator: " ").map { String($0) }
        for part in old { #expect(!read.contains(part), "\(shape): \(part) left in \(read)") }
        // Each variant reads as revised in the list of values too.
        #expect(edited.current.contains { $0.entity == "EMAIL_ADDRESS" && $0.standIn == "jane.roe@" + domain })
    }

    @Test func aSurnameTypedAloneRenamesOnlyTheSurname() throws {
        let result = try Self.scrubbed(.text)
        let customer = result.findings[try Self.customer(result)]
        let title = try #require(result.findings.first { $0.original == "Ms Ferriter" || $0.original == "Ferriter" }, "\(result.findings.map(\.original))")
        let first = try #require(customer.standIn.split(separator: " ").first).description
        let typed = title.standIn.hasPrefix("Ms ") ? "Ms Roe" : "Roe"
        let edited = try Self.edit(result, [title.id], replacement: typed)
        let read = Self.read(edited, .text)
        #expect(read.contains(first + " Roe") && read.contains("Ms Roe"), "\(read)")
    }

    /// The renaming itself, as the review reads it: a name word for word, a handle piece by piece.
    @Test func aStandInIsRenamedTheWayItWasWritten() {
        let names = PersonLinks.Names(first: "Maren", last: "Holt")
        let renaming = Review.Renaming(first: "Jane", last: "Roe")
        #expect(Review.renamed("Maren Holt", entity: "PERSON", names: names, to: renaming) == "Jane Roe")
        #expect(Review.renamed("HOLT, Maren", entity: "PERSON", names: names, to: renaming) == "ROE, Jane")
        #expect(Review.renamed("M. Holt", entity: "PERSON", names: names, to: renaming) == "J. Roe")
        #expect(Review.renamed("maren.holt@quillpost.example", entity: "EMAIL_ADDRESS", names: names, to: renaming) == "jane.roe@quillpost.example")
        #expect(Review.renamed("mholt@quillpost.example", entity: "EMAIL_ADDRESS", names: names, to: renaming) == "jroe@quillpost.example")
        #expect(Review.renamed("@marenh", entity: "USERNAME", names: names, to: renaming) == "@janer")
        #expect(Review.renamed("holt42", entity: "USERNAME", names: names, to: renaming) == "roe42")
        #expect(Review.renamed("M.H.", entity: "INITIALS", names: names, to: renaming) == "J.R.")
        #expect(Review.renaming("Ms Holt", to: "Ms Roe", names: names) == Review.Renaming(first: nil, last: "Roe"))
        #expect(Review.renaming("Maren Holt", to: "Jane Q. Roe", names: names) == Review.Renaming(first: "Jane", last: "Roe"))
        #expect(Review.renaming("Maren Holt", to: "Jane", names: names) == nil)
    }

    // MARK: Refusals

    @Test func anUnsafeReplacementIsRefusedAndNothingIsWritten() throws {
        let result = try Self.scrubbed(.text)
        let customer = result.findings[try Self.customer(result)]
        var marks = Marks()
        marks.add("side gate", as: "LOCATION")
        let marked = try result.applying(result.choices, marks: marks)
        #expect(marked.refusal("", for: [customer]) == .empty)
        #expect(marked.refusal("   ", for: [customer]) == .empty)
        #expect(marked.refusal("Odalys Ferriter", for: [customer]) == .original)
        #expect(marked.refusal("ODALYS ferriter", for: [customer]) == .original)
        #expect(marked.refusal("Ódalys Férriter", for: [customer]) == .original)
        #expect(marked.refusal("Dr Odalys Ferriter Jr", for: [customer]) == .original)
        // Another value found, or one marked by hand, as a word.
        let email = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" })
        #expect(marked.refusal("Jane " + email.original.uppercased(), for: [customer]) == .other(email.original))
        #expect(marked.refusal("Jane of the Side Gate", for: [customer]) == .other("side gate"))
        // Not as part of another word, and never a value shorter than three letters.
        #expect(marked.refusal("Jane Sidegateway", for: [customer]) == nil)
        #expect(marked.refusal("Jane Roe", for: [customer]) == nil)
        // Refused through the editing API too: nothing of it reaches the edits.
        #expect(throws: Refusal.original) { try marked.editing([customer], kind: nil, replacement: "odalys ferriter", choices: marked.choices, marks: marked.marks, edits: marked.edits) }
    }

    @Test func aBareNumberTakesOnlyDigits() throws {
        let input = #"{"customer":"Odalys Ferriter","phone":4158672290,"locker":"GRV-88213"}"#
        let result = try Scrubber.scrub(Data(input.utf8), name: "locker.json", forceFullDetection: false, seed: 7)
        let phone = try #require(result.findings.first { $0.original == "4158672290" }, "\(result.findings.map(\.original))")
        #expect(result.refusal("call Jane", for: [phone]) == .number)
        #expect(result.refusal("2125550147", for: [phone]) == nil)
        let edited = try Self.edit(result, [phone.id], replacement: "2125550147")
        #expect(Self.output(edited).contains("2125550147") && (try? JSONSerialization.jsonObject(with: edited.output)) != nil, "\(Self.output(edited))")
    }

    // MARK: Kind changes

    /// A new kind draws a fresh stand-in of that kind, never the old one,
    /// and one that looks like the new kind.
    @Test(arguments: Marks.kinds.filter { $0 != "PERSON" })
    func aChangedKindDrawsAStandInOfThatKind(_ kind: String) throws {
        let result = try Self.scrubbed(.csv)
        let customer = result.findings[try Self.customer(result)]
        let edited = try Self.edit(result, [customer.id], kind: kind)
        let revised = edited.revised(customer)
        #expect(revised.entity == kind && revised.standIn != customer.standIn, "\(kind): \(revised.standIn)")
        #expect(Self.fits(revised.standIn, kind, like: customer.original), "\(kind): \(revised.standIn)")
        #expect(Self.parses(edited, .csv))
    }

    /// A value Scrub left as written has no stand-in of its own yet: changed
    /// to a kind, it draws the one marking it as that kind draws.
    @Test(arguments: Marks.kinds)
    func aChangedKindDrawsTheStandInMarkingWould(_ kind: String) throws {
        // A name only a model read, that nothing else agrees with: left as written for a person to decide.
        let note = "The deploy broke again. Rhosyn fixed it before lunch and pushed the patch."
        let result = try Scrubber.scrub(Data(note.utf8), name: "note.txt", forceFullDetection: false, seed: 3)
        let suspect = try #require(result.findings.first { $0.suspected }, "the note must hold a value left as written: \(result.findings.map(\.original))")
        guard suspect.entity != kind else { return }
        let changed = try Self.edit(result, [suspect.id], kind: kind).revised(suspect)
        let (choices, marks) = result.marking([suspect.original], as: kind, choices: result.choices, marks: result.marks)
        let marked = try result.applying(choices, marks: marks)
        #expect(marked.byHand.first?.standIn == changed.standIn, "\(kind): marked \(marked.byHand.first?.standIn ?? "-") vs changed \(changed.standIn)")
        #expect(Self.fits(changed.standIn, kind, like: suspect.original), "\(kind): \(changed.standIn)")
    }

    // MARK: Marks, choices, determinism

    @Test func aMarkTakesATypedReplacementWithItsVariants() throws {
        // Written in lowercase, a name no detector reads: the person marks it.
        let input = "ticket 4471: harrowgate lisk owns the rollout. h. lisk signed off; ping harrowgate.lisk or hlisk."
        let result = try Scrubber.scrub(Data(input.utf8), name: "notes.txt", forceFullDetection: false, seed: 9)
        var marks = Marks()
        marks.add("Harrowgate Lisk", as: "PERSON")
        let marked = try result.applying(result.choices, marks: marks)
        let mine = try #require(marked.byHand.first)
        let edited = try Self.edit(marked, [mine.id], replacement: "Jane Roe")
        let after = Self.output(edited)
        #expect(after.contains("jane roe owns") && after.contains("j. roe signed") && after.contains("jane.roe") && after.contains("jroe"), "\(after)")
        #expect(!after.lowercased().contains("lisk") && !after.lowercased().contains("harrowgate"), "\(after)")
        #expect(edited.byHand.first?.standIn == "Jane Roe")
        // Marked again as another kind, it keeps the replacement typed for it.
        let (choices, rekinded, edits) = try edited.editing([try #require(edited.byHand.first)], kind: "EMPLOYER", replacement: nil, choices: edited.choices, marks: edited.marks, edits: edited.edits)
        let employer = try edited.applying(choices, marks: rekinded, edits: edits)
        #expect(employer.byHand.first?.entity == "EMPLOYER" && employer.byHand.first?.standIn == "Jane Roe", "\(employer.byHand.map(\.standIn))")
    }

    @Test func editsCombineWithMarksAndChoices() throws {
        let result = try Self.scrubbed(.text)
        let customer = result.findings[try Self.customer(result)]
        var marks = Marks()
        marks.add("side gate", as: "LOCATION")
        var choices = result.choices
        let (edited, withMarks, edits) = try result.editing([customer], kind: nil, replacement: "Jane Roe", choices: choices, marks: marks, edits: Edits())
        choices = edited
        // One place keeps its original; the others take the name typed.
        choices.set(try #require(customer.places.first), leave: true)
        let written = try result.applying(choices, marks: withMarks, edits: edits)
        let after = Self.output(written)
        #expect(after.components(separatedBy: "Odalys Ferriter").count == 2, "\(after)")
        #expect(after.contains("Jane Roe") || customer.places.count == 1, "\(after)")
        #expect(!after.contains("side gate"), "\(after)")
        // Left everywhere, the edit writes nothing; replaced again, it is back.
        choices.set(customer, leave: true)
        let left = try result.applying(choices, marks: withMarks, edits: edits)
        #expect(!Self.output(left).contains("Jane Roe") && Self.output(left).contains("Handover for Odalys Ferriter"), "\(Self.output(left))")
        choices.set(customer, leave: false)
        #expect(try result.applying(choices, marks: withMarks, edits: edits).output == (try result.applying(edited, marks: withMarks, edits: edits)).output)
    }

    @Test(arguments: Shape.allCases)
    func theSameScrubAndEditsWriteTheSameBytes(_ shape: Shape) throws {
        let first = try Self.scrubbed(shape), second = try Self.scrubbed(shape)
        let customer = first.findings[try Self.customer(first)]
        let email = try #require(first.findings.first { $0.entity == "EMAIL_ADDRESS" })
        var (choices, marks, edits) = try first.editing([customer], kind: nil, replacement: "Jane Roe", choices: first.choices, marks: first.marks, edits: first.edits)
        (choices, marks, edits) = try first.editing([email], kind: "USERNAME", replacement: nil, choices: choices, marks: marks, edits: edits)
        let one = try first.applying(choices, marks: marks, edits: edits), two = try second.applying(choices, marks: marks, edits: edits)
        #expect(one.output == two.output)
        // Written again from a result that already holds them, or in steps, the same.
        #expect(try one.applying(choices, marks: marks, edits: Edits()).applying(choices, marks: marks, edits: edits).output == one.output)
        // Undone, the scrub is as made; redone, the same bytes again.
        let undone = try one.applying(first.choices, marks: Marks(), edits: Edits())
        #expect(undone.output == first.output)
        #expect(try undone.applying(choices, marks: marks, edits: edits).output == one.output)
    }

    /// A pick on an edited stand-in finds the value it replaced, so it can be edited or kept again.
    @Test func anEditedStandInCanBePickedAgain() throws {
        let result = try Self.scrubbed(.text)
        let customer = result.findings[try Self.customer(result)]
        let edited = try Self.edit(result, [customer.id], replacement: "Jane Roe")
        guard case .text(let preview, let marks, _) = edited.preview else { Issue.record("not a text preview"); return }
        let at = (preview as NSString).range(of: "Jane Roe")
        let picked = edited.pick(in: preview, marks: marks, range: (at.location + 1)..<(at.location + 1))
        #expect(picked.replaced.contains { $0.id == customer.id }, "\(picked)")
        let (choices, kept) = edited.keeping(picked, choices: edited.choices, marks: edited.marks)
        #expect(Self.output(try edited.applying(choices, marks: kept)).contains("Handover for Odalys Ferriter"))
    }

    /// Thousands of values read as revised at once, and written quickly.
    @Test func manyEditsStayQuick() throws {
        var csv = "customer,locker,notes\n"
        for row in 0..<3_000 { csv += "Odalys Ferriter \(row),L\(10_000 + row),front desk\n" }
        let result = try Scrubber.scrub(Data(csv.utf8), name: "lockers.csv", forceFullDetection: false, seed: 3)
        let chosen = Array(result.findings.prefix(500))
        let clock = ContinuousClock(), started = clock.now
        let (choices, marks, edits) = try result.editing(chosen, kind: "ID_NUMBER", replacement: nil, choices: result.choices, marks: result.marks, edits: result.edits)
        let edited = try result.applying(choices, marks: marks, edits: edits)
        #expect(edited.current.count >= result.findings.count)
        #expect(clock.now - started < .seconds(10), "\(clock.now - started)")
    }
}
