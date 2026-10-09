import Foundation
@testable import ScrubCore
import Testing

/// A person known only by an email that spells their name ("evander.ashdown@…")
/// is that person wherever the document writes the name later, alone, in part
/// or in lowercase: every part goes, and the stand-in names are the ones the
/// address's stand-in is built from. Checked in a JSON record, a CSV row and
/// a mail as text.
@Suite struct EmailNameTests {
    static let documents: [(data: String, name: String)] = [
        (#"{"contact":{"email":"evander.ashdown@example.com"},"history":[{"note":"ashdown rang again about the fee"},{"note":"evander wants the fee waived; the Ashdown account is flagged"},{"note":"left a voicemail for Evander"}]}"#, "case.json"),
        ("id,email,notes\n7,evander.ashdown@example.com,\"ashdown rang again; evander wants the fee waived, the Ashdown account is flagged\"\n", "case.csv"),
        ("From: evander.ashdown@example.com\nSubject: fee\n\nHi, ashdown here again. The fee is still on my statement.\nThanks\n", "mail.txt"),
    ]

    @Test func aNameSpelledByAnEmailIsThatPersonEverywhere() throws {
        for document in Self.documents {
            let result = try Scrubber.scrub(Data(document.data.utf8), name: document.name, forceFullDetection: false, seed: 9)
            let output = String(decoding: result.output, as: UTF8.self)
            let words = PersonFields.lowerWords(output)
            #expect(!words.contains("evander") && !words.contains("ashdown"), "\(document.name) → \(output)")
            // Type oracle: the surname written alone takes the surname the address's stand-in is built from.
            let email = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" }, "\(document.name): \(result.findings.map(\.original))")
            let local = email.standIn.split(separator: "@")[0].split(separator: ".").map { $0.lowercased() }
            #expect(local.count == 2, "\(document.name) → \(email.standIn)")
            let surname = try #require(result.findings.first { $0.original.lowercased() == "ashdown" }, "\(document.name): \(result.findings.map(\.original))")
            #expect(Review.names.contains(surname.entity) && !surname.suspected, "\(document.name) → \(surname)")
            #expect(surname.standIn.lowercased() == local.last, "\(document.name): \(surname.standIn) / \(email.standIn)")
        }
    }

    /// A reply's header writes the time before the sender: its "PM" is no surname, and the sender
    /// is the one person the mail's sign-off and greeting name.
    @Test func aRepliesTimeIsNoSurname() throws {
        let text = "Hi Odalys,\n\nThe refund went out today.\n\nOn Tue, Jul 07, 2026 at 05:16 PM, Odalys Ferriter <odalys.ferriter@example.org> wrote:\n> Hi team,\n> where is my refund?\n>\n> Odalys\n"
        let result = try Scrubber.scrub(Data(text.utf8), name: "mail.txt", forceFullDetection: false, seed: 9)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(output.contains(" at 05:16 PM, "), "\(output)")
        #expect(!PersonFields.lowerWords(output).contains("odalys") && !PersonFields.lowerWords(output).contains("ferriter"), "\(output)")
        let full = try #require(result.findings.first { $0.original == "Odalys Ferriter" }, "\(result.findings.map(\.original))")
        let given = try #require(result.findings.first { $0.original == "Odalys" }, "\(result.findings.map(\.original))")
        #expect(full.standIn.hasPrefix(given.standIn + " "), "\(full.standIn) / \(given.standIn)")
    }

    /// A shared mailbox or an address of ordinary words spells no one: the words stay in prose.
    @Test func anAddressOfOrdinaryWordsTeachesNoName() throws {
        let text = "From: rose.hill@example.com\nCc: sales.team@example.com\n\nThe rose bushes by the hill need water; the sales team will order hoses.\n"
        let result = try Scrubber.scrub(Data(text.utf8), name: "mail.txt", forceFullDetection: false, seed: 9)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(output.hasSuffix("The rose bushes by the hill need water; the sales team will order hoses.\n"), "\(output)")
    }
}
