import Foundation
@testable import ScrubCore
import Testing

// Each national identifier is known by its check, not by the key it sits
// under: a value passing it is found, the same value with one character
// changed is not, and its stand-in passes the same check.

private let samples: [String: String] = [
    "CPF": "111.444.777-35",
    "CUIL": "20-12345678-6",
    "RUT": "12.345.678-5",
    "CURP": "GAXR850314HJCLNS07",
    "RFC": "GAXR850314K73",
    "CODICE_FISCALE": "RSSMRA85T10A562S",
    "DNI": "12345678Z",
    "NIE": "X1234567L",
    "NIR": "1 85 05 78 006 084 91",
    "BELGIAN_NATIONAL_NUMBER": "85.07.30-033.28",
    "BSN": "111222333",
    "STEUER_ID": "86095742719",
    "PESEL": "44051401359",
    "PERSONNUMMER": "811228-9874",
    "FODSELSNUMMER": "01010750160",
    "CPR": "010190-1234",
    "HETU": "131052-308T",
    "NINO": "AB123456C",
    "NHS_NUMBER": "943 476 5919",
    "SIN": "130 692 411",
    "AADHAAR": "2345 6789 0124",
    "PAN": "ABCPD1234E",
    "RESIDENT_ID": "11010519491231002X",
    "RRN": "900101-1234567",
    "SOUTH_AFRICAN_ID": "8001015009087",
    "TCKN": "10000000146",
    "NRIC": "S1234567D",
    "HKID": "A123456(3)",
    "TAIWAN_ID": "A123456789",
    "MY_NUMBER": "123456789018",
    "DOWOD": "ABA300000",
    "UK_DRIVING_LICENCE": "MORGA753116SM9IJ",
    "DE_DOCUMENT": "L01X00T471",
    "KVNR": "A123456780",
    "RVNR": "65170839J003",
    "NPI": "1234567893",
    "DEA": "AB1234563",
    "MBI": "1EG4-TE5-MK73",
    "TFN": "123 456 782",
    "AU_MEDICARE": "2123 45670 1",
    "EPIC": "ABC1234567",
    "THAI_ID": "1-1017-00203-55-7",
    "NIN": "12345678902",
    "TEUDAT_ZEHUT": "123456782",
    "PIS": "120.12345.67-2",
    "CLAVE_ELECTOR": "GMVLMR80070501M100",
    "AR_DNI": "12.345.678",
    "PASSPORT": "AB1234567",
    "BITCOIN": "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
    "ETHEREUM": "0x52908400098527886E0F7030069857D2E4169EE7",
    "MAC_ADDRESS": "00:1A:2B:3C:4D:5E",
]
/// Kinds whose only check is their shape: one digit changed is still one of them.
private let shapeOnly: Set<String> = ["CPR", "NINO", "PAN", "RRN", "EPIC", "MBI", "AR_DNI", "PASSPORT", "ETHEREUM", "CLAVE_ELECTOR", "UK_DRIVING_LICENCE", "MAC_ADDRESS"]
// Shape-only kinds are drawn as any ID of their shape; a document number of a known shape keeps it.
@Test func shapeOnlyKindsKeepTheirShape() throws {
    try check(#"{"national_id":"ZX4829137","passport":{"number":"Y83368442"}}"#, gone: ["ZX4829137", "Y83368442"]) { route, root, output in
        #expect(output.range(of: #""national_id":"[A-Z]{2}\d{7}""#, options: .regularExpression) != nil && output.range(of: #""number":"[A-Z]\d{8}""#, options: .regularExpression) != nil, "\(route): \(output)")
    }
}

private func recognizer(_ name: String) -> Recognizer? { Recognizers.all.first { $0.name == name } }

@Test func everyRecognizerHasASample() {
    #expect(Set(samples.keys) == Set(Recognizers.all.map(\.name)))
}

