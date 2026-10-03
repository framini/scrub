import Foundation
@testable import ScrubCore
import Testing

/// A person marks what Scrub missed, and keeps what it replaced wrongly, on
/// top of the scrub as made: every place and variant takes one stand-in, each
/// place can be left on its own, and the same scrub and marks write the same bytes.

enum HandoverShape: String, CaseIterable, Sendable { case text, json, csv, xml }

/// A courier's handover in each shape a file comes in. Scrub replaces the
/// customer, and misses the depot's name, the locker code and the driver's chat handle.
private func handover(_ shape: HandoverShape) -> (name: String, data: Data) {
    let text: String
    switch shape {
    case .text:
        text = """
        Handover for Odalys Ferriter (odalys.ferriter@kestrel.example).
        Parcel waits at the Quillmere depot, locker GRV-88213. QUILLMERE closes at six.
        Quillmere's side gate is the one to use; the depot log calls it quillmere_gate.
        Driver on chat: wrenhollis. Ask wrenhollis or @wrenhollis before noon.
        """
    case .json:
        text = #"{"handover":{"customer":"Odalys Ferriter","email":"odalys.ferriter@kestrel.example","depot":"Quillmere","locker":"GRV-88213","driver_chat":"wrenhollis","notes":"QUILLMERE closes at six. Quillmere's side gate; log calls it quillmere_gate. Ask @wrenhollis before noon."}}"#
    case .csv:
        text = """
        customer,email,depot,locker,driver_chat,notes
        Odalys Ferriter,odalys.ferriter@kestrel.example,Quillmere,GRV-88213,wrenhollis,"QUILLMERE closes at six. Quillmere's side gate; log calls it quillmere_gate. Ask @wrenhollis before noon."
        Perrin Achebe,perrin.achebe@lowfield.example,Quillmere,GRV-11902,wrenhollis,Leave at the front desk

        """
    case .xml:
        text = """
        <handover><customer>Odalys Ferriter</customer><email>odalys.ferriter@kestrel.example</email><depot>Quillmere</depot><locker>GRV-88213</locker><driverChat>wrenhollis</driverChat><notes>QUILLMERE closes at six. Quillmere's side gate; log calls it quillmere_gate. Ask @wrenhollis before noon.</notes></handover>
        """
    }
    return (["text": "handover.txt", "json": "handover.json", "csv": "handover.csv", "xml": "handover.xml"][shape.rawValue] ?? "handover.txt", Data(text.utf8))
}

private func scrubbed(_ shape: HandoverShape, seed: UInt64 = 21) throws -> ScrubResult {
    let input = handover(shape)
    return try Scrubber.scrub(input.data, name: input.name, forceFullDetection: false, seed: seed)
}

private func text(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

/// Whether a stand-in can pass for a value of `entity`.
private func fits(_ standIn: String, _ entity: String, like original: String) -> Bool {
    func mask(_ s: String) -> String { String(s.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 }) }
    switch entity {
    case "PERSON", "LOCATION": return !standIn.isEmpty && standIn.allSatisfy { $0.isLetter || " .'-’".contains($0) }
    case "USERNAME": return !standIn.isEmpty && !standIn.contains(" ") && !standIn.contains("@") || standIn.hasPrefix("@") && standIn.count > 1
    case "ID_NUMBER": return mask(standIn) == mask(original)
    case "EMAIL_ADDRESS": return standIn.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    case "PHONE_NUMBER": return standIn.filter(\.isNumber).count >= 7 && !standIn.contains(where: \.isLetter)
    default: return !standIn.isEmpty
    }
}

/// Each output still parses as its format, so a mark never breaks the file.
private func parses(_ result: ScrubResult, _ shape: HandoverShape) -> Bool {
    switch shape {
    case .json: return (try? JSONSerialization.jsonObject(with: result.output)) != nil
    case .xml: return XMLParser(data: result.output).parse()
    case .csv: return text(result).split(separator: "\n").allSatisfy { !$0.isEmpty }
    case .text: return true
    }
}

