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

    @Test func aHandleCutFromAGivenNameIsReplaced() throws {
        let json = #"{"applicant": {"first_name": "Evangelina", "last_name": "Vey", "dob": "1990-02-11"}, "socials": {"photos": "@evang.vey.uk", "clips": "@evangvey90", "status": "linked"}}"#
        let out = try Self.scrub(json, name: "response.json")
        #expect(try JSONSerialization.jsonObject(with: Data(out.output.utf8)) is [String: Any])
        #expect(!out.output.lowercased().contains("evang") && !Self.hasWord("vey", in: out.output), "\(out.output)")
        #expect(out.output.contains(#""photos": "@"#) && out.output.contains(#".uk", "clips": "@"#) && out.output.contains(#"90", "status": "linked"}"#), "\(out.output)")
    }

    @Test func aPersonWrittenInSeparateNameFieldsIsOnePerson() throws {
        let json = #"{"person": {"given_names": "Rosalba Itzel", "surnames": "Quintanar Ochoa", "birth_date": "1986-09-14"}, "contact": {"posts": "@riquintanar", "page": "https://links.example.org/riqo"}}"#
        let out = try Self.scrub(json, name: "response.json")
        #expect(!out.output.lowercased().contains("quintanar"), "\(out.output)")
        // Initials of the whole name, which no one field holds, are asked about.
        #expect(!out.output.contains("riqo") || out.suspects.contains("riqo"), "\(out.output) \(out.suspects)")
    }

    @Test func profileLinksAndLoginsBuiltFromANameAreReplaced() throws {
        let links = ["https://social.example.net/in/torvald-lindqvist-1984", "https://forum.example.org/u/torvaldlindqvist", "https://pics.example.com/profile/t.lindqvist", "https://chat.example.com/u/torvlind"]
        let json = #"{"profile": {"first_name": "Torvald", "last_name": "Lindqvist", "login": "torvaldl84", "links": [\#(links.map { "\"\($0)\"" }.joined(separator: ", "))]}}"#
        let xml = "<profile><firstName>Torvald</firstName><lastName>Lindqvist</lastName><login>torvaldl84</login>" + links.map { "<link>\($0)</link>" }.joined() + "</profile>"
        for (text, name) in [(json, "profile.json"), (xml, "profile.xml")] {
            let out = try Self.scrub(text, name: name)
            let lower = out.output.lowercased()
            #expect(!lower.contains("lindq") && !lower.contains("torv") && !lower.contains("lind"), "\(name): \(out.output)")
            for host in ["https://social.example.net/in/", "https://forum.example.org/u/", "https://pics.example.com/profile/", "https://chat.example.com/u/"] { #expect(out.output.contains(host), "\(name): \(out.output)") }
        }
    }

    @Test func aSurnameAfterAMaritalCueIsThePersonsSurname() throws {
        let text = "Courrier reçu de Mme veuve Arnoux le 3 mars. Mme Clémence Vautrin épouse Lescure a signé le formulaire. M. Gaspard Fleuret ép. Roumagne était présent.\n"
        let out = try Self.scrub(text, name: "Pasted text")
        for part in ["Arnoux", "Clémence", "Vautrin", "Lescure", "Gaspard", "Fleuret", "Roumagne"] { #expect(!out.output.contains(part), "\(part): \(out.output)") }
        for kept in ["Courrier reçu de Mme veuve ", " le 3 mars. Mme ", " épouse ", " a signé le formulaire. M. ", " ép. ", " était présent.\n"] { #expect(out.output.contains(kept), "\(kept): \(out.output)") }
    }

    @Test func aSurnameWithParticlesAloneInANoteIsReplaced() throws {
        for (full, surname) in [("Marco Di Stefano", "Di Stefano"), ("Paloma De la Cruz", "De la Cruz"), ("Pieter Van der Berg", "Van der Berg"), ("Seán Ó Briain", "Ó Briain"), ("Elena Ruiz", "Ruiz")] {
            let json = #"{"customer": {"full_name": "\#(full)", "status": "active"}, "notes": "Called back; \#(surname) confirmed the address on file."}"#
            let out = try Self.scrub(json, name: "response.json")
            let last = surname.split(separator: " ").last.map(String.init)!
            #expect(!Self.hasWord(last, in: out.output) || out.suspects.contains { $0.contains(last) }, "\(surname): \(out.output)")
            #expect(out.output.contains(#""notes": "Called back; "#) && out.output.contains(" confirmed the address on file."), "\(out.output)")
        }
    }

    @Test func aCodeIsNeverSearchedForNameParts() throws {
        let json = #"{"person": {"name": "Ada Wibowo"}, "check": {"detail": "Matcher returned TIDAK_ADA_KECOCOKAN for the applicant", "outcome_label": "TIDAK_ADA_KECOCOKAN", "rule": "NAME_MISMATCH_ADA"}}"#
        let out = try Self.scrub(json, name: "response.json")
        #expect(!out.output.contains("Wibowo"), "\(out.output)")
        #expect(out.output.components(separatedBy: "TIDAK_ADA_KECOCOKAN").count == 3 && out.output.contains("NAME_MISMATCH_ADA"), "\(out.output)")
        #expect(!out.suspects.contains { $0.uppercased() == "ADA" }, "\(out.suspects)")
    }

    @Test func aPartInsideAnOrdinaryWordOfProseStaysAsWritten() throws {
        let cases = [
            (#"{"customer": {"full_name": "Lương Thị Hạnh"}, "note": "Khách hàng đến chi nhánh Hà Nội lúc 9 giờ, nhân viên kiểm tra giấy tờ nhanh chóng."}"#, ["chi nhánh", "nhanh chóng"]),
            (#"{"customer": {"full_name": "Nguyễn Thị Lan"}, "note": "Trời lạnh nên khách hàng gọi điện thay vì đến quầy."}"#, ["Trời lạnh nên"]),
            (#"{"customer": {"full_name": "Şule Kaya"}, "note": "Müşteri şubeye geldi; kayak tatilinden döndüğünü söyledi."}"#, ["kayak tatilinden"]),
        ]
        for (json, kept) in cases {
            let out = try Self.scrub(json, name: "response.json")
            for words in kept { #expect(out.output.contains(words), "\(words): \(out.output)") }
        }
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
