import Foundation
@testable import ScrubCore
import Testing

private func scrubText(_ text: String) throws -> (String, ScrubResult) {
    let result = try Scrubber.scrub(Data(text.utf8), name: "notes.txt")
    return (try #require(String(data: result.output, encoding: .utf8)), result)
}

@Test func replacesInline() throws {
    let (text, result) = try scrubText("Hi team,\n\nRobert Mitchell (robert@acme-corp.com, 212-867-5309) asked for a refund.\n")
    #expect(!text.contains("Robert Mitchell"))
    #expect(!text.contains("robert@acme-corp.com"))
    #expect(text.contains("asked for a refund."))
    if case let .text(preview, marks, _) = result.preview {
        #expect(marks.allSatisfy { $0.range.count > 0 && $0.range.upperBound <= (preview as NSString).length })
    }
    #expect(result.unresolved.isEmpty)
}

@Test(arguments: ["078-05-1120", "123-45-6789", "900-12-3456", "666-12-3456", "219-09-9999"])
func ssnShapedNumbersBecomeFakeSSNs(_ ssn: String) throws {
    let (text, result) = try scrubText("Call back re: renewal, her SSN is \(ssn) and her phone is 212-867-5309.\n")
    #expect(!text.contains(ssn))
    if case let .text(preview, marks, _) = result.preview {
        let ssns = marks.filter { $0.entity == "US_SSN" }.map { (preview as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(ssns.count == 1)
        #expect(ssns.first?.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) != nil)
        #expect(marks.contains { $0.entity == "PHONE_NUMBER" })
    }
    #expect(result.unresolved.isEmpty)
}

@Test(arguments: ["42 Wallaby Way", "1600 Pennsylvania Avenue NW", "221B Baker Street", "350 Fifth Ave, Suite 3400"])
func streetAddressesInFreeText(_ address: String) throws {
    let (text, result) = try scrubText("Please ship it to \(address), as agreed.\n")
    #expect(!text.contains(address))
    #expect(text.contains("as agreed."))
    #expect(result.unresolved.isEmpty)
}

@Test func correctionCatchesSurvivingOriginal() throws {
    let job = Job()
    let fake = job.replacement(for: "PERSON", original: "Robert Mitchell")
    let initial = "\(fake) wrote to Robert Mitchell."
    let (text, _, unresolved) = try Correction.run(initial, marks: [Mark(range: 0..<(fake as NSString).length, entity: "PERSON")], job: job)
    #expect(!text.contains("Robert Mitchell"))
    #expect(unresolved.isEmpty)
}

// A JSON body pasted inside a curl command is plain text, but its keys still say what each value is.
@Test func quotedKeysInTextHintTheirValues() throws {
    let (text, result) = try scrubText(#"""
    curl -X POST https://api.example.com/verifications \
    -d '{
      "user": {
        "email_address": "acharleston@email.com",
        "name": { "given_name": "Anna", "family_name": "Charleston" },
        "address": { "street2": "Apt 1A", "postal_code": "94103", "country": "US" },
        "id_number": { "value": "123456789", "type": "us_ssn" },
        "aliases": ["Anna Charleston"],
        "note": "said "hi"", "name": Bob said "Robert Mitchell"
      }
    }'
    """#)
    for original in ["acharleston@email.com", "Anna", "Charleston", "94103", "123456789"] { #expect(!text.contains(original)) }
    for kept in [#""country": "US""#, #""type": "us_ssn""#, "api.example.com"] { #expect(text.contains(kept)) }
    // A second address line is replaced, and stays one.
    #expect(!text.contains("Apt 1A") && text.range(of: #""street2": "Apt \d[A-Z]""#, options: .regularExpression) != nil)
    #expect(text.range(of: #""value": "\d{9}""#, options: .regularExpression) != nil)
    if case let .text(preview, marks, _) = result.preview {
        let ids = marks.filter { $0.entity == "ID_NUMBER" }.map { (preview as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(ids.count == 1)
        #expect(!marks.contains { $0.entity == "PHONE_NUMBER" })
    }
}

@Test func keyedValuesFollowNestingAndIgnoreProse() {
    let text = #"x "name": "Ann Lee", "id": {"value": "A12"}, "ssn": {"value": "1"}, "tags": ["a"], "names": {"name": ["Bo Li"]}, "phone": 5, "email" : "a@b.co" "#
    let found = KeyedValues.find(text).map { ((text as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)), $0.entity) }
    #expect(found.map(\.0) == ["Ann Lee", "1", "Bo Li", "a@b.co"])
    #expect(found.map(\.1) == ["PERSON", "US_SSN", "PERSON", "EMAIL_ADDRESS"])
    #expect(KeyedValues.find(#"She said "name": then left, "email": \"x@y.z\""#).isEmpty)
}

@Test func bareNameInTextWaitsForItsSiblings() {
    func names(_ text: String) -> [String] {
        KeyedValues.find(text).filter { $0.entity == "PERSON" }.map { (text as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
    }
    #expect(names(#"{"name": "Everyday Checking", "mask": "0000"}"#).isEmpty)
    #expect(names(#"{"name": "Priya Raghunathan", "phone": "x"}"#) == ["Priya Raghunathan"])
    #expect(names(#""owners": [{"names": ["Alberta Charleson"]}], "users": [{"name": "Priya Raghunathan"}]"#) == ["Alberta Charleson", "Priya Raghunathan"])
}

// A JavaScript request body: bare keys and single-quoted values.
@Test func objectLiteralsInCodeHintTheirValues() throws {
    let (text, _) = try scrubText("""
    const request: CreateUserRequest = {
      user: {
        name: { given_name: 'Anna', family_name: 'Charleston' },
        id_number: { value: '123456789', type: 'us_ssn' },
      },
    };
    person = {'email': 'acharleston@email.com', "postal_code" => "94103", 'city': 'Pawnee'}
    """)
    for original in ["Anna", "Charleston", "123456789", "acharleston", "94103", "Pawnee"] { #expect(!text.contains(original)) }
    #expect(text.contains("type: 'us_ssn'"))
    #expect(text.range(of: #"value: '\d{9}'"#, options: .regularExpression) != nil)
}

@Test func codeLikeProseIsNotAKey() {
    #expect(KeyedValues.find("It's Anna's: 'Charleston' and Acme::Client name: 'Anna Lee' at https://x.io 'hi'").map(\.entity) == ["PERSON"])
    #expect(KeyedValues.find("don't say name: it's 'Bob Stone'").isEmpty)
}

// A point locates someone, so it moves, to the same precision; codes and acronyms around it stay.
@Test func coordinatesMoveAndAcronymsInPastedCodeStay() throws {
    let (text, _) = try scrubText("""
    {"latitude": 47.2529001, "longitude": -122.4443, "metroCode": 819}
    CLIENT_KEY = "/path/to/client.key"       # client private key (PEM)
    """)
    #expect(!text.contains("47.2529001") && !text.contains("-122.4443"))
    #expect(text.range(of: #""latitude": -?\d{1,2}\.\d{7}, "longitude": -?\d{1,3}\.\d{4}, "metroCode": 819"#, options: .regularExpression) != nil, "\(text)")
    #expect(text.contains("(PEM)"))
}

/// A log line quoting a request whose body is itself a string of JSON: the person inside it,
/// two levels of escapes deep and their surname written with a `\u` escape, is read as one level is.
@Test(arguments: ["service.log", "Pasted text"])
func doublyEscapedBodyInALogLineIsReadInside(_ name: String) throws {
    let log = #"""
    2026-03-02 09:41:07,552 [pool-3] ERROR CheckClient - upstream 422 payload="{\"body\": \"{\\\"applicant\\\": {\\\"givenName\\\": \\\"Annelise\\\", \\\"surname\\\": \\\"Kj\\\\u00e6rgaard\\\", \\\"phone\\\": \\\"+45 55 50 01 42\\\"}}\"}" trace=7c1e0d9a44b24f0f9e3a
    2026-03-02 09:41:07,560 [pool-3] WARN  CheckClient - retry body="{\"body\": \"{\\\"surname\\\": \\\"Kj\\\\u00e6rgaard\\\"}\"}"
    2026-03-02 09:41:07,561 [pool-3] INFO  CheckClient - queued for manual review
    """#
    let result = try Scrubber.scrub(Data(log.utf8), name: name)
    let output = try #require(String(data: result.output, encoding: .utf8))
    for original in ["Annelise", #"Kj\\\\u00e6rgaard"#, "rgaard", "55 50 01 42"] { #expect(!output.contains(original), "\(original) in \(output)") }
    #expect(output.contains("trace=7c1e0d9a44b24f0f9e3a") && output.hasSuffix("INFO  CheckClient - queued for manual review"))
    // Each body still reads as the string of JSON it was, two levels down.
    for line in output.split(separator: "\n").prefix(2) {
        let quoted = try #require(line.range(of: #""\{(?:[^"\\]|\\.)*\}""#, options: .regularExpression))
        let outer = try #require(try JSONSerialization.jsonObject(with: Data(line[quoted].utf8), options: .fragmentsAllowed) as? String)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(outer.utf8)) as? [String: String])["body"]
        #expect(try JSONSerialization.jsonObject(with: Data(try #require(body).utf8)) is [String: Any])
    }
}

/// A German customer's letter: its salutation, its nouns after an article and the request around the
/// applicant's name stay word for word; only the name, the birth date after "geb." and the tax ID go.
@Test func aGermanLetterKeepsItsWordsAndLosesItsPerson() throws {
    let letter = """
    Betreff: Prüfung meines Kontos

    Sehr geehrte Damen und Herren,

    ich habe eine Frage zu meinem Konto. Bitte prüfen Sie den Antrag von Frau Wiebke Austermann, geb. 17.03.1984, wohnhaft in Bielefeld. Meine Steuer-ID ist 47136280512.

    Mit freundlichen Grüßen
    Wiebke Austermann
    """
    let (output, _) = try scrubText(letter)
    for original in ["Wiebke", "Austermann", "17.03.1984", "47136280512"] { #expect(!output.contains(original), "\(original) in \(output)") }
    for kept in ["Betreff: Prüfung meines Kontos\n\nSehr geehrte Damen und Herren,\n\nich habe eine Frage zu meinem Konto. Bitte prüfen Sie den Antrag von Frau ",
                 ", geb. ", ", wohnhaft in ", ". Meine Steuer-ID ist ", "\n\nMit freundlichen Grüßen\n"] {
        #expect(output.contains(kept), "\(kept) not in \(output)")
    }
    // The stand-in takes the name's place and nothing around it: two words after "Frau", as the sign-off writes them.
    let after = try #require(output.components(separatedBy: "Antrag von Frau ").last?.components(separatedBy: ", geb.").first)
    #expect(after.split(separator: " ").count == 2 && output.hasSuffix("\n" + after), "\(output)")
}

/// A double-barrelled surname after a hyphenated given name, and the same person signing with hyphenated
/// initials: no half of the surname and no initial stays, and the surname takes one stand-in in both places.
@Test(arguments: ["Hello, my name is Karl-Heinz Brettschneider-Oldenhove and I can't log in to my account.\nRegards,\nK.-H. Brettschneider-Oldenhove",
                  "mein Name ist Karl-Heinz Brettschneider-Oldenhove, geboren am 3. Juni 1958 in Kassel. Ich komme nicht in mein Konto.\n\nMit freundlichen Grüßen\nK.-H. Brettschneider-Oldenhove"])
func aDoubleBarrelledNameAndItsInitialsGoWhole(_ message: String) throws {
    let (output, _) = try scrubText(message)
    for original in ["Karl", "Heinz", "Brettschneider", "Oldenhove", "K.-H."] { #expect(!output.contains(original), "\(original) in \(output)") }
    let lines = output.split(separator: "\n")
    let signature = try #require(lines.last).split(separator: " ")
    #expect(signature.count == 2 && signature[0].wholeMatch(of: /\p{Lu}\.-\p{Lu}\./) != nil, "\(output)")
    #expect(lines[0].contains(" " + signature[1] + " ") || lines[0].contains(" " + signature[1] + ","), "\(output)")
}

/// A case note naming an applicant in full, then by two initials and the first word of a double surname,
/// and a colleague by an initial: each initialled form is the same person's stand-in, its first initial theirs.
@Test func initialsFollowTheFullNamesStandIn() throws {
    let note = """
    Applicant Tomás Ignacio Arreola Benítez called about the refund; reviewer Anneliese Wohlgemuth took the call.
    Signed: T. I. Arreola. Approved: A. Wohlgemuth.
    """
    for seed: UInt64 in 0..<4 {
    let output = String(decoding: try Scrubber.scrub(Data(note.utf8), name: "notes.txt", forceFullDetection: false, seed: seed).output, as: UTF8.self)
    for original in ["Tomás", "Arreola", "Benítez", "Anneliese", "Wohlgemuth"] { #expect(!output.contains(original), "\(original) in \(output)") }
    let lines = output.split(separator: "\n").map(String.init)
    let applicant = try #require(lines[0].components(separatedBy: "Applicant ").last?.components(separatedBy: " called").first).split(separator: " ")
    let reviewer = try #require(lines[0].components(separatedBy: "reviewer ").last?.components(separatedBy: " took").first).split(separator: " ")
    let signed = try #require(lines[1].components(separatedBy: "Signed: ").last?.components(separatedBy: ". Approved").first).split(separator: " ")
    let approved = try #require(lines[1].components(separatedBy: "Approved: ").last?.dropLast()).split(separator: " ")
    #expect(signed.count == 3 && signed[0] == "\(applicant[0].prefix(1))." && applicant.contains(signed[2]), "\(output)")
    #expect(approved.count == 2 && approved[0] == "\(reviewer[0].prefix(1))." && approved[1] == reviewer.last!, "\(output)")
    }
}

/// An audit log's line keeps every key and path around a person's email: the address after "target=user/"
/// or "subject=customers/" is replaced alone, never with the key's path read into its local part.
@Test(arguments: [UInt64(1), 2, 3])
func anAuditLogKeepsTheKeysAroundAnEmail(_ seed: UInt64) throws {
    let log = """
    2026-03-02T10:14:22Z actor=admin.ops target=user/48213 action=update field=surname old="Halvorsen" new="Brekke"
    2026-03-02T10:14:23Z actor=admin.ops target=user/ingrid.halvorsen@example.no action=view
    2026-03-02T10:14:24Z actor=k.marsh@example.org target=user/ingrid.halvorsen@example.no action=update field=email old="ingrid.halvorsen@example.no" new="ingrid.brekke@example.no"
    2026-03-02T10:14:25Z actor=admin.ops subject=customers/eu/teo.lisboa@example.net action=export
    """
    let result = try Scrubber.scrub(Data(log.utf8), name: "Pasted text", forceFullDetection: false, seed: seed)
    let output = String(decoding: result.output, as: UTF8.self)
    func keys(_ line: Substring) -> [String] { line.matches(of: /([a-z_]+)=/).map { String($0.1) } }
    let before = log.split(separator: "\n"), after = output.split(separator: "\n")
    #expect(before.count == after.count, "\(output)")
    for (original, made) in zip(before, after) { #expect(keys(original) == keys(made), "\(original)\n→ \(made)") }
    #expect(after[1].contains(" target=user/") && after[2].contains(" target=user/") && after[3].contains(" subject=customers/eu/"), "\(output)")
    for original in ["ingrid.halvorsen", "teo.lisboa", "ingrid.brekke"] { #expect(!output.contains(original), "\(original) in \(output)") }
}

/// A log's pair whose key names a person holds one, written "Surname, Given" or "Given Surname", quoted or
/// not; a record's key written as a namespace and a reference ("key=cust:CU-55120") keeps its prefix and
/// shape, the same stand-in wherever it is written, and is never read as a secret.
@Test(arguments: 1...3)
func aLogPairUnderAPersonsKeyHoldsTheirName(_ seed: Int) throws {
    let log = """
    2026-03-14T09:12:44.118Z INFO  [consumer-3] c.e.payments.SettlementListener - processed offset=88123 partition=4 key=cust:CU-55120 subject="Oyelaran, Babatunde" amount=125.40 currency=EUR status=OK
    2026-03-14T09:12:45.002Z WARN  [consumer-3] c.e.payments.SettlementListener - retry customer=Ingrid Halvorsen payer='Marta Kowalczyk' beneficiary=Tomasz Nowicki account_holder="Dlamini, Sipho" cache=cust:CU-55120
    2026-03-14T09:12:46.310Z INFO  [consumer-3] c.e.payments.SettlementListener - committed offset=88124 cust_name="Halvorsen, Ingrid" topic=settlements.v2 subject="Monthly Statement"

    """
    let result = try Scrubber.scrub(Data(log.utf8), name: "consumer.log", forceFullDetection: false, seed: UInt64(seed))
    let output = String(decoding: result.output, as: UTF8.self)
    for original in ["Oyelaran", "Babatunde", "Ingrid", "Halvorsen", "Marta", "Kowalczyk", "Tomasz", "Nowicki", "Dlamini", "Sipho", "55120"] {
        #expect(!output.contains(original), "\(original) in \(output)")
    }
    let lines = output.split(separator: "\n").map(String.init)
    #expect(lines.count == 3 && lines[2].hasSuffix(#"topic=settlements.v2 subject="Monthly Statement""#), "\(output)")
    // "Surname, Given" keeps its order and its comma; the record's key keeps its prefix, the same in both lines.
    let subject = try #require(lines[0].range(of: #"subject="[^"]+""#, options: .regularExpression)).lowerBound
    #expect(lines[0][subject...].range(of: #"^subject="\p{Lu}[\p{L}'-]+, \p{Lu}[\p{L}'-]+" amount=125\.40"#, options: .regularExpression) != nil, "\(output)")
    let key = try #require(lines[0].range(of: #"key=cust:CU-\d{5} "#, options: .regularExpression))
    #expect(lines[1].hasSuffix("cache=" + lines[0][key].dropFirst(4).dropLast()), "\(output)")
    #expect(!result.findings.contains { $0.entity == "SECRET" }, "\(result.findings.map { "\($0.entity) \($0.original)" })")
    #expect(result.unresolved.isEmpty, "\(result.unresolved.map { "\($0.entity) \($0.original ?? "")" })")
}

/// A company's name ending in a legal form ("Cía. Ltda.", "S.A.C.", "e Hijos", "& Co.") is no person's, and the
/// place right after its form is its seat, kept with it ("d.o.o. Beograd"); the people beside them are replaced.
@Test(arguments: 1...3)
func aCompanysFormAndSeatStayAsWritten(_ seed: Int) throws {
    let text = """
    Factura emitida por Example Envíos Cía. Ltda. a nombre de Laura Méndez.
    Proveedor: Transportes Andinos S.A.C., contacto Pedro Quispe.
    Distribuidor: Example Ferretería e Hijos, sucursal norte.
    Isporučilac: Primer Trgovina d.o.o. Beograd, kontakt Marko Petrović.
    Supplier: Northwind Foods & Co., contact Grace Holt.

    """
    let result = try Scrubber.scrub(Data(text.utf8), name: "Pasted text", forceFullDetection: false, seed: UInt64(seed))
    let output = String(decoding: result.output, as: UTF8.self)
    for kept in ["Example Envíos Cía. Ltda.", "Transportes Andinos S.A.C.", "Example Ferretería e Hijos", "Primer Trgovina d.o.o. Beograd,", "Northwind Foods & Co."] {
        #expect(output.contains(kept), "\(kept) in \(output)")
    }
    for original in ["Laura", "Méndez", "Pedro", "Quispe", "Marko", "Petrović", "Grace", "Holt"] { #expect(!output.contains(original), "\(original) in \(output)") }
    #expect(!result.findings.contains { $0.original.contains("Envíos") || $0.original == "Beograd" }, "\(result.findings.map { "\($0.entity) \($0.original)" })")
    #expect(!(result.unresolved.contains { ($0.original ?? "").contains("Envíos") }))
}

/// An address ends before a phone's label in any language and before a clause a joining word opens: the label,
/// the clause and the phone's country code stay as written, and the relative the clause names is replaced.
@Test(arguments: 1...3)
func anAddressEndsBeforeALabelOrAClause(_ seed: Int) throws {
    let text = """
    Vivo en Calle Mayor 12, 3º B, 28013 Madrid con mi hija Lucía desde 2019.
    Adresas: Gedimino pr. 9-12, LT-01103 Vilnius Telefonas +370 612 34567
    Adrese: Brīvības iela 118-7, Rīga Tālrunis +371 2955 0123

    """
    let result = try Scrubber.scrub(Data(text.utf8), name: "Pasted text", forceFullDetection: false, seed: UInt64(seed))
    let output = String(decoding: result.output, as: UTF8.self)
    let lines = output.split(separator: "\n").map(String.init)
    #expect(lines.count == 3, "\(output)")
    #expect(lines[0].range(of: #" con mi hija \p{Lu}\p{Ll}+ desde 2019\.$"#, options: .regularExpression) != nil, "\(output)")
    #expect(lines[1].range(of: #" Telefonas \+370 \d{3} \d{5}$"#, options: .regularExpression) != nil, "\(output)")
    #expect(lines[2].range(of: #" Tālrunis \+371 \d{4} \d{4}$"#, options: .regularExpression) != nil, "\(output)")
    for original in ["Mayor 12", "28013", "Lucía", "Gedimino", "01103", "612 34567", "Brīvības", "2955 0123"] { #expect(!output.contains(original), "\(original) in \(output)") }
    #expect(!result.findings.contains { $0.entity == "ADDRESS" && ($0.original.hasSuffix(" con mi hija Lucía") || $0.original.hasSuffix("Telefonas") || $0.original.hasSuffix("Tālrunis")) },
            "\(result.findings.map { "\($0.entity) \($0.original)" })")
}

/// The word between a name and a parent's or husband's ("s/o", "binti", "bin", "a/l", "bt.") stays as written,
/// and both names around it are replaced.
@Test(arguments: 1...3)
func aLineageWordStaysBetweenTwoNames(_ seed: Int) throws {
    let text = "Father's name: Ahmed s/o Rashid. Guardian: Siti binti Abdullah. Next of kin: Ali bin Hassan, Kumar a/l Rajan and Nurul bt. Aziz.\n"
    let result = try Scrubber.scrub(Data(text.utf8), name: "Pasted text", forceFullDetection: false, seed: UInt64(seed))
    let output = String(decoding: result.output, as: UTF8.self)
    let name = #"\p{Lu}[\p{L}'-]+"#
    let shape = "^Father's name: \(name) s/o \(name)\\. Guardian: \(name) binti \(name)\\. Next of kin: \(name) bin \(name), \(name) a/l \(name) and \(name) bt\\. \(name)\\.$"
    #expect(output.trimmingCharacters(in: .newlines).range(of: shape, options: .regularExpression) != nil, "\(output)")
    for original in ["Ahmed", "Rashid", "Siti", "Abdullah", "Ali ", "Hassan", "Kumar", "Rajan", "Nurul", "Aziz"] { #expect(!output.contains(original), "\(original) in \(output)") }
}

/// A log's pair under a person's key holds one whole name, a surname's particles too ("de", "van der", "da"):
/// quoted or not, written "Surname, Given" or "Given Surname", no word of it stays beside a stand-in.
@Test(arguments: 1...3)
func aLogPairsNameIsReplacedWholeWithItsParticles(_ seed: Int) throws {
    let log = """
    2026-05-02T08:01:12.410Z INFO  [payout-2] c.e.payouts.Dispatcher - sent beneficiary="Hendrik de Boer" amount=10.00 currency=EUR status=OK
    2026-05-02T08:01:13.022Z INFO  [payout-2] c.e.payouts.Dispatcher - sent payer=Joost van der Linde amount=12.00 holder="de Vries, Annelies" status=OK
    2026-05-02T08:01:14.530Z WARN  [payout-2] c.e.payouts.Dispatcher - retry customer='Aurelio di Stefano' account_holder="Ferreira da Costa, Mariana" status=RETRY
    2026-05-02T08:01:15.004Z INFO  [payout-2] c.e.payouts.Dispatcher - sent beneficiary=Liesbeth von Arnim amount=3.50 status=OK

    """
    let result = try Scrubber.scrub(Data(log.utf8), name: "payouts.log", forceFullDetection: false, seed: UInt64(seed))
    let output = String(decoding: result.output, as: UTF8.self)
    for original in ["Hendrik", "Boer", "Joost", "Linde", "Vries", "Annelies", "Aurelio", "Stefano", "Ferreira", "Costa", "Mariana", "Liesbeth", "Arnim"] {
        #expect(!output.contains(original), "\(original) in \(output)")
    }
    let lines = output.split(separator: "\n").map(String.init)
    #expect(lines.count == 4, "\(output)")
    for (line, tail) in zip(lines, [" amount=10.00 currency=EUR status=OK", " amount=12.00 holder=", " account_holder=", " amount=3.50 status=OK"]) {
        #expect(line.contains(tail), "\(tail): \(output)")
    }
    // "Surname, Given" keeps its comma and order.
    #expect(lines[1].range(of: #"holder="[^",]+, [^",]+" status=OK$"#, options: .regularExpression) != nil, "\(output)")
    #expect(lines[2].range(of: #"account_holder="[^",]+, [^",]+" status=RETRY$"#, options: .regularExpression) != nil, "\(output)")
}

/// Where a log's pair under a person's key had a part of its name replaced, no word of it stays beside the stand-in,
/// even one no reader took for a name ("Lopes" of holder="Ana Paula ao Lopes"); the pair's joining words stay.
@Test(arguments: 1...3)
func noPartOfAPersonStaysInsideALogPairsReplacedName(_ seed: Int) throws {
    let log = """
    2026-05-02T08:01:13.120Z INFO  [payout-2] c.e.payouts.Dispatcher - queued payer="Ana Paula" amount=4.20 status=PENDING
    2026-05-02T08:01:14.530Z INFO  [payout-2] c.e.payouts.Dispatcher - sent holder="Ana Paula ao Lopes" amount=4.20 status=OK
    2026-05-02T08:01:15.004Z INFO  [payout-2] c.e.payouts.Dispatcher - sent amount=4.20 status=OK note="settled"

    """
    let result = try Scrubber.scrub(Data(log.utf8), name: "payouts.log", forceFullDetection: false, seed: UInt64(seed))
    let output = String(decoding: result.output, as: UTF8.self)
    for original in ["Ana", "Paula", "Lopes"] { #expect(!output.contains(original), "\(original) in \(output)") }
    #expect(output.contains(" ao ") && output.contains(#"" amount=4.20 status=OK"#) && output.contains(#"note="settled""#), "\(output)")
}