private let missed: [(text: String, entity: String, variants: [String])] = [
    ("Quillmere", "LOCATION", ["quillmere"]),
    ("GRV-88213", "ID_NUMBER", ["GRV-88213"]),
    ("wrenhollis", "USERNAME", ["wrenhollis"]),
]

@Test(arguments: HandoverShape.allCases)
func aMarkedValueAndItsVariantsLeaveNoTrace(_ shape: HandoverShape) throws {
    let result = try scrubbed(shape)
    let before = text(result)
    var (choices, marks) = (result.choices, Marks())
    // As the app marks: a value Scrub only suspected and left as written is replaced too.
    for value in missed where before.contains(value.text) { (choices, marks) = result.marking([value.text], as: value.entity, choices: choices, marks: marks) }
    try #require(!marks.isEmpty, "the handover must hold something Scrub missed: \(before)")
    let marked = try result.applying(choices, marks: marks)
    let after = text(marked).lowercased()
    for entry in marks.entries {
        let value = try #require(missed.first { $0.text == entry.text })
        for variant in value.variants { #expect(!after.contains(variant.lowercased()), "\(shape): \(variant) left in \(after)") }
        let finding = try #require(marked.byHand.first { $0.original == entry.text })
        #expect(finding.places.count >= 1 && fits(finding.standIn, entry.entity, like: entry.text), "\(shape): \(entry.text) → \(finding.standIn)")
        #expect(after.contains(finding.standIn.lowercased()), "\(shape): \(finding.standIn) missing")
    }
    // What Scrub replaced stays replaced, the file still parses, and the counts grow by the places marked.
    #expect(!after.contains("ferriter") && parses(marked, shape))
    let added = marked.byHand.reduce(0) { $0 + $1.places.count }
    #expect(marked.counts.values.reduce(0, +) >= result.counts.values.reduce(0, +) + added)
}

@Test(arguments: HandoverShape.allCases)
func theSameScrubAndMarksWriteTheSameBytes(_ shape: HandoverShape) throws {
    let first = try scrubbed(shape), second = try scrubbed(shape)
    var marks = Marks()
    for value in missed where text(first).contains(value.text) { marks.add(value.text, as: value.entity) }
    let one = try first.applying(first.choices, marks: marks), two = try second.applying(second.choices, marks: marks)
    #expect(one.output == two.output)
    // Marked one at a time, or in another order, the file comes out the same.
    var stepwise = first
    var growing = Marks()
    for entry in marks.entries {
        growing.add(entry.text, as: entry.entity)
        stepwise = try stepwise.applying(stepwise.choices, marks: growing)
    }
    #expect(stepwise.output == one.output)
    var reversed = Marks()
    for entry in marks.entries.reversed() { reversed.add(entry.text, as: entry.entity) }
    #expect(try first.applying(first.choices, marks: reversed).output == one.output)
    // Taking every mark back writes the scrub as made.
    #expect(try one.applying(one.choices, marks: Marks()).output == first.output)
}

@Test func aPlaceLeftAsWrittenKeepsItsOriginalAndOnlyThere() throws {
    let result = try scrubbed(.csv)
    var marks = Marks()
    marks.add("Quillmere", as: "LOCATION")
    let marked = try result.applying(result.choices, marks: marks)
    let finding = try #require(marked.byHand.first)
    #expect(finding.places.count >= 3, "both depots and the note: \(finding.places.count)")
    var choices = marked.choices
    choices.set(try #require(finding.places.first), leave: true)
    let undone = try marked.applying(choices, marks: marks)
    #expect(text(undone).components(separatedBy: "Quillmere").count == 2, "\(text(undone))")
    #expect(text(undone).contains(finding.standIn))
    // Left everywhere, it is as Scrub made it.
    choices.set(finding, leave: true)
    #expect(try marked.applying(choices, marks: marks).output == result.output)
}

@Test func aMarkedNameTakesTheStandInItsPartsAlreadyHave() throws {
    // Scrub read "Varrick" in the log and replaced it, but not the team's full name.
    let input = #"{"sprint":"Harrowgate","owner_team":"Ysolde Varrick","chat":"yvarrick","log":"VARRICK, Y. signed off; Varrick's notes attached"}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "sprint.json", forceFullDetection: false, seed: 5)
    let surname = try #require(result.findings.first { $0.original == "Varrick" }, "\(text(result))")
    // Selected with the surname's stand-in beside it, the first name is what to mark.
    guard case .text(let preview, let shown, _) = result.preview else { Issue.record("not a text preview"); return }
    let team = (preview as NSString).range(of: "Ysolde " + surname.standIn)
    #expect(result.pick(in: preview, marks: shown, range: team.location..<NSMaxRange(team)).missed == ["Ysolde"])
    var marks = Marks()
    marks.add("Ysolde", as: "PERSON")
    let marked = try result.applying(result.choices, marks: marks)
    #expect(!text(marked).lowercased().contains("ysolde"), "\(text(marked))")
    // A handle built from the name is a variant of it too.
    var full = Marks()
    full.add("yvarrick", as: "USERNAME")
    #expect(!text(try result.applying(result.choices, marks: full)).contains("yvarrick"))
    #expect(text(marked).contains(surname.standIn))
}

@Test func aMarkedFullNameReplacesItsInitialsHandlesAndPossessives() throws {
    // A team name Scrub reads as no one, written every way a person's name is.
    let input = "Ticket 4471: Harrowgate Lisk owns the rollout. LISK, H. approved; H. Lisk's sign-off is attached; Lisk, Harrowgate is on call; ping harrowgate.lisk or hlisk."
    let result = try Scrubber.scrub(Data(input.utf8), name: "notes.txt", forceFullDetection: false, seed: 9)
    let before = text(result)
    var marks = Marks()
    marks.add("Harrowgate Lisk", as: "PERSON")
    let after = text(try result.applying(result.choices, marks: marks))
    for variant in ["harrowgate", "lisk"] where before.lowercased().contains(variant) {
        #expect(!after.lowercased().contains(variant), "\(variant) left in \(after)")
    }
}

@Test func keepingTheOriginalOfAStandInLeavesItEverywhere() throws {
    let result = try scrubbed(.text)
    let customer = try #require(result.findings.first { $0.original == "Odalys Ferriter" })
    guard case .text(let preview, let marks, _) = result.preview else { Issue.record("not a text preview"); return }
    let at = (preview as NSString).range(of: customer.standIn)
    // A click inside the stand-in picks it whole.
    let picked = result.pick(in: preview, marks: marks, range: (at.location + 2)..<(at.location + 2))
    #expect(picked.replaced.contains { $0.id == customer.id } && picked.missed.isEmpty)
    let (choices, kept) = result.keeping(picked, choices: result.choices, marks: result.marks)
    let after = text(try result.applying(choices, marks: kept))
    #expect(after.contains("Odalys Ferriter") && !after.contains(customer.standIn), "\(after)")
}

@Test func aSelectionIsWidenedToWholeValues() throws {
    let result = try scrubbed(.json)
    guard case .text(let preview, let marks, _) = result.preview else { Issue.record("not a text preview"); return }
    let ns = preview as NSString
    // Half a word, and half a code, are taken whole.
    let depot = ns.range(of: "\"Quillmere\"")
    #expect(result.pick(in: preview, marks: marks, range: (depot.location + 3)..<(depot.location + 7)).missed == ["Quillmere"])
    let locker = ns.range(of: "GRV-88213")
    #expect(result.pick(in: preview, marks: marks, range: (locker.location + 1)..<(locker.location + 6)).missed == ["GRV-88213"])
    // A selection over several lines of JSON picks the values, not the keys.
    let lines = ns.range(of: "\"depot\"")
    let end = NSMaxRange(ns.range(of: "\"wrenhollis\""))
    let picked = result.pick(in: preview, marks: marks, range: lines.location..<end)
    #expect(Set(picked.missed).isSuperset(of: ["GRV-88213", "wrenhollis"]) && !picked.missed.contains { $0.contains("depot") || $0.contains("locker") }, "\(picked.missed)")
    // A selection wholly on a stand-in picks what it replaced.
    let customer = try #require(result.findings.first { $0.original == "Odalys Ferriter" })
    let stand = ns.range(of: customer.standIn)
    #expect(result.pick(in: preview, marks: marks, range: stand.location..<NSMaxRange(stand)).replaced.contains { $0.id == customer.id })
}

@Test func markingAValueKeptAsWrittenReplacesItAgain() throws {
    let result = try scrubbed(.text)
    let customer = try #require(result.findings.first { $0.original == "Odalys Ferriter" })
    var choices = result.choices
    choices.set(customer, leave: true)
    let kept = try result.applying(choices)
    #expect(text(kept).contains("Odalys Ferriter"))
    let (again, marks) = kept.marking(["Odalys Ferriter"], as: "PERSON", choices: kept.choices, marks: kept.marks)
    #expect(!text(try kept.applying(again, marks: marks)).contains("Odalys Ferriter"))
}

/// Whatever kind the person picks, the value is replaced, by a stand-in of that kind.
@Test(arguments: Marks.kinds)
func everyKindReplacesTheValueWithOneOfItsKind(_ kind: String) throws {
    let result = try scrubbed(.csv)
    var marks = Marks()
    marks.add("Quillmere", as: kind)
    let marked = try result.applying(result.choices, marks: marks)
    let finding = try #require(marked.byHand.first)
    // Secrets and IDs are told apart by case: "QUILLMERE" would be another one.
    let exact = ["SECRET", "ID_NUMBER"].contains(kind)
    #expect(finding.standIn.lowercased() != "quillmere" && !(exact ? text(marked) : text(marked).lowercased()).contains(exact ? "Quillmere" : "quillmere"), "\(kind): \(text(marked))")
    #expect(fits(finding.standIn, kind, like: "Quillmere"), "\(kind): \(finding.standIn)")
    #expect(parses(marked, .csv) && text(marked).split(separator: "\n").count == text(result).split(separator: "\n").count)
}

@Test func theKindIsGuessedFromThePatternTheFieldOrTheShape() {
    #expect(Marks.guess("wren.hollis@kestrel.example") == "EMAIL_ADDRESS")
    #expect(Marks.guess("(415) 867-2290") == "PHONE_NUMBER")
    #expect(Marks.guess("GRV-88213") == "ID_NUMBER")
    #expect(Marks.guess("wrenhollis") != "PERSON")
    #expect(Marks.guess("14 Larkspur Row") == "ADDRESS")
    #expect(Marks.guess("Ysolde Varrick") == "PERSON")
    #expect(Marks.guess("Kestrel Freight Ltd") == "EMPLOYER")
}

@Test func aValueMarkedAgainTakesTheNewKind() {
    var marks = Marks()
    let first = marks.add("Quillmere", as: "LOCATION")
    #expect(marks.add("quillmere", as: "LOCATION") == first && marks.entries.count == 1)
    marks.add("QUILLMERE", as: "PERSON")
    #expect(marks.entries.count == 1 && marks.entries[0].entity == "PERSON" && marks.entries[0].id != first.id)
    marks.remove(marks.entries[0].id)
    #expect(marks.isEmpty)
}

/// Marking reads the scrub as made with one search, not the detectors again.
@Test func markingALargeTableIsQuick() throws {
    var csv = "account,depot,locker,notes\n"
    for row in 0..<5_000 { csv += "AC-\(10_000 + row),\(row.isMultiple(of: 50) ? "Quillmere" : "Larkfield"),L\(row % 97),\(row.isMultiple(of: 7) ? "via Quillmere gate" : "front desk")\n" }
    let result = try Scrubber.scrub(Data(csv.utf8), name: "lockers.csv", forceFullDetection: false, seed: 3)
    var marks = Marks()
    marks.add("Quillmere", as: "LOCATION")
    let clock = ContinuousClock()
    let started = clock.now
    let marked = try result.applying(result.choices, marks: marks)
    let took = clock.now - started
    // Scrub read the gate's notes as a place itself; the depot column is what it missed.
    #expect(!text(marked).contains("Quillmere"))
    #expect((marked.byHand.first?.places.count ?? 0) >= 100)
    #expect(took < .seconds(5), "\(took)")
}
