import Foundation
@testable import ScrubCore
import Testing

/// What the rules leave as written, the span tagger reads, and what it
/// suspects review asks about. It never replaces anything and never takes
/// away what a rule found.
@Suite(.serialized, .enabled(if: SpanTagger.shared != nil))
struct EscalationTests {
    static func scrub(_ text: String, _ name: String, layer: Bool = true) throws -> ScrubResult {
        try Escalation.$active.withValue(layer) { try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 11) }
    }

    @Test func aNameTheRulesLeftInProseIsAskedAbout() throws {
        let tagger = try #require(SpanTagger.shared)
        let text = "Escalated by Tamsin Oberdorf this morning; she will call back about the refund."
        var leaf = DocumentLeaf(text)
        leaf.reading = .prose
        let suspects = try Escalation.suspects([leaf], [DocumentValue(text: text, marks: [], unresolved: [])], tagger: tagger)
        let marks = try #require(suspects[0])
        #expect(marks.map(\.original) == ["Tamsin Oberdorf"] && marks.map(\.entity) == ["PERSON"], "\(marks)")
        #expect(marks.allSatisfy { $0.confidence == LeakGate.suspectConfidence })
        // A place a rule already marked is never read again.
        let marked = Mark(range: 13..<28, entity: "PERSON", original: "Tamsin Oberdorf", confidence: 0.9)
        #expect(try Escalation.suspects([leaf], [DocumentValue(text: text, marks: [marked], unresolved: [])], tagger: tagger).isEmpty)
    }

    @Test func aFieldNoRuleKnowsIsAskedAboutAndLeftAsWritten() throws {
        let json = #"{"case": {"subj_x": "Brigida Oyelaran", "status": "open", "opened": "2024-03-02"}}"#
        let off = try Self.scrub(json, "case.json", layer: false)
        #expect(off.findings.isEmpty, "\(off.findings)")
        let on = try Self.scrub(json, "case.json")
        #expect(on.output == off.output)
        let suspect = try #require(on.findings.first { $0.original == "Brigida Oyelaran" })
        #expect(suspect.suspected && suspect.needsReview && suspect.entity == "PERSON" && suspect.standIn != "Brigida Oyelaran")
        #expect(on.leftAsWritten.contains(suspect.id))
        #expect(on.findings.count == 1, "\(on.findings.map(\.original))")
    }

    @Test func aHexKeyTheTaggerCallsAnAccountIsNotAskedAbout() throws {
        let tagger = try #require(SpanTagger.shared)
        // The tagger reads this system key as an account number…
        let line = "acct: 9f86d081884c7d65 (record also has: acct, status)"
        let hits = tagger.hits(Array(line.unicodeScalars), labels: Escalation.labels, threshold: Escalation.threshold)
        #expect(hits.contains { Escalation.accounts.contains($0.label) && $0.range == 6..<22 }, "\(hits)")
        // …and its shape rules that out, where the rules left it as written.
        var leaf = DocumentLeaf("9f86d081884c7d65")
        leaf.reading = .line(key: "acct", siblings: ["acct", "status"])
        let value = DocumentValue(text: "9f86d081884c7d65", marks: [], unresolved: [])
        #expect(try Escalation.suspects([leaf], [value], tagger: tagger).isEmpty)
        // A name under the same key is still asked about.
        var named = DocumentLeaf("Brigida Oyelaran")
        named.reading = .line(key: "acct", siblings: ["acct", "status"])
        let suspects = try Escalation.suspects([named], [DocumentValue(text: "Brigida Oyelaran", marks: [], unresolved: [])], tagger: tagger)
        #expect(suspects[0]?.map(\.entity) == ["PERSON"], "\(suspects)")
    }

    @Test(arguments: [
        ("9f86d081884c7d65", "acct", "iban", true),
        ("2476b133-1652-44a5-9da7-861a009b1521", "", "username", true),
        ("6199655365", "ref", "phone_number", true),
        ("6199655365", "member_no", "phone_number", false),
        ("3f4661b915b4", "id", "national_id_number", false),
        ("4111111111111111", "", "card_number", false),
        ("Brigida Oyelaran", "subj_x", "email", true),
        ("odalys@example.com", "", "email", false),
        ("Oyelaran", "", "bank_account", true),
        ("Brigida Oyelaran", "", "person", false),
        ("agent_marta", "", "person", true),
    ])
    func shapesRuleOutWhatCannotBeTheLabel(_ value: String, _ key: String, _ label: String, _ dropped: Bool) {
        #expect(Escalation.dropped(value, key: key, label: label) == dropped)
    }

    static let documents: [(String, String)] = [
        ("Hi team, Odalys Fenwright (odalys.fenwright@example.com, 555-0142) asked about card 4111 1111 1111 1111. Escalated by Tamsin Oberdorf.", "note.txt"),
        (#"{"applicant": {"first_name": "Odalys", "last_name": "Fenwright", "email": "odalys.fenwright@example.com", "phone": "+1 555-0142"}, "case": {"subj_x": "Brigida Oyelaran", "note": "Called back Tamsin Oberdorf about the refund on Friday."}}"#, "case.json"),
        ("id,holder,agent_note\n1,Odalys Fenwright,\"called back Brigida Oyelaran about the card\"\n", "cases.csv"),
        (#"<case><holder>Odalys Fenwright</holder><x9>Brigida Oyelaran</x9><note>Escalated by Tamsin Oberdorf.</note></case>"#, "case.xml"),
    ]

    @Test func aRuleFindingIsNeverTakenAway() throws {
        for (text, name) in Self.documents {
            let off = try Self.scrub(text, name, layer: false)
            let on = try Self.scrub(text, name)
            #expect(on.output == off.output, "\(name)")
            for finding in off.findings {
                let same = on.findings.first { $0.original == finding.original && $0.entity == finding.entity }
                #expect(same?.standIn == finding.standIn && same?.suspected == finding.suspected && same?.confidence == finding.confidence, "\(name): \(finding)")
            }
            #expect(on.findings.filter { !$0.suspected }.count == off.findings.filter { !$0.suspected }.count, "\(name)")
        }
    }

    @Test func theSameInputGivesTheSameReview() throws {
        for (text, name) in Self.documents {
            let first = try Self.scrub(text, name), second = try Self.scrub(text, name)
            #expect(first.output == second.output)
            #expect(first.findings.map { "\($0.entity) \($0.original) \($0.standIn) \($0.suspected)" } == second.findings.map { "\($0.entity) \($0.original) \($0.standIn) \($0.suspected)" })
        }
    }

    /// Off, the layer never runs: what Scrub does is what it did before it.
    @Test func offScrubIsAsBefore() throws {
        try Escalation.$active.withValue(false) { #expect(Escalation.tagger == nil) }
        for (text, name) in Self.documents {
            let off = try Self.scrub(text, name, layer: false)
            let again = try Self.scrub(text, name, layer: false)
            #expect(off.output == again.output && off.findings.map(\.original) == again.findings.map(\.original))
        }
    }
}