@Test func checksKnowTheirIdentifiers() throws {
    for (name, sample) in samples {
        let recognizer = try #require(recognizer(name))
        #expect(recognizer.passes(sample), "\(name): \(sample)")
        // One character moved by one fails every check that has one.
        guard !shapeOnly.contains(name) else { continue }
        // A Medicare card's last digit is the card's issue, not its check.
        let index = try #require(name == "AU_MEDICARE" ? sample.firstIndex { $0.isNumber } : sample.lastIndex { $0.isNumber })
        let digit = try #require(sample[index].wholeNumberValue)
        var changed = sample
        changed.replaceSubrange(index...index, with: String((digit + 1) % 10))
        #expect(!recognizer.passes(changed), "\(name): \(changed)")
    }
}

@Test func drawnIdentifiersPassTheirChecksAndForms() {
    var rng: any RandomNumberGenerator = SeededGenerator(seed: 11)
    for recognizer in Recognizers.all {
        let like = recognizer.kept(samples[recognizer.name] ?? "")
        for _ in 0..<40 {
            let canonical = recognizer.draw(like, &rng)
            #expect(recognizer.check(canonical), "\(recognizer.name): \(String(canonical))")
            // Written in its sample's layout, separators and all.
            var next = canonical.makeIterator()
            let drawn = String((samples[recognizer.name] ?? "").map { recognizer.separators.contains($0) ? $0 : next.next() ?? $0 })
            let written = recognizer.forms.contains { form in
                TextRanges.matches(form.pattern, in: drawn).contains { $0.range.location == 0 && $0.range.length == (drawn as NSString).length }
            }
            #expect(written, "\(recognizer.name) draws a value none of its forms writes: \(drawn)")
        }
    }
}

@Test func standInsKeepTheLayoutAndPassTheCheck() throws {
    var rng: any RandomNumberGenerator = SeededGenerator(seed: 3)
    for (name, sample) in samples where recognizer(name)?.verifies == true {
        guard let made = Recognizers.standIn(for: sample, using: &rng) else { Issue.record("\(name): no stand-in"); continue }
        #expect(made != sample && Recognizers.recognizing(made) != nil, "\(name): \(sample) → \(made)")
        #expect(made.map { $0.isLetter || $0.isNumber } == sample.map { $0.isLetter || $0.isNumber }, "\(name): \(sample) → \(made)")
    }
    // Written in small letters, it stays so.
    guard let lower = Recognizers.standIn(for: "rssmra85t10a562s", using: &rng) else { Issue.record("no stand-in"); return }
    #expect(lower == lower.lowercased() && Recognizers.recognizing(lower) != nil, "\(lower)")
}

@Test func bareDigitsNeedAWordNamingThem() {
    func found(_ text: String, key: String? = nil) -> Bool {
        Patterns.find(text, contextWords: Set(KeyHints.words(key)), isCancelled: { false }).contains { $0.entity == "ID_NUMBER" }
    }
    // A form chance seldom writes is enough alone.
    #expect(found("Reference 111.444.777-35 was checked."))
    #expect(found("holder RSSMRA85T10A562S"))
    // Bare digits passing a check are no identifier without a word naming them...
    #expect(!found("Order 11144477735 shipped."))
    #expect(!found("Order 44051401359 shipped."))
    // ...one before them, in any language, or in their key.
    #expect(found("CPF 11144477735"))
    #expect(found("Numer PESEL: 44051401359"))
    #expect(found("Fødselsnummer 01010750160"))
    #expect(found("44051401359", key: "pesel"))
    // One failing its check is none, whatever names it.
    #expect(!found("CPF 111.444.777-36"))
}

@Test func identifiersAreFoundUnderAnyKey() throws {
    let body = #"{"holder":{"ref":"111.444.777-35","code":"RSSMRA85T10A562S","tax":"12345678Z","resident":"11010519491231002X"},"status":"ACTIVE"}"#
    try check(body, gone: ["111.444.777-35", "RSSMRA85T10A562S", "12345678Z", "11010519491231002X"])
    let output = try Route.file.scrub(body)
    let root = try OrderedJSON.parse(output)
    guard case .object(let top) = root, case .object(let holder)? = top.first?.1 else { Issue.record("\(output)"); return }
    for (key, value) in holder {
        guard case .string(let text) = value else { continue }
        #expect(Recognizers.recognizing(text) != nil, "\(key): \(text) fails its check")
    }
}

