import Foundation
@testable import ScrubCore
import Testing

/// A person written in prose with an initial, a nickname in quotes, a
/// surname's particles, a suffix or a surname of several words is one person: every part of the name
/// goes, not only the parts a reader found on its own, the whole name takes
/// one stand-in, and the words of the sentence around it stay. Checked in a
/// text file and in a note of a JSON, CSV and XML record.
@Suite struct JoinedNameTests {
    typealias Path = ProseNameTests.Path

    /// A note, the name as written in it, the words of the name that must go, and words around it that must stay.
    static let people: [(note: String, name: String, parts: [String], kept: [String])] = [
        ("Ticket escalated by Bram K Vossberg on Tuesday after the second chargeback.", "Bram K Vossberg", ["bram", "vossberg"], ["escalated", "tuesday"]),
        ("Escalated by Odalys M Ferriter on Tuesday; no reply since.", "Odalys M Ferriter", ["odalys", "ferriter"], ["escalated", "reply"]),
        ("Called Ingrid T Haddleton about the disputed transfer; no answer.", "Ingrid T Haddleton", ["ingrid", "haddleton"], ["called", "disputed"]),
        ("Odell 'the closer' Haddleton lasted three seasons on the account.", "Odell 'the closer' Haddleton", ["odell", "haddleton"], ["lasted", "account"]),
        ("Lenny 'the fixer' Brown handled the escalation.", "Lenny 'the fixer' Brown", ["lenny", "brown"], ["handled", "escalation"]),
        ("Teodoro \"Teddy\" Banks asked for a callback about the late fee.", "Teodoro \"Teddy\" Banks", ["teodoro", "teddy", "banks"], ["asked", "callback"]),
        ("Agent Corinne \"Cori\" Lavalle closed the ticket after the refund cleared.", "Corinne \"Cori\" Lavalle", ["corinne", "cori", "lavalle"], ["agent", "closed", "ticket"]),
        ("Spoke with Joost van der Linde and Inés de la Vega about the lease.", "Joost van der Linde", ["joost", "linde", "inés", "vega"], ["spoke", "with", "lease"]),
        ("We met Joost van der Linde today.", "Joost van der Linde", ["joost", "linde"], ["met", "today"]),
        ("Signed by Arthur Wendell King Jr. at the branch.", "Arthur Wendell King", ["arthur", "wendell", "king"], ["signed", "jr", "branch"]),
        // The rest of a surname after the part a reader found, and a surname's particles no reader found.
        ("- Example case: applicant Marta Nogueira Pinto (DOB 1973-11-01) failed on address match.", "Marta Nogueira Pinto", ["marta", "nogueira", "pinto"], ["applicant", "failed", "match"]),
        ("[14:44] odalys: @brisa can you look at the DocCheck failure for Elif Aydın?\n[14:48] brisa: sure, which request id?", "Elif Aydın", ["elif", "aydın"], ["failure", "request"]),
        ("Attendees: Caio dos Ramos, Venkatesh", "Caio dos Ramos", ["caio", "ramos"], ["attendees"]),
    ]

    @Test(arguments: Path.allCases)
    func everyPartOfAJoinedNameGoesAndTheSentenceStays(_ path: Path) throws {
        for person in Self.people {
            let (result, output) = try ProseNameTests.scrub(person.note, path)
            let label = "[\(path)] \(person.note)"
            let words = PersonFields.lowerWords(output)
            for part in person.parts { #expect(!words.contains(part), "\(label) → \(output)") }
            for word in person.kept { #expect(words.contains(word), "\(label) → \(output)") }
            // Type oracle: the name is one person, replaced as one, by a name.
            let finding = try #require(result.findings.first { $0.original == person.name }, "\(label): \(result.findings.map { "\($0.entity) \($0.original)" })")
            #expect(Review.names.contains(finding.entity) && !finding.suspected, "\(label) → \(finding.entity)")
            #expect(PersonFields.looksLikeName(finding.standIn), "\(label) → \(finding.standIn)")
            #expect(!result.findings.contains { $0.original != person.name && person.name.contains($0.original) }, "\(label): \(result.findings.map(\.original))")
        }
    }

    /// A suffix stays after the stand-in, its full stop with it.
    @Test func aSuffixStaysAsWritten() throws {
        let (_, output) = try ProseNameTests.scrub("Signed by Arthur Wendell King Jr. at the branch.", .text)
        #expect(output.hasSuffix(" Jr. at the branch."), "\(output)")
    }

    /// A first name before a word that is no name, all in lowercase, is no person.
    static let things = [
        "Customer saw an amber alert on the dashboard, then the will power setting reset.",
        "The rose gold case shipped late; grace period ends in june.",
    ]

    @Test(arguments: Path.allCases)
    func aFirstNameBeforeAnOrdinaryWordStays(_ path: Path) throws {
        for note in Self.things {
            let (result, output) = try ProseNameTests.scrub(note, path)
            #expect(result.findings.isEmpty, "[\(path)] \(note) → \(output)")
        }
    }
}
