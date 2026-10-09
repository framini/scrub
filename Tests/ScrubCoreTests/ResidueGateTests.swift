import Foundation
@testable import ScrubCore
import Testing

/// The residue gate: once any part of a person's name is found, no part of
/// it stays in the output unseen. Each part is replaced, or listed for review.
@Suite struct ResidueGateTests {
    struct Scrubbed {
        let output: String
        let suspects: [String]
        let standIns: [String]
        let originals: [String]
    }
    static func scrub(_ text: String, name: String, seed: UInt64 = 11) throws -> Scrubbed {
        let result = try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: seed)
        let findings = result.review?.findings ?? []
        return Scrubbed(output: String(decoding: result.output, as: UTF8.self), suspects: result.unresolved.compactMap(\.original),
                        standIns: findings.filter { !$0.suspected }.map(\.standIn), originals: findings.map(\.original))
    }
    /// Whether `word` is in `text` as a whole word, in any case.
    static func hasWord(_ word: String, in text: String) -> Bool {
        text.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    @Test func aHyphenatedGivenNameAfterATitleIsOneName() throws {
        let text = "Visit log 14 March\nMr. Kim Min-jun arrived late for the 10:00 slot. Min-jun apologised and asked to rebook.\n"
        let out = try Self.scrub(text, name: "Pasted text")
        #expect(!out.output.contains("Min-jun") && !Self.hasWord("jun", in: out.output), "\(out.output)")
        #expect(out.output.hasPrefix("Visit log 14 March\nMr. ") && out.output.contains(" arrived late for the 10:00 slot. "))
    }

    @Test func aShortGivenNameThatIsAWordIsAskedAboutWhereItIsNotBesideTheName() throws {
        let text = "Statement taken from Lương Thị Hạnh An at the branch.\nAn confirmed the time of the withdrawal with the teller.\n"
        let out = try Self.scrub(text, name: "Pasted text")
        // Every "An" still standing, written as a name, is listed for review; the article is no one.
        let standing = out.output.components(separatedBy: "An ").count - 1
        #expect(out.suspects.filter { $0 == "An" }.count == standing, "\(out.output) \(out.suspects)")
        #expect(standing == 0 || out.output.contains("An confirmed"))
    }

    @Test func aHandleRunFromANameInTextIsReplaced() throws {
        let text = "Ciarán Ó Dálaigh (@ciaranodalaigh) replied to the thread on Tuesday.\n"
        let out = try Self.scrub(text, name: "Pasted text")
        #expect(!out.output.lowercased().contains("odalaigh") && !out.output.lowercased().contains("ciaran"), "\(out.output)")
    }

    @Test func aHandleOfInitialsIsAskedAbout() throws {
        let text = "Bartolomeu Xisto Carvalhosa posts as @bxcarvalhosa and keeps notes at https://notes.example.org/bxcq for the team.\n"
        let out = try Self.scrub(text, name: "Pasted text")
        #expect(!out.output.lowercased().contains("carvalhosa"), "\(out.output)")
        if out.output.contains("bxcq") { #expect(out.suspects.contains("bxcq"), "\(out.output) \(out.suspects)") }
    }

    @Test func aNameRunTogetherInAnotherFieldIsReplacedInJSON() throws {
        let json = #"{"applicant": {"given_name": "Ingrid", "family_name": "Fjeldvang", "id": "ap_7731"}, "activity": [{"event": "profile_view", "url": "https://social.example.net/in/ingrid-fjeldvang-1984"}, {"event": "login", "detail": "signed in as ingridfjeldvang from the mobile app"}]}"#
        let out = try Self.scrub(json, name: "response.json")
        #expect(try JSONSerialization.jsonObject(with: Data(out.output.utf8)) is [String: Any])
        #expect(!out.output.lowercased().contains("fjeldvang") && !out.output.lowercased().contains("ingrid"), "\(out.output)")
        for key in ["applicant", "given_name", "activity", "event", "url", "detail", "profile_view", "signed in as "] { #expect(out.output.contains(key)) }
    }

    @Test func aNameInALogLineIsReplacedInEveryForm() throws {
        let log = "2026-10-01T10:00:00Z INFO auth user=ciaranodalaigh result=ok\n2026-10-01T10:00:02Z INFO profile name=\"Ciarán Ó Dálaigh\" plan=basic\n"
        let out = try Self.scrub(log, name: "app.log")
        #expect(!out.output.lowercased().contains("odalaigh"), "\(out.output)")
        #expect(out.output.contains("INFO auth user=") && out.output.contains(" result=ok\n") && out.output.contains(" plan=basic\n"))
    }

    @Test func aMaidenNameInAnAttributeAndHandlesInXMLAreCovered() throws {
        let xml = #"<customers><customer given="Solène" family="Marchetaud" maiden="Quéruel"><note>Mme Solène Marchetaud, née Quéruel. Messages from @solenequeruel are hers.</note></customer></customers>"#
        let out = try Self.scrub(xml, name: "export.xml")
        #expect(!out.output.lowercased().contains("queruel") && !out.output.contains("Quéruel"), "\(out.output)")
        #expect(out.output.contains("<customer given=") && out.output.contains("maiden="))
    }

    @Test func aCSVNoteHandleBuiltFromTheNameIsReplaced() throws {
        let csv = "id,full_name,notes\n1,Seán Ó Briain,\"prefers chat; alt @seanobriain, old handle briain.s\"\n"
        let out = try Self.scrub(csv, name: "people.csv")
        #expect(!out.output.lowercased().contains("briain") && !out.output.lowercased().contains("sean"), "\(out.output)")
        #expect(out.output.hasPrefix("id,full_name,notes\n1,") && out.output.contains("\"prefers chat; alt @"))
    }

    // MARK: The guarantee

    private static let shapes: [[String]] = [
        ["Oğuzhan", "Karabağlı"], ["Femke", "van", "Rijswijk"], ["Joana", "Ribeiro", "Matoso"], ["Lương", "Thị", "Hạnh"],
        ["Ciarán", "Ó", "Dálaigh"], ["Matteo", "Lo", "Bianco"], ["Solène", "Marchetaud"], ["Ximena", "Arreola", "Quiroz"],
        ["Jörg", "Brennecke"], ["Zbigniew", "Łukaszczyk"], ["Anne-Marie", "Duvoisin"], ["Thorvald", "Nyhagen"],
    ]
    /// Letters as a reader compares them: lowercase and without accents, judged without ScrubCore.
    static func fold(_ text: String) -> String {
        let plain: [Character: String] = ["đ": "d", "ı": "i", "ł": "l", "ø": "o", "ß": "ss"]
        return text.lowercased().map { plain[$0] ?? String($0).folding(options: .diacriticInsensitive, locale: nil) }.joined()
    }
    private static let particles: Set<String> = ["van", "ó", "lo", "de", "da", "di"]
    /// A name's words as a reader compares them, without particles.
    static func parts(_ name: String) -> [String] {
        name.split { $0.isWhitespace || $0 == "-" || $0 == "'" || $0 == "’" || $0 == "," }.map { Self.fold(String($0)) }
            .filter { $0.count >= 2 && $0.allSatisfy(\.isLetter) && !particles.contains($0) && !NameEvidence.titles.contains($0) }
    }
    static func document(_ gen: inout Gen, format: String) -> String {
        let name = gen.choose(shapes), full = name.joined(separator: " ")
        let given = name[0], family = name.dropFirst().joined(separator: " ")
        let handle = Self.fold(name.joined()).filter(\.isLetter)
        let slug = name.map { Self.fold($0).filter(\.isLetter) }.joined(separator: "-") + "-\(gen.int(1950...2005))"
        let note = gen.shuffled(["\(given) asked for a \(gen.filler()).", "Messages come from @\(handle).", "Profile https://people.example.org/u/\(slug) is \(gen.filler()).",
                                 "Mr. \(family) is \(gen.filler()).", "\(gen.filler(capitalized: true)) for \(full)."]).prefix(gen.int(2...5)).joined(separator: " ")
        switch format {
        case "json": return #"{"record": {"full_name": "\#(full)", "status": "pending"}, "notes": "\#(note)"}"#
        case "csv": return "full_name,status,notes\n\"\(full)\",pending,\"\(note)\"\n"
        case "xml": return "<record><fullName>\(full)</fullName><status>pending</status><notes>\(note.replacingOccurrences(of: "&", with: "&amp;"))</notes></record>"
        default: return "Customer: \(full)\nStatus: pending\nNotes: \(note)\n"
        }
    }

    /// For generated documents, every part of every name found is gone from the
    /// output, written inside a stand-in, or listed for review.
    @Test func everyPartOfAFoundNameIsReplacedOrAskedAbout() throws {
        let run = PropertyRun("residueGate")
        defer { run.finish() }
        for index in 0..<run.count {
            var gen = Gen(seed: run.seed(index))
            let format = ["json", "csv", "xml", "txt"][index % 4]
            let text = Self.document(&gen, format: format)
            let out = try Self.scrub(text, name: "residue." + format, seed: run.seed(index))
            let found = Set(out.originals.flatMap(Self.parts))
            let output = Self.fold(out.output)
            let covers = (out.standIns + out.suspects).map { Self.fold($0) }.filter { !$0.isEmpty }
            for part in found {
                var from = output.startIndex
                while let hit = output.range(of: part, range: from..<output.endIndex) {
                    from = hit.upperBound
                    let before = hit.lowerBound > output.startIndex ? output[output.index(before: hit.lowerBound)] : " "
                    let after = hit.upperBound < output.endIndex ? output[hit.upperBound] : " "
                    // Short parts only as words of their own; long ones run into others too.
                    if part.count < 4, before.isLetter || after.isLetter { continue }
                    let covered = covers.contains { cover in
                        var start = output.startIndex
                        while let place = output.range(of: cover, range: start..<output.endIndex) {
                            if place.lowerBound <= hit.lowerBound && hit.upperBound <= place.upperBound { return true }
                            start = output.index(after: place.lowerBound)
                        }
                        return false
                    }
                    #expect(covered, "\"\(part)\" left unseen in \(out.output)\nsuspects \(out.suspects)\nseed \(run.seed(index)) format \(format)\nINPUT:\n\(text)")
                }
            }
        }
    }
}
