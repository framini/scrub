import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// No original Scrub found or a person marked stays in the output after an
/// edit or a mark: a replacement typed for a mark, or a kind changed, keeps
/// every place the mark reached, its initials and handles included; a
/// replacement that hides a name's word beside digits, in an email, a handle
/// or a link is refused; and a selection is read where it was made, so one
/// in prose is marked as written whatever a link elsewhere writes.
@Suite struct EditCoverageTests {
    enum Shape: String, CaseIterable, Sendable { case text, json, csv, xml, link }

    static func output(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

    /// The output as a reader reads it, in lowercase: escapes, markup and links decoded.
    static func read(_ result: ScrubResult) -> String {
        let text = output(result).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "\\/", with: "/")
        let decoded = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
        return Visible.plain(decoded).replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression).lowercased()
    }

    static func parses(_ result: ScrubResult, _ shape: Shape) -> Bool {
        switch shape {
        case .json: return (try? JSONSerialization.jsonObject(with: result.output)) != nil
        case .xml: return XMLParser(data: result.output).parse()
        case .csv: return (try? CSVReader.rows(output(result))).map { Set($0.map(\.count)).count == 1 } ?? false
        case .text, .link: return true
        }
    }

    static func scrub(_ text: String, _ shape: Shape, name: String, seed: UInt64 = 9) throws -> ScrubResult {
        let ext = shape == .text || shape == .link ? "txt" : shape.rawValue
        return try Scrubber.scrub(Data(text.utf8), name: name + "." + ext, forceFullDetection: false, seed: seed)
    }

    // MARK: A changed mark keeps every place it reached

    /// A rollout note naming a team lead in lowercase, which no detector
    /// reads: in full, by initial, and in two handles.
    static func rollout(_ shape: Shape) -> String {
        let note = "harrowgate lisk owns the rollout. h. lisk signed off; ping harrowgate.lisk or hlisk."
        switch shape {
        case .text: return "ticket 4471: \(note)\n"
        case .link: return "ticket 4471: \(note)\nboard: https://corvane.test/find?q=harrowgate.lisk&sort=new\n"
        case .json: return #"{"ticket":"4471","notes":"\#(note)"}"#
        case .csv: return "ticket,notes\n4471,\"\(note)\"\n"
        case .xml: return "<ticket><id>4471</id><notes>\(note)</notes></ticket>"
        }
    }

    /// Each original word of the lead, gone from what a reader reads.
    static func noLead(_ result: ScrubResult, _ label: String) {
        let read = Self.read(result)
        #expect(!read.contains("lisk") && !read.contains("harrowgate"), "\(label): an original is back: \(output(result))")
    }

    /// The marked lead, and the result with the mark.
    static func marked(_ shape: Shape) throws -> (result: ScrubResult, marked: ScrubResult) {
        let result = try scrub(rollout(shape), shape, name: "rollout")
        try #require(read(result).contains("hlisk") && read(result).contains("h. lisk"), "\(shape): nothing may read the lead: \(output(result))")
        var marks = Marks()
        marks.add("Harrowgate Lisk", as: "PERSON")
        let marked = try result.applying(result.choices, marks: marks)
        noLead(marked, "\(shape) marked")
        return (result, marked)
    }

    static func step(_ result: ScrubResult, kind: String? = nil, replacement: String? = nil) throws -> ScrubResult {
        let mine = try #require(result.byHand.first)
        let (choices, marks, edits) = try result.editing([mine], kind: kind, replacement: replacement, choices: result.choices, marks: result.marks, edits: result.edits)
        return try result.applying(choices, marks: marks, edits: edits)
    }

    /// A first name typed for the full name: every form reads it, the handles in lowercase.
    @Test(arguments: Shape.allCases)
    func aOneWordReplacementReachesEveryForm(_ shape: Shape) throws {
        let (_, marked) = try Self.marked(shape)
        let edited = try Self.step(marked, replacement: "Jane")
        Self.noLead(edited, "\(shape) Jane")
        #expect(Self.parses(edited, shape), "\(shape): \(Self.output(edited))")
        let read = Self.read(edited)
        #expect(read.contains("jane owns") && read.contains("jane signed off") && read.contains("ping jane or jane."), "\(shape): \(read)")
        #expect(edited.byHand.first?.standIn == "Jane" && edited.byHand.first?.places.count == marked.byHand.first?.places.count, "\(shape)")
        if shape == .link { #expect(EditsTests.query("q", in: Self.output(edited)) == "jane", "\(Self.output(edited))") }
    }

    /// Changed to an employer, every form the person's name took stays replaced, with the employer's stand-in.
    @Test(arguments: Shape.allCases)
    func aKindChangedKeepsEveryForm(_ shape: Shape) throws {
        let (_, marked) = try Self.marked(shape)
        let edited = try Self.step(marked, kind: "EMPLOYER")
        Self.noLead(edited, "\(shape) EMPLOYER")
        #expect(Self.parses(edited, shape), "\(shape): \(Self.output(edited))")
        let mine = try #require(edited.byHand.first)
        // Type oracle: an employer's name, written whole in the name's forms and as a handle in its handles.
        #expect(mine.entity == "EMPLOYER" && EditsTests.fits(mine.standIn, "EMPLOYER", like: mine.original) && mine.places.count == marked.byHand.first?.places.count, "\(shape): \(mine.standIn)")
        #expect(Self.read(edited).contains(Review.handle(mine.standIn)), "\(shape): \(Self.output(edited))")
    }

    /// Typed, re-kinded and typed again, each state keeps every form replaced, and each comes back byte for byte.
    @Test(arguments: Shape.allCases)
    func successiveEditsKeepEveryFormAndUndoToTheSameBytes(_ shape: Shape) throws {
        let (result, marked) = try Self.marked(shape)
        var states: [ScrubResult] = [marked]
        for (kind, replacement) in [(nil, "Jane"), ("EMPLOYER", nil), (nil, "Quarry Works"), ("PERSON", nil), (nil, "Jane Roe")] as [(String?, String?)] {
            let next = try Self.step(try #require(states.last), kind: kind, replacement: replacement)
            Self.noLead(next, "\(shape) \(kind ?? "") \(replacement ?? "")")
            #expect(Self.parses(next, shape))
            states.append(next)
        }
        // A full name typed last writes each form by its parts.
        let read = Self.read(try #require(states.last))
        #expect(read.contains("jane roe owns") && read.contains("j. roe signed off") && read.contains("jane.roe") && read.contains("jroe"), "\(shape): \(read)")
        // Undone step by step from the last, and redone, each state's bytes come back.
        let last = try #require(states.last)
        for state in states.reversed() {
            #expect(try last.applying(state.choices, marks: state.marks, edits: state.edits).output == state.output, "\(shape)")
        }
        #expect(try marked.applying(result.choices, marks: Marks(), edits: Edits()).output == result.output)
        // The same scrub and steps write the same bytes.
        let (_, again) = try Self.marked(shape)
        var twin = again
        for (kind, replacement) in [(nil, "Jane"), ("EMPLOYER", nil), (nil, "Quarry Works"), ("PERSON", nil), (nil, "Jane Roe")] as [(String?, String?)] {
            twin = try Self.step(twin, kind: kind, replacement: replacement)
        }
        #expect(twin.output == last.output, "\(shape)")
    }

    /// Scrub's own findings keep every place too: a one-word name, or another kind, for a person Scrub found.
    @Test(arguments: EditsTests.Shape.allCases)
    func aFindingEditedLeavesNoOriginal(_ shape: EditsTests.Shape) throws {
        let result = try EditsTests.scrubbed(shape)
        let customer = try EditsTests.customer(result)
        for (kind, replacement) in [(nil, "Jane"), ("EMPLOYER", nil), ("USERNAME", nil)] as [(String?, String?)] {
            let edited = try EditsTests.edit(result, [customer], kind: kind, replacement: replacement)
            let read = EditsTests.read(edited, shape).lowercased()
            #expect(!read.contains("odalys") && !read.contains("ferriter"), "\(shape) \(kind ?? "") \(replacement ?? ""): \(Self.output(edited))")
            #expect(EditsTests.parses(edited, shape))
        }
    }

    // MARK: A name's word beside digits is refused

    @Test(arguments: EditsTests.Shape.allCases)
    func aNameWordInAnEmailAHandleOrALinkIsRefused(_ shape: EditsTests.Shape) throws {
        let result = try EditsTests.scrubbed(shape)
        let customer = result.findings[try EditsTests.customer(result)]
        for typed in ["ferriter99@example.org", "odalys99@example.org", "99odalys@example.org", "o.ferriter+1@example.org", "odalys_99@example.org", "Ferriter2024@example.org",
                      "@odalys99", "@ferriter_7", "https://x.test/ferriter", "https://x.test/u/odalys99", "https://x.test/find?who=ferriter99", "odalysferriter99@example.org"] {
            #expect(result.refusal(typed, for: [customer]) != nil, "\(shape): \(typed)")
            #expect(EditSafetyTests.refused(result, typed, for: [customer.id]), "\(shape): \(typed)")
        }
        // An email, a handle or a link that holds no word of a name is fine, and so is a short or unrelated word.
        for typed in ["jane.roe@example.org", "jroe77@example.org", "@jane99", "https://x.test/u/jane", "Jane Roe", "Jo99", "Ferris Odell", "fer99@example.org", "oda@example.org"] {
            #expect(result.refusal(typed, for: [customer]) == nil, "\(shape): \(typed) → \(String(describing: result.refusal(typed, for: [customer])))")
        }
    }

    /// The probe as it came: one name under a key, and a typed email for it.
    @Test func anEmailTypedForANameInJSONIsRefused() throws {
        let result = try Self.scrub(#"{"customer":"Odalys Ferriter"}"#, .json, name: "customer")
        let customer = try #require(result.findings.first { $0.original == "Odalys Ferriter" })
        for typed in ["ferriter99@example.org", "odalys99@example.org"] {
            #expect(result.refusal(typed, for: [customer]) != nil, "\(typed)")
            #expect(EditSafetyTests.refused(result, typed, for: [customer.id]), "\(typed)")
        }
        let edited = try EditsTests.edit(result, [customer.id], replacement: "jane.roe@example.org")
        let object = try JSONSerialization.jsonObject(with: edited.output) as? [String: String]
        #expect(object == ["customer": "jane.roe@example.org"], "\(Self.output(edited))")
    }

    // MARK: A selection is read where it was made

    /// A ticket written in prose, and again in a link's query where "+" reads as a space.
    static func ticket(_ shape: Shape) -> String {
        let note = "Ticket KX+4471 is ready. https://corvane.test/find?q=KX+4471"
        switch shape {
        case .text, .link: return note + "\n"
        case .json: return #"{"status":"\#(note)"}"#
        case .csv: return "status\n\(note)\n"
        case .xml: return "<status>\(note)</status>"
        }
    }

    /// The selection of `needle` inside `context` in the preview: a table's cell, or the text.
    static func pick(_ result: ScrubResult, _ needle: String, after context: String) -> Pick? {
        func at(_ text: String, _ marks: [Mark]) -> Pick? {
            let ns = text as NSString
            let around = ns.range(of: context)
            guard around.location != NSNotFound else { return nil }
            let found = ns.range(of: needle, range: NSRange(location: around.location, length: ns.length - around.location))
            guard found.location != NSNotFound else { return nil }
            return result.pick(in: text, marks: marks, range: found.location..<NSMaxRange(found))
        }
        switch result.preview {
        case .text(let text, let marks, _): return at(text, marks)
        case .table(_, let rows, _, let marks):
            for (row, cells) in rows.enumerated() {
                for (column, cell) in cells.enumerated() where cell.contains(context) {
                    return at(cell, marks.filter { $0.row == row && $0.column == column }.map { Mark(range: $0.range, entity: $0.entity) })
                }
            }
            return nil
        }
    }

    @Test(arguments: Shape.allCases.filter { $0 != .link })
    func aProseSelectionIsMarkedAsWrittenWhateverALinkWrites(_ shape: Shape) throws {
        let result = try Self.scrub(Self.ticket(shape), shape, name: "ticket")
        try #require(Self.output(result).contains("Ticket KX+4471") && Self.output(result).contains("q=KX+4471"), "\(shape): \(Self.output(result))")
        let picked = try #require(Self.pick(result, "KX+4471", after: "Ticket "), "\(shape)")
        #expect(picked.missed == ["KX+4471"], "\(shape): \(picked.missed)")
        let (choices, marks) = result.marking(picked.missed, as: "ID_NUMBER", choices: result.choices, marks: result.marks)
        let marked = try result.applying(choices, marks: marks)
        let after = Self.output(marked)
        // The place selected is replaced, and so is the same text in the link.
        #expect(EditEquivalenceTests.replacedWhereSelected(result, marked, "KX+4471", after: "Ticket "), "\(shape): \(after)")
        #expect(!after.contains("KX+4471") && !after.contains("4471"), "\(shape): \(after)")
        #expect(Self.parses(marked, shape), "\(shape): \(after)")
        // Type oracle: an ID of the same shape.
        let mine = try #require(marked.byHand.first)
        #expect(mine.original == "KX+4471" && EditsTests.fits(mine.standIn, "ID_NUMBER", like: "KX+4471") && mine.places.count == 2, "\(shape): \(mine.standIn) \(mine.places.count)")
        // Undone, as made; the same selection again, the same bytes.
        #expect(try marked.applying(result.choices, marks: Marks()).output == result.output)
        let again = try Self.scrub(Self.ticket(shape), shape, name: "ticket")
        let repicked = try #require(Self.pick(again, "KX+4471", after: "Ticket "))
        let remarked = again.marking(repicked.missed, as: "ID_NUMBER", choices: again.choices, marks: again.marks)
        #expect(try again.applying(remarked.0, marks: remarked.1).output == marked.output)
    }

    /// The same text selected inside the link is the value the link reads.
    @Test func aLinkSelectionIsReadAsTheLinkReadsIt() throws {
        let result = try Self.scrub(Self.ticket(.text), .text, name: "ticket")
        let picked = try #require(Self.pick(result, "KX+4471", after: "q="))
        #expect(picked.missed == ["KX 4471"], "\(picked.missed)")
        let review = try #require(result.review)
        #expect(review.identity("KX+4471", at: review.place(of: "KX+4471", in: nil)) == "KX+4471")
        #expect(review.identity("KX+4471", at: review.place(of: "KX+4471", in: .query)) == "KX 4471")
        #expect(review.identity("KX+4471") == "KX+4471", "without a place, nothing is decoded")
    }

    /// Selected encoded in a link, the mark reaches the place selected and the value written plainly.
    @Test(arguments: Shape.allCases.filter { $0 != .link })
    func anEncodedSelectionReachesThePlainValue(_ shape: Shape) throws {
        let note = "the quillmere depot opens at six. https://maps.corvane.test/find?q=%51uillmere"
        let text: String = switch shape {
        case .text, .link: note + "\n"
        case .json: #"{"depot":"\#(note)"}"#
        case .csv: "depot\n\(note)\n"
        case .xml: "<depot>\(note)</depot>"
        }
        let result = try Self.scrub(text, shape, name: "depot")
        let picked = try #require(Self.pick(result, "%51uillmere", after: "q="), "\(shape)")
        #expect(picked.missed == ["Quillmere"], "\(shape): \(picked.missed)")
        let (choices, marks) = result.marking(picked.missed, as: "LOCATION", choices: result.choices, marks: result.marks)
        let marked = try result.applying(choices, marks: marks)
        #expect(!Self.read(marked).contains("quillmere") && EditEquivalenceTests.replacedWhereSelected(result, marked, "%51uillmere", after: "q="), "\(shape): \(Self.output(marked))")
        #expect(Self.parses(marked, shape))
    }
}
