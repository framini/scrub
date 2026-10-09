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
}
