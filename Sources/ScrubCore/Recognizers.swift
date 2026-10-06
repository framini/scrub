import CryptoKit
import Foundation

/// An identifier a country gives a person, described as data after open-source
/// recognizers (see THIRD_PARTY_NOTICES): the forms it is written in, the
/// words that name it, and the check its own characters carry. A value that
/// fails its check is not that identifier. One that passes, in a form chance
/// seldom writes (letters in their places, separators, a date), needs no word
/// naming it; bare digits, which any count or code may be, need one before
/// them or in their key. Each also draws a fresh value of its own, so a
/// stand-in passes the check its original did.
struct Recognizer: Sendable {
    struct Form: Sendable {
        let pattern: TextPattern
        let score: Double
        /// Whether a value of this form that passes the check is the identifier with no word naming it.
        let alone: Bool
        init(_ pattern: String, _ score: Double, alone: Bool = false) {
            self.pattern = TextPattern(pattern)
            self.score = score
            self.alone = alone
        }
    }
    let name: String
    let entity: String
    let forms: [Form]
    /// Words before a value, or in its key, that name it; an entry of several words matches them in a row.
    let context: Set<String>
    /// Keys it is written under, as `KeyHints` compacts them ("cpf_number" → "cpfnumber").
    let keys: Set<String>
    /// Whether its letters are one whatever their case (a codice fiscale), or case is part of the value (a Base58 address).
    let folds: Bool
    /// What its spelling may write between characters, dropped before the check.
    let separators: Set<Character>
    /// Whether its check is more than its shape (a check digit, a checksum): only then can values passing it name a field on their own (see `Fields`).
    let verifies: Bool
    /// Its check, over the value's characters other than separators, in capitals.
    let check: @Sendable ([Character]) -> Bool
    /// A fresh value passing `check`, shaped like the given one (as long, the same version) where its kind allows.
    let draw: @Sendable ([Character], inout any RandomNumberGenerator) -> [Character]

    init(_ name: String, entity: String = "ID_NUMBER", keys: Set<String> = [], forms: [Form], context: Set<String>, folds: Bool = true, verifies: Bool = true, separators: String = " .-/", check: @escaping @Sendable ([Character]) -> Bool, draw: @escaping @Sendable ([Character], inout any RandomNumberGenerator) -> [Character]) {
        self.name = name
        self.entity = entity
        self.forms = forms
        self.context = context
        self.keys = keys
        self.folds = folds
        self.verifies = verifies
        self.separators = Set(separators)
        self.check = check
        self.draw = draw
    }

    func kept(_ value: String) -> [Character] {
        (folds ? value.uppercased() : value).filter { !separators.contains($0) }
    }
    /// Whether one of its forms writes `value` whole.
    func writes(_ value: String) -> Bool {
        let length = (value as NSString).length
        return forms.contains { form in TextRanges.matches(form.pattern, in: value).contains { $0.range.location == 0 && $0.range.length == length } }
    }
    func passes(_ value: String) -> Bool {
        let characters = kept(value)
        return !characters.isEmpty && check(characters)
    }
}

enum Recognizers {
    static let entity = "ID_NUMBER"