@Test func segwitAddressesCheckBothWays() {
    // BIP 173's and BIP 350's own examples, a version 0 and a version 1 address.
    #expect(Recognizers.recognizing("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")?.name == "BITCOIN")
    #expect(Recognizers.recognizing("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4")?.name == "BITCOIN")
    #expect(Recognizers.recognizing("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0")?.name == "BITCOIN")
    #expect(Recognizers.recognizing("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5") == nil)
    var rng: any RandomNumberGenerator = SeededGenerator(seed: 5)
    for sample in ["bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"] {
        let made = Recognizers.standIn(for: sample, using: &rng)
        #expect(made.map { $0 != sample && $0.count == sample.count && Recognizers.recognizing($0) != nil } == true, "\(sample) → \(made ?? "none")")
    }
}

@Test func ibanLengthsHoldRegistryExamples() {
    for iban in ["DE89370400440532013000", "GB82WEST12345698765432", "FR1420041010050500013M02606", "ES9121000418450200051332", "IT60X0542811101000000123456",
                 "NL91ABNA0417164300", "BE68539007547034", "CH9300762011623852957", "AT611904300234573201", "PT50000201231234567890154", "NO9386011117947",
                 "PL61109010140000071219812874", "SE4550000000058398257466", "DK5000400440116243", "FI2112345600000785", "IE29AIBK93115212345678",
                 "LU280019400644750000", "BR1800360305000010009795493C1", "SA0380000000608010167519", "AE070331234567890123456", "TR330006100519786457841326",
                 "QA58DOHB00001234567890ABCDEFG", "MT84MALT011000012345MTLCAST001S"] {
        #expect(Patterns.iban(iban), "\(iban)")
    }
    // The right remainder at the wrong length for its country is no IBAN.
    #expect(!Patterns.iban("DE8937040044053201300"))
}

@Test func typedRecordsAndKeysNameTheirIdentifiers() throws {
    let body = #"{"documents":[{"type":"TCKN","number":"10000000146"},{"type":"PESEL","value":"44051401359"}],"tckn":"10000000146","nhs_number":"9434765919","owner":{"tfn":"123456782"}}"#
    try check(body, gone: ["10000000146", "44051401359", "9434765919", "123456782"])
    #expect(KeyHints.hint("tckn") == "ID_NUMBER" && KeyHints.hint("btc_address") == "CRYPTO" && KeyHints.hint("epic") == nil)
}

@Test func walletsAndDevicesAreReplacedInPlace() throws {
    let body = #"{"payout":{"wallet":"1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2","network":"BTC"},"device":{"mac":"00:1A:2B:3C:4D:5E","os":"14.2"}}"#
    try check(body, gone: ["1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", "00:1A:2B:3C:4D:5E"])
}

@Test func aFieldOfCheckedValuesIsThatIdentifier() throws {
    // Bare digits under a key naming nothing: each alone could be any number, but all four pass one check.
    let body = #"{"rows":[{"ref":"11144477735","status":"OK"},{"ref":"52998224725","status":"OK"},{"ref":"39053344705","status":"OK"},{"ref":"86288366757","status":"OK"}]}"#
    try check(body, gone: ["11144477735", "52998224725", "39053344705", "86288366757"]) { route, root, output in
        #expect(output.contains(#""status":"OK""#), "\(route): \(output)")
    }
    // Values passing no check give the field no kind.
    let leaves = ["11144477736", "52998224726", "39053344706", "86288366758"].map { value -> DocumentLeaf in
        var leaf = DocumentLeaf(value)
        leaf.field = "rows.ref"
        return leaf
    }
    var founds: [[Span]] = Array(repeating: [], count: leaves.count)
    Fields.decide(leaves, &founds)
    #expect(founds.allSatisfy { $0.isEmpty }, "\(founds)")
}
