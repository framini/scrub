import Foundation
@testable import ScrubCore
import Testing

// Each national identifier is known by its check, not by the key it sits
// under: a value passing it is found, the same value with one character
// changed is not, and its stand-in passes the same check.

let recognizerSamples: [String: String] = [
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
    // Ported kinds: specimens and synthetic values with computed checks.
    "DE_BSNR": "721234567",
    "DE_LANR": "123456601",
    "DE_DRIVING_LICENCE": "B0721234581",
    "DE_HANDELSREGISTER": "HRB 123456",
    "DE_LICENCE_PLATE": "M AB 1234",
    "DE_PLZ": "10115",
    "STEUERNUMMER": "181/815/08155",
    "DE_VAT_ID": "DE123456788",
    "ORGANISATIONSNUMMER": "552234-5676",
    "ES_PASSPORT": "PAA123456",
    "GSTIN": "27ABCPK1234F1Z5",
    "IN_VEHICLE_REGISTRATION": "MH 12 AB 1234",
    "IT_DRIVER_LICENSE": "U1B2C3456X",
    "IT_IDENTITY_CARD": "CA00000AA",
    "PARTITA_IVA": "12345670017",
    "KR_BRN": "123-45-67891",
    "KR_DRIVER_LICENSE": "11-90-123456-01",
    "KR_PASSPORT": "M123A4567",
    "ZA_COMPANY_REGISTRATION": "2015/123456/07",
    "ZA_DRIVER_LICENSE": "4021000123AB",
    "ZA_INCOME_TAX_NUMBER": "0123456782",
    "ZA_LICENSE_PLATE": "BC 12 DF GP",
    "ZA_PHONE_NUMBER": "+27 82 012 3456",
    "ZA_TRAFFIC_REGISTER_NUMBER": "1234567890123",
    "ZA_VAT_NUMBER": "4123456789",
    "NG_VEHICLE_REGISTRATION": "ABC-123DE",
    "TR_LICENSE_PLATE": "34-AB-1234",
    "PH_TIN": "123-456-782",
    "PH_UMID": "1234-5678901-2",
    "SG_UEN": "201912345R",
    "ABN": "18 123 456 789",
    "ACN": "123 456 780",
    "ABA_ROUTING": "012345672",
    "CA_POSTAL_CODE": "H0H 0H0",
    "UK_POSTCODE": "AB12 3DE",
    "UK_VEHICLE_REGISTRATION": "AB51 ABC",
    "PRIOR_AUTHORIZATION": "PA-123456789",
    "CLAIM_NUMBER": "CLM-1234567890",
    "PRESCRIPTION_NUMBER": "RX-1234567",
    "REFERRAL_NUMBER": "REF-1234567",
    "EIN": "12-3456789",
    "US_HEALTH_MEMBER_ID": "XYZ123456789",
]
// Shape-only kinds are drawn as any ID of their shape; a document number of a known shape keeps it.
@Test func shapeOnlyKindsKeepTheirShape() throws {
    try check(#"{"national_id":"ZX4829137","passport":{"number":"Y83368442"}}"#, gone: ["ZX4829137", "Y83368442"]) { route, root, output in
        #expect(output.range(of: #""national_id":"[A-Z]{2}\d{7}""#, options: .regularExpression) != nil && output.range(of: #""number":"[A-Z]\d{8}""#, options: .regularExpression) != nil, "\(route): \(output)")
    }
}

private func recognizer(_ name: String) -> Recognizer? { Recognizers.all.first { $0.name == name } }

@Test func everyRecognizerHasASample() {
    #expect(Set(recognizerSamples.keys) == Set(Recognizers.all.map(\.name)))
}

@Test func checksKnowTheirIdentifiers() throws {
    for (name, sample) in recognizerSamples {
        let recognizer = try #require(recognizer(name))
        #expect(recognizer.passes(sample), "\(name): \(sample)")
        // One character moved by one fails every check that has one.
        guard recognizer.verifies else { continue }
        // A Medicare card's or a German licence's last character is its issue, a doctor's number's its specialty, not its check.
        let index = try #require(["AU_MEDICARE", "DE_LANR", "DE_DRIVING_LICENCE"].contains(name) ? sample.firstIndex { $0.isNumber } : sample.lastIndex { $0.isNumber })
        let digit = try #require(sample[index].wholeNumberValue)
        var changed = sample
        changed.replaceSubrange(index...index, with: String((digit + 1) % 10))
        #expect(!recognizer.passes(changed), "\(name): \(changed)")
    }
}

