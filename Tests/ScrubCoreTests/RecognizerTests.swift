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
]

private func recognizer(_ name: String) -> Recognizer? { Recognizers.all.first { $0.name == name } }

@Test func everyRecognizerHasASample() {
    #expect(Set(samples.keys) == Set(Recognizers.all.map(\.name)))
}

@Test func checksKnowTheirIdentifiers() throws {
    for (name, sample) in samples {
        let recognizer = try #require(recognizer(name))
        #expect(recognizer.passes(sample), "\(name): \(sample)")
        // One character moved by one fails every check that has one.
        guard !["CPR", "NINO", "PAN", "RRN"].contains(name) else { continue }
        let index = try #require(sample.lastIndex { $0.isNumber })
        let digit = try #require(sample[index].wholeNumberValue)
        var changed = sample
        changed.replaceSubrange(index...index, with: String((digit + 1) % 10))
        #expect(!recognizer.passes(changed), "\(name): \(changed)")
    }
}

@Test func drawnIdentifiersPassTheirChecksAndForms() {
    var rng: any RandomNumberGenerator = SeededGenerator(seed: 11)
    for recognizer in Recognizers.all {
        let length = recognizer.kept(samples[recognizer.name] ?? "").count
        for _ in 0..<40 {
            let canonical = recognizer.draw(length, &rng)
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
    for (name, sample) in samples {
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
