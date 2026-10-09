import Foundation
@testable import ScrubCore
import Testing

/// Where a record is written: a JSON object, a CSV row, an XML element, or
/// text with a field on each line (`key: value`, or a properties file's `key=value`).
enum FieldLayout: String, CaseIterable, Sendable { case json, csv, xml, colon, equals }

enum PersonFields {
    /// One record's fields, written on `path`.
    static func written(_ fields: [(String, String)], _ path: FieldLayout, record: String = "lease") -> (Data, String) {
        switch path {
        case .json:
            let body = fields.map { #""\#($0.0)": "\#($0.1)""# }.joined(separator: ", ")
            return (Data("{\(body)}".utf8), "\(record).json")
        case .csv:
            func cell(_ value: String) -> String { value.contains(",") ? "\"\(value)\"" : value }
            let text = fields.map(\.0).joined(separator: ",") + "\n" + fields.map { cell($0.1) }.joined(separator: ",") + "\n"
            return (Data(text.utf8), "\(record).csv")
        case .xml:
            let body = fields.map { "<\($0.0)>\($0.1.replacingOccurrences(of: "&", with: "&amp;"))</\($0.0)>" }.joined()
            return (Data("<\(record)s><\(record)>\(body)</\(record)></\(record)s>".utf8), "\(record).xml")
        case .colon, .equals:
            let text = fields.map { "\($0.0)\(path == .colon ? ": " : "=")\($0.1)" }.joined(separator: "\n") + "\n"
            return (Data(text.utf8), "\(record).txt")
        }
    }

    /// The words of a text, in lowercase, read through either apostrophe.
    static func lowerWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init))
    }

    /// Written as a person's name: two to four capitalised words of letters,
    /// an apostrophe or a hyphen.
    static func looksLikeName(_ value: String) -> Bool {
        let words = value.split(separator: " ")
        return (2...4).contains(words.count) && words.allSatisfy { word in
            word.first?.isUppercase == true && word.allSatisfy { $0.isLetter || "'’-".contains($0) }
        }
    }
}

/// A value under a key that says it is a person's name is replaced whole,
/// however the name is written: a hyphenated surname, an apostrophe either
/// way, a surname's particles, several given names. Its stand-in is a name,
/// and no word of the original stays, in every format.
struct WholeNameFieldTests {
    static let keys = ["name", "full_name", "cosigner_name", "cosigner", "applicant", "contact", "guarantor"]
    static let names = ["Brisa Smith-Jones", "Tomasz O'Sullivan", "Tomasz O’Sullivan", "Odalys van der Berg", "Mary Anne Quillmere"]

