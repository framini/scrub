import Foundation
@testable import ScrubCore
import Testing

/// A person written in a sentence with a hyphenated surname, an apostrophe
/// either way or a surname's particles is replaced whole, and a later
/// mention of a part of the name alone is theirs too, in every input that
/// carries prose: a text file, and a note in a JSON, CSV or XML record.
/// Brands, places and companies written with a hyphen stay as written.
@Suite struct ProseNameTests {
    enum Path: String, CaseIterable, Sendable { case text, json, csv, xml }

    static func written(_ note: String, _ path: Path) -> (Data, String) {
        switch path {
        case .text: return (Data(note.utf8), "note.txt")
        case .json:
            let escaped = note.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            return (Data(#"{"ticket":"T-2207","note":"\#(escaped)"}"#.utf8), "ticket.json")
        case .csv: return (Data("ticket,note\nT-2207,\"\(note.replacingOccurrences(of: "\"", with: "\"\""))\"\n".utf8), "ticket.csv")
        case .xml: return (Data("<tickets><ticket><ref>T-2207</ref><note>\(note)</note></ticket></tickets>".utf8), "ticket.xml")
        }
    }

    static func scrub(_ note: String, _ path: Path) throws -> (ScrubResult, String) {
        let (data, name) = written(note, path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 9)
        return (result, String(decoding: result.output, as: UTF8.self))
    }

    /// A person's sentence, the name written whole, and the words of it that must not stay.
    static let people: [(note: String, name: String, words: [String])] = [
        ("Tenant: Brisa Smith-Jones. Later mail came from Brisa about the lease.", "Brisa Smith-Jones", ["brisa", "smith", "jones"]),
        ("Tenant: Brisa Smith‐Jones. Later mail came from Brisa about the lease.", "Brisa Smith‐Jones", ["brisa", "smith", "jones"]),
        ("Tenant: Brisa Smith–Jones. Later mail came from Brisa about the lease.", "Brisa Smith–Jones", ["brisa", "smith", "jones"]),
        ("The keys went to Odalys Ferriter-Quillmere on Monday. Odalys signed for them.", "Odalys Ferriter-Quillmere", ["odalys", "ferriter", "quillmere"]),
        ("Ms Zorvane Smith-Jones signed the lease. Later Zorvane called about the deposit.", "Zorvane Smith-Jones", ["zorvane", "smith", "jones"]),
        ("We met Tomasz O'Sullivan on Monday. Later Tomasz called about the lease.", "Tomasz O'Sullivan", ["tomasz", "sullivan"]),
        ("We met Tomasz O’Sullivan on Monday. Later Tomasz called about the lease.", "Tomasz O’Sullivan", ["tomasz", "sullivan"]),
        ("We met Odalys van der Berg on Monday. Later Odalys called about the lease.", "Odalys van der Berg", ["odalys", "berg"]),
    ]

