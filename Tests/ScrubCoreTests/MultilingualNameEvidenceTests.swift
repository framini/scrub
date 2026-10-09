import Foundation
@testable import ScrubCore
import Testing

/// In a language other than English a name only guessed needs evidence, and three kinds of it read in any
/// language: a table column headed with a word for a name ("Naam", "Name", "Nom"), a salutation that opens a
/// letter to the person ("Beste", "Liebe", "Chère"), and a label for whom a letter or an account is for
/// ("Geadresseerd aan:", "Kontoinhaber:", "Destinataire :"). The salutation and the label stay as written,
/// and a salutation to no one by name ("Liebe Grüße", "Beste klant") names no one.
@Suite struct MultilingualNameEvidenceTests {
    static let letters: [(language: String, text: String, gone: [String], kept: [String])] = [
        ("Dutch", """
        Overzicht van de wijzigingen in uw rekening

        "IBAN","Naam","Woonplaats","Opmerkingen"
        "NL91ABNA0417164300","Tjalling Verhoeckx","Zwolle","Adres gewijzigd"

        Beste Femke Haasbroek,

        Wij hebben uw verzoek ontvangen en het nieuwe adres verwerkt in onze administratie.

        Geadresseerd aan:
        Sieuwke Brandsema
        Kerkstraat 12

        Met vriendelijke groet,
        De afdeling Klantenservice
        """, ["Verhoeckx", "Haasbroek", "Brandsema"], ["\"Naam\"", "Beste ", "Geadresseerd aan:", "Met vriendelijke groet,"]),
        ("German", """
        Übersicht der Kontobewegungen

        "Kundennummer";"Name";"Ort";"Bemerkung"
        "K-1001";"Wiltrud Brunnhuber";"Passau";"Adresse geändert"

        Liebe Hiltrud Zwerenz,

        wir haben Ihren Antrag erhalten und die neue Anschrift in unseren Unterlagen eingetragen.

        Kontoinhaber: Ottokar Wendelsteiner
        Kontonummer: 0123456789

        Liebe Grüße
        Ihr Kundenservice
        """, ["Brunnhuber", "Zwerenz", "Wendelsteiner"], ["\"Name\"", "Liebe ", "Kontoinhaber:", "Liebe Grüße"]),
        ("French", """
        Relevé des opérations du compte

        "Référence","Nom","Ville","Remarque"
        "R-2207","Ombeline Garnache-Vauquois","Valence","Adresse modifiée"

        Chère Apolline Rouvière-Daubigné,

        Nous avons bien reçu votre demande et la nouvelle adresse a été enregistrée dans nos fichiers.

        Destinataire :
        Auguste Vermorel-Chastagnier
        12 rue des Tanneurs

        Cordialement,
        Le service clientèle
        """, ["Garnache", "Rouvière", "Vermorel"], ["\"Nom\"", "Chère ", "Destinataire :", "Cordialement,"]),
    ]

    @Test(arguments: letters.indices)
    func columnSalutationAndLabelAreEvidence(_ index: Int) throws {
        let letter = Self.letters[index]
        let result = try Scrubber.scrub(Data(letter.text.utf8), name: "letter.txt", forceFullDetection: false, seed: 11)
        let output = String(decoding: result.output, as: UTF8.self)
        for word in letter.gone { #expect(!output.contains(word), "\(letter.language): \(word) left in\n\(output)") }
        for words in letter.kept { #expect(output.contains(words), "\(letter.language): \(words) changed\n\(output)") }
    }

    @Test func aSalutationToNoOneNamesNoOne() throws {
        let text = "Beste klant,\n\nUw pas is verlopen. Vraag een nieuwe aan via de website.\n\nLiebe Grüße\nIhr Team"
        let result = try Scrubber.scrub(Data(text.utf8), name: "letter.txt", forceFullDetection: false, seed: 11)
        #expect(String(decoding: result.output, as: UTF8.self) == text)
    }

    /// A chat's or a log's lines with commas in them are no table, so the first of them heads no column of names.
    static let notTables: [(shape: String, name: String, text: String, kept: [String])] = [
        ("a word after a speaker's label", "Pasted text", """
        [16:21] Customer: Assalam o alaikum, mera account verify nahi ho raha, please check.
        [16:22] Agent Danish: Ji main check karta hoon.
        [16:23] Agent Danish: Shukriya. Screening result NO_HIT, ticket PK-CS-2026-4410.
        """, ["Ji main check", ": Shukriya."]),
        ("a role labelling a chat's line", "Pasted text", """
        [21:03] Cliente: Hola, buenas noches.
        [21:04] Asesor (Ezequiel): Buenas noches, señora Ocampo. ¿En qué le puedo ayudar?
        [21:05] Cliente: Quiero cambiar mi dirección.
        [21:06] Asesor (Ezequiel): Con gusto, un momento.
        """, ["[21:04] Asesor (", "[21:06] Asesor ("]),
        ("a host in a log's line", "consumer.log", """
        [2026-10-09 17:10:01,102] INFO [Producer clientId=payments-producer-1] Connected to broker
        [2026-10-09 17:10:02,409] WARN commit latency 1840ms exceeds threshold 1000ms (broker queue-2.internal:9093)
        """, ["(broker queue-2.internal:9093)"]),
        ("a host in a log's line, pasted", "Pasted text", """
        [2026-10-09 17:10:01,102] INFO [Producer clientId=payments-producer-1] Connected to broker
        [2026-10-09 17:10:02,409] WARN commit latency 1840ms exceeds threshold 1000ms (broker queue-2.internal:9093)
        """, ["(broker queue-2.internal:9093)"]),
    ]

    @Test(arguments: notTables.indices)
    func aChatOrALogIsNoTable(_ index: Int) throws {
        let item = Self.notTables[index]
        let result = try Scrubber.scrub(Data(item.text.utf8), name: item.name, forceFullDetection: false, seed: 11)
        let output = String(decoding: result.output, as: UTF8.self)
        for words in item.kept { #expect(output.contains(words), "\(item.shape): \(words) changed\n\(output)") }
    }

    /// The word a line's first comma follows heads no column there, whatever the line above says: a log's host, a chat's
    /// reply and a role labelling a chat's line take no evidence from it. A real table's column still does.
    @Test func noColumnInAChatOrALog() {
        let log = "[2026-10-09 17:10:01,102] INFO [Producer clientId=payments-producer-1] Connected to broker\n"
            + "[2026-10-09 17:10:02,409] WARN commit latency 1840ms exceeds threshold 1000ms (broker queue-2.internal:9093)\n"
        let chat = "[21:03] Cliente: Hola, buenas noches.\n[21:04] Asesor (Ezequiel): Buenas noches, señora Ocampo.\n"
        let reply = "[16:21] Customer: Assalam o alaikum, mera account verify nahi ho raha, please check.\n[16:23] Agent Danish: Shukriya. Ticket PK-CS-2026-4410.\n"
        let table = "\"IBAN\",\"Naam\",\"Woonplaats\"\n\"NL91ABNA0417164300\",\"Tjalling Verhoeckx\",\"Zwolle\"\n"
        func range(of word: String, in text: String) -> Range<Int> {
            let found = (text as NSString).range(of: word)
            return found.location..<found.location + found.length
        }
        #expect(!NameEvidence.columned(range(of: "broker queue", in: log), in: log))
        #expect(!NameEvidence.columned(range(of: "Asesor", in: chat), in: chat))
        #expect(!NameEvidence.columned(range(of: "Shukriya", in: reply), in: reply))
        #expect(NameEvidence.columned(range(of: "Tjalling Verhoeckx", in: table), in: table))
    }
}