    static let all: [Recognizer] = [
        Recognizer("CPF", keys: ["cpf", "cpfnumber", "numerocpf", "nrcpf"], forms: [
            .init(#"(?<![\d.])\d{3}\.\d{3}\.\d{3}-\d{2}(?![\d.-])"#, 0.5, alone: true),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["cpf", "cadastro", "contribuinte"], check: { characters in
            guard let d = numbers(characters), d.count == 11, Set(d).count > 1 else { return false }
            return d[9] == cpfDigit(d[0..<9]) && d[10] == cpfDigit(d[0..<10])
        }, draw: { _, rng in
            var d = randomDigits(9, &rng)
            d.append(cpfDigit(d[...])); d.append(cpfDigit(d[...]))
            return characters(d)
        }),
        Recognizer("CUIL", keys: ["cuil", "cuit", "cuilnumber", "cuitnumber"], forms: [
            .init(#"\b(?:20|23|24|27)-\d{8}-\d\b"#, 0.5, alone: true),
            .init(#"\b(?:20|23|24|27)\d{9}\b"#, 0.05),
        ], context: ["cuit", "cuil"], check: { characters in
            guard let d = numbers(characters), d.count == 11, [20, 23, 24, 27].contains(d[0] * 10 + d[1]), let last = cuilDigit(d[0..<10]) else { return false }
            return d[10] == last
        }, draw: { _, rng in
            while true {
                let d = (Int.random(in: 0...1, using: &rng) == 0 ? [2, 0] : [2, 7]) + randomDigits(8, &rng)
                if let last = cuilDigit(d[...]) { return characters(d + [last]) }
            }
        }),
        Recognizer("RUT", keys: ["rut", "rutnumber", "numerorut"], forms: [
            .init(#"\b\d{1,2}\.\d{3}\.\d{3}-[\dkK](?![\w-])"#, 0.5, alone: true),
            .init(#"\b\d{7,8}-[\dkK](?![\w-])"#, 0.1),
            .init(#"\b\d{7,8}[\dkK]\b"#, 0.05),
        ], context: ["rut"], check: { characters in
            guard (8...9).contains(characters.count), let body = numbers(Array(characters.dropLast())) else { return false }
            return characters.last == rutDigit(body)
        }, draw: { like, rng in
            let count = like.count
            let body = [Int.random(in: 1...9, using: &rng)] + randomDigits(max(6, min(7, count - 2)), &rng)
            return characters(body) + [rutDigit(body)]
        }),
        Recognizer("CURP", keys: ["curp"], forms: [
            .init(#"\b[A-Z][AEIOUX][A-Z]{2}\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[HMX](?:AS|BC|BS|CC|CL|CM|CS|CH|DF|DG|GT|GR|HG|JC|MC|MN|MS|NT|NL|OC|PL|QT|QR|SP|SL|SR|TC|TS|TL|VZ|YN|ZS|NE)[B-DF-HJ-NP-TV-Z]{3}[A-Z\d]\d\b"#, 0.6, alone: true),
        ], context: ["curp"], check: { characters in
            guard characters.count == 18, let last = characters[17].wholeNumberValue else { return false }
            return curpDigit(characters[0..<17]) == last
        }, draw: { _, rng in
            let date = randomDate(&rng)
            var c = [pick(consonants, &rng), pick("AEIOU", &rng), pick(letters, &rng), pick(letters, &rng)]
            c += characters(twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day))
            c += [pick("HM", &rng)] + Array(["JC", "NL", "DF", "PL", "GT", "VZ", "CH", "SR"][Int.random(in: 0..<8, using: &rng)])
            c += [pick(consonants, &rng), pick(consonants, &rng), pick(consonants, &rng), Character(String(Int.random(in: 0...9, using: &rng)))]
            return c + [Character(String(curpDigit(c[...])))]
        }),
        Recognizer("RFC", keys: ["rfc"], forms: [
            .init(#"\b[A-ZÑ&]{4}\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[A-Z\d]{2}[\dA]\b"#, 0.3),
        ], context: ["rfc"], separators: " -", check: { characters in
            characters.count == 13 && rfcDigit(characters[0..<12]) == characters[12]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            var c = [pick(consonants, &rng), pick("AEIOU", &rng), pick(letters, &rng), pick(letters, &rng)]
            c += characters(twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day))
            c += [pick(letters + digits, &rng), pick(letters + digits, &rng)]
            return c + [rfcDigit(c[...])]
        }),
        Recognizer("CODICE_FISCALE", keys: ["codicefiscale", "fiscalcode"], forms: [
            .init(#"(?i)\b(?:[A-Z][AEIOU][AEIOUX]|[AEIOU]X{2}|[B-DF-HJ-NP-TV-Z]{2}[A-Z]){2}[\dLMNP-V]{2}[A-EHLMPR-T](?:[04LQ][1-9MNP-V]|[1256MRNS][\dLMNP-V]|[37PT][01LM])[A-MZ][\dLMNP-V]{3}[A-Z]\b"#, 0.6, alone: true),
        ], context: ["codice", "fiscale", "cf"], check: { characters in
            characters.count == 16 && fiscalLetter(characters[0..<15]) == characters[15]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            var c = (0..<6).map { _ in pick(consonants, &rng) }
            c += characters(twoDigits(date.year % 100)) + [Array("ABCDEHLMPRST")[date.month - 1]]
            c += characters(twoDigits(date.day + (Int.random(in: 0...1, using: &rng) == 0 ? 0 : 40)))
            c += [pick("ABCDEFGHILM", &rng), Character(String(Int.random(in: 1...9, using: &rng)))] + characters(randomDigits(2, &rng))
            return c + [fiscalLetter(c[...])]
        }),
        Recognizer("DNI", keys: ["dni", "nif", "dninumber", "numerodni", "nifnumber"], forms: [
            .init(#"\b\d{8}-?[A-HJ-NP-TV-Z]\b"#, 0.3),
        ], context: ["dni", "nif", "documento", "identidad", "tax", "fiscal"], check: { characters in
            guard characters.count == 9, let d = numbers(Array(characters.prefix(8))) else { return false }
            return dniLetter(number(d)) == characters[8]
        }, draw: { _, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            return characters(d) + [dniLetter(number(d))]
        }),
        Recognizer("NIE", keys: ["nie", "nienumber"], forms: [
            .init(#"\b[XYZ]-?\d{7}-?[A-HJ-NP-TV-Z]\b"#, 0.3),
        ], context: ["nie", "nif", "extranjero", "tax", "fiscal"], check: { characters in
            guard characters.count == 9, let lead = "XYZ".firstIndex(of: characters[0]), let d = numbers(Array(characters[1..<8])) else { return false }
            return dniLetter("XYZ".distance(from: "XYZ".startIndex, to: lead) * 10_000_000 + number(d)) == characters[8]
        }, draw: { _, rng in
            let lead = Int.random(in: 0...1, using: &rng)
            let d = randomDigits(7, &rng)
            return [Array("XY")[lead]] + characters(d) + [dniLetter(lead * 10_000_000 + number(d))]
        }),
        Recognizer("NIR", keys: ["nir", "numerosecu", "numerosecuritesociale", "securitesociale"], forms: [
            .init(#"\b[12] \d{2} (?:0[1-9]|1[0-2]) (?:\d{2}|2[AB]) \d{3} \d{3} \d{2}\b"#, 0.5, alone: true),
            .init(#"\b[12]\d{2}(?:0[1-9]|1[0-2])(?:\d{2}|2[AB])\d{8}\b"#, 0.05),
        ], context: ["nir", "insee", "sécurité", "securite", "sociale", "secu", "sécu"], check: { characters in
            guard characters.count == 15, let key = Int(String(characters[13...])) else { return false }
            let body = String(characters[0..<13]).replacingOccurrences(of: "2A", with: "19").replacingOccurrences(of: "2B", with: "18")
            guard let value = Int(body) else { return false }
            return key == 97 - value % 97
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let body = [Int.random(in: 1...2, using: &rng)] + twoDigits(date.year % 100) + twoDigits(date.month)
                + twoDigits(Int.random(in: 21...89, using: &rng)) + randomDigits(6, &rng)
            return characters(body + twoDigits(97 - number(body) % 97))
        }),
        Recognizer("BELGIAN_NATIONAL_NUMBER", keys: ["rijksregisternummer", "insz", "niss", "registrenational"], forms: [
            .init(#"\b\d{2}\.\d{2}\.\d{2}-\d{3}\.\d{2}\b"#, 0.5, alone: true),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["rijksregisternummer", "insz", "niss", "rrn"], check: { characters in
            guard let d = numbers(characters), d.count == 11 else { return false }
            let body = number(Array(d[0..<9])), key = d[9] * 10 + d[10]
            return key == 97 - body % 97 || key == 97 - (2_000_000_000 + body) % 97
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let body = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + [0] + twoDigits(Int.random(in: 1...97, using: &rng))
            return characters(body + twoDigits(97 - number(body) % 97))
        }),
        Recognizer("BSN", keys: ["bsn", "burgerservicenummer"], forms: [
            .init(#"\b\d{9}\b"#, 0.05),
            .init(#"\b\d{4}\.\d{2}\.\d{3}\b"#, 0.1),
        ], context: ["bsn", "burgerservicenummer", "sofinummer"], check: { characters in
            guard let d = numbers(characters), d.count == 9, d.contains(where: { $0 != 0 }) else { return false }
            return (zip(d[0..<8], (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } - d[8]) % 11 == 0
        }, draw: { _, rng in
            while true {
                let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
                let last = zip(d, (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 11
                if last < 10 { return characters(d + [last]) }
            }
        }),
        Recognizer("STEUER_ID", keys: ["steuerid", "steueridentifikationsnummer", "idnr"], forms: [
            .init(#"\b[1-9]\d{10}\b"#, 0.05),
            .init(#"\b[1-9]\d \d{3} \d{3} \d{3}\b"#, 0.1),
        ], context: ["steuerid", "steueridentifikationsnummer", "idnr", "identifikationsnummer", "steuer"], check: { characters in
            guard let d = numbers(characters), d.count == 11, d[0] != 0 else { return false }
            let counts = Dictionary(grouping: d[0..<10], by: { $0 }).mapValues(\.count)
            return counts.values.allSatisfy { $0 <= 3 } && counts.values.contains { $0 > 1 } && steuerDigit(d[0..<10]) == d[10]
        }, draw: { _, rng in
            var d = Array(0...9).shuffled(using: &rng)
            d[Int.random(in: 1...9, using: &rng)] = d[0] == 0 ? d[1] : d[0]
            if d[0] == 0 { d.swapAt(0, d.firstIndex { $0 != 0 } ?? 1) }
            return characters(d + [steuerDigit(d[...])])
        }),
        Recognizer("PESEL", keys: ["pesel"], forms: [
            .init(#"\b\d{2}(?:[02468][1-9]|[13579][012])(?:0[1-9]|[12]\d|3[01])\d{5}\b"#, 0.05),
        ], context: ["pesel"], check: { characters in
            guard let d = numbers(characters), d.count == 11 else { return false }
            return (10 - zip(d[0..<10], [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]).reduce(0) { $0 + $1.0 * $1.1 } % 10) % 10 == d[10]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(4, &rng)
            return characters(d + [(10 - zip(d, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]).reduce(0) { $0 + $1.0 * $1.1 } % 10) % 10])
        }),
        Recognizer("PERSONNUMMER", keys: ["personnummer", "samordningsnummer"], forms: [
            .init(#"\b(?:19|20)?\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01]|[6-8]\d|9[01])[-+]\d{4}\b"#, 0.3),
            .init(#"\b(?:19|20)?\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01]|[6-8]\d|9[01])\d{4}\b"#, 0.05),
        ], context: ["personnummer", "samordningsnummer"], separators: " -+", check: { characters in
            guard let all = numbers(characters), all.count == 10 || all.count == 12 else { return false }
            let d = Array(all.suffix(10))
            let day = d[4] * 10 + d[5]
            return (1...12).contains(d[2] * 10 + d[3]) && ((1...31).contains(day) || (61...91).contains(day)) && Patterns.luhn(d)
        }, draw: { like, rng in
            let count = like.count
            let date = randomDate(&rng)
            let body = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(3, &rng)
            return characters((count == 12 ? [1, 9] : []) + body + [luhnDigit(body)])
        }),
        Recognizer("FODSELSNUMMER", keys: ["fodselsnummer", "fdselsnummer"], forms: [
            .init(#"\b(?:[0-6]\d|7[01])(?:0[1-9]|1[0-2])\d{7}\b"#, 0.05),
        ], context: ["fødselsnummer", "fodselsnummer", "personnummer"], check: { characters in
            guard let d = numbers(characters), d.count == 11, let first = norwayDigit(d[0..<9], [3, 7, 6, 1, 8, 9, 4, 5, 2]),
                  let second = norwayDigit(d[0..<10], [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) else { return false }
            return first == d[9] && second == d[10]
        }, draw: { _, rng in
            while true {
                let date = randomDate(&rng)
                var d = twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + randomDigits(3, &rng)
                guard let first = norwayDigit(d[...], [3, 7, 6, 1, 8, 9, 4, 5, 2]) else { continue }
                d.append(first)
                guard let second = norwayDigit(d[...], [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) else { continue }
                return characters(d + [second])
            }
        }),
        Recognizer("CPR", keys: ["cpr", "cprnummer", "cprnumber"], forms: [
            .init(#"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}-\d{4}\b"#, 0.1),
            .init(#"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{6}\b"#, 0.05),
        ], context: ["cpr", "personnummer"], verifies: false, check: { characters in
            guard let d = numbers(characters), d.count == 10 else { return false }
            // The century is read off the year and the seventh digit, as the CPR register writes it.
            let year = d[4] * 10 + d[5]
            let century = switch d[6] {
            case 0...3: 1900
            case 4, 9: year <= 36 ? 2000 : 1900
            default: year <= 57 ? 2000 : 1800
            }
            return realDate(year: century + year, month: d[2] * 10 + d[3], day: d[0] * 10 + d[1])
        }, draw: { _, rng in
            let date = randomDate(&rng)
            return characters(twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + randomDigits(4, &rng))
        }),
        Recognizer("HETU", keys: ["hetu", "henkilotunnus", "henkiltunnus"], forms: [
            .init(#"\b\d{6}[ABCDEFUVWXY]\d{3}[0-9A-FHJ-NPR-Y]\b"#, 0.5, alone: true),
            .init(#"\b\d{6}[-+]\d{3}[0-9A-FHJ-NPR-Y]\b"#, 0.3),
        ], context: ["hetu", "henkilötunnus", "henkilotunnus"], separators: " ", check: { characters in
            guard characters.count == 11, let d = numbers(Array(characters[0..<6]) + Array(characters[7..<10])) else { return false }
            let century: Int
            switch characters[6] {
            case "+": century = 1800
            case "-", "U", "V", "W", "X", "Y": century = 1900
            default: century = 2000
            }
            guard realDate(year: century + d[4] * 10 + d[5], month: d[2] * 10 + d[3], day: d[0] * 10 + d[1]) else { return false }
            return hetuMarks[number(d) % 31] == characters[10]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let d = twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + [0] + twoDigits(Int.random(in: 2...89, using: &rng))
            return characters(Array(d[0..<6])) + ["-"] + characters(Array(d[6...])) + [hetuMarks[number(d) % 31]]
        }),
        Recognizer("NINO", keys: ["nino", "nationalinsurancenumber", "ninumber"], forms: [
            .init(#"\b(?!BG|GB|NK|KN|NT|TN|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?\d{2} ?\d{2} ?\d{2} ?[A-D]\b"#, 0.3),
        ], context: ["nino", "national insurance", "ni number"], verifies: false, check: { $0.count == 9 }, draw: { _, rng in
            [pick("ABCEGHJKLMPRSTWXY", &rng), pick("ABCEHJLMPRSTWXY", &rng)] + characters(randomDigits(6, &rng)) + [pick("ABCD", &rng)]
        }),
        Recognizer("NHS_NUMBER", keys: ["nhs", "nhsnumber", "nhsno"], forms: [
            .init(#"\b\d{3}[- ]?\d{3}[- ]?\d{4}\b"#, 0.05),
        ], context: ["nhs"], check: { characters in
            guard let d = numbers(characters), d.count == 10 else { return false }
            return zip(d, (1...10).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 11 == 0
        }, draw: { _, rng in
            while true {
                let d = [Int.random(in: 4...6, using: &rng)] + randomDigits(8, &rng)
                let last = (11 - zip(d, (2...10).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 11
                if last < 10 { return characters(d + [last]) }
            }
        }),
        Recognizer("SIN", keys: ["sin", "socialinsurancenumber", "sinnumber"], forms: [
            .init(#"\b[1-79]\d{2}[- ]?\d{3}[- ]?\d{3}\b"#, 0.05),
        ], context: ["sin", "social insurance", "nas", "assurance sociale"], check: { characters in
            guard let d = numbers(characters), d.count == 9 else { return false }
            return Patterns.luhn(d)
        }, draw: { _, rng in
            let d = [Int.random(in: 1...7, using: &rng)] + randomDigits(7, &rng)
            return characters(d + [luhnDigit(d)])
        }),
        Recognizer("AADHAAR", keys: ["aadhaar", "aadhar", "aadhaarnumber", "aadharnumber"], forms: [
            .init(#"\b[2-9]\d{3}[- ]?\d{4}[- ]?\d{4}\b"#, 0.05),
        ], context: ["aadhaar", "aadhar", "uidai"], check: { characters in
            guard let d = numbers(characters), d.count == 12, d[0] >= 2, d != Array(d.reversed()) else { return false }
            return verhoeff(d) == 0
        }, draw: { _, rng in
            let d = [Int.random(in: 2...9, using: &rng)] + randomDigits(10, &rng)
            return characters(d + [verhoeffDigit(d)])
        }),
        Recognizer("PAN", keys: ["pannumber", "pancard", "panno"], forms: [
            .init(#"\b[A-Z]{3}[ABCFGHLJPT][A-Z]\d{4}[A-Z]\b"#, 0.3),
        ], context: ["pan", "permanent"], verifies: false, check: { $0.count == 10 }, draw: { _, rng in
            [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng), "P", pick(letters, &rng)] + characters(randomDigits(4, &rng)) + [pick(letters, &rng)]
        }),
        Recognizer("RESIDENT_ID", keys: ["residentid", "residentidnumber", "shenfenzheng"], forms: [
            .init(#"\b[1-8]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]\b"#, 0.5, alone: true),
        ], context: ["身份证", "身份证号", "shenfenzheng"], check: { characters in
            guard characters.count == 18, let d = numbers(Array(characters[0..<17])),
                  realDate(year: number(Array(d[6..<10])), month: d[10] * 10 + d[11], day: d[12] * 10 + d[13]) else { return false }
            return residentMark(d) == characters[17]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let d = [Int.random(in: 1...6, using: &rng)] + randomDigits(5, &rng) + [1, 9] + twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(3, &rng)
            return characters(d) + [residentMark(d)]
        }),
        Recognizer("RRN", keys: ["rrn", "residentregistrationnumber"], forms: [
            .init(#"(?<!\d)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])-[1-8]\d{6}(?!\d)"#, 0.3),
            .init(#"(?<!\d)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[1-8]\d{6}(?!\d)"#, 0.05),
        ], context: ["rrn", "주민등록번호", "외국인등록번호"], verifies: false, check: { characters in
            guard let d = numbers(characters), d.count == 13 else { return false }
            let century = [9: 1800, 0: 1800, 1: 1900, 2: 1900, 5: 1900, 6: 1900, 3: 2000, 4: 2000, 7: 2000, 8: 2000][d[6]] ?? 1900
            return realDate(year: century + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5])
        }, draw: { _, rng in
            let date = randomDate(&rng)
            var d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + [Int.random(in: 1...2, using: &rng)] + randomDigits(5, &rng)
            d.append((11 - zip(d, [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5]).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 10)
            return characters(d)
        }),
        Recognizer("SOUTH_AFRICAN_ID", keys: ["rsaid", "saidnumber", "southafricanid"], forms: [
            .init(#"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{4}[01][89]\d\b"#, 0.05),
        ], context: ["identity", "rsa"], check: { characters in
            guard let d = numbers(characters), d.count == 13 else { return false }
            return realDate(year: 1900 + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5]) && Patterns.luhn(d)
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(4, &rng) + [0, 8]
            return characters(d + [luhnDigit(d)])
        }),
        Recognizer("TCKN", keys: ["tckn", "tckimlikno", "kimlikno", "tcno", "tckimlik"], forms: [
            .init(#"\b[1-9]\d{10}\b"#, 0.05),
        ], context: ["tckn", "kimlik"], check: { characters in
            guard let d = numbers(characters), d.count == 11, d[0] != 0 else { return false }
            return d[9] == tcknTenth(d) && d[10] == d[0..<10].reduce(0, +) % 10
        }, draw: { _, rng in
            var d = [Int.random(in: 1...9, using: &rng)] + randomDigits(8, &rng)
            d.append(tcknTenth(d))
            return characters(d + [d.reduce(0, +) % 10])
        }),
        Recognizer("NRIC", keys: ["nric", "nricno", "nricnumber", "nricfin", "finnumber"], forms: [
            .init(#"\b[STFGM]\d{7}[A-Z]\b"#, 0.3),
        ], context: ["nric", "fin"], check: { characters in
            guard characters.count == 9, let d = numbers(Array(characters[1..<8])) else { return false }
            return nricLetter(characters[0], d) == characters[8]
        }, draw: { like, rng in
            let lead = like.first.map { "STFGM".contains($0) ? $0 : "S" } ?? pick("ST", &rng)
            let d = randomDigits(7, &rng)
            return [lead] + characters(d) + [nricLetter(lead, d) ?? "A"]
        }),
        Recognizer("HKID", keys: ["hkid", "hkidnumber", "hkidno"], forms: [
            .init(#"(?<![A-Za-z0-9])[A-Z]{1,2}\d{6}\([\dA]\)"#, 0.5, alone: true),
            .init(#"\b[A-Z]{1,2}\d{6}[\dA]\b"#, 0.1),
        ], context: ["hkid", "身份證", "身份證號碼"], separators: " ()", check: { characters in
            (8...9).contains(characters.count) && hkidMark(Array(characters.dropLast())) == characters.last
        }, draw: { like, rng in
            let body = (like.count == 9 ? [pick(letters, &rng)] : []) + [pick(letters, &rng)] + characters(randomDigits(6, &rng))
            return body + [hkidMark(body) ?? "0"]
        }),
        Recognizer("TAIWAN_ID", keys: ["taiwanid", "rocid", "twid"], forms: [
            .init(#"\b[A-Z][12]\d{8}\b"#, 0.3),
        ], context: ["身分證", "身分證字號", "統一編號", "taiwan"], check: { characters in
            guard characters.count == 10, let first = taiwanLetters[characters[0]], let d = numbers(Array(characters[1...])) else { return false }
            return zip([first / 10, first % 10] + d, [1, 9, 8, 7, 6, 5, 4, 3, 2, 1, 1]).reduce(0) { $0 + $1.0 * $1.1 } % 10 == 0
        }, draw: { _, rng in
            let lead = pick("ABCDEFGHJKLMNPQRSTUVXYWZIO", &rng)
            let first = taiwanLetters[lead] ?? 10
            let d = [Int.random(in: 1...2, using: &rng)] + randomDigits(7, &rng)
            let sum = zip([first / 10, first % 10] + d, [1, 9, 8, 7, 6, 5, 4, 3, 2, 1]).reduce(0) { $0 + $1.0 * $1.1 }
            return [lead] + characters(d + [(10 - sum % 10) % 10])
        }),
        Recognizer("MY_NUMBER", keys: ["mynumber", "kojinbango", "individualnumber"], forms: [
            .init(#"\b\d{4} ?\d{4} ?\d{4}\b"#, 0.05),
        ], context: ["マイナンバー", "個人番号", "mynumber"], check: { characters in
            guard let d = numbers(characters), d.count == 12 else { return false }
            return myNumberDigit(Array(d[0..<11])) == d[11]
        }, draw: { _, rng in
            let d = randomDigits(11, &rng)
            return characters(d + [myNumberDigit(d)])
        }),
        Recognizer("DOWOD", keys: ["dowod", "dowodosobisty", "numerdowodu", "seriainumerdowodu"], forms: [
            .init(#"\b[A-Z]{3} ?\d{6}\b"#, 0.3),
        ], context: ["dowód", "dowodu", "dowod", "osobisty", "osobistego"], check: { characters in
            guard characters.count == 9 else { return false }
            let values = characters.compactMap(alnumValue)
            return values.count == 9 && zip(values, [7, 3, 1, 9, 7, 3, 1, 7, 3]).reduce(0) { $0 + $1.0 * $1.1 } % 10 == 0
        }, draw: { _, rng in
            let head = [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng)]
            let tail = randomDigits(5, &rng)
            let partial = zip(head.compactMap(alnumValue), [7, 3, 1]).reduce(0) { $0 + $1.0 * $1.1 } + zip(tail, [7, 3, 1, 7, 3]).reduce(0) { $0 + $1.0 * $1.1 }
            // The check digit, weighed 9, makes the sum a multiple of ten.
            let check = (0...9).first { (partial + $0 * 9) % 10 == 0 } ?? 0
            return head + characters([check] + tail)
        }),
        Recognizer("UK_DRIVING_LICENCE", keys: ["drivinglicencenumber", "dvlanumber"], forms: [
            .init(#"\b[A-Z9]{5}\d(?:[05][1-9]|[16][0-2])(?:0[1-9]|[12]\d|3[01])\d[A-Z9]{2}\d[A-Z]{2}\b"#, 0.5, alone: true),
        ], context: ["licence", "license", "driving", "dvla"], verifies: false, separators: " ", check: { characters in
            guard characters.count == 16 else { return false }
            let surname = String(characters[0..<5])
            return surname != "99999" && surname.range(of: "^[A-Z]+9*$", options: .regularExpression) != nil
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let month = date.month + (Bool.random(using: &rng) ? 50 : 0)
            return (0..<5).map { _ in pick(consonants, &rng) } + characters([date.year % 100 / 10] + twoDigits(month) + twoDigits(date.day) + [date.year % 10])
                + [pick(letters, &rng), "9"] + characters([Int.random(in: 0...9, using: &rng)]) + [pick(letters, &rng), pick(letters, &rng)]
        }),
        Recognizer("DE_DOCUMENT", keys: ["personalausweisnummer", "ausweisnummer", "reisepassnummer", "passnummer"], forms: [
            .init(#"\b[CFGHJKLMNPRTVWXYZ][CFGHJKLMNPRTVWXYZ0-9]{8}\d?\b"#, 0.3),
        ], context: ["personalausweis", "ausweis", "ausweisnummer", "personalausweisnummer", "reisepass", "passnummer", "reisepassnummer", "dokumentennummer"], verifies: false, check: { characters in
            guard characters.count == 9 || characters.count == 10, characters.contains(where: \.isNumber) else { return false }
            guard characters.count == 10 else { return true }
            return icaoDigit(Array(characters[0..<9])) == characters[9].wholeNumberValue
        }, draw: { like, rng in
            let body = [pick("CFGHJKLMNPRTVWXYZ", &rng)] + (0..<7).map { _ in pick("CFGHJKLMNPRTVWXYZ0123456789", &rng) } + [pick(digits, &rng)]
            return like.count == 10 ? body + characters([icaoDigit(body)]) : body
        }),
        Recognizer("KVNR", keys: ["kvnr", "krankenversichertennummer", "versichertennummer"], forms: [
            .init(#"\b[A-Z]\d{9}\b"#, 0.3),
        ], context: ["krankenversichertennummer", "versichertennummer", "kvnr", "krankenversicherung", "krankenkasse"], check: { characters in
            guard characters.count == 10, let letter = characters[0].asciiValue, characters[0].isLetter, let d = numbers(Array(characters[1...])) else { return false }
            return kvnrDigit(Int(letter) - 64, Array(d[0..<8])) == d[8]
        }, draw: { _, rng in
            let lead = pick(letters, &rng)
            let d = randomDigits(8, &rng)
            return [lead] + characters(d + [kvnrDigit(Int(lead.asciiValue ?? 65) - 64, d)])
        }),
        Recognizer("RVNR", keys: ["rvnr", "rentenversicherungsnummer", "sozialversicherungsnummer", "svnr", "svnummer"], forms: [
            .init(#"\b\d{2} ?(?:0[1-9]|[12]\d|3[01]|5[1-9]|[67]\d|8[01])(?:0[1-9]|1[0-2])\d{2} ?[A-Z] ?\d{2} ?\d\b"#, 0.3),
        ], context: ["rentenversicherungsnummer", "sozialversicherungsnummer", "versicherungsnummer", "rvnr", "svnr"], check: { characters in
            guard characters.count == 12, characters[8].isLetter, let letter = characters[8].asciiValue,
                  let head = numbers(Array(characters[0..<8])), let tail = numbers(Array(characters[9..<12])) else { return false }
            return rvnrDigit(head, Int(letter) - 64, Array(tail[0..<2])) == tail[2]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let head = [Int.random(in: 1...6, using: &rng), Int.random(in: 0...9, using: &rng)] + twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100)
            let letter = pick(letters, &rng)
            let serial = randomDigits(2, &rng)
            return characters(head) + [letter] + characters(serial + [rvnrDigit(head, Int(letter.asciiValue ?? 65) - 64, serial)])
        }),
        Recognizer("NPI", keys: ["npi", "npinumber", "nationalproviderid", "nationalprovideridentifier"], forms: [
            .init(#"\b[12]\d{9}\b"#, 0.05),
            .init(#"\b[12]\d{3}[ -]\d{3}[ -]\d{3}\b"#, 0.1),
        ], context: ["npi", "national provider"], check: { characters in
            guard let d = numbers(characters), d.count == 10, Set(d[0..<9]).count > 1 else { return false }
            return Patterns.luhn([8, 0, 8, 4, 0] + d)
        }, draw: { _, rng in
            let d = [Int.random(in: 1...2, using: &rng)] + randomDigits(8, &rng)
            return characters(d + [luhnDigit([8, 0, 8, 4, 0] + d)])
        }),
        Recognizer("DEA", entity: "MEDICAL_LICENSE", keys: ["deanumber", "dearegistration", "dearegistrationnumber"], forms: [
            .init(#"\b[ABCDEFGHJKLMPRSTUX][A-Z9]\d{7}\b"#, 0.3),
        ], context: ["dea"], check: { characters in
            guard characters.count == 9, let d = numbers(Array(characters[2...])) else { return false }
            return deaDigit(d) == d[6]
        }, draw: { _, rng in
            let d = randomDigits(6, &rng)
            return [pick("ABFM", &rng), pick(letters, &rng)] + characters(d + [deaDigit(d)])
        }),
        Recognizer("MBI", keys: ["mbi", "medicarebeneficiaryidentifier", "medicareid"], forms: [
            .init(#"\b[1-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y\d]\d-[AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y\d]\d-[AC-HJKMNP-RT-Y]{2}\d{2}\b"#, 0.5, alone: true),
            .init(#"\b[1-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y\d]\d[AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y\d]\d[AC-HJKMNP-RT-Y]{2}\d{2}\b"#, 0.3),
        ], context: ["mbi", "medicare", "beneficiary"], verifies: false, check: { $0.count == 11 }, draw: { _, rng in
            let letter = "ACDEFGHJKMNPQRTUVWXY"
            return characters([Int.random(in: 1...9, using: &rng)]) + [pick(letter, &rng), pick(letter + digits, &rng), pick(digits, &rng), pick(letter, &rng), pick(letter + digits, &rng), pick(digits, &rng), pick(letter, &rng), pick(letter, &rng), pick(digits, &rng), pick(digits, &rng)]
        }),
        Recognizer("TFN", keys: ["tfn", "taxfilenumber"], forms: [
            .init(#"\b\d{3} ?\d{3} ?\d{3}\b"#, 0.05),
        ], context: ["tfn", "tax file number"], check: { characters in
            guard let d = numbers(characters), d.count == 9 else { return false }
            return zip(d, [1, 4, 3, 7, 5, 8, 6, 9, 10]).reduce(0) { $0 + $1.0 * $1.1 } % 11 == 0
        }, draw: { _, rng in
            while true {
                let d = randomDigits(8, &rng)
                let partial = zip(d, [1, 4, 3, 7, 5, 8, 6, 9]).reduce(0) { $0 + $1.0 * $1.1 }
                if let last = (0...9).first(where: { (partial + $0 * 10) % 11 == 0 }) { return characters(d + [last]) }
            }
        }),
        Recognizer("AU_MEDICARE", keys: ["medicarecardnumber"], forms: [
            .init(#"\b[2-6]\d{3} ?\d{5} ?\d(?:[ /-]?\d)?\b"#, 0.05),
        ], context: ["medicare"], separators: " .-/", check: { characters in
            guard let d = numbers(characters), d.count == 10 || d.count == 11, (2...6).contains(d[0]) else { return false }
            return zip(d[0..<8], [1, 3, 7, 9, 1, 3, 7, 9]).reduce(0) { $0 + $1.0 * $1.1 } % 10 == d[8]
        }, draw: { like, rng in
            let d = [Int.random(in: 2...6, using: &rng)] + randomDigits(7, &rng)
            return characters(d + [zip(d, [1, 3, 7, 9, 1, 3, 7, 9]).reduce(0) { $0 + $1.0 * $1.1 } % 10] + [Int.random(in: 1...9, using: &rng)] + randomDigits(max(0, like.count - 10), &rng))
        }),
        Recognizer("EPIC", keys: ["epicnumber", "voterid", "voteridnumber", "votercardnumber"], forms: [
            .init(#"\b[A-Z]{3}\d{7}\b"#, 0.3),
        ], context: ["voter", "elector", "epic number", "epic card"], verifies: false, check: { $0.count == 10 }, draw: { _, rng in
            [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng)] + characters(randomDigits(7, &rng))
        }),
        Recognizer("THAI_ID", keys: ["thaiid", "thainationalid"], forms: [
            .init(#"\b[1-8]-\d{4}-\d{5}-\d{2}-\d\b"#, 0.5, alone: true),
            .init(#"\b[1-8]\d{12}\b"#, 0.05),
        ], context: ["บัตรประชาชน", "เลขประจำตัวประชาชน", "thai"], check: { characters in
            guard let d = numbers(characters), d.count == 13 else { return false }
            return thaiDigit(Array(d[0..<12])) == d[12]
        }, draw: { _, rng in
            let d = [Int.random(in: 1...8, using: &rng)] + randomDigits(11, &rng)
            return characters(d + [thaiDigit(d)])
        }),
        Recognizer("NIN", keys: ["nin", "ninnumber", "nimc", "nimcnumber"], forms: [
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["nin", "nimc"], check: { characters in
            guard let d = numbers(characters), d.count == 11 else { return false }
            return verhoeff(d) == 0
        }, draw: { _, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(9, &rng)
            return characters(d + [verhoeffDigit(d)])
        }),
        Recognizer("TEUDAT_ZEHUT", keys: ["teudatzehut", "zehut", "israeliid"], forms: [
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["zehut", "teudat", "תעודת", "זהות"], check: { characters in
            guard let d = numbers(characters), d.count == 9 else { return false }
            return Patterns.luhn(d)
        }, draw: { _, rng in
            let d = randomDigits(8, &rng)
            return characters(d + [luhnDigit(d)])
        }),
        Recognizer("PIS", keys: ["pis", "pispasep", "pasep", "pisnumber", "nis", "nisnumber"], forms: [
            .init(#"\b\d{3}\.\d{5}\.\d{2}-\d\b"#, 0.5, alone: true),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["pis", "pasep", "nis"], check: { characters in
            guard let d = numbers(characters), d.count == 11, Set(d).count > 1 else { return false }
            return pisDigit(Array(d[0..<10])) == d[10]
        }, draw: { _, rng in
            let d = [Int.random(in: 1...2, using: &rng)] + randomDigits(9, &rng)
            return characters(d + [pisDigit(d)])
        }),
        Recognizer("CLAVE_ELECTOR", keys: ["claveelector", "clavedeelector", "claveine"], forms: [
            .init(#"\b[A-Z]{6}\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|[12]\d|3[0-2])[HM]\d{3}\b"#, 0.5, alone: true),
        ], context: ["elector", "ine"], verifies: false, check: { $0.count == 18 }, draw: { _, rng in
            let date = randomDate(&rng)
            return [pick(consonants, &rng), pick("AEIOU", &rng), pick(consonants, &rng), pick("AEIOU", &rng), pick(consonants, &rng), pick("AEIOU", &rng)]
                + characters(twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + twoDigits(Int.random(in: 1...32, using: &rng))) + [pick("HM", &rng)] + characters(randomDigits(3, &rng))
        }),
        Recognizer("AR_DNI", forms: [
            .init(#"\b\d{1,2}\.\d{3}\.\d{3}\b"#, 0.1),
        ], context: ["dni", "documento"], verifies: false, check: { characters in
            (7...8).contains(characters.count) && numbers(characters) != nil
        }, draw: { like, rng in
            characters([Int.random(in: 1...9, using: &rng)] + randomDigits(max(0, like.count - 1), &rng))
        }),
        Recognizer("PASSPORT", forms: [
            .init(#"\b[A-Z]{1,2}\d{6,8}\b"#, 0.1),
        ], context: ["passport", "护照", "여권", "pasaporte", "passeport", "reisepass", "passaporto", "paspoort", "paszport", "passaporte"], verifies: false, check: { characters in
            let letters = characters.prefix { $0.isLetter }.count
            return (1...2).contains(letters) && (6...8).contains(characters.count - letters) && characters.dropFirst(letters).allSatisfy(\.isNumber)
        }, draw: { like, rng in
            like.map { $0.isLetter ? pick(letters, &rng) : pick(digits, &rng) }
        }),
        Recognizer("BITCOIN", entity: "CRYPTO", keys: ["btcaddress", "bitcoinaddress"], forms: [
            .init(#"\b[13][1-9A-HJ-NP-Za-km-z]{25,34}\b"#, 0.5, alone: true),
            .init(#"\b(?:bc1|BC1)[02-9ac-hj-np-zAC-HJ-NP-Z]{11,71}\b"#, 0.5, alone: true),
        ], context: ["wallet", "btc", "bitcoin", "crypto"], folds: false, separators: "", check: { characters in
            characters.first == "1" || characters.first == "3" ? base58Check(characters) : bech32Valid(String(characters))
        }, draw: { like, rng in
            like.first == "1" || like.first == "3" ? base58Draw(like, &rng) : bech32Draw(like, &rng)
        }),
        Recognizer("ETHEREUM", entity: "CRYPTO", keys: ["ethaddress", "ethereumaddress"], forms: [
            .init(#"\b0x[0-9a-fA-F]{40}\b"#, 0.3),
        // Its check is its length: a 20-byte hash is written the same way, so it is named or not one.
        ], context: ["wallet", "eth", "ethereum", "crypto"], folds: false, verifies: false, separators: "", check: { $0.count == 42 }, draw: { like, rng in
            Array("0x") + like.dropFirst(2).map { $0.isNumber ? pick(digits, &rng) : $0.isUppercase ? pick("ABCDEF", &rng) : pick("abcdef", &rng) }
        }),
        Recognizer("MAC_ADDRESS", keys: ["macaddress", "macaddr", "hardwareaddress", "bssid", "wifimac", "devicemac"], forms: [
            .init(#"(?<![0-9A-Fa-f:-])[0-9A-Fa-f]{2}([:-])(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])"#, 0.6, alone: true),
            .init(#"\b[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\b"#, 0.6, alone: true),
            .init(#"\b[0-9A-Fa-f]{12}\b"#, 0.05),
        ], context: ["mac", "hardware", "ethernet", "bssid", "wifi"], verifies: false, separators: ":-.", check: { characters in
            characters.count == 12 && characters.allSatisfy(\.isHexDigit) && Set(characters).count > 1
        }, draw: { _, rng in
            // Locally administered and unicast: the first octet's low bits are 10, so it is nobody's device.
            Array(String(format: "%02X", Int.random(in: 0...63, using: &rng) << 2 | 2)) + (0..<10).map { _ in pick("0123456789ABCDEF", &rng) }
        }),
    ]

    /// The kinds the registry finds.
    static let entities = Set(all.map(\.entity))
    /// Every key a recognizer is written under, and the kind it names (see `KeyHints.hint`).
    static let keyNames: [String: String] = all.reduce(into: [:]) { names, recognizer in
        for key in recognizer.keys where names[key] == nil { names[key] = recognizer.entity }
    }

    /// The recognizer a whole value is written as and passes the check of,
    /// one whose check is more than its shape first ("ZX4829137" is any
    /// document number's shape before it is a German ID card's).
    static func recognizing(_ value: String) -> Recognizer? { candidates(value).first }
    /// Every kind that writes `value` whole and passes it, those whose check verifies first.
    static func candidates(_ value: String) -> [Recognizer] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let length = (trimmed as NSString).length
        guard length >= 7, length <= 96 else { return [] }
        let matching = all.filter { $0.writes(trimmed) && $0.passes(trimmed) }
        return matching.filter(\.verifies) + matching.filter { !$0.verifies }
    }

    /// A fresh value of the kind `original` is, written as it is (its separators where they were, its letters in its case), which passes the same check in one of its forms.
    /// A kind known by its shape alone keeps its letters and digits where they were: its check can't tell another layout from a mistake.
    static func standIn(for original: String, using rng: inout any RandomNumberGenerator) -> String? {
        // A value two kinds write ("ZN26148285": a passport, or by chance a German card's number) takes the first that can draw one.
        for recognizer in candidates(original) {
            if let made = standIn(for: original, as: recognizer, using: &rng) { return made }
        }
        return nil
    }
    private static func standIn(for original: String, as recognizer: Recognizer, using rng: inout any RandomNumberGenerator) -> String? {
        let kept = recognizer.kept(original.trimmingCharacters(in: .whitespaces))
        let fits = { (characters: [Character]) -> Bool in
            // No zero leads one whose original had none: the same identifier may be written as a JSON number elsewhere.
            guard characters.first != "0" || kept.first == "0" else { return false }
            let written = write(characters, like: original, recognizer)
            return recognizer.passes(written) && recognizer.writes(written.trimmingCharacters(in: .whitespaces))
        }
        for _ in 0..<(recognizer.verifies ? 32 : 16) {
            let drawn = recognizer.draw(kept, &rng)
            guard drawn.count == kept.count, drawn != kept else { continue }
            if !recognizer.verifies, zip(drawn, kept).contains(where: { $0.isNumber != $1.isNumber }) { continue }
            if fits(drawn) { return write(drawn, like: original, recognizer) }
        }
        guard !recognizer.verifies, let last = kept.indices.last else { return nil }
        // Its own draw writes another layout: each character changed in turn, to one of its kind that
        // keeps the value in a form, its last one written again where that is a check digit.
        func pool(_ character: Character) -> [Character] { Array(character.isNumber ? digits : character.isLowercase ? letters.lowercased() : letters) }
        var characters = kept
        for index in characters.indices.dropLast() {
            let was = characters[index], end = characters[last]
            for _ in 0..<12 {
                guard let made = pool(was).randomElement(using: &rng), made != was else { continue }
                characters[index] = made
                if fits(characters) { break }
                if let ending = pool(end).shuffled(using: &rng).first(where: { characters[last] = $0; return fits(characters) }) { characters[last] = ending; break }
                characters[index] = was
                characters[last] = end
            }
        }
        return characters != kept && fits(characters) ? write(characters, like: original, recognizer) : nil
    }
    /// `characters` written in `original`'s layout: its separators where they were, its small letters small where the kind folds case.
    static func write(_ characters: [Character], like original: String, _ recognizer: Recognizer) -> String {
        var next = characters.makeIterator()
        return String(original.map { character -> Character in
            guard !recognizer.separators.contains(character), !character.isWhitespace, let made = next.next() else { return character }
            return recognizer.folds && character.isLowercase ? Character(made.lowercased()) : made
        })
    }

    /// The kind of identifier `value`, whole, is where `words` name it: it passes a kind's check in one of its forms and one of the words names that kind,
    /// as a key's words name a string under it ("kimlik": 89508837288).
    static func named(_ value: String, by words: Set<String>) -> String? {
        let ns = value as NSString
        return find(value, ns: ns, units: Array(value.utf16), contextWords: words, isCancelled: { false }).first { $0.range == 0..<ns.length && $0.score >= 1 }?.entity
    }

    /// Words that sit between a value and the word naming it without changing what it names ("the", "my", "de").
    private static let stopwords: Set<String> = ["the", "a", "an", "is", "are", "was", "my", "your", "his", "her", "their", "our", "its", "of", "for", "to", "no", "nr", "de", "del", "la", "el", "le", "les", "der", "die", "das", "des", "und", "y", "e", "et", "du", "da", "do", "dos", "di", "il", "van", "het", "och", "og", "i"]
    /// Whether one of `context` is among `words`: a single word as written, several in a row.
    static func names(_ context: Set<String>, in words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let set = Set(words)
        return context.contains { entry in
            guard entry.contains(" ") else { return set.contains(entry) }
            let parts = entry.split(separator: " ").map(String.init)
            guard parts.count <= words.count else { return false }
            return (0...(words.count - parts.count)).contains { start in Array(words[start..<(start + parts.count)]) == parts }
        }
    }
    /// The words before `range` that may name it, stopwords left out, nearest five.
    private static func before(_ range: Range<Int>, in text: String) -> [String] {
        Array(Context.words(before: range.lowerBound, in: text, limit: 10).map { $0.lowercased() }.filter { !stopwords.contains($0) }.suffix(5))
    }

    /// Identifiers in `text`: one passing its check in a form that needs no
    /// naming word scores 0.85, one named by a word before it or by its key
    /// scores 1, as validated and context-supported results do, a
    /// bare one keeps its form's score, and one failing its check is none.
    static func find(_ text: String, ns: NSString, units: [UInt16], contextWords: Set<String>, isCancelled: () -> Bool) -> [Span] {
        var spans: [Span] = []
        for recognizer in all {
            if isCancelled() { return spans }
            for form in recognizer.forms {
                guard let regex = form.pattern.regex else { continue }
                for match in Patterns.matches(regex, in: ns, units: units, isCancelled: isCancelled) {
                    let range = match.range.location..<NSMaxRange(match.range)
                    guard recognizer.passes(ns.substring(with: match.range)) else { continue }
                    // A key's words name it in any order ("number_nhs"); words in text, in theirs.
                    let named = recognizer.context.contains { Set($0.split(separator: " ").map(String.init)).isSubset(of: contextWords) }
                        || names(recognizer.context, in: before(range, in: text))
                    let score = named ? 1 : form.alone ? 0.85 : form.score
                    if score >= 0.4 { spans.append(Span(range: range, entity: recognizer.entity, score: score)) }
                }
            }
        }
        return spans
    }

    // MARK: Checks

    private static let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let consonants = "BCDFGHJKLMNPRSTVZ"
    private static let digits = "0123456789"
    private static let hetuMarks = Array("0123456789ABCDEFHJKLMNPRSTUVWXY")

    private static func numbers(_ characters: [Character]) -> [Int]? {
        let values = characters.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
        return values.count == characters.count ? values : nil
    }
    private static func number(_ digits: [Int]) -> Int { digits.reduce(0) { $0 * 10 + $1 } }
    private static func characters(_ digits: [Int]) -> [Character] { digits.map { Character(String($0)) } }
    private static func twoDigits(_ value: Int) -> [Int] { [value / 10 % 10, value % 10] }
    private static func realDate(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }
    private static func cpfDigit(_ digits: ArraySlice<Int>) -> Int {
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * (digits.count + 1 - $1.offset) }
        let rest = sum * 10 % 11
        return rest == 10 ? 0 : rest
    }
    private static func cuilDigit(_ digits: ArraySlice<Int>) -> Int? {
        let rest = 11 - zip(digits, [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest == 11 ? 0 : rest == 10 ? nil : rest
    }
    private static func rutDigit(_ body: [Int]) -> Character {
        let sum = body.reversed().enumerated().reduce(0) { $0 + $1.element * [2, 3, 4, 5, 6, 7][$1.offset % 6] }
        let rest = 11 - sum % 11
        return rest == 11 ? "0" : rest == 10 ? "K" : Character(String(rest))
    }
    private static let curpAlphabet = Array("0123456789ABCDEFGHIJKLMNÑOPQRSTUVWXYZ")
    private static func curpDigit(_ characters: ArraySlice<Character>) -> Int {
        let sum = characters.enumerated().reduce(0) { $0 + (curpAlphabet.firstIndex(of: $1.element) ?? 0) * (18 - $1.offset) }
        return (10 - sum % 10) % 10
    }
    private static let rfcAlphabet = Array("0123456789ABCDEFGHIJKLMN&OPQRSTUVWXYZ Ñ")
    private static func rfcDigit(_ characters: ArraySlice<Character>) -> Character {
        let rest = characters.enumerated().reduce(0) { $0 + (rfcAlphabet.firstIndex(of: $1.element) ?? 0) * (13 - $1.offset) } % 11
        return rest == 0 ? "0" : rest == 1 ? "A" : Character(String(11 - rest))
    }
    private static let fiscalOdd: [Character: Int] = Dictionary(uniqueKeysWithValues: Array(zip(Array("0123456789"), [1, 0, 5, 7, 9, 13, 15, 17, 19, 21])) + Array(zip(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), [1, 0, 5, 7, 9, 13, 15, 17, 19, 21, 2, 4, 18, 20, 11, 3, 6, 8, 12, 14, 16, 10, 22, 25, 24, 23])))
    private static func fiscalLetter(_ characters: ArraySlice<Character>) -> Character {
        let sum = characters.enumerated().reduce(0) { total, item in
            let value = item.offset % 2 == 0 ? fiscalOdd[item.element] ?? 0 : item.element.wholeNumberValue ?? Int((item.element.asciiValue ?? 65) - 65)
            return total + value
        }
        return Array(letters)[sum % 26]
    }
    private static func dniLetter(_ value: Int) -> Character { Array("TRWAGMYFPDXBNJZSQVHLCKE")[value % 23] }
    /// ISO 7064 MOD 11,10.
    private static func steuerDigit(_ digits: ArraySlice<Int>) -> Int {
        var product = 10
        for digit in digits {
            var sum = (digit + product) % 10
            if sum == 0 { sum = 10 }
            product = 2 * sum % 11
        }
        let check = 11 - product
        return check == 10 ? 0 : check
    }
    private static func norwayDigit(_ digits: ArraySlice<Int>, _ weights: [Int]) -> Int? {
        let rest = 11 - zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest == 11 ? 0 : rest == 10 ? nil : rest
    }
    private static func residentMark(_ digits: [Int]) -> Character {
        Array("10X98765432")[zip(digits, [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11]
    }
    private static func tcknTenth(_ d: [Int]) -> Int {
        (((d[0] + d[2] + d[4] + d[6] + d[8]) * 7 - (d[1] + d[3] + d[5] + d[7])) % 10 + 10) % 10
    }
    private static func luhnDigit(_ body: [Int]) -> Int { (0...9).first { Patterns.luhn(body + [$0]) } ?? 0 }
    private static let verhoeffD: [[Int]] = [[0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],[3,4,0,1,2,8,9,5,6,7],[4,0,1,2,3,9,5,6,7,8],[5,9,8,7,6,0,4,3,2,1],[6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],[8,7,6,5,9,3,2,1,0,4],[9,8,7,6,5,4,3,2,1,0]]
    private static let verhoeffP: [[Int]] = [[0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],[8,9,1,6,0,4,3,5,2,7],[9,4,5,3,1,2,6,8,7,0],[4,2,8,6,5,7,3,9,0,1],[2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,3,2,5,8]]
    private static func verhoeff(_ digits: [Int]) -> Int {
        digits.reversed().enumerated().reduce(0) { verhoeffD[$0][verhoeffP[$1.offset % 8][$1.element]] }
    }
    private static func verhoeffDigit(_ body: [Int]) -> Int { (0...9).first { verhoeff(body + [$0]) == 0 } ?? 0 }

    private static func nricLetter(_ lead: Character, _ digits: [Int]) -> Character? {
        let sum = zip(digits, [2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } + ("TG".contains(lead) ? 4 : lead == "M" ? 3 : 0)
        switch lead {
        case "S", "T": return Array("JZIHGFEDCBA")[sum % 11]
        case "F", "G": return Array("XWUTRQPNMLK")[sum % 11]
        // Issued from 2022, read off its own table backwards (as the government's own forms check it).
        case "M": return Array("KLJNPQRTUWX")[10 - sum % 11]
        default: return nil
        }
    }
    private static func alnumValue(_ character: Character) -> Int? {
        if let digit = character.wholeNumberValue, character.isASCII { return digit }
        guard let ascii = character.asciiValue, (65...90).contains(ascii) else { return nil }
        return Int(ascii) - 55
    }
    private static func hkidMark(_ body: [Character]) -> Character? {
        guard body.count == 7 || body.count == 8 else { return nil }
        let padded = body.count == 7 ? [nil] + body.map { Optional($0) } : body.map { Optional($0) }
        var sum = 0
        for (character, weight) in zip(padded, [9, 8, 7, 6, 5, 4, 3, 2]) {
            guard let character else { sum += 36 * weight; continue }
            guard let value = alnumValue(character) else { return nil }
            sum += value * weight
        }
        let rest = (11 - sum % 11) % 11
        return rest == 10 ? "A" : Character(String(rest))
    }
    private static let taiwanLetters: [Character: Int] = ["A": 10, "B": 11, "C": 12, "D": 13, "E": 14, "F": 15, "G": 16, "H": 17, "I": 34, "J": 18, "K": 19, "L": 20, "M": 21, "N": 22, "O": 35, "P": 23, "Q": 24, "R": 25, "S": 26, "T": 27, "U": 28, "V": 29, "W": 32, "X": 30, "Y": 31, "Z": 33]
    private static func myNumberDigit(_ body: [Int]) -> Int {
        let sum = (1...11).reduce(0) { $0 + body[11 - $1] * ($1 <= 6 ? $1 + 1 : $1 - 5) }
        let rest = sum % 11
        return rest <= 1 ? 0 : 11 - rest
    }
    /// ICAO 9303's check: weights 7, 3, 1 over values, a letter worth 10 to 35.
    private static func icaoDigit(_ characters: [Character]) -> Int {
        characters.enumerated().reduce(0) { $0 + (alnumValue($1.element) ?? 0) * [7, 3, 1][$1.offset % 3] } % 10
    }
    private static func crossSum(_ value: Int) -> Int { value / 10 + value % 10 }
    private static func kvnrDigit(_ letter: Int, _ digits: [Int]) -> Int {
        ([letter / 10, letter % 10] + digits).enumerated().reduce(0) { $0 + crossSum($1.element * ($1.offset % 2 == 0 ? 1 : 2)) } % 10
    }
    private static func rvnrDigit(_ head: [Int], _ letter: Int, _ serial: [Int]) -> Int {
        zip(head + [letter / 10, letter % 10] + serial, [2, 1, 2, 5, 7, 1, 2, 1, 2, 1, 2, 1]).reduce(0) { $0 + crossSum($1.0 * $1.1) } % 10
    }
    private static func deaDigit(_ d: [Int]) -> Int { (d[0] + d[2] + d[4] + 2 * (d[1] + d[3] + d[5])) % 10 }
    private static func thaiDigit(_ body: [Int]) -> Int {
        let rest = body.enumerated().reduce(0) { $0 + $1.element * (13 - $1.offset) } % 11
        return rest <= 1 ? 1 - rest : 11 - rest
    }
    private static func pisDigit(_ body: [Int]) -> Int {
        let rest = 11 - zip(body, [3, 2, 9, 8, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest >= 10 ? 0 : rest
    }

    // MARK: Addresses of wallets

    private static let base58 = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static func base58Bytes(_ characters: [Character]) -> [UInt8]? {
        var bytes: [UInt8] = []
        for character in characters {
            guard var carry = base58.firstIndex(of: character) else { return nil }
            for index in bytes.indices.reversed() {
                carry += Int(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 { bytes.insert(UInt8(carry & 0xff), at: 0); carry >>= 8 }
        }
        return Array(repeating: 0, count: characters.prefix { $0 == "1" }.count) + bytes
    }
    private static func base58Text(_ bytes: [UInt8]) -> [Character] {
        var digits: [Int] = []
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                carry += digits[index] << 8
                digits[index] = carry % 58
                carry /= 58
            }
            while carry > 0 { digits.append(carry % 58); carry /= 58 }
        }
        return Array(repeating: "1", count: bytes.prefix { $0 == 0 }.count) + digits.reversed().map { base58[$0] }
    }
    private static func doubleSHA(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: Data(SHA256.hash(data: Data(bytes))))) }
    /// A legacy address: a version byte and 20 bytes of hash, then the first four bytes of their double SHA-256.
    private static func base58Check(_ characters: [Character]) -> Bool {
        guard let bytes = base58Bytes(characters), bytes.count == 25 else { return false }
        return Array(doubleSHA(Array(bytes[0..<21])).prefix(4)) == Array(bytes[21...])
    }
    private static func base58Draw(_ like: [Character], _ rng: inout any RandomNumberGenerator) -> [Character] {
        let version: UInt8 = like.first == "3" ? 5 : 0
        var made: [Character] = []
        for _ in 0..<64 {
            let payload = [version] + (0..<20).map { _ in UInt8.random(in: 0...255, using: &rng) }
            made = base58Text(payload + doubleSHA(payload).prefix(4))
            if made.count == like.count { return made }
        }
        return made
    }
    private static let bech32Alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static func polymod(_ values: [Int]) -> Int {
        let generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var check = 1
        for value in values {
            let top = check >> 25
            check = (check & 0x1ffffff) << 5 ^ value
            for index in 0..<5 where (top >> index) & 1 == 1 { check ^= generator[index] }
        }
        return check
    }
    private static func expanded(_ prefix: String) -> [Int] {
        let values = prefix.unicodeScalars.map { Int($0.value) }
        return values.map { $0 >> 5 } + [0] + values.map { $0 & 31 }
    }
    /// A segwit address: Bech32 for version 0, Bech32m after (BIP 173, BIP 350).
    private static func bech32Valid(_ value: String) -> Bool {
        guard value == value.lowercased() || value == value.uppercased() else { return false }
        let lower = value.lowercased()
        guard let separator = lower.lastIndex(of: "1"), lower.count <= 90 else { return false }
        let prefix = String(lower[..<separator])
        var data: [Int] = []
        for character in lower[lower.index(after: separator)...] {
            guard let index = bech32Alphabet.firstIndex(of: character) else { return false }
            data.append(index)
        }
        guard !prefix.isEmpty, data.count >= 7 else { return false }
        let check = polymod(expanded(prefix) + data)
        return check == (data[0] == 0 ? 1 : 0x2bc830a3)
    }
    private static func bech32Draw(_ like: [Character], _ rng: inout any RandomNumberGenerator) -> [Character] {
        let upper = like.contains { $0.isUppercase }
        let count = max(7, like.count - 3 - 6)
        let version = like.count > 3 ? bech32Alphabet.firstIndex(of: Character(like[3].lowercased())) ?? 0 : 0
        var data = [version] + (1..<count).map { _ in Int.random(in: 0...31, using: &rng) }
        // The program's bits past its last whole byte are zero.
        let spare = (count - 1) * 5 % 8
        data[count - 1] &= ~((1 << spare) - 1)
        let mod = polymod(expanded("bc") + data + [0, 0, 0, 0, 0, 0]) ^ (version == 0 ? 1 : 0x2bc830a3)
        let made = Array("bc1") + (data + (0..<6).map { (mod >> (5 * (5 - $0))) & 31 }).map { bech32Alphabet[$0] }
        return upper ? made.map { Character($0.uppercased()) } : made
    }

    // MARK: Drawing

    private static func randomDigits(_ count: Int, _ rng: inout any RandomNumberGenerator) -> [Int] {
        (0..<count).map { _ in Int.random(in: 0...9, using: &rng) }
    }
    private static func pick(_ from: String, _ rng: inout any RandomNumberGenerator) -> Character {
        Array(from).randomElement(using: &rng) ?? "A"
    }
    /// A birth date of an adult, its day at most the 28th so any month holds it.
    private static func randomDate(_ rng: inout any RandomNumberGenerator) -> (year: Int, month: Int, day: Int) {
        (Int.random(in: 1950...1999, using: &rng), Int.random(in: 1...12, using: &rng), Int.random(in: 1...28, using: &rng))
    }
}
