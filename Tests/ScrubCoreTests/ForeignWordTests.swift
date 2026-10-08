import Foundation
@testable import ScrubCore
import Testing

/// A word of the text's own language that a reader only guessed was a name stays as written and
/// is asked about; a person with a title, a phrase that introduces them or a given name and a
/// surname is replaced. Values that say what kind of thing a record is, a link's words, a log's
/// protocol, a company and a date written out in words are never someone's name.
@Suite struct ForeignWordTests {
    static func scrub(_ text: String, name: String = "Pasted text") throws -> (ScrubResult, String) {
        let result = try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 11)
        return (result, String(decoding: result.output, as: UTF8.self))
    }

    @Test func germanNounsStayAndTheTitledCustomerGoes() throws {
        let chat = """
        [09:02] Agentin: Guten Morgen, hier ist Herr Lukas Brandauer vom Support.
        [09:03] Kunde: Hallo, mein Name ist Ingrid Wehrmeister. Ich warte seit Montag auf die Freigabe.
        [09:04] Agentin: Danke. Ergebnis der Prüfung: kein Treffer auf der Sanktionsliste, aber Wohnort unklar.
        [09:07] Kunde: Mache ich. Das ist ernst, ich brauche das Konto bis Freitag.
        """
        let (result, output) = try Self.scrub(chat)
        for word in ["Guten Morgen", "Agentin:", "Kunde:", "Montag", "Wohnort unklar", "kein Treffer auf der Sanktionsliste", "bis Freitag"] {
            #expect(output.contains(word), "\(word) → \(output)")
        }
        for name in ["Lukas", "Brandauer", "Ingrid", "Wehrmeister"] { #expect(!output.contains(name), "\(name) → \(output)") }
        // What was only guessed is still put to a person, never dropped.
        #expect(result.findings.contains { $0.suspected && ["Wohnort", "Kunde", "Guten Morgen", "Montag", "Freitag", "Agentin"].contains($0.original) })
    }

    @Test func dutchPronounAndSpanishGreetingStay() throws {
        let letter = """
        Geachte heer of mevrouw,

        Wij, Maarten Hoogeveen en Floor Kerstholt, willen graag een gezamenlijke rekening openen.
        Graag ontvangen wij de formulieren per post. Vandaar de vraag over een Zwitserse rekening.
        """
        let (result, dutch) = try Self.scrub(letter)
        for word in ["Wij,", "ontvangen wij", "Vandaar de vraag", "Zwitserse rekening"] { #expect(dutch.contains(word), "\(word) → \(dutch)") }
        // The two people are replaced, or, where nothing confirms them, put to a person: never left unseen.
        for name in ["Maarten Hoogeveen", "Floor Kerstholt"] {
            #expect(!dutch.contains(name) || result.findings.contains { $0.suspected && $0.original.contains(name) }, "\(name) → \(dutch)")
        }
        let mail = "Asunto: Solicitud de verificación\n\nBuenos días:\n\nMi marido, Teodoro Galindo Urrutia, también es titular de la cuenta. Me llamo Leonor Bastida.\n"
        let (_, spanish) = try Self.scrub(mail)
        for word in ["Buenos días", "Mi marido", "Solicitud de verificación"] { #expect(spanish.contains(word), "\(word) → \(spanish)") }
        for name in ["Teodoro", "Urrutia", "Leonor", "Bastida"] { #expect(!spanish.contains(name), "\(name) → \(spanish)") }
    }

    @Test func kindsLinksProtocolsAndCompaniesAreNoOne() throws {
        let record = """
        {"cliente": {"nome": "Hermínio Valadares Portela"},
         "dependentes": [{"nome": "Silvano Portela", "parentesco": "filho", "estado_civil": "solteiro"}],
         "empresa": "Example Lisboa Consultoria, Lda.",
         "observacao": "Contrato assinado com Example Lisboa Consultoria, Lda. em junho."}
        """
        let (_, json) = try Self.scrub(record, name: "client.json")
        for value in ["\"filho\"", "\"solteiro\"", "Example Lisboa Consultoria, Lda."] { #expect(json.contains(value), "\(value) → \(json)") }
        #expect(!json.contains("Silvano") && !json.contains("Hermínio"), "\(json)")
        let log = """
        $ curl -v https://api.example.com/v1/accounts/verify
        * TLS handshake, Client hello (1):
        > POST /v1/accounts/verify HTTP/2
        < HTTP/2 200
        {"status":"verified","subject":"Quirina Delacroix-Mbeki"}
        """
        let (_, curl) = try Self.scrub(log, name: "verify.log")
        for value in ["/v1/accounts/verify", "TLS handshake", "Client hello"] { #expect(curl.contains(value), "\(value) → \(curl)") }
        #expect(!curl.contains("Quirina"), "\(curl)")
    }

    @Test func aDateWrittenOutIsOneDateInItsOwnLanguage() throws {
        let (_, german) = try Self.scrub("Meine Mutter, Frau Waltraud Eisenhauer, geboren am 3. März 1948, möchte ein Konto eröffnen.\n")
        let born = try #require(german.range(of: #"geboren am (\d{1,2})\. (\p{L}+) (\d{4}),"#, options: .regularExpression), "\(german)")
        let written = String(german[born])
        #expect(!written.contains("3. März 1948"), "\(written)")
        let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
        #expect(months.contains { written.contains(" \($0) ") }, "\(written)")
        let year = Int(written.suffix(5).prefix(4)) ?? 0
        #expect((1900...2025).contains(year), "\(written)")
        // A Polish date is never read as a house number, a street and a town.
        let (_, polish) = try Self.scrub("Urodziłem się 12 maja 1966 r. w Lublinie. Proszę o kontakt w sprawie blokady konta.\n")
        #expect(polish.contains("maja") && polish.contains("Proszę o kontakt"), "\(polish)")
    }
}
