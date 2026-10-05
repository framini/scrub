import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// A replacement a person types never brings an original back, in what it
/// says or in what it would write in the person's other forms; a bare JSON
/// number takes only a number; names typed one after another for one person
/// make one person; and a kind that cannot be written where its value stands
/// is refused, never claimed while the output keeps the old stand-in.
@Suite struct EditSafetyTests {
    typealias Shape = EditsTests.Shape

    static func scrub(_ text: String, name: String, seed: UInt64 = 41) throws -> ScrubResult {
        try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: seed)
    }

    static func refused(_ result: ScrubResult, _ typed: String, for ids: [Int]) -> Bool {
        do {
            _ = try result.editing(result.findings.filter { ids.contains($0.id) }, kind: nil, replacement: typed, choices: result.choices, marks: result.marks, edits: result.edits)
            return false
        } catch { return error is Refusal }
    }

    /// The bare number under "phone", as the output writes it.
    static func phone(in result: ScrubResult) -> String? {
        let text = EditsTests.output(result)
        guard let range = text.range(of: #""phone"\s*:\s*[^,}\s]+"#, options: .regularExpression) else { return nil }
        return String(text[range].drop { $0 != ":" }.dropFirst().drop(while: \.isWhitespace))
    }

    /// Whether a refusal names `word`, in any case.
    static func names(_ refusal: Refusal?, _ word: String) -> Bool {
        guard let refusal else { return false }
        return String(describing: refusal).lowercased().contains(word.lowercased())
    }

    // MARK: A typed replacement brings nothing back

    @Test(arguments: Shape.allCases)
    func aKeptNameWordIsRefused(_ shape: Shape) throws {
        let result = try EditsTests.scrubbed(shape)
        let customer = result.findings[try EditsTests.customer(result)]
        // Her first name kept, or her surname, as a word, a possessive, or in capitals.
        for (typed, word) in [("Odalys Roe", "odalys"), ("Jane Ferriter", "ferriter"), ("Jane FERRITER", "ferriter"), ("Jane Roe-Ferriter", "ferriter"),
                              ("Ferriter's cousin", "ferriter"), ("Ödalys Roe", "odalys")] {
            let refusal = result.refusal(typed, for: [customer])
            #expect(refusal != nil && (Self.names(refusal, word) || refusal == .original), "\(shape): \(typed) → \(String(describing: refusal))")
            #expect(Self.refused(result, typed, for: [customer.id]), "\(shape): \(typed) must be refused by editing too")
        }
        // A name typed anew that keeps nothing of hers is fine.
        #expect(result.refusal("Jane Roe", for: [customer]) == nil)
        #expect(result.refusal("Ferris Odell", for: [customer]) == nil, "a word that only begins like hers is no part of her name")
    }

    @Test(arguments: Shape.allCases)
    func theOriginalHiddenOrEncodedIsRefused(_ shape: Shape) throws {
        let result = try EditsTests.scrubbed(shape)
        let customer = result.findings[try EditsTests.customer(result)]
        for typed in ["Odalys\u{200B}Ferriter", "Odalys \u{2060}Ferriter", "Odalys\u{00A0}Ferriter", "Oda\u{00AD}lys Ferriter", "Odal\u{200D}ys Roe",
                      "Odalys%20Ferriter", "Odalys+Ferriter", "%4Fdalys Roe", "odalysferriter", "oferriter", "Odal**ys** Ferriter", "Jane Fer\u{2062}riter", "Jane \u{2064}Ferri\u{200E}ter"] {
            #expect(result.refusal(typed, for: [customer]) != nil, "\(shape): \(typed.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "\\u{%04X}", $0.value) }.joined())")
            #expect(Self.refused(result, typed, for: [customer.id]))
        }
    }

    /// Another person's name word, from a name Scrub found, or one marked by hand.
    @Test(arguments: Shape.allCases)
    func anotherPersonsNameWordIsRefused(_ shape: Shape) throws {
        let result = try EditsTests.scrubbed(shape)
        let customer = result.findings[try EditsTests.customer(result)]
        var marks = Marks()
        marks.add("Quillmere Tavish", as: "PERSON")
        let marked = try result.applying(result.choices, marks: marks)
        #expect(Self.names(marked.refusal("Jane Tavish", for: [customer]), "tavish"), "\(shape)")
        #expect(Self.names(marked.refusal("Quillmere Roe", for: [customer]), "quillmere"), "\(shape)")
        #expect(marked.refusal("quillmeretavish", for: [customer]) != nil, "\(shape)")
    }

    /// A handover whose customer's email is her two names joined: a name
    /// typed for her that keeps neither word whole can still spell her
    /// handle once her email is renamed piece by piece.
    static func joinedHandle(_ shape: Shape) -> (name: String, text: String) {
        let link = "https://portal.corvane.test/parcels?name=Odalys+Ferriter&ref=48213"
        switch shape {
        case .text: return ("handle.txt", "Handover for Odalys Ferriter (odalysferriter@kestrel.example). Odalys said the side gate is open. Track it at \(link)\n")
        case .link: return ("handle.txt", "Parcel page: \(link)\nCustomer: Odalys Ferriter, odalysferriter@kestrel.example\n")
        case .json: return ("handle.json", #"{"customer":"Odalys Ferriter","email":"odalysferriter@kestrel.example","page":"\#(link)"}"#)
        case .csv: return ("handle.csv", "customer,email,page\nOdalys Ferriter,odalysferriter@kestrel.example,\(link)\n")
        case .xml: return ("handle.xml", "<handover><customer>Odalys Ferriter</customer><email>odalysferriter@kestrel.example</email><page>\(link.replacingOccurrences(of: "&", with: "&amp;"))</page></handover>")
        }
    }

    @Test(arguments: Shape.allCases)
    func aVariantThatWouldHoldTheOriginalIsRefused(_ shape: Shape) throws {
        let input = Self.joinedHandle(shape)
        let result = try Self.scrub(input.text, name: input.name)
        let customer = result.findings[try EditsTests.customer(result)]
        let email = try #require(result.findings.first { $0.original == "odalysferriter@kestrel.example" }, "\(shape): \(result.findings.map(\.original))")
        // Her email's stand-in is her stand-in name joined, so a name typed for her renames it.
        let renamed = try EditsTests.edit(result, [customer.id], replacement: "Jane Roe")
        try #require(renamed.revised(email).standIn.hasPrefix("janeroe@"), "\(shape): \(renamed.revised(email).standIn)")
        // Neither word is hers, but joined they spell her handle.
        let typed = "Odaly Sferriter"
        #expect(result.refusal(typed, for: [customer]) != nil, "\(shape)")
        #expect(Self.refused(result, typed, for: [customer.id]), "\(shape)")
    }

    // MARK: A bare JSON number takes a JSON number

    @Test func aBareNumberTakesOnlyAValidJSONNumber() throws {
        let result = try Self.scrub(#"{"customer":"Odalys Ferriter","phone":7025550128,"locker":"GRV-88213"}"#, name: "locker.json", seed: 7)
        let phone = try #require(result.findings.first { $0.original == "7025550128" }, "\(result.findings.map(\.original))")
        for typed in ["0012345678", "+2125550147", "2125550147.", ".5", "1e", "1e+", "--1", "1 2", "١٢٣", "0x1F", "2125550147\n"] {
            #expect(result.refusal(typed, for: [phone]) == .number, "\(typed)")
            #expect(Self.refused(result, typed, for: [phone.id]), "\(typed)")
        }
        for typed in ["2125550147", "0", "-2125550147", "2125550.147", "2.125e9", "2E+9", "-0.5e-3"] {
            #expect(result.refusal(typed, for: [phone]) == nil, "\(typed)")
            let edited = try EditsTests.edit(result, [phone.id], replacement: typed)
            #expect((try? JSONSerialization.jsonObject(with: edited.output)) != nil, "\(typed): \(EditsTests.output(edited))")
            #expect(Self.phone(in: edited) == typed, "\(EditsTests.output(edited))")
        }
    }

    /// Only a bare number is held to a number: the same phone written as text takes any text.
    @Test(arguments: [Shape.text, .csv, .xml])
    func aNumberWrittenAsTextTakesAnyNumberShape(_ shape: Shape) throws {
        let text: String, name: String
        switch shape {
        case .csv: (text, name) = ("customer,phone\nOdalys Ferriter,7025550128\n", "lockers.csv")
        case .xml: (text, name) = ("<locker><customer>Odalys Ferriter</customer><phone>7025550128</phone></locker>", "locker.xml")
        default: (text, name) = ("Call Odalys Ferriter on 7025550128 before noon.", "note.txt")
        }
        let result = try Self.scrub(text, name: name, seed: 7)
        let phone = try #require(result.findings.first { $0.original == "7025550128" }, "\(shape): \(result.findings.map(\.original))")
        #expect(result.refusal("0012345678", for: [phone]) == nil, "\(shape)")
    }

    // MARK: Successive names make one person

    /// The ids of the customer's full name and of her first name alone.
    static func person(_ result: ScrubResult) throws -> (full: Int, first: Int) {
        let full = try EditsTests.customer(result)
        let first = try #require(result.findings.firstIndex { $0.original == "Odalys" }, "the first name alone: \(result.findings.map(\.original))")
        return (full, first)
    }

    /// Each name typed in turn, from the editor as it then reads; the state after each.
    static func edits(_ result: ScrubResult, _ steps: [(Int, String)]) throws -> [(Choices, Marks, Edits)] {
        var state = (result.choices, result.marks, result.edits)
        var made: [(Choices, Marks, Edits)] = []
        var current = result
        for (id, typed) in steps {
            state = try current.editing(current.findings.filter { $0.id == id }, kind: nil, replacement: typed, choices: state.0, marks: state.1, edits: state.2)
            current = try current.applying(state.0, marks: state.1, edits: state.2)
            made.append(state)
        }
        return made
    }

    @Test(arguments: [Shape.text, .json, .csv, .xml])
    func aFirstNameTypedAfterTheFullNameRenamesEveryForm(_ shape: Shape) throws {
        let result = try EditsTests.scrubbed(shape)
        let (full, first) = try Self.person(result)
        let email = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" })
        let domain = try #require(email.standIn.split(separator: "@").last).description
        let steps = try Self.edits(result, [(full, "Jane Roe"), (first, "Alice")])
        let state = try #require(steps.last)
        let edited = try result.applying(state.0, marks: state.1, edits: state.2)
        let read = EditsTests.read(edited, shape)
        #expect(read.contains("Alice Roe") && read.contains("Alice said") && read.contains("Ms Roe") && read.contains("alice.roe@" + domain), "\(shape): \(read)")
        #expect(!read.contains("Jane"), "\(shape): the first name typed before is gone everywhere: \(read)")
        #expect(EditsTests.query("name", in: EditsTests.output(edited)).map { URLs.decode($0, .query) } == "Alice Roe", "\(shape): \(EditsTests.output(edited))")
        // The list of values says the same.
        #expect(edited.revised(result.findings[full]).standIn == "Alice Roe" && edited.revised(result.findings[first]).standIn == "Alice")
        #expect(edited.current.contains { $0.entity == "EMAIL_ADDRESS" && $0.standIn == "alice.roe@" + domain })
        #expect(EditsTests.parses(edited, shape))
    }

    @Test(arguments: [Shape.text, .json, .csv, .xml])
    func aFullNameTypedAfterTheFirstNameRenamesEveryForm(_ shape: Shape) throws {
        let result = try EditsTests.scrubbed(shape)
        let (full, first) = try Self.person(result)
        let email = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" })
        let domain = try #require(email.standIn.split(separator: "@").last).description
        let steps = try Self.edits(result, [(first, "Alice"), (full, "Jane Roe")])
        let state = try #require(steps.last)
        let edited = try result.applying(state.0, marks: state.1, edits: state.2)
        let read = EditsTests.read(edited, shape)
        #expect(read.contains("Jane Roe") && read.contains("Jane said") && read.contains("Ms Roe") && read.contains("jane.roe@" + domain), "\(shape): \(read)")
        #expect(!read.contains("Alice"), "\(shape): \(read)")
        #expect(edited.revised(result.findings[full]).standIn == "Jane Roe" && edited.revised(result.findings[first]).standIn == "Jane")
        #expect(EditsTests.parses(edited, shape))
    }

    /// The same edits made in the same order write the same bytes; undone
    /// step by step, each earlier state's bytes come back exactly.
    @Test(arguments: [Shape.text, .json, .csv, .xml])
    func successiveNamesUndoAndRedoToTheSameBytes(_ shape: Shape) throws {
        let one = try EditsTests.scrubbed(shape), two = try EditsTests.scrubbed(shape)
        let (full, first) = try Self.person(one)
        let steps = try Self.edits(one, [(full, "Jane Roe"), (first, "Alice")])
        let outputs = try steps.map { try one.applying($0.0, marks: $0.1, edits: $0.2).output }
        #expect(try steps.map { try two.applying($0.0, marks: $0.1, edits: $0.2).output } == outputs)
        let last = try one.applying(steps[1].0, marks: steps[1].1, edits: steps[1].2)
        let undone = try last.applying(steps[0].0, marks: steps[0].1, edits: steps[0].2)
        #expect(undone.output == outputs[0])
        #expect(try undone.applying(one.choices, marks: Marks(), edits: Edits()).output == one.output)
        #expect(try undone.applying(steps[1].0, marks: steps[1].1, edits: steps[1].2).output == outputs[1])
    }

    // MARK: A kind that cannot be written is refused

    @Test func aBareNumberCannotBecomeAName() throws {
        let result = try Self.scrub(#"{"customer":"Odalys Ferriter","phone":7025550128,"locker":"GRV-88213"}"#, name: "locker.json", seed: 7)
        let phone = try #require(result.findings.first { $0.original == "7025550128" }, "\(result.findings.map(\.original))")
        #expect(throws: Refusal.number) { try result.editing([phone], kind: "PERSON", replacement: nil, choices: result.choices, marks: result.marks, edits: result.edits) }
        #expect(throws: Refusal.number) { try result.editing([phone], kind: "EMAIL_ADDRESS", replacement: nil, choices: result.choices, marks: result.marks, edits: result.edits) }
        // Edits that ask for it anyway are not written partly, and the list says what is written.
        var edits = Edits()
        edits.setKind("PERSON", of: phone.id)
        let forced = try result.applying(result.choices, marks: result.marks, edits: edits)
        let shown = try #require(forced.current.first { $0.id == phone.id })
        #expect(Self.phone(in: forced) == phone.standIn, "\(EditsTests.output(forced))")
        #expect(shown.entity == phone.entity && shown.standIn == phone.standIn, "\(shown.entity) \(shown.standIn)")
        #expect((try? JSONSerialization.jsonObject(with: forced.output)) != nil)
    }
}