@Test func drawnIdentifiersPassTheirChecksAndForms() {
    var rng: any RandomNumberGenerator = SeededGenerator(seed: 11)
    for recognizer in Recognizers.all {
        let like = recognizer.kept(recognizerSamples[recognizer.name] ?? "")
        for _ in 0..<40 {
            let canonical = recognizer.draw(like, &rng)
            #expect(recognizer.check(canonical), "\(recognizer.name): \(String(canonical))")
            // Written in its sample's layout, separators and all.
            var next = canonical.makeIterator()
            let drawn = String((recognizerSamples[recognizer.name] ?? "").map { recognizer.separators.contains($0) ? $0 : next.next() ?? $0 })
            let written = recognizer.forms.contains { form in
                TextRanges.matches(form.pattern, in: drawn).contains { $0.range.location == 0 && $0.range.length == (drawn as NSString).length }
            }
            #expect(written, "\(recognizer.name) draws a value none of its forms writes: \(drawn)")
        }
    }
}

@Test func standInsKeepTheLayoutAndPassTheCheck() throws {
    var rng: any RandomNumberGenerator = SeededGenerator(seed: 3)
    for (name, sample) in recognizerSamples where recognizer(name)?.verifies == true {
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

/// The value at `path` in a parsed document: a key in an object, an index in a list.
private func value(_ root: JSONValue, _ path: String...) -> JSONValue? {
    var node = root
    for step in path {
        switch node {
        case .object(let pairs): guard let next = pairs.first(where: { $0.0 == step })?.1 else { return nil }; node = next
        case .array(let members): guard let index = Int(step), members.indices.contains(index) else { return nil }; node = members[index]
        default: return nil
        }
    }
    return node
}

@Test func aColumnOfNumbersIsReadAsStringsAre() throws {
    let body = #"{"rows":[{"ref":11144477735},{"ref":52998224725},{"ref":39053344705},{"ref":86288366757}]}"#
    try check(body, gone: ["11144477735", "52998224725", "39053344705", "86288366757"]) { route, root, output in
        for index in 0..<4 {
            guard case .number(let made)? = value(root, "rows", String(index), "ref") else { Issue.record("\(route): not a number: \(output)"); continue }
            #expect(Recognizers.recognizing(made)?.name == "CPF", "\(route): \(made)")
        }
    }
}

@Test func oneReferenceRepeatedIsOneChance() throws {
    // "123456782" passes a nine-digit check by chance; four line items writing it are one value, not four.
    let body = #"{"items":[{"order_id":"123456782","sku":"A1"},{"order_id":"123456782","sku":"B2"},{"order_id":"123456782","sku":"C3"},{"order_id":"123456782","sku":"D4"}]}"#
    for route in Route.allCases {
        let output = try route.scrub(body)
        #expect(output.components(separatedBy: "123456782").count == 5, "\(route): \(output)")
    }
}

@Test func hashesAreNoWallets() throws {
    let hashes = ["0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed", "0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359", "0xdbf03b407c01e7cd3cbea99509d93f8dddc8c6fb", "0xd1220a0cf47c7b9be7a2e6ba89f429762e7b9adb"]
    let body = #"{"blocks":["# + hashes.map { #"{"parent_hash":"\#($0)"}"# }.joined(separator: ",") + "]}"
    for route in Route.allCases {
        let output = try route.scrub(body)
        for hash in hashes { #expect(output.contains(hash), "\(route): \(output)") }
    }
}

@Test func namingWordsReachOnlyASlot() throws {
    // A batch number under "medicare" is the batch's; a work item typed "EPIC" is no voter card.
    let body = #"{"medicare":{"batch_id":2123456701,"number":"2123456701"},"ticket":{"type":"EPIC","code":"ABC1234567"}}"#
    for route in Route.allCases {
        let output = try route.scrub(body)
        #expect(output.contains(#""batch_id":2123456701"#) && output.contains("ABC1234567"), "\(route): \(output)")
        #expect(output.components(separatedBy: "2123456701").count == 2, "\(route): the card's number stayed: \(output)")
    }
}

@Test func checksFollowTheirRegisters() throws {
    // Issued from 2022; the turn of the century's leap day; a birthplace code led by a zero.
    func kinds(_ value: String) -> Set<String> { Set(Recognizers.candidates(value).map(\.name)) }
    #expect(kinds("M1234567K").contains("NRIC") && !kinds("M1234567L").contains("NRIC"))
    #expect(kinds("290200-4001").contains("CPR") && !kinds("290201-4001").contains("CPR"))
    #expect(kinds("RSSMRA85T10A001V").contains("CODICE_FISCALE"))
    let body = #"{"people":[{"type":"FIN","number":"M1234567K"},{"type":"CPR","number":"2902004001"}],"note":"codice RSSMRA85T10A001V"}"#
    try check(body, gone: ["M1234567K", "2902004001", "RSSMRA85T10A001V"])
}

@Test func anIdentifiersStandInSurvivesEveryLaterStep() throws {
    // Written as a string first and a number after, and beside its own last four digits.
    for seed in UInt64(1)...24 {
        for route in Route.allCases {
            let output = try route.scrub(#"{"a":{"cpf":"529.982.247-25"},"b":{"cpf":52998224725},"last4":4725}"#, seed: seed)
            guard let root = try? OrderedJSON.parse(String(output[output.firstIndex(of: "{")!...output.lastIndex(of: "}")!])),
                  case .string(let written)? = value(root, "a", "cpf"), case .number(let number)? = value(root, "b", "cpf") else { Issue.record("\(route) \(seed): \(output)"); continue }
            #expect(Recognizers.recognizing(written)?.name == "CPF" && Recognizers.recognizing(number)?.name == "CPF", "\(route) \(seed): \(output)")
            #expect(written.filter(\.isNumber) == number, "\(route) \(seed): \(output)")
        }
    }
}

@Test func aFieldIsVotedOnEveryValueItWrites() throws {
    // Strings and numbers in one field are one column; a nested body's field is the same field.
    let mixed = #"{"rows":[{"ref":11144477735},{"ref":"52998224725"},{"ref":39053344705},{"ref":"86288366757"}]}"#
    try check(mixed, gone: ["11144477735", "52998224725", "39053344705", "86288366757"])
    // Small amounts beside four large ones are values of the field too: no nine in ten pass.
    let amounts = #"{"amounts":[11144477735,52998224725,39053344705,86288366757,1,2,3,4,5,6,7,8,9,10]}"#
    for route in Route.allCases {
        let output = try route.scrub(amounts)
        #expect(output.contains("11144477735") && output.contains("86288366757"), "\(route): \(output)")
    }
}

@Test func repeatsLendAColumnNoWeight() throws {
    // Four references pass a check by chance and four don't; one passing written again and again is still one.
    // Nine digits, so nothing reads them as phone numbers: only the column could make them identifiers.
    let passing = ["731205069", "509514056", "743234884", "647392221"], failing = ["553454709", "410773681", "725264298", "814191760"]
    let refs = passing + failing + Array(repeating: passing[0], count: 36)
    let body = #"{"orders":["# + refs.map { #"{"order_id":"\#($0)"}"# }.joined(separator: ",") + "]}"
    for route in Route.allCases {
        let output = try route.scrub(body)
        for ref in passing + failing { #expect(output.contains(ref), "\(route): \(ref) changed") }
    }
    // Without the failing ones, the four passing are a column of that identifier: the vote reaches this field.
    let column = #"{"orders":["# + passing.map { #"{"order_id":"\#($0)"}"# }.joined(separator: ",") + "]}"
    try check(column, gone: passing)
}

@Test func aRecordsKindReachesWhatItsSlotsWrap() throws {
    let body = #"{"a":{"type":"CPR","number":[2902004001]},"b":{"type":"CPR","number":{"value":"3112994001"}},"c":{"documents":[{"type":"CPF","number":"529.982.247-25"}]}}"#
    try check(body, gone: ["2902004001", "3112994001", "529.982.247-25"])
    // A slot's key names nothing; the nearest key that does is the value's: the batch's, not the card's.
    let batch = #"{"medicare":{"batch":{"number":2123456701}}}"#
    for route in Route.allCases {
        let output = try route.scrub(batch)
        #expect(output.contains("2123456701"), "\(route): \(output)")
    }
}

@Test func italianCodesForTheTwentyNinth() throws {
    for code in ["RSSMRA85T29A562N", "RSSMRA85T69A562R"] {
        #expect(Recognizers.candidates(code).contains { $0.name == "CODICE_FISCALE" }, "\(code)")
    }
    try check(#"{"note":"codice fiscale RSSMRA85T29A562N, RSSMRA85T69A562R"}"#, gone: ["RSSMRA85T29A562N", "RSSMRA85T69A562R"])
}

@Test func identifiersSharingDigitsEachKeepTheirCheck() throws {
    for seed in UInt64(1)...12 {
        for body in [#"{"a":{"nric":"S1234567D"},"b":{"nric":"T1234567J"}}"#, #"{"a":{"nric":"T1234567J"},"b":{"nric":"S1234567D"}}"#] {
            for route in Route.allCases {
                let output = try route.scrub(body, seed: seed)
                guard let root = try? OrderedJSON.parse(String(output[output.firstIndex(of: "{")!...output.lastIndex(of: "}")!])) else { Issue.record("\(route): \(output)"); continue }
                for side in ["a", "b"] {
                    guard case .string(let made)? = value(root, side, "nric") else { Issue.record("\(route): \(output)"); continue }
                    #expect(Recognizers.candidates(made).contains { $0.name == "NRIC" }, "\(route) \(seed): \(output)")
                }
            }
        }
    }
}

@Test func aDecidedFieldReachesItsFewStrings() throws {
    // Two strings and two numbers: the field is decided across all four, and both strings follow it.
    let values = ["731205069", "509514056", "743234884", "647392221"]
    try check(#"{"orders":[{"order_id":"731205069"},{"order_id":509514056},{"order_id":"743234884"},{"order_id":647392221}]}"#, gone: values)
    try check(#"{"orders":[{"order_id":731205069},{"order_id":509514056},{"order_id":"743234884"},{"order_id":647392221}]}"#, gone: values)
}

@Test func aRecordsKindReachesAnEncodedSlot() throws {
    let encoded = Data(#"{"value":2902004001}"#.utf8).base64EncodedString()
    try check(#"{"a":{"type":"CPR","number":"[2902004001]"},"b":{"type":"CPR","number":"{\"value\":3112994001}"},"c":{"type":"CPR","number":"\#(encoded)"}}"#,
              gone: ["2902004001", "3112994001"])
}

@Test func aNameWrittenInsideAWordStillNamesIt() throws {
    // "nhs" before "no", "pesel" closing a compound, as written in keys and German prose.
    try check(#"{"patient_nhsno":"9434765919","kundenpesel":"44051401359","note":"Kunden-Steuernummer 17 543 186 927"}"#, gone: ["9434765919", "44051401359", "17 543 186 927"])
    // A short name only before a word for "number": "cprs" names nothing.
    #expect(Recognizers.mentions("cprnummer", "cpr") && !Recognizers.mentions("cprs", "cpr") && !Recognizers.mentions("unlicensed", "license"))
}

@Test func registersReadAsTheirAuthoritiesWriteThem() throws {
    func kinds(_ value: String) -> Set<String> { Set(Recognizers.candidates(value).map(\.name)) }
    // A refugee's South African number, and one born on 29 February 2000.
    #expect(kinds("8001015000284").contains("SOUTH_AFRICAN_ID") && kinds("0002295000083").contains("SOUTH_AFRICAN_ID"))
    var rng: any RandomNumberGenerator = SeededGenerator(seed: 9)
    // A foreigner's Korean number stays a foreigner's, a Finnish code of this century keeps its letter, a Z NIE its Z.
    for _ in 0..<8 {
        let korean = try #require(Recognizers.standIn(for: "900319-5123456", using: &rng))
        #expect("5678".contains(Array(korean)[7]), "\(korean)")
        let finnish = try #require(Recognizers.standIn(for: "010120A123K", using: &rng))
        #expect(Array(finnish)[6] == "A", "\(finnish)")
        let spanish = try #require(Recognizers.standIn(for: "Z1234567R", using: &rng))
        #expect(spanish.first == "Z", "\(spanish)")
    }
}

@Test func portedKindsAreFoundWhereTheyAreWritten() throws {
    // A postcode alone in prose, a plate its word names, a GST number's own structure, a routing number under its key.
    try check(#"{"note":"Mailing code K1A 0B1 for the Ottawa office","car":"registration AB51 ABC","supplier":"Supplier 27ABCPK1234F1Z5 invoiced"}"#,
              gone: ["K1A 0B1", "AB51 ABC", "27ABCPK1234F1Z5"])
    try check(#"{"routing_number":"021000021"}"#, gone: ["021000021"]) { route, root, output in
        guard case .string(let made)? = value(root, "routing_number") else { Issue.record("\(route): \(output)"); return }
        #expect(Recognizers.candidates(made).contains { $0.name == "ABA_ROUTING" }, "\(route): \(made)")
    }
}

@Test func aPassportPrintedWithASpaceIsRead() throws {
    try check(#"{"note":"Passport A12 34567 on file"}"#, gone: ["A12 34567"])
}

@Test func anIPAddressNeverStandsInForItself() throws {
    // Stand-ins are documentation addresses, and a sample may be one already.
    for seed in UInt64(1)...60 {
        let output = String(decoding: try Scrubber.scrub(Data(#"{"ip_address":"203.0.113.10","ip6":"2001:db8::1a2"}"#.utf8), name: "x.json", forceFullDetection: false, seed: seed).output, as: UTF8.self)
        #expect(!output.contains("203.0.113.10") && !output.contains("2001:db8::1a2"), "seed \(seed): \(output)")
    }
}

@Test func aWordInProseNamesTheStandInsKind() throws {
    // "nif" names Spain's number, "claim" a claim's: each stand-in is of that kind, not of another the value passes by chance.
    for (note, kind) in [("Holder nif 23332969-K on file", "DNI"), ("Holder claim CLM785751 on file", "CLAIM_NUMBER")] {
        let original = String(note.split(separator: " ")[2])
        try check("{\"note\":\"\(note)\"}", gone: [original]) { route, root, output in
            guard case .string(let written)? = value(root, "note") else { Issue.record("\(route): \(output)"); return }
            let made = String(written.split(separator: " ")[2])
            #expect(Recognizers.candidates(made).contains { $0.name == kind }, "\(route): \(made)")
        }
    }
}

@Test func namedKindsReachEveryWayAValueIsWritten() throws {
    // A practice number as a JSON number, a plate a logbook names though it reads like a British Standard,
    // a licence and a plate a record's type names in words with punctuation.
    try check(#"{"bsnr":722586313}"#, gone: ["722586313"])
    try check(#"{"note":"Holder logbook BS77BOE on file"}"#, gone: ["BS77BOE"])
    try check(#"[{"type":"V5C","number":"LA52-VSE"},{"type":"DRIVER'S LICENSE","number":"B7353417348"},{"type":"UNIFIED MULTI-PURPOSE ID","number":"123413499657"}]"#,
              gone: ["LA52-VSE", "B7353417348", "123413499657"])
}

@Test func aShortRegisterNumberKeepsItsRegisterAndOneStandIn() throws {
    try check(#"{"a":{"handelsregister":"HRB 39"},"b":{"handelsregister":"HRB39"}}"#, gone: ["HRB 39", "HRB39"]) { route, root, output in
        guard case .string(let spaced)? = value(root, "a", "handelsregister"), case .string(let bare)? = value(root, "b", "handelsregister") else { Issue.record("\(route): \(output)"); return }
        #expect(spaced.hasPrefix("HRB ") && spaced.replacingOccurrences(of: " ", with: "") == bare, "\(route): \(output)")
    }
}

@Test func aKeyNamingAKindIsNoOnesName() throws {
    // "Umid" is a given name, but "umid card" is the field a Philippine ID is written under.
    try check(#"{"umid card":"1234-9402375-0","korean brn":"766-65-89706"}"#, gone: ["1234-9402375-0", "766-65-89706"]) { route, root, output in
        #expect(output.contains("\"umid card\"") && output.contains("\"korean brn\""), "\(route): \(output)")
    }
}

@Test func genericPatternsRejectWhatNoIssuerWrites() {
    // An 18-digit ID opening with a 1 passing Luhn by chance is no card; "::" alone is no host.
    #expect(!Patterns.find("Event 1592876430123456787 logged", isCancelled: { false }).contains { $0.entity == "CREDIT_CARD" })
    #expect(!Patterns.find("bound to :: on start", isCancelled: { false }).contains { $0.entity == "IP_ADDRESS" })
    #expect(!Patterns.find("born 2024-99-99", isCancelled: { false }).contains { $0.entity == "DATE_OF_BIRTH" })
}

@Test func aCentralLondonPostcodeStaysInTheUK() throws {
    // No place but central London writes "SW1A": its city and postcode become one British place, never one abroad.
    try check(#"{"postcode":"SW1A 1AA","city":"London"}"#, gone: ["SW1A 1AA"]) { route, root, output in
        guard case .string(let city)? = value(root, "city"), case .string(let postcode)? = value(root, "postcode"),
              let place = Places.all.first(where: { $0.city == city }) else { Issue.record("\(route): \(output)"); return }
        #expect(place.country == "GB" && place.postal.contains(String(postcode.prefix { $0 != " " })), "\(route): \(output)")
    }
}
