import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// What a document writes is what the review accepted: a typed replacement
/// whose written form (an XML name keeps only some characters) would spell
/// an original is refused, a name in a handle's short words is refused
/// whatever separates them, a person's name built into an element name is
/// that person's and follows their edits, and a flattened column with a
/// field of several words beside it makes the record a person's.
@Suite struct WrittenFormTests {
    typealias Finding = ScrubCore::Finding

    static func output(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

    static func scrub(_ text: String, _ ext: String, seed: UInt64 = 9) throws -> ScrubResult {
        try Scrubber.scrub(Data(text.utf8), name: "record." + ext, forceFullDetection: false, seed: seed)
    }

    static func edit(_ result: ScrubResult, _ finding: Finding, kind: String? = nil, replacement: String? = nil) throws -> ScrubResult {
        let target = result.current.first { $0.id == finding.id } ?? finding
        let (choices, marks, edits) = try result.editing([target], kind: kind, replacement: replacement, choices: result.choices, marks: result.marks, edits: result.edits)
        return try result.applying(choices, marks: marks, edits: edits)
    }

    // MARK: An XML name keeps only some characters

    @Test func aReplacementAnElementNameWouldJoinIntoTheOriginalIsNeverWritten() throws {
        let text = "<root><Odalys>hello</Odalys><first_name>Odalys</first_name></root>"
        let result = try Self.scrub(text, "xml")
        let name = try #require(result.findings.first { $0.original == "Odalys" }, "\(Self.output(result))")
        for typed in ["Oda lys", "Oda/lys", "Oda💫lys", "O dalys", "Oda\tlys", "ODA LYS", "Odá lys"] {
            if result.refusal(typed, for: [name]) != nil { continue }
            let edited = try Self.edit(result, name, replacement: typed)
            #expect(!Self.output(edited).lowercased().contains("odalys"), "\(typed): \(Self.output(edited))")
        }
        // A replacement of the same characters in another order is no one's name.
        #expect(result.refusal("Ysla Doe", for: [name]) == nil)
        let fine = try Self.edit(result, name, replacement: "Ysla Doe")
        #expect(!Self.output(fine).lowercased().contains("odalys"), "\(Self.output(fine))")
    }

    @Test func anAttributeNameIsWrittenSoToo() throws {
        let text = #"<root><person Odalys="1"><first_name>Odalys</first_name></person></root>"#
        let result = try Self.scrub(text, "xml")
        let name = try #require(result.findings.first { $0.original == "Odalys" }, "\(Self.output(result))")
        for typed in ["Oda lys", "Oda=lys", "Oda\"lys"] {
            if result.refusal(typed, for: [name]) != nil { continue }
            let edited = try Self.edit(result, name, replacement: typed)
            #expect(!Self.output(edited).lowercased().contains("odalys"), "\(typed): \(Self.output(edited))")
        }
    }

    // MARK: A short name in a handle

    @Test func aShortNameIsRefusedInAHandleWhateverSeparatesItsWords() throws {
        let shapes: [(String, String)] = [
            (#"{"customer":"Bo Li"}"#, "json"),
            ("<order><customer>Bo Li</customer></order>", "xml"),
            ("customer,total\nBo Li,12\nAn Wu,4\n", "csv"),
            ("customer: Bo Li\ntotal: 12\n", "txt"),
            ("Customer Bo Li called about the order.", "txt"),
        ]
        for (text, ext) in shapes {
            let result = try Self.scrub(text, ext)
            let customer = try #require(result.findings.first { $0.original == "Bo Li" }, "\(ext): \(Self.output(result))")
            for typed in ["bo.li99@example.org", "@bo_li99", "bo-li", "BO.LI", "li.bo@example.org", "x bo_li x", "bo+li@corvane.test"] {
                #expect(result.refusal(typed, for: [customer]) != nil, "\(ext): \(typed)")
            }
            // Another person's name, and words that only hold the short ones, are no one's.
            for typed in ["Bob Lin", "Boris Lim", "bob.lin42@example.org", "Jane Roe"] {
                #expect(result.refusal(typed, for: [customer]) == nil, "\(ext): \(typed) → \(String(describing: result.refusal(typed, for: [customer])))")
            }
        }
    }

    @Test func anotherShortNameInAHandleIsRefusedForAnyone() throws {
        let result = try Self.scrub(#"{"customer":"Bo Li","agent":"Odalys Ferriter"}"#, "json")
        let agent = try #require(result.findings.first { $0.original == "Odalys Ferriter" }, "\(Self.output(result))")
        #expect(result.refusal("bo.li@corvane.test", for: [agent]) != nil)
        #expect(result.refusal("Jane Roe", for: [agent]) == nil)
    }

    // MARK: A name built into an element name

    @Test func aNameBuiltIntoAnElementNameFollowsItsPerson() throws {
        let text = "<root><willrose>ok</willrose><customer>Will Rose</customer></root>"
        let result = try Self.scrub(text, "xml")
        #expect(!Self.output(result).lowercased().contains("willrose"), "\(Self.output(result))")
        let customer = try #require(result.findings.first { $0.original == "Will Rose" }, "\(Self.output(result))")
        let edited = try Self.edit(result, customer, replacement: "Jane Roe")
        let written = Self.output(edited)
        #expect(written.contains("<customer>Jane Roe</customer>"), "\(written)")
        #expect(written.lowercased().contains("<janeroe>"), "\(written)")
        // Nothing of the first stand-in is left.
        let first = try #require(customer.standIn.split(separator: " ").first.map(String.init))
        #expect(!written.contains(first), "\(written)")
        // Kept as written, both are hers again; undone, the scrub as made.
        let kept = try edited.applying(Choices(left: Set(edited.current.filter { $0.original.lowercased().replacingOccurrences(of: " ", with: "") == "willrose" }.map(\.id))), marks: edited.marks, edits: edited.edits)
        #expect(Self.output(kept).contains("<willrose>"), "\(Self.output(kept))")
        #expect(Self.output(kept).contains("<customer>Will Rose</customer>"), "\(Self.output(kept))")
        #expect(try kept.applying(result.choices, marks: Marks(), edits: Edits()).output == result.output)
        // The tag is a finding a person can see and pick.
        #expect(result.findings.contains { $0.original.lowercased() == "willrose" }, "\(result.findings.map(\.original))")
    }

    @Test func aSnakeCaseNameInAnElementNameFollowsItsPersonToo() throws {
        let text = "<root><will_rose_notes>ok</will_rose_notes><customer>Will Rose</customer></root>"
        let result = try Self.scrub(text, "xml")
        #expect(!Self.output(result).lowercased().contains("will_rose"), "\(Self.output(result))")
        let customer = try #require(result.findings.first { $0.original == "Will Rose" })
        let edited = try Self.edit(result, customer, replacement: "Jane Roe")
        #expect(Self.output(edited).contains("<jane_roe_notes>"), "\(Self.output(edited))")
    }

    // MARK: A flattened record's fields of several words

    @Test func aFieldOfSeveralWordsBesideAFlattenedNameMakesItAPersons() throws {
        // A person's own field makes any name theirs.
        for (second, value) in [("application.date_of_birth", "1984-03-02"), ("application.dob", "1984-03-02")] {
            let text = "application.name,\(second)\nzorvane quillmere,\(value)\n"
            let result = try Self.scrub(text, "csv")
            #expect(!Self.output(result).lowercased().contains("quillmere"), "\(second): \(Self.output(result))")
        }
        // A way to reach them, which an app has too, a name written as a person's.
        for (second, value) in [("application.email_address", "o.quillmere@corvane.test"), ("application.phone_number", "(415) 555-0142")] {
            let text = "application.name,\(second)\nOdalys Quillmere,\(value)\n"
            let result = try Self.scrub(text, "csv")
            #expect(!Self.output(result).lowercased().contains("quillmere"), "\(second): \(Self.output(result))")
        }
        // Under an app, beside its own fields, a name is the app's.
        let app = try Self.scrub("application.name,application.release_date\nLedgerly,2024-01-02\n", "csv")
        #expect(Self.output(app).contains("Ledgerly"), "\(Self.output(app))")
    }

    // MARK: A name made valid or told apart

    @Test func aNameMadeValidNeverSpellsTheOriginal() throws {
        let shapes = [
            "<root><n123>ok</n123><username>n123</username></root>",
            #"<root><item n123="1"/><username>n123</username></root>"#,
            "<root><n123>ok</n123><n12>x</n12><username>n123</username></root>",
            "<root><n1>ok</n1><username>n1</username></root>",
        ]
        for text in shapes {
            var result = try Self.scrub(text, "xml")
            if !result.findings.contains(where: { $0.original.lowercased() == "n123" || $0.original.lowercased() == "n1" }) {
                var marks = Marks()
                marks.add(text.contains("n123") ? "n123" : "n1", as: "USERNAME")
                result = try result.applying(result.choices, marks: marks)
            }
            let original = text.contains("n123") ? "n123" : "n1"
            let handle = try #require(result.current.first { $0.original.lowercased() == original }, "\(text): \(result.current.map(\.original))")
            for typed in ["123", "12", "n12", "1x", "1", "-123", "_123"] {
                if result.refusal(typed, for: [handle]) != nil { continue }
                let edited = try Self.edit(result, handle, replacement: typed)
                let written = Self.output(edited)
                #expect(XMLParser(data: edited.output).parse(), "\(text) / \(typed): \(written)")
                let names = written.split(whereSeparator: { "<>/= \"".contains($0) }).map { $0.lowercased() }
                #expect(!names.contains(original), "\(text) / \(typed): \(written)")
                #expect(!names.contains { $0.contains(original) && !Review.squeezed(typed).lowercased().contains(original) }, "\(text) / \(typed): \(written)")
            }
        }
    }

    // MARK: Another kind for a typed replacement

    @Test func anotherKindForATypedReplacementIsCheckedInEveryFormItWrites() throws {
        // A person marks a lowercase name as an employer, types a replacement, then makes it a person.
        let text = #"{"first_name":"Odalys","notes":"harrowgate lisk owns the rollout. ping harrowgatelisk."}"#
        let result = try Self.scrub(text, "json")
        var marks = result.marks
        marks.add("harrowgate lisk", as: "EMPLOYER")
        let marked = try result.applying(result.choices, marks: marks)
        let mark = try #require(marked.byHand.first, "\(marked.byHand)")
        for typed in ["Oda lys", "oda-lys", "ODA LYS"] {
            guard marked.refusal(typed, for: [mark]) == nil else { continue }
            let typedIn = try Self.edit(marked, mark, replacement: typed)
            let now = try #require(typedIn.byHand.first)
            do {
                let (choices, marks, edits) = try typedIn.editing([now], kind: "PERSON", replacement: nil, choices: typedIn.choices, marks: typedIn.marks, edits: typedIn.edits)
                let person = try typedIn.applying(choices, marks: marks, edits: edits)
                #expect(!Self.output(person).lowercased().contains("odalys"), "\(typed): \(Self.output(person))")
            } catch is Refusal {}
        }
        // A replacement no form of which spells anyone is kept through the change.
        let fine = try Self.edit(marked, mark, replacement: "Jane Roe")
        let now = try #require(fine.byHand.first)
        let (choices, rekinded, edits) = try fine.editing([now], kind: "PERSON", replacement: nil, choices: fine.choices, marks: fine.marks, edits: fine.edits)
        let person = try fine.applying(choices, marks: rekinded, edits: edits)
        #expect(Self.output(person).contains("Jane Roe owns") && Self.output(person).contains("janeroe"), "\(Self.output(person))")
    }

    @Test func anotherKindForAFindingsTypedReplacementIsCheckedToo() throws {
        let text = #"{"first_name":"Odalys","employer":"Harrowgate Lisk","notes":"ping harrowgatelisk about it"}"#
        let result = try Self.scrub(text, "json")
        guard let employer = result.findings.first(where: { $0.original == "Harrowgate Lisk" }) else { return }
        for typed in ["Oda lys", "oda-lys"] {
            guard result.refusal(typed, for: [employer]) == nil else { continue }
            let typedIn = try Self.edit(result, employer, replacement: typed)
            for kind in Marks.kinds where kind != employer.entity {
                do {
                    let changed = try Self.edit(typedIn, employer, kind: kind)
                    #expect(!Self.output(changed).lowercased().contains("odalys"), "\(typed) as \(kind): \(Self.output(changed))")
                } catch is Refusal {}
            }
        }
    }
}
