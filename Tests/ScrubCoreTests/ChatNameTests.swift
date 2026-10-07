import Foundation
@testable import ScrubCore
import Testing

/// Names typed in lowercase in chat: the speaker of a chat line is replaced
/// wherever it is a first name that is no ordinary word; a name that is also
/// a word ("will", "grace") after what names a person in chat is asked about,
/// never replaced on a guess and never silently left; and the ordinary words
/// of a chat ("will do", "note:") stay as written. Checked in a text file and
/// in a note of a JSON, CSV and XML record.
@Suite struct ChatNameTests {
    enum Path: String, CaseIterable, Sendable { case text, json, csv, xml }

    static func scrub(_ note: String, _ path: Path) throws -> (ScrubResult, String) {
        let data: Data, name: String
        switch path {
        case .text: (data, name) = (Data(note.utf8), "chat.txt")
        case .json: (data, name) = (try JSONSerialization.data(withJSONObject: ["ticket": "T-2207", "transcript": note], options: [.sortedKeys]), "ticket.json")
        case .csv: (data, name) = (Data("ticket,transcript\nT-2207,\"\(note.replacingOccurrences(of: "\"", with: "\"\""))\"\n".utf8), "ticket.csv")
        case .xml: (data, name) = (Data("<tickets><ticket><ref>T-2207</ref><transcript>\(note.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))</transcript></ticket></tickets>".utf8), "ticket.xml")
        }
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 9)
        return (result, String(decoding: result.output, as: UTF8.self))
    }

    /// A transcript, the speakers that must go, and the words that must stay.
    static let transcripts: [(note: String, gone: [String], kept: [String])] = [
        ("[09:14] ingrid: can someone check the refund queue?\n[09:15] ops-bot: queue is empty\n[09:16] ingrid: thanks", ["ingrid"], ["ops", "bot", "queue", "refund"]),
        ("sven: did the customer reply?\ndeepa: not yet, chasing now", ["sven", "deepa"], ["customer", "reply", "chasing"]),
        ("<tomasz> on it\n<leilani> thanks, closing the ticket", ["tomasz", "leilani"], ["closing", "ticket"]),
        // A name that is also a word speaks twice in a transcript, and the one it talks with no list holds.
        ("wren: hey kasimirov did u see the refund?\nkasimirov: yeah, fixing it\nwren: ok thx", ["wren", "kasimirov"], ["refund", "fixing"]),
        // A word that speaks again at a chat's times beside a listed speaker, and a speaker mentioned with "@".
        ("[09:01] fleur: @odalys can you look at the refund?\n[09:04] odalys: sure, which one?\n[09:06] fleur: this morning's, thanks", ["fleur", "odalys"], ["refund", "morning"]),
    ]

    @Test(arguments: Path.allCases)
    func aChatLinesSpeakerIsReplaced(_ path: Path) throws {
        for transcript in Self.transcripts {
            let (result, output) = try Self.scrub(transcript.note, path)
            let label = "[\(path)] \(transcript.note)"
            let words = PersonFields.lowerWords(output)
            for name in transcript.gone {
                #expect(!words.contains(name), "\(label) → \(output)")
                // Type oracle: a person, one stand-in for each speaker wherever they speak, written in lowercase as typed.
                let finding = try #require(result.findings.first { $0.original == name }, "\(label): \(result.findings.map(\.original))")
                #expect(Review.names.contains(finding.entity) && !finding.suspected, "\(label) → \(finding.entity)")
                #expect(finding.standIn == finding.standIn.lowercased() && finding.standIn.allSatisfy(\.isLetter), "\(label) → \(finding.standIn)")
            }
            for word in transcript.kept { #expect(words.contains(word), "\(label) → \(output)") }
        }
    }

    /// A name that is also a word, where chat names a person with it: asked about, left as written.
    static let doubted: [(note: String, name: String)] = [
        ("spoke to will about the bill, he wants it split", "will"),
        ("ask grace about the refund before closing", "grace"),
        ("grace mentioned the outage started at noon", "grace"),
        ("will: can you check the card?\nsven: on it", "will"),
    ]

    @Test(arguments: Path.allCases)
    func aNameThatIsAWordIsAskedAboutWhereChatNamesSomeone(_ path: Path) throws {
        for (note, name) in Self.doubted {
            let (result, output) = try Self.scrub(note, path)
            let label = "[\(path)] \(note)"
            #expect(PersonFields.lowerWords(output).contains(name), "\(label) → \(output)")
            let finding = try #require(result.findings.first { $0.original == name }, "\(label): \(result.findings.map(\.original))")
            #expect(finding.suspected && finding.doubt == .unconfirmed && Review.names.contains(finding.entity), "\(label) → \(finding)")
        }
    }

    /// Chat's own words, and labels before a colon, name no one.
    static let plain = [
        "thanks, will do. I will ask about it tomorrow.",
        "note: customer called twice.\nstatus: pending\nerror: timeout after 30s",
        "the refund is due in june, per the contract; grace period applies.",
        "INFO: sync started\nWARN: retrying the upload\nINFO: sync done",
    ]

    @Test(arguments: Path.allCases)
    func chatsOwnWordsStay(_ path: Path) throws {
        for note in Self.plain {
            let (result, output) = try Self.scrub(note, path)
            #expect(result.findings.isEmpty, "[\(path)] \(note) → \(output)")
        }
    }
}
