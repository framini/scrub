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

    /// A company with a legal form, however its country writes it, stays as written, name and form,
    /// in a sentence and in a record: none of them is a person, and "S.r.l." is no one's handle.
    @Test(arguments: [
        "Bellandi Arredamenti S.r.l.", "Cortesi Mobili Srl", "Ferrandi Costruzioni S.p.A.", "Horvat Gradnja d.o.o.", "Novotný Strojírny s.r.o.",
        "Wiśniewski Logistyka Sp. z o.o.", "Brenner Bau GmbH & Co. KG", "Virtanen Ohjelmistot Oy", "Haugen Eiendom AS", "Lindqvist Data ASA",
        "Ekström Konsult AB", "Tamm Tarkvara OÜ", "Ozols Būve SIA", "Kazlauskas Prekyba UAB", "Nagy Építő Kft.", "Szabó Ipari Zrt.",
        "Yılmaz Tekstil A.Ş.", "Hargreaves Joinery Ltd", "Mokoena Holdings (Pty) Ltd", "Tan Wei Trading Pte. Ltd.", "Ribeiro Exportações S.A.",
        "Moreau Conseil S.A.S.", "Lefèvre Peinture SARL", "Garnier Logiciels SAS", "Van Dijk Techniek B.V.", "Peeters Bouw N.V.", "De Wit Advies BV",
        "Janssens Groep NV", "Ferreira Consultoria Lda.", "Oliveira Comércio Ltda.", "Navarro Reformas S.L.", "Gutiérrez Alimentos S.A. de C.V.",
        "Παπαδόπουλος Κατασκευές Α.Ε.", "Петров Консулт ЕООД", "Иванов Логистик ООО",
    ])
    func aCompanyWithItsLegalFormIsNoOne(_ company: String) throws {
        for sentence in ["Invoice 2024-118 was issued by \(company) on 3 March and paid by bank transfer.\n",
                         "Fornitore: \(company), con sede legale in centro. Fattura saldata il 3 marzo.\n",
                         "Lieferant: \(company). Die Rechnung wurde am 3. März bezahlt.\n",
                         "Supplier: \(company) invoiced us twice this month.\n"] {
            let (_, prose) = try Self.scrub(sentence)
            #expect(prose.contains(company), "\(prose)")
        }
        let (_, json) = try Self.scrub(#"{"invoice": {"number": "2024-118", "issuer": "\#(company)", "note": "Paid to \#(company) in full."}}"#, name: "invoice.json")
        #expect(json.components(separatedBy: company).count == 3, "\(json)")
    }
}

/// A place a reader only guessed, in a language Scrub reads the words of, is replaced only as a place Scrub knows,
/// beside a postcode or an address, or written as a town; one made of the language's own words stays and is asked about.
@Suite struct ForeignPlaceTests {
    static func gated(_ text: String, _ places: [String]) -> (kept: [String], doubted: [String]) {
        let spans = places.map { place in
            let range = (text as NSString).range(of: place)
            return Span(range: range.location..<NSMaxRange(range), entity: "LOCATION", score: 0.6)
        }
        let address = (text as NSString).range(of: "Lindenstraße 14, 34117 Kassel")
        let all = address.location == NSNotFound ? spans : spans + [Span(range: address.location..<NSMaxRange(address), entity: "ADDRESS", score: 0.9)]
        let gated = NameEvidence.gate(all, doubts: [], evidenced: [], in: text, document: nil)
        return (gated.spans.filter { $0.entity == "LOCATION" }.map { TextRanges.substring(text, $0.range) }, gated.doubts.map { TextRanges.substring(text, $0.range) })
    }

    @Test func aGermanLettersOwnWordsAreNoPlace() {
        let letter = """
        Sehr geehrte Frau Albrecht,
        bitte senden Sie uns eine Kopie Ihres Personalausweises sowie einen aktuellen Nachweis Ihrer Anschrift. Den Abschlag für Strom und Wasser haben wir erhalten.
        Sie sind geboren in Kassel und wohnen in der Lindenstraße 14, 34117 Kassel. Ihre Tochter studiert in Essen, Ihr Sohn arbeitet in Leipzig.
        """
        let (kept, doubted) = Self.gated(letter, ["Kopie Ihres", "Strom", "Kassel", "Essen", "Leipzig"])
        #expect(doubted.contains("Kopie Ihres") && doubted.contains("Strom"), "\(doubted)")
        #expect(!kept.contains("Kopie Ihres") && !kept.contains("Strom"), "\(kept)")
        for town in ["Kassel", "Essen", "Leipzig"] { #expect(kept.contains(town), "\(town): \(kept)") }
    }

    @Test func aDutchAndASpanishWordAreNoPlaceButAPostcodesTownIs() {
        let dutch = "Wij hebben uw kopie van het paspoort ontvangen, maar de achterkant ontbreekt nog. Stuur deze alstublieft opnieuw naar 3511 Brakeldorp."
        let (kept, doubted) = Self.gated(dutch, ["achterkant", "Brakeldorp"])
        #expect(doubted == ["achterkant"] && kept == ["Brakeldorp"], "\(kept) \(doubted)")
        let spanish = "Hemos recibido la copia de su documento de identidad, pero falta el reverso. Por favor envíelo de nuevo a la oficina de Valdemoro Alto."
        let (keptSpanish, doubtedSpanish) = Self.gated(spanish, ["Por favor", "Valdemoro Alto"])
        #expect(doubtedSpanish == ["Por favor"] && keptSpanish == ["Valdemoro Alto"], "\(keptSpanish) \(doubtedSpanish)")
    }
}

/// Short words of the text's own language a reader ran into a name ("Ik ben", "dla", "geboren") are no part of it.
@Suite struct ForeignSmallWordTests {
    @Test func aFormsSmallWordsBeforeANameStay() throws {
        let form = """
        Aanvraagformulier rekening, ontvangen op het kantoor in de stad.
        Naam: Ik ben Lotte Brakenhoff
        Opmerking: de klant belt morgen terug over de verlenging van het contract.
        """
        let (result, output) = try ForeignWordTests.scrub(form)
        #expect(output.contains("Naam: Ik ben "), "\(output)")
        for name in ["Lotte", "Brakenhoff"] { #expect(!output.contains(name), "\(name) → \(output)") }
        #expect(!result.findings.contains { $0.original.hasPrefix("Ik") }, "\(result.findings.map(\.original))")
    }

    @Test func aDutchLettersOwnWordsAreNoOneToAskAbout() throws {
        let letter = """
        Goedemiddag,
        Ik ben de nieuwe contactpersoon voor uw dossier. Ik ben bereikbaar op werkdagen tussen negen en vijf.
        Met vriendelijke groet,
        Femke Brakenhoff
        """
        let (result, output) = try ForeignWordTests.scrub(letter)
        #expect(output.contains("Ik ben de nieuwe") && output.contains("Ik ben bereikbaar"), "\(output)")
        #expect(!output.contains("Brakenhoff"), "\(output)")
        #expect(!result.findings.contains { $0.original == "Ik ben" }, "\(result.findings.map(\.original))")
    }
}