    @Test(arguments: FieldLayout.allCases, keys)
    func aNameFieldIsReplacedWhole(_ path: FieldLayout, _ key: String) throws {
        for name in Self.names {
            let (data, file) = PersonFields.written([("lease_id", "L-2207"), (key, name), ("plan", "Gold"), ("status", "active")], path)
            let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 5)
            let output = String(decoding: result.output, as: UTF8.self)
            let label = "[\(path) \(key)] \(name)"
            let finding = try #require(result.findings.first { $0.original == name }, "\(label) not found whole: \(result.findings.map { "\($0.entity) \($0.original)" })")
            #expect(Review.names.contains(finding.entity) && PersonFields.looksLikeName(finding.standIn), "\(label) → \(finding.entity) \(finding.standIn)")
            let left = PersonFields.lowerWords(output)
            for word in PersonFields.lowerWords(name) where word.count > 1 { #expect(!left.contains(word), "\(label): \(word) left in \(output)") }
            // What names no one stays as written.
            for kept in ["L-2207", "Gold", "active"] { #expect(output.contains(kept), "\(label): \(kept) changed in \(output)") }
            if path == .json { #expect((try? JSONSerialization.jsonObject(with: result.output)) != nil, "\(label)") }
            if path == .xml { #expect((try? XMLDocument(data: result.output)) != nil, "\(label)") }
        }
    }

    /// A field that names a plan, not a person, keeps its value.
    @Test(arguments: FieldLayout.allCases)
    func aFieldThatIsNoPersonStays(_ path: FieldLayout) throws {
        let (data, file) = PersonFields.written([("lease_id", "L-2207"), ("plan_name", "Gold"), ("primary_key", "lease_id"), ("status", "active")], path)
        let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 5)
        #expect(result.findings.isEmpty, "[\(path)] \(result.findings.map { "\($0.entity) \($0.original)" })")
    }
}

/// An email built from a name with an apostrophe or a hyphen belongs to
/// that person wherever it is written, with the apostrophe straight, curly
/// or left out, and the hyphen left out, kept or written as a dot. Its
/// stand-in is built from the person's stand-in name.
struct ApostropheEmailTests {
    enum Path: String, CaseIterable, Sendable { case text, json, csv, xml }

    /// The tenant named in one record and the email in another, so only the name links them.
    static func document(_ name: String, _ email: String, _ path: Path) -> (Data, String) {
        switch path {
        case .text:
            return (Data("Tenancy for \(name), unit 4B, from March.\nThe boiler report came later from \(email), with photos.\n".utf8), "tenancy.txt")
        case .json:
            return (Data(#"{"tenants": [{"name": "\#(name)", "unit": "4B"}], "log": [{"from": "\#(email)", "topic": "boiler"}]}"#.utf8), "tenancy.json")
        case .csv:
            return (Data("name,unit,contact\n\(name),4B,\nQuillmere Tavish,7C,\n,,\(email)\n".utf8), "tenancy.csv")
        case .xml:
            return (Data("<tenancy><tenant><name>\(name)</name><unit>4B</unit></tenant><log><entry><from>\(email)</from><topic>boiler</topic></entry></log></tenancy>".utf8), "tenancy.xml")
        }
    }

    static let cases: [(name: String, locals: [String])] = [
        ("Tomasz O’Sullivan", ["tomasz.osullivan", "tomasz.o-sullivan", "tomasz.o'sullivan", "osullivan.tomasz", "t.osullivan", "tomaszosullivan"]),
        ("Tomasz O'Sullivan", ["tomasz.osullivan", "tomasz.o-sullivan", "osullivan.tomasz", "t.osullivan"]),
        ("Brisa Smith-Jones", ["brisa.smith-jones", "brisa.smithjones", "brisa.smith.jones", "bsmithjones", "smithjones.brisa"]),
    ]

    @Test(arguments: Path.allCases)
    func anEmailFollowsItsPersonsName(_ path: Path) throws {
        for (name, locals) in Self.cases {
            for local in locals {
                let email = "\(local)@kestrel.example"
                let (data, file) = Self.document(name, email, path)
                let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 9)
                let label = "[\(path)] \(name) / \(email)"
                let person = try #require(result.findings.first { Review.names.contains($0.entity) && $0.original == name }, "\(label): \(result.findings.map(\.original))")
                let address = try #require(result.findings.first { $0.entity == "EMAIL_ADDRESS" && $0.original == email }, "\(label): \(result.findings.map(\.original))")
                // Type oracle: an address, and its local part built from his stand-in name.
                let parts = address.standIn.split(separator: "@")
                #expect(parts.count == 2 && parts[1].contains("."), "\(label) → \(address.standIn)")
                let letters = String(parts.first ?? "").lowercased().filter(\.isLetter)
                let given = person.standIn.split(separator: " ").first.map { $0.lowercased().filter(\.isLetter) } ?? ""
                let surname = person.standIn.split(separator: " ").last.map { $0.lowercased().filter(\.isLetter) } ?? ""
                #expect(letters.contains(surname) && (letters.contains(given) || letters.hasPrefix(String(given.prefix(1)))), "\(label): \(person.standIn) but \(address.standIn)")
                let left = PersonFields.lowerWords(String(decoding: result.output, as: UTF8.self))
                for word in ["tomasz", "osullivan", "sullivan", "brisa", "smith", "jones", "smithjones", "bsmithjones"] { #expect(!left.contains(word), "\(label): \(word) left") }
            }
        }
    }
}

/// Two people in one flat record, told apart by their keys' qualifiers
/// ("applicant_name" and "spouse_name", "applicantEmail" and
/// "cosignerEmail"), are two people, as they are with "applicant.name" or
/// an object each: their own stand-in names, emails following them, and
/// birth parts following their own birth dates. One person's record with
/// qualified fields of its own ("home_phone" and "work_phone") stays one.
struct FlatRecordPeopleTests {
    enum Shape: String, CaseIterable, Sendable { case json, csv, xml }
    enum Style: String, CaseIterable, Sendable { case snake, camel }

    struct Person { let name: String, local: String, iso: String }
    static let pairs: [(String, String)] = [("applicant", "spouse"), ("applicant", "cosigner"), ("primary", "secondary"), ("guarantor", "applicant"), ("billing", "shipping")]
    /// Same surname, born in the same month.
    static let couple = [Person(name: "Odalys Ferriter", local: "odalys.ferriter", iso: "1988-03-14"), Person(name: "Corwin Ferriter", local: "corwin.ferriter", iso: "1990-03-27")]

    static func key(_ role: String, _ field: String, _ style: Style) -> String {
        guard style == .camel else { return "\(role)_\(field)" }
        let words = field.split(separator: "_")
        return role + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func fields(_ roles: (String, String), _ style: Style) -> [(String, String)] {
        [("case_id", "A-1001")] + zip([roles.0, roles.1], couple).flatMap { role, person -> [(String, String)] in
            let month = String(Int(person.iso.split(separator: "-")[1])!)
            return [(key(role, "name", style), person.name), (key(role, "email", style), "\(person.local)@corvane.test"),
                    (key(role, "dob", style), person.iso), (key(role, "birth_month", style), month)]
        }
    }

    static func scrub(_ fields: [(String, String)], _ shape: Shape, seed: UInt64) throws -> ScrubResult {
        let (data, file) = PersonFields.written(fields, shape == .json ? .json : shape == .csv ? .csv : .xml, record: "case")
        return try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: seed)
    }

    /// The scrubbed value of each field, read back from the output.
    static func values(_ result: ScrubResult, _ shape: Shape, keys: [String]) throws -> [String: String] {
        switch shape {
        case .json:
            let object = try #require(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
            return object.compactMapValues { $0 as? String ?? ($0 as? NSNumber)?.stringValue }
        case .csv:
            let rows = String(decoding: result.output, as: UTF8.self).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            return Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))
        case .xml:
            let document = try XMLDocument(data: result.output)
            return Dictionary(uniqueKeysWithValues: keys.compactMap { key in try? document.nodes(forXPath: "//\(key)").first?.stringValue.map { (key, $0) } })
        }
    }

    @Test(arguments: Shape.allCases, Style.allCases)
    func twoPeopleInOneRecordAreTwo(_ shape: Shape, _ style: Style) throws {
        for roles in Self.pairs {
            let fields = Self.fields(roles, style)
            let result = try Self.scrub(fields, shape, seed: 13)
            let label = "[\(shape) \(style) \(roles)]"
            let values = try Self.values(result, shape, keys: fields.map(\.0))
            var drawn: [String] = []
            for (role, person) in zip([roles.0, roles.1], Self.couple) {
                let name = try #require(values[Self.key(role, "name", style)], "\(label) \(values)")
                let email = try #require(values[Self.key(role, "email", style)], "\(label) \(values)")
                let dob = try #require(values[Self.key(role, "dob", style)], "\(label) \(values)")
                let month = try #require(values[Self.key(role, "birth_month", style)], "\(label) \(values)")
                #expect(PersonFields.looksLikeName(name) && name != person.name, "\(label) \(person.name) → \(name)")
                // Each email is built from its own person's stand-in name.
                let local = email.split(separator: "@").first.map { $0.lowercased() } ?? ""
                let parts = name.lowercased().split(separator: " ").map { $0.filter(\.isLetter) }
                #expect(local == parts.joined(separator: "."), "\(label) \(name) but \(email)")
                // Each month follows its own stand-in birth date.
                #expect(dob != person.iso && Int(month) == Int(dob.split(separator: "-")[1]), "\(label) \(person.iso) → \(dob), month \(month)")
                drawn.append(name)
            }
            #expect(drawn[0] != drawn[1], "\(label) both became \(drawn[0])")
            // The same file and seed write the same result.
            let again = try Self.scrub(fields, shape, seed: 13)
            #expect(again.output == result.output, "\(label) not deterministic")
        }
    }

    /// One person with qualified fields of their own ("home_phone" beside
    /// "work_phone", "first_name" beside "last_name", "billing_email") stays one.
    @Test(arguments: Shape.allCases)
    func onePersonsQualifiedFieldsStayOnePerson(_ shape: Shape) throws {
        let records: [[(String, String)]] = [
            [("name", "Odalys Ferriter"), ("email", "odalys.ferriter@corvane.test"), ("home_phone", "(415) 867-2290"), ("work_phone", "(415) 867-2291"), ("created_at", "2024-05-02")],
            [("first_name", "Odalys"), ("last_name", "Ferriter"), ("billing_email", "odalys.ferriter@corvane.test"), ("shipping_phone", "(415) 867-2290")],
            [("applicant_name", "Odalys Ferriter"), ("email", "odalys.ferriter@corvane.test"), ("applicant_dob", "1988-03-14")],
        ]
        for fields in records {
            let result = try Self.scrub(fields, shape, seed: 13)
            let label = "[\(shape)] \(fields.map(\.0))"
            let values = try Self.values(result, shape, keys: fields.map(\.0))
            let name = try #require(values["name"] ?? values["applicant_name"] ?? values["first_name"].flatMap { first in values["last_name"].map { "\(first) \($0)" } }, "\(label) \(values)")
            let email = try #require(values["email"] ?? values["billing_email"], "\(label) \(values)")
            #expect(PersonFields.looksLikeName(name) && email.split(separator: "@").first.map { $0.lowercased() } == name.lowercased().split(separator: " ").map { $0.filter(\.isLetter) }.joined(separator: "."), "\(label) \(name) but \(email)")
            if let created = values["created_at"] { #expect(created == "2024-05-02", "\(label) created_at → \(created)") }
        }
    }
}

/// <first> and <last> in a person's record are read as their name's parts,
/// as <first_name> and <last_name> are; elsewhere, or holding no name, they
/// stay as written.
struct XMLNamePartTests {
    @Test(arguments: ["person", "applicant", "contact", "record"])
    func firstAndLastInAPersonAreTheirName(_ record: String) throws {
        for (first, last) in [("first", "last"), ("given", "family")] {
            let xml = "<people><\(record)><\(first)>Odalys</\(first)><\(last)>Ferriter</\(last)><email>odalys.ferriter@corvane.test</email><status>active</status></\(record)></people>"
            let result = try Scrubber.scrub(Data(xml.utf8), name: "people.xml", forceFullDetection: false, seed: 3)
            let label = "[\(record) \(first)/\(last)]"
            let document = try XMLDocument(data: result.output)
            let given = try #require(try document.nodes(forXPath: "//\(first)").first?.stringValue)
            let surname = try #require(try document.nodes(forXPath: "//\(last)").first?.stringValue)
            let email = try #require(try document.nodes(forXPath: "//email").first?.stringValue)
            #expect(PersonFields.looksLikeName("\(given) \(surname)") && given != "Odalys" && surname != "Ferriter", "\(label) → \(given) \(surname)")
            #expect(email.split(separator: "@").first.map(String.init) == "\(given).\(surname)".lowercased(), "\(label) \(given) \(surname) but \(email)")
            #expect(try document.nodes(forXPath: "//status").first?.stringValue == "active", "\(label)")
        }
    }

    /// Flags, dates, numbers and weekdays under <first> and <last> are no name.
    @Test func firstAndLastHoldingNoNameStay() throws {
        let xml = "<report><flags><first>true</first><last>false</last></flags><range><first>2024-01-01</first><last>2024-03-31</last></range><pages><first>1</first><last>12</last></pages><shift><first>Monday</first><last>Friday</last></shift><sort><first>asc</first></sort></report>"
        let result = try Scrubber.scrub(Data(xml.utf8), name: "report.xml", forceFullDetection: false, seed: 3)
        #expect(result.findings.isEmpty, "\(result.findings.map { "\($0.entity) \($0.original)" })")
        #expect(String(decoding: result.output, as: UTF8.self).contains("<first>Monday</first><last>Friday</last>"))
    }
}

/// A record keyed in another language is read as one keyed in English: a Turkish
/// applicant's given name, surname, parents' names, birth date, birthplace and
/// address, and a birth date under its key in the languages forms are filled in.
struct OtherLanguageRecordTests {
    @Test func aTurkishApplicantsRecordIsReplacedWhole() throws {
        let json = #"""
        {
          "basvuruNo": "BSV-2026-004417",
          "durum": "ONAYLANDI",
          "musteri": {
            "ad": "Elif",
            "soyad": "Karagöz",
            "dogumTarihi": "14.09.1991",
            "dogumYeri": "Eskişehir",
            "babaAdi": "Tarık",
            "anneAdi": "Nurhan",
            "telefon": "+90 555 010 47 21",
            "eposta": "elif.karagoz@example.com",
            "adres": "Çınar Sok. No:18 D:3, Moda, Kadıköy/İstanbul"
          },
          "kanal": "MOBIL"
        }
        """#
        for seed in UInt64(0)..<4 {
            let result = try Scrubber.scrub(Data(json.utf8), name: "basvuru.json", forceFullDetection: false, seed: seed)
            let text = String(decoding: result.output, as: UTF8.self)
            let object = try #require(try JSONSerialization.jsonObject(with: result.output) as? [String: Any], "seed \(seed): no longer parses")
            let record = try #require(object["musteri"] as? [String: String])
            for gone in ["Elif", "Karagöz", "14.09.1991", "Eskişehir", "Tarık", "Nurhan", "Çınar", "Moda", "elif.karagoz"] {
                #expect(!text.contains(gone), "seed \(seed): \(gone) left in \(text)")
            }
            let date = try #require(record["dogumTarihi"])
            #expect(date.range(of: #"^\d{2}\.\d{2}\.\d{4}$"#, options: .regularExpression) != nil, "seed \(seed): \(date)")
            #expect(object["durum"] as? String == "ONAYLANDI" && object["kanal"] as? String == "MOBIL" && object["basvuruNo"] as? String == "BSV-2026-004417")
            // Replaced outright, not left for a person's look.
            for finding in result.findings where ["Karagöz", "14.09.1991", "Tarık"].contains(finding.original) {
                #expect(!finding.suspected && !finding.needsReview, "seed \(seed): \(finding.original) only offered for review")
            }
        }
    }

    @Test(arguments: [
        ("dossier.json", #"{"dossier": "OUV-2026-1182", "titulaire": {"prenom": "Maëlle", "nom": "Quintard", "date_naissance": "1987-11-23"}}"#, "1987-11-23"),
        ("pratica.json", #"{"pratica": "PRA-2026-3310", "cliente": {"nome": "Ottavia", "cognome": "Brenzi", "data_nascita": "23/11/1987"}}"#, "23/11/1987"),
        ("solicitud.json", #"{"solicitud": "SOL-2026-7720", "titular": {"nombre_completo": "Remedios Alcaraz Pons", "fecha_nac": "23/11/1987"}}"#, "23/11/1987"),
        ("basvuru.json", #"{"basvuru": "BSV-2026-5512", "kisi": {"adSoyad": "Elif Karagöz", "dogum_tarihi": "23.11.1987"}}"#, "23.11.1987"),
        ("wniosek.json", #"{"wniosek": "WN-2026-0915", "osoba": {"imie": "Zofia", "nazwisko": "Wróblewska", "data_urodzenia": "1987-11-23"}}"#, "1987-11-23"),
    ])
    func aBirthDateUnderItsKeyInAnotherLanguageIsReplaced(_ name: String, _ json: String, _ date: String) throws {
        let result = try Scrubber.scrub(Data(json.utf8), name: name, forceFullDetection: false, seed: 5)
        let text = String(decoding: result.output, as: UTF8.self)
        #expect(!text.contains(date), "\(name): \(text)")
        let finding = try #require(result.findings.first { $0.original == date }, "\(name): \(result.findings.map(\.original))")
        #expect(finding.entity == "DATE_OF_BIRTH" && !finding.suspected && !finding.needsReview, "\(name): \(finding.entity)")
        #expect(finding.standIn.count == date.count && finding.standIn.filter(\.isNumber).count == date.filter(\.isNumber).count, "\(name): \(finding.standIn)")
    }

    /// The surname someone was born with, among their name's parts, is replaced as their family name is, by a surname of its own.
    @Test func aMaidenNameAmongANamesPartsIsReplaced() throws {
        let json = #"{"parties": [{"role": "applicant", "names": {"given": "Halina", "family": "Wierzbowska", "maiden": "Grabarczyk"}, "born": "1984-02-19"}, {"role": "spouse", "names": {"given": "Ove", "family": "Lindhagen"}}]}"#
        for seed in UInt64(0)..<4 {
            let result = try Scrubber.scrub(Data(json.utf8), name: "parties.json", forceFullDetection: false, seed: seed)
            let text = String(decoding: result.output, as: UTF8.self)
            for gone in ["Halina", "Wierzbowska", "Grabarczyk", "Lindhagen"] { #expect(!text.contains(gone), "seed \(seed): \(gone) left in \(text)") }
            let parties = try #require((try JSONSerialization.jsonObject(with: result.output) as? [String: Any])?["parties"] as? [[String: Any]])
            let names = try #require(parties[0]["names"] as? [String: String])
            let maiden = try #require(names["maiden"])
            // A surname of its own: two surnames never share one stand-in.
            #expect(PersonFields.looksLikeName("Ann " + maiden) && maiden != names["family"], "seed \(seed): \(names)")
        }
    }
}