    @Test(arguments: Path.allCases)
    func aNameInASentenceIsReplacedWholeAndItsPartsWithIt(_ path: Path) throws {
        for person in Self.people {
            let (result, output) = try Self.scrub(person.note, path)
            let label = "[\(path)] \(person.note)"
            let words = PersonFields.lowerWords(output)
            for word in person.words { #expect(!words.contains(word), "\(label) → \(output)") }
            // Type oracle: the name is one person, and its stand-in reads as a name.
            let finding = try #require(result.findings.first { $0.original.hasSuffix(person.name) }, "\(label): \(result.findings.map { "\($0.entity) \($0.original)" })")
            #expect(Review.names.contains(finding.entity), "\(label) → \(finding.entity)")
            #expect(PersonFields.looksLikeName(finding.standIn.split(separator: " ").filter { !People.isTitle(String($0)) }.joined(separator: " ")), "\(label) → \(finding.standIn)")
            // The given name alone later is the same person's: it takes the first word of their stand-in.
            let given = try #require(person.name.split(separator: " ").first.map(String.init))
            let alone = try #require(result.findings.first { $0.original == given }, "\(label): \(result.findings.map(\.original))")
            #expect(finding.standIn.split(separator: " ").contains { $0 == alone.standIn }, "\(label): \(finding.standIn) / \(alone.standIn)")
            // The same scrub writes the same bytes.
            #expect(try Self.scrub(person.note, path).0.output == result.output)
        }
    }

    @Test func aHyphenatedSurnameAloneLaterIsReplacedToo() throws {
        let note = "Tenant: Brisa Smith-Jones. Later Smith-Jones and Brisa both signed."
        for path in Path.allCases {
            let (_, output) = try Self.scrub(note, path)
            let words = PersonFields.lowerWords(output)
            #expect(!words.contains("brisa") && !words.contains("smith") && !words.contains("jones"), "[\(path)] \(output)")
        }
    }

    /// Hyphenated brands, places and companies, none after a given name.
    static let things = [
        "The Rolls-Royce was parked outside the depot.",
        "Later we drove to Winston-Salem for the night.",
        "She leased a Mercedes-Benz for the move.",
        "Hewlett-Packard shipped the printer on Tuesday.",
        "Coca-Cola sponsored the street fair.",
        "We met at the Rolls-Royce showroom, then took a Mercedes-Benz to the Coca-Cola plant.",
    ]

    @Test(arguments: Path.allCases)
    func aHyphenatedBrandOrPlaceIsNoOne(_ path: Path) throws {
        for note in Self.things {
            let (result, output) = try Self.scrub(note, path)
            #expect(!result.findings.contains { Review.names.contains($0.entity) }, "[\(path)] \(note): \(result.findings.map { "\($0.entity) \($0.original)" })")
            for brand in ["Rolls-Royce", "Mercedes-Benz", "Hewlett-Packard", "Coca-Cola"] where note.contains(brand) {
                #expect(output.contains(brand), "[\(path)] \(output)")
            }
        }
    }

    /// A note written in another language keeps its own small words, which the readers took for names
    /// ("justificante de domicilio" became "justificante de joseph"): only the people in it are replaced,
    /// a surname after a title of that language too ("Herrn Brenneke").
    @Test(arguments: Path.allCases)
    func smallWordsOfAnotherLanguageStay(_ path: Path) throws {
        let notes: [(note: String, kept: [String], names: [String])] = [
            ("La clienta Odalys Quintero Vidal envió el recibo. Falta el justificante de domicilio y el código de alerta; no cerrar antes del viernes.",
             ["justificante de domicilio", "código de alerta", "antes del viernes"], ["Quintero"]),
            ("Herr Torvald Brenneke hat angerufen. Ich habe die Unterlagen geprüft, aber die Meldung nach Paragraf 12 fehlt noch. Rückruf bitte an Herrn Brenneke.",
             ["Ich habe die Unterlagen", "aber die Meldung nach Paragraf"], ["Brenneke", "Torvald"]),
            ("oi, aqui é o Caetano Brisolla, meu cadastro está travado desde ontem na casa da minha mãe.",
             ["oi, aqui é o", "meu cadastro", "na casa da minha mãe"], ["Brisolla"]),
            ("Brisa Fantoni preferisce i documenti in bianco e nero; colore della carta: azzurro.",
             ["in bianco e nero; colore della carta"], ["Fantoni"]),
            ("Ik ben Joris Achterberg. Dat verklaart de afkeuring van gisteren.",
             ["Dat verklaart de afkeuring"], ["Achterberg"]),
        ]
        for (note, kept, names) in notes {
            let (_, output) = try Self.scrub(note, path)
            for phrase in kept { #expect(output.contains(phrase), "[\(path)] \(phrase): \(output)") }
            for name in names { #expect(!output.contains(name), "[\(path)] \(name): \(output)") }
        }
    }
}

/// A record under a parent that names a business, a product or an app
/// ("application") is still a person's own when the fields beside its
/// "name" say so: an email with a name written as a person's, a birth date,
/// an SSN. Its name is then replaced whole, as a name, in every format; an
/// app's own record keeps its name.
@Suite struct OwnRecordUnderAppTests {
    enum Path: String, CaseIterable, Sendable { case json, csv, xml, jsonList }

    static func written(_ fields: [(String, String)], _ path: Path, parent: String = "application") -> (Data, String) {
        switch path {
        case .json:
            let body = fields.map { #""\#($0.0)":"\#($0.1)""# }.joined(separator: ",")
            return (Data(#"{"\#(parent)":{\#(body)}}"#.utf8), "record.json")
        case .jsonList:
            let body = fields.map { #""\#($0.0)":"\#($0.1)""# }.joined(separator: ",")
            return (Data(#"{"\#(parent)s":[{\#(body)},{"id":"A-2"}]}"#.utf8), "record.json")
        case .csv:
            return (Data((fields.map { parent + "." + $0.0 }.joined(separator: ",") + "\n" + fields.map(\.1).joined(separator: ",") + "\n").utf8), "record.csv")
        case .xml:
            return (Data("<\(parent)>\(fields.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined())</\(parent)>".utf8), "record.xml")
        }
    }

    static let people: [[(String, String)]] = [
        [("name", "Odalys Ferriter"), ("email", "odalys@corvane.test"), ("dob", "1984-03-02")],
        [("name", "Odalys Ferriter"), ("dob", "1984-03-02")],
        [("name", "Odalys Ferriter"), ("ssn", "512-44-1937")],
        [("name", "Odalys Ferriter"), ("email", "odalys@corvane.test")],
        [("name", "Brisa Quillmere"), ("phone", "(415) 555-0172"), ("status", "submitted")],
    ]

    @Test(arguments: Path.allCases)
    func aPersonsRecordUnderAnAppIsTheirs(_ path: Path) throws {
        for fields in Self.people {
            let name = fields[0].1
            let (data, file) = Self.written(fields, path)
            let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 9)
            let output = String(decoding: result.output, as: UTF8.self)
            let label = "[\(path)] \(fields.map(\.0))"
            let finding = try #require(result.findings.first { $0.original == name }, "\(label) \(name) not found whole: \(result.findings.map { "\($0.entity) \($0.original)" })")
            #expect(Review.names.contains(finding.entity) && PersonFields.looksLikeName(finding.standIn), "\(label) → \(finding.entity) \(finding.standIn)")
            for word in name.lowercased().split(separator: " ") { #expect(!PersonFields.lowerWords(output).contains(String(word)), "\(label) → \(output)") }
        }
    }

    static let apps: [[(String, String)]] = [
        [("name", "Ledgerly"), ("version", "2.1")],
        [("name", "Ledgerly Cloud"), ("version", "2.1"), ("support_email", "help@corvane.test")],
        [("name", "Quillmere Sync"), ("email", "ops@corvane.test"), ("platform", "macOS")],
    ]

    @Test(arguments: Path.allCases)
    func anAppsOwnRecordKeepsItsName(_ path: Path) throws {
        for fields in Self.apps {
            let (data, file) = Self.written(fields, path)
            let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 9)
            let output = String(decoding: result.output, as: UTF8.self)
            #expect(output.contains(fields[0].1), "[\(path)] \(output)")
            #expect(!result.findings.contains { Review.names.contains($0.entity) }, "[\(path)] \(result.findings.map { "\($0.entity) \($0.original)" })")
        }
    }
}

/// A known person's given name written alone after their full name takes their stand-in first name, in any
/// language, and their full name written after a form of address in that language ("Mme", "Frau", "signora")
/// is the same person, so the two stand-ins agree.
@Test(arguments: [UInt64(3), 14])
func aGivenNameAloneAfterTheFullNameIsThatPerson(_ seed: UInt64) throws {
    let notes: [(text: String, given: String, full: String)] = [
        ("Note d'appel du 4 mars.\nMme Odile Marchetti a appelé au sujet de sa demande. Odile voulait savoir quand l'argent arrive.\nJ'ai dit à Odile que nous répondrions dans cinq jours.", "Odile", "Marchetti"),
        ("Gesprächsnotiz vom 4. März.\nFrau Hildegard Brenner rief wegen ihres Antrags an. Hildegard fragte, wann das Geld kommt.\nIch habe Hildegard gesagt, dass wir in fünf Tagen antworten.", "Hildegard", "Brenner"),
        ("Nota della telefonata del 4 marzo.\nLa signora Chiara Bassi ha chiamato per la sua domanda. Chiara voleva sapere quando arrivano i soldi.\nHo detto a Chiara che risponderemo entro cinque giorni.", "Chiara", "Bassi"),
    ]
    for note in notes {
        let result = try Scrubber.scrub(Data(note.text.utf8), name: "note.txt", forceFullDetection: false, seed: seed)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(!output.contains(note.given) && !output.contains(note.full), "\(output)")
        let full = try #require(result.findings.first { $0.original.hasSuffix(note.full) }?.standIn, "\(output)")
        let alone = try #require(result.findings.first { $0.original == note.given }?.standIn, "\(output)")
        #expect(full.split(separator: " ").dropLast().last.map(String.init) == alone, "\(full) / \(alone)")
        #expect(result.findings.allSatisfy { !$0.needsReview || ![note.given, note.full].contains($0.original) }, "\(result.findings.map { "\($0.original) \($0.needsReview)" })")
    }
}
