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
