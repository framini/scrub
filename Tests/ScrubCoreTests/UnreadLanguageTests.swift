import Foundation
@testable import ScrubCore
import Testing

/// A name only a reader guessed is replaced only in text the recogniser is sure is English, or with
/// evidence: a title, a phrase that introduces it, a sign-off above it, a handle built from it, a known
/// given name before a surname, or the same person found surely elsewhere. In any other language, with a
/// dictionary or without one, and in text too short or too mixed to tell, a guess is left as written and
/// asked about: a greeting or a phrase of the language is never written over with a name. Checked in a
/// text file and in a note of a JSON, CSV and XML record.
@Suite struct UnreadLanguageTests {
    enum Path: String, CaseIterable, Sendable { case text, json, csv, xml }

    static func scrub(_ note: String, _ path: Path) throws -> (ScrubResult, String) {
        let data: Data, name: String
        switch path {
        case .text: (data, name) = (Data(note.utf8), "chat.txt")
        case .json: (data, name) = (try JSONSerialization.data(withJSONObject: ["ticket": "T-4410", "transcript": note], options: [.sortedKeys]), "ticket.json")
        case .csv: (data, name) = (Data("ticket,transcript\nT-4410,\"\(note.replacingOccurrences(of: "\"", with: "\"\""))\"\n".utf8), "ticket.csv")
        case .xml: (data, name) = (Data("<tickets><ticket><ref>T-4410</ref><transcript>\(note.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))</transcript></ticket></tickets>".utf8), "ticket.xml")
        }
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 11)
        return (result, String(decoding: result.output, as: UTF8.self))
    }

    /// The findings written over as a person: every person-like finding that was not only asked about.
    static func applied(_ result: ScrubResult) -> [(original: String, standIn: String, entity: String)] {
        result.findings.filter { ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION"].contains($0.entity) && !$0.suspected }.map { ($0.original, $0.standIn, $0.entity) }
    }

    /// A support chat in a language Scrub has no dictionary of, the customer introducing themself:
    /// the name's words that must go, and the greetings and phrases that must stay as written.
    static let chats: [(language: String, note: String, gone: [String], kept: [String])] = [
        ("Serbian", "[10:02] Agent: Dobar dan, kako mogu da pomognem?\n[10:03] Klijent: Dobar dan. Zovem se Dragana Petković, imam problem sa karticom.\n[10:05] Klijent: Rođena sam u proleće.\n[10:06] Agent: Hvala, gospođo Petković. Proveravam.",
         ["Dragana", "Petković"], ["Dobar dan", "Klijent:", "kako mogu da pomognem?", "Rođena sam"]),
        ("Croatian", "Klijent: Dobro jutro, moje ime je Ivana Horvatić.\nAgent: Dobro jutro! Kako vam mogu pomoći?\nKlijent: Trebam novu karticu, molim.",
         ["Ivana", "Horvatić"], ["Dobro jutro", "Klijent:", "Kako vam mogu pomoći?"]),
        ("Lithuanian", "Laba diena, mano vardas Rūta Kazlauskienė.\nMano asmens kodas pasikeitė, prašau patikrinti.\nAčiū už pagalbą",
         ["Rūta", "Kazlauskienė"], ["Laba diena", "Mano asmens kodas", "Ačiū"]),
        ("Latvian", "Labdien! Mani sauc Ilze Bērziņa.\nVai varat pārbaudīt manu kontu?\nPaldies par palīdzību",
         ["Ilze", "Bērziņa"], ["Labdien", "Vai varat", "Paldies"]),
        ("Maori", "Kia ora koutou,\nKo Tama Rangihau tōku ingoa. Kei te pātai au mō taku pūkete.\nNgā mihi",
         ["Tama", "Rangihau"], ["Kia ora", "Kei te pātai", "Ngā mihi"]),
        ("Roman Urdu", "Assalam o alaikum, mera naam Bilal Qureshi hai.\nMujhe apne account ke bare mein madad chahiye.\nShukriya",
         ["Bilal", "Qureshi"], ["Assalam o alaikum", "Mujhe apne account", "Shukriya"]),
        ("Swahili", "Habari za asubuhi. Jina langu ni Amani Wanjiru.\nNaomba msaada na akaunti yangu.\nAsante sana",
         ["Amani", "Wanjiru"], ["Habari za asubuhi", "Naomba msaada", "Asante sana"]),
        ("Tagalog", "Magandang umaga po! Ang pangalan ko ay Maricel Dizon.\nPaki-check po ang aking account.\nSalamat po",
         ["Maricel", "Dizon"], ["Magandang umaga", "Paki-check po", "Salamat po"]),
        ("Indonesian", "Selamat pagi, nama saya Budi Santoso.\nSaya ingin menanyakan rekening saya.\nTerima kasih",
         ["Budi", "Santoso"], ["Selamat pagi", "Saya ingin menanyakan", "Terima kasih"]),
        ("Yoruba", "Ẹ kú àárọ̀. Orúkọ mi ni Adebayo Ogunleye.\nẸ jọ̀ọ́, ẹ ràn mí lọ́wọ́ pẹ̀lú àkáǹtì mi.\nẸ ṣé",
         ["Adebayo", "Ogunleye"], ["Ẹ kú àárọ̀", "Ẹ jọ̀ọ́"]),
    ]

    @Test(arguments: Path.allCases)
    func aGreetingStaysAndANameWithEvidenceGoes(_ path: Path) throws {
        for chat in Self.chats {
            let (result, output) = try Self.scrub(chat.note, path)
            let label = "[\(path)] \(chat.language)"
            for word in chat.gone { #expect(!output.contains(word), "\(label) → \(output)") }
            for phrase in chat.kept { #expect(output.contains(phrase), "\(label) → \(output)") }
            // Type oracle: the person is one person, replaced as a name, and nothing else is.
            let person = Self.applied(result).filter { finding in chat.gone.contains { finding.original.contains($0) } }
            #expect(!person.isEmpty && person.allSatisfy { Review.names.contains($0.entity) }, "\(label): \(result.findings.map(\.original))")
            let others = Self.applied(result).filter { finding in !chat.gone.contains { finding.original.contains($0) } }
            #expect(others.isEmpty, "\(label) applied \(others.map { "\($0.original) → \($0.standIn)" })")
        }
    }

    /// The phrases a support chat is made of, in languages Scrub has no dictionary of, and no one's name among them.
    static let phrases: [[String]] = [
        ["Dobar dan", "Kako mogu da pomognem?", "Rođena sam u proleće.", "Hvala na strpljenju.", "Proveravam vaš nalog.", "Kartica je blokirana."],
        ["Dobro jutro", "Kako vam mogu pomoći?", "Trebam novu karticu.", "Lijep pozdrav", "Molim vas pričekajte."],
        ["Laba diena", "Mano asmens kodas pasikeitė.", "Ačiū už pagalbą", "Prašau palaukti.", "Sąskaita užblokuota."],
        ["Labdien", "Vai varat pārbaudīt kontu?", "Paldies", "Lūdzu uzgaidiet.", "Karte ir bloķēta."],
        ["Kia ora", "Ngā mihi", "Kei te pātai au mō taku pūkete.", "Tēnā koe", "Ka pai"],
        ["Assalam o alaikum", "Mujhe madad chahiye.", "Shukriya", "Mera card band ho gaya hai.", "Thora intezar karein."],
        ["Habari za asubuhi", "Naomba msaada.", "Asante sana", "Kadi yangu imezuiwa.", "Tafadhali subiri."],
        ["Magandang umaga po", "Paki-check po ang account.", "Salamat po", "Na-block po ang card ko.", "Sandali lang po."],
        ["Selamat pagi", "Saya ingin menanyakan rekening.", "Terima kasih", "Kartu saya diblokir.", "Mohon tunggu sebentar."],
        ["Ẹ kú àárọ̀", "Ẹ jọ̀ọ́ ẹ ràn mí lọ́wọ́.", "Ẹ ṣé", "Káàdì mi ti dínà."],
    ]
    static let speakers = ["Agent", "Klijent", "Kunde", "Cliente", "Customer", "Support", "Operator"]

    /// Generated chats in those languages, speakers labelling their lines, hold no evidence for anyone: nothing in them is ever written over as a name.
    @Test(arguments: [Path.text, Path.json])
    func noWordOfAChatWithoutEvidenceIsAppliedAsAName(_ path: Path) throws {
        var generator: any RandomNumberGenerator = SeededGenerator(seed: 41)
        for index in 0..<20 {
            let pool = Self.phrases[index % Self.phrases.count]
            let (first, second) = (Self.speakers.randomElement(using: &generator)!, Self.speakers.randomElement(using: &generator)!)
            let timed = Bool.random(using: &generator)
            let lines = (0..<Int.random(in: 3...6, using: &generator)).map { line in
                (timed ? "[10:\(String(format: "%02d", 10 + line))] " : "") + (line.isMultiple(of: 2) ? first : second) + ": " + pool.randomElement(using: &generator)!
            }
            let note = lines.joined(separator: "\n")
            let (result, output) = try Self.scrub(note, path)
            let applied = Self.applied(result)
            #expect(applied.isEmpty, "[\(path)] \(note) → \(output): \(applied.map { "\($0.original) → \($0.standIn)" })")
        }
    }

    /// "Abu Yusuf", "Umm Khalid", "أبو يوسف": a parent called by their child's name is a person, never a place and never left unseen.
    @Test(arguments: [Path.text, Path.json])
    func aParentCalledByTheirChildsNameIsAPerson(_ path: Path) throws {
        let notes: [(note: String, kunya: String, replaced: Bool)] = [
            ("اتصل أبو يوسف بخصوص البطاقة.", "أبو يوسف", false),
            ("Umm Khalid phoned twice about the card.", "Umm Khalid", true),
            ("The landlord, Abu Yusuf, called about the deposit last week.", "Abu Yusuf", true),
        ]
        for entry in notes {
            let (result, output) = try Self.scrub(entry.note, path)
            let finding = try #require(result.findings.first { $0.original == entry.kunya }, "[\(path)] \(entry.note) → \(output): \(result.findings.map(\.original))")
            #expect(finding.entity == "PERSON", "[\(path)] \(entry.note) → \(finding.entity)")
            #expect(finding.suspected != entry.replaced && output.contains(entry.kunya) != entry.replaced, "[\(path)] \(entry.note) → \(output)")
        }
    }

    /// "Kobayashi-san", "Lee-ssi": the form of address joined after a surname stays, after the stand-in the person's surname takes everywhere.
    @Test(arguments: Path.allCases)
    func aJoinedFormOfAddressFollowsThePersonsStandIn(_ path: Path) throws {
        let notes: [(note: String, name: String, surname: String, form: String)] = [
            ("Customer: Akiko Kobayashi\nSpoke with Kobayashi-san on the phone. Kobayashi-san confirmed her address and Ms Kobayashi will call back.", "Akiko Kobayashi", "Kobayashi", "-san"),
            ("Account holder Hiroshi Tanabe called. Tanabe-sama asked for a new card.", "Hiroshi Tanabe", "Tanabe", "-sama"),
            ("Customer: Seo-yeon Hwang\nHwang-ssi confirmed the transfer, and Hwang-nim signed the form.", "Seo-yeon Hwang", "Hwang", "-ssi"),
        ]
        for entry in notes {
            let (result, output) = try Self.scrub(entry.note, path)
            let label = "[\(path)] \(entry.note)"
            #expect(!output.contains(entry.surname), "\(label) → \(output)")
            let person = try #require(result.findings.first { $0.original == entry.name }, "\(label): \(result.findings.map(\.original))")
            let standIn = try #require(person.standIn.split(separator: " ").last.map(String.init))
            #expect(output.contains(standIn + entry.form), "\(label) → \(output)")
        }
    }

    /// "contacto Rosa Huamán", "Contacto: Rosa Huamán", "Kontakt: …": a word naming the contact person, in a record in another language, is evidence.
    @Test(arguments: Path.allCases)
    func aContactsLabelIsEvidenceInAnyLanguage(_ path: Path) throws {
        let notes: [(note: String, name: String)] = [
            ("Example Ferretería e Hijos, contacto Rosa Huamán, pedido 4471 pendiente.\nContacto: Rosa Huamán", "Rosa Huamán"),
            ("Pedido 2210 de Example Materiais Lda.\nContato: Joaquim Bettencourt", "Joaquim Bettencourt"),
            ("Bestellung 8812 von Example Bau GmbH\nKontakt: Wiebke Strothmann", "Wiebke Strothmann"),
            ("Commande 5521, Example Négoce SARL\nResponsable: Ghislaine Morvillier", "Ghislaine Morvillier"),
        ]
        for entry in notes {
            let (result, output) = try Self.scrub(entry.note, path)
            let label = "[\(path)] \(entry.note)"
            for word in entry.name.split(separator: " ") { #expect(!output.contains(word), "\(label) → \(output)") }
            let finding = try #require(result.findings.first { $0.original == entry.name }, "\(label): \(result.findings.map(\.original))")
            #expect(Review.names.contains(finding.entity) && !finding.suspected, "\(label) → \(finding.entity)")
        }
    }

    /// "Kia ora", "Ngā mihi", "aroha nui", "Tēnā koutou": a Māori greeting or sign-off stays as written, a name after one
    /// is replaced or asked about, and a found person's given name that opens a greeting ("aroha nui" beside "Aroha Ngata")
    /// is the greeting's word, never written over with their stand-in.
    @Test(arguments: Path.allCases)
    func aMaoriGreetingStays(_ path: Path) throws {
        let note = """
        Kia ora koutou, aroha nui to everyone at the hui. Aroha Ngata will bring the kai.
        Tēnā koe Wiremu, thanks for the update on the account.

        Ngā mihi,
        Aroha nui,
        Hemi Tawhiri
        """
        let (result, output) = try Self.scrub(note, path)
        let label = "[\(path)]"
        for kept in ["Kia ora koutou", "aroha nui to everyone", "Ngā mihi", "Aroha nui", "Tēnā koe"] { #expect(output.contains(kept), "\(label) \(kept) → \(output)") }
        for gone in ["Ngata", "Hemi", "Tawhiri"] { #expect(!output.contains(gone), "\(label) \(gone) → \(output)") }
        let written = Self.applied(result).map(\.original)
        #expect(!written.contains { ["Kia", "Ngā", "aroha", "Aroha nui", "koutou"].contains($0) || $0.hasPrefix("Kia ora") }, "\(label) \(written)")
    }

    /// A ledger's line in a language Scrub has no dictionary of ("Elektra 45,20 EUR": electricity) holds a word
    /// a name list holds too: asked about, never replaced, while the client named under a label is.
    @Test(arguments: Path.allCases)
    func aLedgersWordThatIsAlsoANameIsAskedAbout(_ path: Path) throws {
        let note = "Mokėjimai:\nElektra 45,20 EUR\nVanduo 12,00 EUR\nKlientas: Rūta Kazlauskienė"
        let (result, output) = try Self.scrub(note, path)
        #expect(output.contains("Elektra 45,20 EUR"), "[\(path)] \(output)")
        #expect(!output.contains("Kazlauskienė"), "[\(path)] \(output)")
        #expect(!Self.applied(result).contains { $0.original == "Elektra" }, "[\(path)] \(Self.applied(result))")
    }
}
