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
    /// A kind that folds case is written by a form in small letters too ("x9613851n").
    func writes(_ value: String) -> Bool {
        let value = folds && value.allSatisfy(\.isASCII) ? value.uppercased() : value
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
        }, draw: { like, rng in
            // X, Y or Z, as the original's.
            let lead = like.first.flatMap { "XYZ".firstIndex(of: $0) }.map { "XYZ".distance(from: "XYZ".startIndex, to: $0) } ?? Int.random(in: 0...1, using: &rng)
            let d = randomDigits(7, &rng)
            return [Array("XYZ")[lead]] + characters(d) + [dniLetter(lead * 10_000_000 + number(d))]
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
        ], context: ["steuerid", "steueridentifikationsnummer", "idnr", "identifikationsnummer"], check: { characters in
            guard let d = numbers(characters), d.count == 11, d[0] != 0 else { return false }
            // Exactly one digit written twice or three times, the three never all side by side (the BZSt's rule).
            let counts = Dictionary(grouping: d[0..<10], by: { $0 }).mapValues(\.count)
            let repeated = counts.filter { $0.value > 1 }
            guard repeated.count == 1, let (digit, times) = repeated.first, times <= 3 else { return false }
            if times == 3, (0..<8).contains(where: { d[$0] == digit && d[$0 + 1] == digit && d[$0 + 2] == digit }) { return false }
            return steuerDigit(d[0..<10]) == d[10]
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
            // Its month carries its century: 81–92 the 1800s, 01–12 the 1900s, then 20 more for each century after.
            let coded = d[2] * 10 + d[3], centuries = [8: 1800, 0: 1900, 2: 2000, 4: 2100, 6: 2200]
            guard let century = centuries[coded / 20 * 2], realDate(year: century + d[0] * 10 + d[1], month: coded % 20, day: d[4] * 10 + d[5]) else { return false }
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
            // A coordination number's day has 60 added; the century is the long spelling's, else either.
            let year = d[0] * 10 + d[1], month = d[2] * 10 + d[3], written = d[4] * 10 + d[5], day = written > 60 ? written - 60 : written
            let centuries = all.count == 12 ? [all[0] * 1000 + all[1] * 100] : [1900, 2000]
            return centuries.contains { realDate(year: $0 + year, month: month, day: day) } && Patterns.luhn(d)
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
        ], context: ["hetu", "henkilötunnus", "henkilotunnus", "personbeteckning", "personal identity code"], separators: " ", check: { characters in
            guard characters.count == 11, let d = numbers(Array(characters[0..<6]) + Array(characters[7..<10])) else { return false }
            let century: Int
            switch characters[6] {
            case "+": century = 1800
            case "-", "U", "V", "W", "X", "Y": century = 1900
            default: century = 2000
            }
            guard realDate(year: century + d[4] * 10 + d[5], month: d[2] * 10 + d[3], day: d[0] * 10 + d[1]) else { return false }
            return hetuMarks[number(d) % 31] == characters[10]
        }, draw: { like, rng in
            // Its century sign, as the original's: "-" or a letter of the same century.
            let sign = like.count == 11 && "-+ABCDEFUVWXY".contains(like[6]) ? like[6] : "-"
            let date = randomDate(&rng)
            let d = twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + [0] + twoDigits(Int.random(in: 2...89, using: &rng))
            return characters(Array(d[0..<6])) + [sign] + characters(Array(d[6...])) + [hetuMarks[number(d) % 31]]
        }),
        Recognizer("NINO", keys: ["nino", "nationalinsurancenumber", "ninumber"], forms: [
            .init(#"\b(?!BG|GB|NK|KN|NT|TN|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?\d{2} ?\d{2} ?\d{2} ?[A-D]\b"#, 0.3),
        ], context: ["nino", "national insurance", "ni number"], verifies: false, check: { $0.count == 9 }, draw: { _, rng in
            [pick("ABCEGHJKLMPRSTWXY", &rng), pick("ABCEHJLMPRSTWXY", &rng)] + characters(randomDigits(6, &rng)) + [pick("ABCD", &rng)]
        }),
        Recognizer("NHS_NUMBER", keys: ["nhs", "nhsnumber", "nhsno"], forms: [
            .init(#"\b\d{3}[- ]?\d{3}[- ]?\d{4}\b"#, 0.05),
        ], context: ["nhs", "national health service"], check: { characters in
            guard let d = numbers(characters), d.count == 10, Set(d).count > 1 else { return false }
            return zip(d, (1...10).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 11 == 0
        }, draw: { _, rng in
            while true {
                let d = [Int.random(in: 4...6, using: &rng)] + randomDigits(8, &rng)
                let last = (11 - zip(d, (2...10).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 11
                if last < 10 { return characters(d + [last]) }
            }
        }),
        Recognizer("SIN", keys: ["sin", "socialinsurancenumber", "sinnumber"], forms: [
            .init(#"\b[1-79]\d{2}([- ]?)\d{3}\1\d{3}\b"#, 0.05),
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
        ], context: ["pan", "permanent account number"], verifies: false, check: { $0.count == 10 && String($0[5..<9]) != "0000" }, draw: { _, rng in
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
        ], context: ["rrn", "주민등록번호", "외국인등록번호", "주민번호", "외국인번호", "resident registration number", "foreigner registration number", "frn"], verifies: false, check: { characters in
            guard let d = numbers(characters), d.count == 13 else { return false }
            let century = [9: 1800, 0: 1800, 1: 1900, 2: 1900, 5: 1900, 6: 1900, 3: 2000, 4: 2000, 7: 2000, 8: 2000][d[6]] ?? 1900
            return realDate(year: century + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5])
        }, draw: { like, rng in
            // Its seventh digit says citizen or foreigner and the century: kept, as is the foreigner's own check.
            let kind = like.count == 13 ? like[6].wholeNumberValue.flatMap { (1...8).contains($0) ? $0 : nil } : nil
            let date = randomDate(&rng)
            let seventh = kind ?? Int.random(in: 1...2, using: &rng)
            var d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + [seventh] + randomDigits(5, &rng)
            let sum = zip(d, [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5]).reduce(0) { $0 + $1.0 * $1.1 }
            d.append(((5...8).contains(seventh) ? 13 - sum % 11 : 11 - sum % 11) % 10)
            return characters(d)
        }),
        Recognizer("SOUTH_AFRICAN_ID", keys: ["rsaid", "saidnumber", "southafricanid"], forms: [
            .init(#"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{4}[012][89]\d\b"#, 0.05),
        ], context: ["identity", "rsa", "south african id", "rsa id", "smart id", "identity number"], check: { characters in
            // Citizen, permanent resident or refugee, then 8 or 9; born in either century (29 February 2000 is a day).
            guard let d = numbers(characters), d.count == 13, d[10] <= 2, d[11] == 8 || d[11] == 9 else { return false }
            let year = d[0] * 10 + d[1], month = d[2] * 10 + d[3], day = d[4] * 10 + d[5]
            return (realDate(year: 1900 + year, month: month, day: day) || realDate(year: 2000 + year, month: month, day: day)) && Patterns.luhn(d)
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(4, &rng) + [0, 8]
            return characters(d + [luhnDigit(d)])
        }),
        Recognizer("TCKN", keys: ["tckn", "tckimlikno", "kimlikno", "tcno", "tckimlik", "kimliknumarasi"], forms: [
            .init(#"\b[1-9]\d{10}\b"#, 0.05),
        ], context: ["tckn", "kimlik", "tc no", "nüfus cüzdanı", "turkish id", "türk kimlik"], check: { characters in
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
            // As printed on the card: surname, date, initials and check, a space between each.
            .init(#"\b[A-Z9]{5} \d(?:[05][1-9]|[16][0-2])(?:0[1-9]|[12]\d|3[01])\d [A-Z9]{2}\d[A-Z]{2}\b"#, 0.5, alone: true),
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
        ], context: ["personalausweis", "ausweis", "ausweisnummer", "personalausweisnummer", "reisepass", "passnummer", "pass nr", "reisepassnummer", "dokumentennummer", "bundespersonalausweis", "ausweisdokument", "npa"], verifies: false, check: { characters in
            guard characters.count == 9 || characters.count == 10, characters.contains(where: \.isNumber) else { return false }
            guard characters.count == 10 else { return true }
            return icaoDigit(Array(characters[0..<9])) == characters[9].wholeNumberValue
        }, draw: { like, rng in
            let body = [pick("CFGHJKLMNPRTVWXYZ", &rng)] + (0..<7).map { _ in pick("CFGHJKLMNPRTVWXYZ0123456789", &rng) } + [pick(digits, &rng)]
            return like.count == 10 ? body + characters([icaoDigit(body)]) : body
        }),
        Recognizer("KVNR", keys: ["kvnr", "krankenversichertennummer", "versichertennummer", "krankenversicherungsnummer"], forms: [
            .init(#"\b[A-Z]\d{9}\b"#, 0.3),
        ], context: ["krankenversichertennummer", "versichertennummer", "kvnr", "krankenversicherung", "krankenkasse", "gesundheitskarte", "egk"], check: { characters in
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
            // Its birth day (50 added past a first number), then its month.
            let day = head[2] * 10 + head[3], month = head[4] * 10 + head[5]
            guard (1...31).contains(day) || (51...81).contains(day), (1...12).contains(month) else { return false }
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
            guard let d = numbers(characters), d.count == 9, Set(d).count > 1 else { return false }
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
        ], context: ["voter", "elector", "epic number", "epic card", "elector photo identity card"], verifies: false, check: { $0.count == 10 }, draw: { _, rng in
            [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng)] + characters(randomDigits(7, &rng))
        }),
        Recognizer("THAI_ID", keys: ["thaiid", "thainationalid"], forms: [
            .init(#"\b[1-8]-\d{4}-\d{5}-\d{2}-\d\b"#, 0.5, alone: true),
            .init(#"\b[1-8]\d{12}\b"#, 0.05),
        ], context: ["บัตรประชาชน", "เลขประจำตัวประชาชน", "เลขบัตรประชาชน", "thai", "tnin", "thai national id"], check: { characters in
            // Its second and third digits are a province's code (ISO 3166-2:TH).
            guard let d = numbers(characters), d.count == 13, thaiProvinces.contains(d[1] * 10 + d[2]) else { return false }
            return thaiDigit(Array(d[0..<12])) == d[12]
        }, draw: { _, rng in
            let province = thaiProvinces.randomElement(using: &rng) ?? 10
            let d = [Int.random(in: 1...8, using: &rng), province / 10, province % 10] + randomDigits(9, &rng)
            return characters(d + [thaiDigit(d)])
        }),
        Recognizer("NIN", keys: ["nin", "ninnumber", "nimc", "nimcnumber"], forms: [
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["nin", "nimc", "national identification number", "national identity number", "nigeria id", "nigerian identification"], check: { characters in
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
            // A Philippine passport's letter, seven digits and letter.
            .init(#"\b[A-Z]\d{7}[A-Z]\b"#, 0.1),
            // An Indian passport printed with a space: "A12 34567".
            .init(#"\b[A-Z][1-9]\d \d{4}[1-9]\b"#, 0.1),
        ], context: ["passport", "护照", "여권", "pasaporte", "passeport", "reisepass", "passaporto", "paspoort", "paszport", "passaporte", "travel document", "hm passport", "hmpo", "dfa"], verifies: false, check: { characters in
            if characters.count == 9, characters[0].isLetter, characters[8].isLetter, numbers(Array(characters[1..<8])) != nil { return true }
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
        // Germany, Sweden and Spain.
        Recognizer("DE_BSNR", entity: "MEDICAL_LICENSE", keys: ["bsnr", "betriebsstaettennummer", "betriebsstattennummer", "betriebsstttennummer"], forms: [
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["bsnr", "betriebsstätte", "betriebsstaette", "betriebsstättennummer", "praxisnummer"], verifies: false, separators: "", check: { characters in
            guard let d = numbers(characters), d.count == 9 else { return false }
            return bsnrAreas.contains(d[0] * 10 + d[1]) && d[2...].contains { $0 != 0 }
        }, draw: { like, rng in
            // The first two digits are a KV region's (or 35 and 75 for the special ranges): the original's is kept.
            let lead = numbers(Array(like.prefix(2))) ?? []
            let area: Int
            if lead.count == 2, bsnrAreas.contains(lead[0] * 10 + lead[1]) {
                area = lead[0] * 10 + lead[1]
            } else {
                area = bsnrAreas.filter { ($0 < 10) == (like.first == "0") }.randomElement(using: &rng) ?? 72
            }
            return characters(twoDigits(area) + randomDigits(7, &rng))
        }),
        Recognizer("DE_LANR", entity: "MEDICAL_LICENSE", keys: ["lanr", "arztnummer", "lebenslangearztnummer"], forms: [
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["lanr", "arztnummer"], separators: "", check: { characters in
            guard let d = numbers(characters), d.count == 9 else { return false }
            return lanrDigit(Array(d[0..<6])) == d[6]
        }, draw: { like, rng in
            let body = randomDigits(6, &rng)
            // Digits 8 and 9 are the physician group (Arztgruppenschlüssel), not the person: kept.
            var group = randomDigits(2, &rng)
            if like.count == 9, let kept = numbers(Array(like[7...])) { group = kept }
            return characters(body + [lanrDigit(body)] + group)
        }),
        Recognizer("DE_DRIVING_LICENCE", keys: ["fuehrerscheinnummer", "fuhrerscheinnummer", "fhrerscheinnummer", "fahrerlaubnisnummer"], forms: [
            .init(#"\b[A-P]\d{2}[0-9A-Z]{6}[0-9X][0-9A-Z]\b"#, 0.3),
        ], context: ["führerschein", "fuehrerschein", "fahrerlaubnis", "driving licence", "driving license", "driver's license", "drivers license"], separators: " ", check: { characters in
            guard characters.count == 11, "ABCDEFGHIJKLMNOP".contains(characters[0]), characters[1].isASCII, characters[1].isNumber,
                  characters[2].isASCII, characters[2].isNumber, characters[10].isASCII, alnumValue(characters[10]) != nil,
                  let mark = licenceMark(Array(characters[0..<9])) else { return false }
            return mark == characters[9]
        }, draw: { like, rng in
            // The Land's letter is kept; the serial's letters and digits stay where the original had them.
            let lead = like.first.flatMap { "ABCDEFGHIJKLMNOP".contains($0) ? $0 : nil } ?? pick("ABCDEFGHIJKLMNOP", &rng)
            var body: [Character] = [lead, pick(digits, &rng), pick(digits, &rng)]
            for index in 3..<9 { body.append(like.count == 11 && like[index].isLetter ? pick(letters, &rng) : pick(digits, &rng)) }
            let issue = like.count == 11 && like[10].isLetter ? pick(letters, &rng) : pick("123456789", &rng)
            return body + [licenceMark(body) ?? "0", issue]
        }),
        Recognizer("DE_HANDELSREGISTER", keys: ["handelsregisternummer", "handelsregister", "hrnummer", "hrbnummer", "hranummer"], forms: [
            .init(#"\bHR[AB] ?[1-9]\d{0,5}\b"#, 0.3),
        ], context: ["handelsregister", "amtsgericht", "registergericht", "registernummer"], verifies: false, separators: " ", check: { characters in
            guard (4...9).contains(characters.count), characters[0] == "H", characters[1] == "R", characters[2] == "A" || characters[2] == "B",
                  let d = numbers(Array(characters[3...])) else { return false }
            return d[0] != 0
        }, draw: { like, rng in
            let head: [Character] = like.count >= 3 && like[0] == "H" && like[1] == "R" && (like[2] == "A" || like[2] == "B") ? Array(like[0..<3]) : ["H", "R", "B"]
            let count = min(6, max(1, like.count - 3))
            return head + characters([Int.random(in: 1...9, using: &rng)] + randomDigits(count - 1, &rng))
        }),
        Recognizer("DE_LICENCE_PLATE", keys: ["kfzkennzeichen", "kraftfahrzeugkennzeichen", "fahrzeugkennzeichen", "amtlicheskennzeichen", "nummernschild"], forms: [
            .init(#"(?<![\w-])[A-ZÄÖÜ]{1,3}(?:-[A-Z]{1,2}[ -]| [A-Z]{1,2} )[1-9]\d{0,3}[EH]?(?![\w-])"#, 0.3),
        ], context: ["kennzeichen", "kfz", "nummernschild", "amtliches kennzeichen", "license plate", "licence plate", "number plate"], verifies: false, separators: " -", check: { characters in
            // District and recognition letters (2 to 5 in all), 1 to 4 digits without a leading zero, at most 8 together, then E or H.
            var rest = characters[...]
            if let last = rest.last, last == "E" || last == "H", rest.dropLast().last?.isNumber == true { rest = rest.dropLast() }
            let letterCount = rest.prefix { $0.isLetter && $0.isUppercase }.count
            let digitPart = Array(rest.dropFirst(letterCount))
            guard (2...5).contains(letterCount), (1...4).contains(digitPart.count), letterCount + digitPart.count <= 8,
                  let d = numbers(digitPart) else { return false }
            return d[0] != 0
        }, draw: { like, rng in
            guard !like.isEmpty else { return ["B", "A", "B", "1", "2", "3", "4"] }
            var made: [Character] = []
            var seenDigit = false
            for (index, character) in like.enumerated() {
                if character.isNumber {
                    made.append(seenDigit ? pick(digits, &rng) : pick("123456789", &rng))
                    seenDigit = true
                } else if seenDigit, index == like.count - 1, character == "E" || character == "H" {
                    made.append(character)
                } else {
                    made.append(pick(letters, &rng))
                }
            }
            return made
        }),
        Recognizer("DE_PLZ", entity: "POSTAL_CODE", keys: ["plz", "postleitzahl"], forms: [
            .init(#"\b(?!01000\b|99999\b)(?:0[1-9]\d{3}|[1-9]\d{4})\b"#, 0.05),
        ], context: ["plz", "postleitzahl"], verifies: false, separators: "", check: { characters in
            guard let d = numbers(characters), d.count == 5 else { return false }
            return (1001...99998).contains(number(d))
        }, draw: { like, rng in
            let value = like.first == "0" ? Int.random(in: 1001...9999, using: &rng) : Int.random(in: 10000...99998, using: &rng)
            return characters([value / 10000, value / 1000 % 10, value / 100 % 10, value / 10 % 10, value % 10])
        }),
        Recognizer("STEUERNUMMER", keys: ["steuernummer", "steuernr", "stnr"], forms: [
            .init(#"\b(?:1[01]|2[1-46-8]|3[0-2]|4[01]|[59]\d)\d{2}0\d{8}\b"#, 0.05),
            .init(#"\b\d{2,3}/\d{3}/\d{5}\b"#, 0.3),
            .init(#"\b\d{3}/\d{4}/\d{4}\b"#, 0.3),
        ], context: ["steuernummer", "stnr", "finanzamt"], verifies: false, separators: "/", check: { characters in
            guard let d = numbers(characters) else { return false }
            // The federal 13-digit scheme opens with a Land's prefix and has a 0 in the fifth place; a Land's own spelling is 10 or 11 digits.
            if d.count == 13 { return steuernummerPrefixes.contains { d.starts(with: $0) } && d[4] == 0 }
            return d.count == 10 || d.count == 11
        }, draw: { like, rng in
            if like.count == 13 {
                let lead = numbers(Array(like.prefix(2))) ?? []
                let prefix = lead.count == 2 && steuernummerPrefixes.contains { lead.starts(with: $0) } ? lead : [2, 8]
                return characters(prefix + randomDigits(2, &rng) + [0] + randomDigits(8, &rng))
            }
            // The first digit marks the Land's spelling ("0FF", "1FF", "2FF"): kept.
            let count = like.count == 10 ? 10 : 11
            let first = like.first?.wholeNumberValue ?? Int.random(in: 1...9, using: &rng)
            return characters([first] + randomDigits(count - 1, &rng))
        }),
        Recognizer("DE_VAT_ID", keys: ["ustidnr", "ustid", "umsatzsteuerid", "umsatzsteueridentifikationsnummer", "vatid", "vatnumber"], forms: [
            .init(#"\b[Dd][Ee][ .-]?\d{3}[ .-]?\d{3}[ .-]?\d{3}\b"#, 0.3),
        ], context: ["ust", "ustidnr", "umsatzsteuer", "vat", "mehrwertsteuer", "mwst"], separators: " .-", check: { characters in
            guard characters.count == 11, characters[0] == "D", characters[1] == "E", let d = numbers(Array(characters[2...])), d[0] != 0 else { return false }
            return steuerDigit(d[0..<8]) == d[8]
        }, draw: { _, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            return ["D", "E"] + characters(d + [steuerDigit(d[...])])
        }),
        Recognizer("ORGANISATIONSNUMMER", keys: ["organisationsnummer", "orgnr", "orgnummer"], forms: [
            .init(#"\b\d{2}[2-9]\d{3}-\d{4}\b"#, 0.3),
            .init(#"\b\d{2}[2-9]\d{7}\b"#, 0.05),
        ], context: ["organisationsnummer", "orgnr", "orgnummer", "företagsnummer", "organisation number"], separators: "-", check: { characters in
            guard let d = numbers(characters), d.count == 10, d[2] >= 2 else { return false }
            return Patterns.luhn(d)
        }, draw: { like, rng in
            // The first digit is the group (legal form's family): kept.
            let group = like.first?.wholeNumberValue.flatMap { $0 == 0 ? nil : $0 } ?? 5
            let body = [group, Int.random(in: 0...9, using: &rng), Int.random(in: 2...9, using: &rng)] + randomDigits(6, &rng)
            return characters(body + [luhnDigit(body)])
        }),
        Recognizer("ES_PASSPORT", keys: ["pasaporte", "numeropasaporte", "nmeropasaporte"], forms: [
            .init(#"\b[A-Z]{3}\d{6}\b"#, 0.1),
        ], context: ["pasaporte", "passport"], verifies: false, separators: "", check: { characters in
            guard characters.count == 9 else { return false }
            return characters[0..<3].allSatisfy { $0.isASCII && $0.isUppercase } && numbers(Array(characters[3...])) != nil
        }, draw: { _, rng in
            [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng)] + characters(randomDigits(6, &rng))
        }),

        // India, Italy and Korea.
        Recognizer("GSTIN", keys: ["gstin", "gstinno", "gstinnumber"], forms: [
            .init(#"\b(?:0[1-9]|[12]\d|3[0-8]|97|99)[A-Z]{3}[ABCFGHJLPT][A-Z]\d{4}[A-Z][1-9A-Z]Z[\dA-Z]\b"#, 0.6, alone: true),
        ], context: ["gstin", "gst", "goods and services tax", "gst number", "gst registration"], separators: " -", check: { characters in
            guard characters.count == 15, let state = numbers(Array(characters[0..<2])), gstStates.contains(number(state)),
                  characters[2..<5].allSatisfy({ letters.contains($0) }), panHolders.contains(characters[5]), letters.contains(characters[6]),
                  let serial = numbers(Array(characters[7..<11])), number(serial) > 0, letters.contains(characters[11]),
                  characters[12] != "0", characters[13] == "Z" else { return false }
            return gstinMark(Array(characters[0..<14])) == characters[14]
        }, draw: { _, rng in
            let body = characters(twoDigits(Int.random(in: 1...37, using: &rng)))
                + [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng), pick(panHolders, &rng), pick(letters, &rng)]
                + Array(String(format: "%04d", Int.random(in: 1...9999, using: &rng))) + [pick(letters, &rng), pick("123456789", &rng), "Z"]
            return body + [gstinMark(body) ?? "0"]
        }),
        Recognizer("IN_VEHICLE_REGISTRATION", forms: [
            .init(#"\b[A-Z]{2}[ -]?(?:\d[ -]?(?:[A-Z]{1,3}|[A-Z][ -][A-Z]{2})|\d{2}[ -]?[A-Z]{1,2})[ -]?(?!0000)\d{4}\b"#, 0.3),
            .init(#"\b[2-9][1-9][ -]?BH[ -]?(?!0000)\d{4}[ -]?[A-HJ-NP-Z]{2}\b"#, 0.3),
            .init(#"\b\d{1,3}[ -]?(?:CD|CC|UN)[ -]?[1-9]\d{0,3}\b"#, 0.3),
        ], context: ["rto", "vehicle", "plate", "vehicle registration", "registration plate", "number plate", "vehicle number"], verifies: false, separators: " -", check: { characters in
            plateValid(characters)
        }, draw: { like, rng in
            plateDraw(like, &rng)
        }),
        Recognizer("IT_DRIVER_LICENSE", keys: ["numeropatente"], forms: [
            .init(#"\b[A-Z]{2}\d{7}[A-Z]\b"#, 0.3),
            .init(#"\bU1[BCDEFGHJKLMNPRSTUWXYZ\d]{7}[A-Z]\b"#, 0.3),
        ], context: ["patente", "patente guida", "licenza guida"], verifies: false, separators: " ", check: { characters in
            guard characters.count == 10, letters.contains(characters[9]) else { return false }
            if characters[0] == "U", characters[1] == "1" { return characters[2..<9].allSatisfy { italianLicenceMarks.contains($0) } }
            return letters.contains(characters[0]) && letters.contains(characters[1]) && numbers(Array(characters[2..<9])) != nil
        }, draw: { like, rng in
            if like.starts(with: ["U", "1"]) { return ["U", "1"] + (0..<7).map { _ in pick(italianLicenceMarks, &rng) } + [pick(letters, &rng)] }
            let province = Array(["MI", "RM", "TO", "NA", "FI", "BO", "GE", "PA", "BA", "VE", "VR", "PD", "CT", "BS", "BG"].randomElement(using: &rng) ?? "MI")
            return province + characters(randomDigits(7, &rng)) + [pick(letters, &rng)]
        }),
        Recognizer("IT_IDENTITY_CARD", keys: ["cartaidentita", "cartadidentita", "numerocartaidentita", "numerocie"], forms: [
            .init(#"\b[A-Z]{2}\d{5}[A-Z]{2}\b"#, 0.3),
            .init(#"\b\d{7}[A-Z]{2}\b"#, 0.3),
            .init(#"\b[A-Z]{2} ?\d{7}\b"#, 0.3),
        ], context: ["identità", "identita", "cie", "carta identità", "carta identita", "documento identità", "documento riconoscimento"], verifies: false, separators: " ", check: { characters in
            guard characters.count == 9 else { return false }
            let shape = characters.map { $0.isASCII && $0.isNumber ? "9" : letters.contains($0) ? "A" : "?" }.joined()
            return ["AA99999AA", "9999999AA", "AA9999999"].contains(shape)
        }, draw: { like, rng in
            if like.first?.isNumber == true { return characters(randomDigits(7, &rng)) + [pick(letters, &rng), pick(letters, &rng)] }
            if like.count == 9, like.last?.isNumber == true { return [pick(letters, &rng), pick(letters, &rng)] + characters(randomDigits(7, &rng)) }
            return ["C", pick(letters, &rng)] + characters(randomDigits(5, &rng)) + [pick(letters, &rng), pick(letters, &rng)]
        }),
        Recognizer("PARTITA_IVA", keys: ["piva", "partitaiva", "numeropartitaiva"], forms: [
            .init(#"\bIT ?\d{11}\b"#, 0.3),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["piva", "partita iva", "p iva"], separators: " ", check: { characters in
            let body = characters.count == 13 && characters.starts(with: ["I", "T"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 11, number(Array(d[0..<7])) > 0 else { return false }
            let office = number(Array(d[7..<10]))
            return ((1...100).contains(office) || [120, 121, 888, 999].contains(office)) && Patterns.luhn(d)
        }, draw: { like, rng in
            let office = Int.random(in: 1...100, using: &rng)
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(6, &rng) + [office / 100, office / 10 % 10, office % 10]
            return (like.first == "I" ? ["I", "T"] : []) + characters(d + [luhnDigit(d)])
        }),
        Recognizer("KR_BRN", keys: ["krbrn"], forms: [
            .init(#"(?<!\d)\d{3}-\d{2}-\d{5}(?!\d)"#, 0.3),
            .init(#"\b\d{10}\b"#, 0.05),
        ], context: ["사업자등록번호", "사업자번호", "사업자", "brn", "business registration number", "korean brn"], separators: " -", check: { characters in
            guard let d = numbers(characters), d.count == 10, number(Array(d[0..<3])) >= 101, number(Array(d[3..<5])) > 0, number(Array(d[5..<9])) > 0 else { return false }
            return brnDigit(d) == d[9]
        }, draw: { _, rng in
            let office = Int.random(in: 101...999, using: &rng)
            let serial = Int.random(in: 1...9999, using: &rng)
            let d = [office / 100, office / 10 % 10, office % 10] + twoDigits(Int.random(in: 1...99, using: &rng)) + twoDigits(serial / 100) + twoDigits(serial % 100)
            return characters(d + [brnDigit(d)])
        }),
        Recognizer("KR_DRIVER_LICENSE", forms: [
            .init(#"\b(?:1[1-9]|2[0-68])[- ]\d{2}[- ]\d{6}[- ]\d{2}\b"#, 0.3),
            .init(#"\b(?:1[1-9]|2[0-68])\d{10}\b"#, 0.05),
        ], context: ["운전면허", "운전면허번호", "운전면허증", "면허번호", "korean driver license", "korean driver's license"], verifies: false, separators: " -", check: { characters in
            guard let d = numbers(characters), d.count == 12 else { return false }
            return koreanLicenceRegions.contains(d[0] * 10 + d[1])
        }, draw: { _, rng in
            characters(twoDigits(koreanLicenceRegions.randomElement(using: &rng) ?? 11)) + characters(randomDigits(10, &rng))
        }),
        Recognizer("KR_PASSPORT", forms: [
            .init(#"\b[MSROD]\d{3}[A-Z]\d{4}\b"#, 0.3),
        ], context: ["korean passport", "대한민국 여권", "여권", "여권번호", "passport"], verifies: false, separators: " ", check: { characters in
            guard characters.count == 9, "MSROD".contains(characters[0]), letters.contains(characters[4]) else { return false }
            return numbers(Array(characters[1..<4])) != nil && numbers(Array(characters[5..<9])) != nil
        }, draw: { like, rng in
            let lead = like.first.map { "MSROD".contains($0) ? $0 : "M" } ?? "M"
            return [lead] + characters(randomDigits(3, &rng)) + [pick(letters, &rng)] + characters(randomDigits(4, &rng))
        }),

        // South Africa, Nigeria, Turkey, the Philippines and Singapore.
        Recognizer("ZA_COMPANY_REGISTRATION", keys: ["cipc", "cipcnumber", "cipcregistrationnumber"], forms: [
            .init(#"\b(?:19|20)\d{2}/\d{6}/\d{2}\b"#, 0.3),
            .init(#"\b(?:CK|NR|[KTWBMN])\d{4}/\d{6}(?:/\d{2})?\b"#, 0.3),
        ], context: ["cipc", "company registration", "registration number", "close corporation", "company reg", "enterprise number"], verifies: false, separators: "/ ", check: { characters in
            let lead = characters.prefix { $0.isLetter }
            guard ["", "CK", "NR", "K", "T", "W", "B", "M", "N"].contains(String(lead)), let d = numbers(Array(characters.dropFirst(lead.count))) else { return false }
            guard lead.isEmpty ? d.count == 12 : d.count == 10 || d.count == 12 else { return false }
            return (1800...currentYear).contains(number(Array(d[0..<4])))
        }, draw: { like, rng in
            let lead = like.prefix { $0.isLetter }
            let prefix: [Character] = ["CK", "NR", "K", "T", "W", "B", "M", "N"].contains(String(lead)) ? Array(lead) : []
            let rest = Array(like.dropFirst(prefix.count))
            let suffix: [Character] = rest.count == 12 && numbers(rest) != nil ? Array(rest[10...]) : prefix.isEmpty ? ["0", "7"] : []
            let year = Int.random(in: 1990...2020, using: &rng)
            return prefix + characters(twoDigits(year / 100) + twoDigits(year % 100) + randomDigits(6, &rng)) + suffix
        }),
        Recognizer("ZA_DRIVER_LICENSE", forms: [
            .init(#"\b\d{6,10}[A-Z0-9]{2,5}\b"#, 0.3),
        ], context: ["driving licence", "driving license", "driver's licence", "driver's license", "drivers licence", "drivers license", "licence number", "license number", "enatis", "natis"], verifies: false, separators: " ", check: { characters in
            guard (10...14).contains(characters.count), characters.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) }) else { return false }
            return numbers(Array(characters.prefix(max(6, characters.count - 5)))) != nil && characters.contains { $0.isLetter }
        }, draw: { like, rng in
            let count = min(max(like.count, 10), 14)
            let head = max(6, count - 5)
            var tail = (head..<count).map { index in index < like.count && like[index].isLetter ? pick(letters, &rng) : pick(digits, &rng) }
            if !tail.contains(where: { $0.isLetter }) { tail[tail.count - 1] = pick(letters, &rng) }
            return characters(randomDigits(head, &rng)) + tail
        }),
        Recognizer("ZA_INCOME_TAX_NUMBER", keys: ["sarstaxnumber", "sarsnumber", "incometaxnumber", "taxreferencenumber", "incometaxreferencenumber"], forms: [
            .init(#"\b[01239]\d{9}\b"#, 0.05),
        ], context: ["sars", "tax reference", "tax reference number", "income tax", "income tax number", "tax number", "itr", "tax registration"], separators: " -/", check: { characters in
            guard let d = numbers(characters), d.count == 10, [0, 1, 2, 3, 9].contains(d[0]) else { return false }
            return Patterns.luhn(d)
        }, draw: { like, rng in
            let lead = like.first.flatMap { "01239".contains($0) ? $0.wholeNumberValue : nil } ?? [0, 1, 2, 3, 9][Int.random(in: 0...4, using: &rng)]
            let d = [lead] + randomDigits(8, &rng)
            return characters(d + [luhnDigit(d)])
        }),
        Recognizer("ZA_LICENSE_PLATE", forms: [
            .init(#"\b[A-Z]{2,4}\d{2,4}[A-Z]{0,4}(?:GP|ZN|WP|EC|NC|FS|LP|MP|NW)\b"#, 0.3),
            .init(#"\b[A-Z]{2} ?\d{2} ?[A-Z]{2} ?(?:GP|ZN|WP|EC|NC|FS|LP|MP|NW)\b"#, 0.3),
            .init(#"\b[A-Z]{2,3} ?\d{2,3} ?(?:GP|ZN|WP|EC|NC|FS|LP|MP|NW)\b"#, 0.3),
            .init(#"\b\d{2,3} ?[A-Z]{2,3} ?EC\b"#, 0.3),
        ], context: ["licence plate", "license plate", "number plate", "plate number", "vehicle registration", "natis", "enatis"], verifies: false, separators: " -", check: { characters in
            zaPlate(characters)
        }, draw: { like, rng in
            let model = zaPlate(like) ? like : Array("BC12DFGP")
            return model.dropLast(2).map { $0.isLetter ? pick(plateConsonants, &rng) : pick(digits, &rng) } + model.suffix(2)
        }),
        Recognizer("ZA_PHONE_NUMBER", entity: "PHONE_NUMBER", keys: ["cellphonenumber", "cellnumber", "cellno", "landlinenumber"], forms: [
            .init(#"(?<![\w+])\+27[ -]?[1-8]\d[ -]?\d{3}[ -]?\d{4}\b"#, 0.3),
            .init(#"(?<![\w(])\(0[1-8]\d\) ?\d{3}[ -]?\d{4}\b"#, 0.3),
            .init(#"\b0[1-8]\d[ -]\d{3}[ -]\d{4}\b"#, 0.3),
            .init(#"\b0[1-8]\d{8}\b"#, 0.05),
        ], context: ["phone", "telephone", "cell", "cellphone", "cellular", "mobile", "handset", "contact number", "landline", "tel", "home number", "work number", "office number", "sms", "whatsapp"], verifies: false, separators: " -()+", check: { characters in
            guard let d = numbers(characters) else { return false }
            if d.count == 10 { return d[0] == 0 && (1...8).contains(d[1]) }
            return d.count == 11 && d[0] == 2 && d[1] == 7 && (1...8).contains(d[2])
        }, draw: { like, rng in
            let international = like.count == 11 && like.starts(with: ["2", "7"])
            let national = numbers(Array(like.dropFirst(international ? 2 : 1))) ?? []
            let head = national.count == 9 && (1...8).contains(national[0]) ? Array(national[0..<2]) : [8, 2]
            return characters((international ? [2, 7] : [0]) + head + randomDigits(7, &rng))
        }),
        Recognizer("ZA_TRAFFIC_REGISTER_NUMBER", keys: ["trafficregisternumber", "trafficregisterno"], forms: [
            .init(#"\b\d{13}\b"#, 0.05),
        ], context: ["traffic register", "traffic register number", "trn", "enatis", "natis", "vehicle register"], verifies: false, separators: " ", check: { characters in
            guard let d = numbers(characters), d.count == 13 else { return false }
            return !southAfricanIDLike(d)
        }, draw: { _, rng in
            var d = randomDigits(13, &rng)
            if southAfricanIDLike(d) { d[12] = (d[12] + 1) % 10 }
            return characters(d)
        }),
        Recognizer("ZA_VAT_NUMBER", keys: ["vatvendornumber", "savatnumber", "vatvendorno"], forms: [
            .init(#"\b4\d{9}\b"#, 0.05),
        ], context: ["vat", "vat number", "vat no", "vat registration", "vat vendor", "value added tax", "tax invoice", "sars"], verifies: false, separators: " ", check: { characters in
            guard let d = numbers(characters) else { return false }
            return d.count == 10 && d[0] == 4
        }, draw: { _, rng in
            characters([4] + randomDigits(9, &rng))
        }),
        Recognizer("NG_VEHICLE_REGISTRATION", forms: [
            .init(#"\b[A-Z]{3}[- ]?\d{3}[A-Z]{2}\b"#, 0.3),
        ], context: ["plate number", "vehicle registration", "license plate", "licence plate", "number plate", "plate"], verifies: false, separators: " -", check: { characters in
            guard characters.count == 8, numbers(Array(characters[3..<6])) != nil else { return false }
            return (characters[0..<3] + characters[6...]).allSatisfy { $0.isASCII && $0.isUppercase }
        }, draw: { _, rng in
            let serial = Int.random(in: 1...999, using: &rng)
            return [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng)] + characters([serial / 100, serial / 10 % 10, serial % 10]) + [pick(letters, &rng), pick(letters, &rng)]
        }),
        Recognizer("TR_LICENSE_PLATE", keys: ["plaka", "plakano", "aracplakasi", "plakanumarasi"], forms: [
            .init(#"\b(?:0[1-9]|[1-7]\d|8[01])([ -]?)(?:[A-PR-VYZ]\1\d{4,5}|[A-PR-VYZ]{2}\1\d{3,4}|[A-PR-VYZ]{3}\1\d{2,3})\b"#, 0.3),
        ], context: ["plaka", "araç plakası", "plaka numarası", "kayıt plakası", "taşıt plakası", "tr plaka", "license plate", "number plate", "plate"], verifies: false, separators: " -", check: { characters in
            turkishPlate(characters) != nil
        }, draw: { like, rng in
            let (province, letterCount, digitCount) = turkishPlate(like) ?? (characters(twoDigits(Int.random(in: 1...81, using: &rng))), 2, 3)
            return province + (0..<letterCount).map { _ in pick(turkishPlateLetters, &rng) } + [pick("123456789", &rng)] + characters(randomDigits(digitCount - 1, &rng))
        }),
        Recognizer("PH_TIN", keys: ["birtin", "phtin", "tinno"], forms: [
            .init(#"\b\d{3}-\d{3}-\d{3}(?:-\d{3})?\b"#, 0.3),
            .init(#"\b\d{9}\b"#, 0.05),
            .init(#"\b\d{12}\b"#, 0.05),
        ], context: ["tin", "taxpayer identification number", "taxpayer id", "tax id", "bir", "bir tin"], verifies: false, separators: " -", check: { characters in
            numbers(characters).map { $0.count == 9 || $0.count == 12 } ?? false
        }, draw: { like, rng in
            var body = randomDigits(8, &rng)
            for _ in 0..<64 where phTinRest(body) == 10 { body = randomDigits(8, &rng) }
            if phTinRest(body) == 10 { body = [0, 0, 0, 1, 2, 3, 4, 5] }
            let branch = like.count == 12 ? numbers(Array(like[9...])) ?? [] : []
            return characters(body + [phTinRest(body)] + branch)
        }),
        Recognizer("PH_UMID", keys: ["umid", "umidnumber", "umidno", "umidcrn", "commonreferencenumber"], forms: [
            .init(#"\b\d{4}-\d{7}-\d\b"#, 0.3),
            .init(#"\b\d{12}\b"#, 0.05),
        ], context: ["umid", "umid number", "umid card", "unified multi-purpose id", "unified multipurpose id", "common reference number"], verifies: false, separators: " -", check: { characters in
            numbers(characters)?.count == 12
        }, draw: { like, rng in
            let head = like.count == 12 ? numbers(Array(like.prefix(4))) ?? randomDigits(4, &rng) : randomDigits(4, &rng)
            return characters(head + randomDigits(8, &rng))
        }),
        Recognizer("SG_UEN", keys: ["uen", "uennumber", "uenno"], forms: [
            .init(#"\b\d{8}[A-Z]\b"#, 0.1),
            .init(#"\b(?:18|19|20)\d{7}[A-Z]\b"#, 0.1),
            .init(#"\b[RST]\d{2}[A-Z]{2}\d{4}[A-Z]\b"#, 0.3),
        ], context: ["uen", "unique entity number", "business registration", "acra"], separators: " ", check: { characters in
            guard characters.count == 9 || characters.count == 10 else { return false }
            let body = Array(characters.dropLast())
            if characters.count == 10, let d = numbers(body) {
                guard (1800...currentYear).contains(number(Array(d[0..<4]))) else { return false }
            } else if characters.count == 10 {
                guard "RST".contains(characters[0]), let year = numbers(Array(characters[1..<3])), numbers(Array(characters[5..<9])) != nil,
                      uenEntityTypes.contains(String(characters[3..<5])), characters[0] != "T" || number(year) <= currentYear % 100 else { return false }
            }
            return uenLetter(body) == characters.last
        }, draw: { like, rng in
            let body: [Character]
            if like.count == 9 {
                body = characters(randomDigits(8, &rng))
            } else if like.count == 10, let lead = like.first, "RST".contains(lead) {
                let year = lead == "T" ? Int.random(in: 0...(currentYear % 100), using: &rng) : Int.random(in: 0...99, using: &rng)
                let type = uenEntityTypes.contains(String(like[3..<5])) ? Array(like[3..<5]) : ["L", "L"]
                body = [lead] + characters(twoDigits(year)) + type + characters(randomDigits(4, &rng))
            } else {
                let year = Int.random(in: 1970...2020, using: &rng)
                body = characters(twoDigits(year / 100) + twoDigits(year % 100) + randomDigits(5, &rng))
            }
            return body + [uenLetter(body) ?? "A"]
        }),

        // Australia, Canada, the United Kingdom and the United States.
        Recognizer("ABN", keys: ["abn", "abnnumber", "australianbusinessnumber"], forms: [
            .init(#"\b\d{2} \d{3} \d{3} \d{3}\b"#, 0.1),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["abn", "australian business number"], separators: " ", check: { characters in
            guard let d = numbers(characters), d.count == 11, d[0] > 0 else { return false }
            return (zip(d, [10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19]).reduce(0) { $0 + $1.0 * $1.1 } - 10) % 89 == 0
        }, draw: { _, rng in
            let body = randomDigits(9, &rng)
            return characters(twoDigits(abnLead(body)) + body)
        }),
        Recognizer("ACN", keys: ["acn", "acnnumber", "australiancompanynumber"], forms: [
            .init(#"\b\d{3} \d{3} \d{3}\b"#, 0.1),
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["acn", "australian company number"], separators: " ", check: { characters in
            guard let d = numbers(characters), d.count == 9, Set(d).count > 1 else { return false }
            return acnDigit(Array(d[0..<8])) == d[8]
        }, draw: { _, rng in
            let body = randomDigits(8, &rng)
            return characters(body + [acnDigit(body)])
        }),
        Recognizer("ABA_ROUTING", keys: ["aba", "abanumber", "abarouting", "abaroutingnumber", "routingnumber", "routingtransitnumber", "bankrouting", "bankroutingnumber", "rtn"], forms: [
            .init(#"\b(?:0\d|1[0-2]|2[1-9]|3[0-2]|6[1-9]|7[0-2]|80)\d{7}\b"#, 0.05),
            .init(#"\b(?:0\d|1[0-2]|2[1-9]|3[0-2]|6[1-9]|7[0-2]|80)\d{2}-\d{4}-\d\b"#, 0.1),
        ], context: ["aba", "routing", "routing number", "routing transit number", "rtn", "abarouting", "bankrouting"], separators: "-", check: { characters in
            guard let d = numbers(characters), d.count == 9, Set(d).count > 1, abaPrefixes.contains(d[0] * 10 + d[1]) else { return false }
            return abaDigit(Array(d[0..<8])) == d[8]
        }, draw: { like, rng in
            let given = like.count >= 2 ? numbers(Array(like.prefix(2))).map(number) : nil
            let lead = given.flatMap { abaPrefixes.contains($0) ? $0 : nil } ?? abaPrefixes.randomElement(using: &rng) ?? 1
            let body = twoDigits(lead) + randomDigits(6, &rng)
            return characters(body + [abaDigit(body)])
        }),
        Recognizer("CA_POSTAL_CODE", entity: "POSTAL_CODE", keys: ["capostalcode", "canadapostalcode", "canadianpostalcode"], forms: [
            .init(#"\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z] \d[ABCEGHJ-NPRSTV-Z]\d\b"#, 0.5, alone: true),
            .init(#"\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z]\d[ABCEGHJ-NPRSTV-Z]\d\b"#, 0.1),
        ], context: ["postal code", "postcode", "code postal", "zip", "canada", "ontario", "quebec", "québec", "alberta", "british columbia"], verifies: false, separators: " ", check: { characters in
            String(characters).range(of: #"^[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z]\d[ABCEGHJ-NPRSTV-Z]\d$"#, options: .regularExpression) != nil
        }, draw: { like, rng in
            // The first letter is the province or region; it stays, so the stand-in is in the same part of Canada.
            let region = "ABCEGHJKLMNPRSTVXY"
            let first = like.first.flatMap { region.contains($0) ? $0 : nil } ?? pick(region, &rng)
            let rest = "ABCEGHJKLMNPRSTVWXYZ"
            return [first, pick(digits, &rng), pick(rest, &rng), pick(digits, &rng), pick(rest, &rng), pick(digits, &rng)]
        }),
        Recognizer("UK_POSTCODE", entity: "POSTAL_CODE", keys: ["ukpostcode", "britishpostcode", "gbpostcode"], forms: [
            .init(#"\b(?:GIR 0AA|[A-PR-UWYZ](?:\d[ABCDEFGHJKPSTUW]?|\d{2}|[A-HK-Y]\d[ABEHMNPRVWXY]?|[A-HK-Y]\d{2}) \d[ABD-HJLNP-UW-Z]{2})\b"#, 0.5, alone: true),
            .init(#"\b(?:GIR0AA|[A-PR-UWYZ](?:\d[ABCDEFGHJKPSTUW]?|\d{2}|[A-HK-Y]\d[ABEHMNPRVWXY]?|[A-HK-Y]\d{2})\d[ABD-HJLNP-UW-Z]{2})\b"#, 0.1),
        ], context: ["postcode", "post code", "postal code", "zip"], verifies: false, separators: " ", check: { characters in
            String(characters).range(of: #"^(?:GIR0AA|[A-PR-UWYZ](?:\d[ABCDEFGHJKPSTUW]?|\d{2}|[A-HK-Y]\d[ABEHMNPRVWXY]?|[A-HK-Y]\d{2})\d[ABD-HJLNP-UW-Z]{2})$"#, options: .regularExpression) != nil
        }, draw: { like, rng in
            let outward = like.count >= 5 ? String(like.dropLast(3).map { $0.isNumber ? "9" : "A" }) : ""
            let shapes = ["A9", "A99", "A9A", "AA9", "AA99", "AA9A"]
            let shape = shapes.contains(outward) ? outward : like.count == 7 ? "AA99" : like.count == 5 ? "A9" : "AA9"
            let letter = shape.dropFirst().first == "A"
            var made: [Character] = [pick("ABCDEFGHIJKLMNOPRSTUWYZ", &rng)]
            for (index, kind) in shape.enumerated().dropFirst() {
                if kind == "9" { made.append(pick(digits, &rng)) }
                else if index == 1 { made.append(pick("ABCDEFGHKLMNOPQRSTUVWXY", &rng)) }
                else { made.append(pick(letter ? "ABEHMNPRVWXY" : "ABCDEFGHJKPSTUW", &rng)) }
            }
            return made + [pick(digits, &rng), pick("ABDEFGHJLNPQRSTUWXYZ", &rng), pick("ABDEFGHJLNPQRSTUWXYZ", &rng)]
        }),
        Recognizer("UK_VEHICLE_REGISTRATION", keys: ["vrn", "vrm", "vehicleregistration", "vehicleregistrationnumber", "vehicleregistrationmark", "vehiclereg", "registrationplate", "numberplate", "regplate", "carregistration"], forms: [
            .init(#"\b[A-HJ-PR-Y]{2}(?:0[2-9]|[12]\d|5[1-9]|[67]\d)[ -]?[A-HJ-PR-Z]{3}\b"#, 0.3),
            .init(#"\b[A-HJ-NPR-TV-Y][1-9]\d{0,2}[ -]?[A-HJ-PR-Y][A-HJ-PR-Z]{2}\b"#, 0.1),
            .init(#"\b[A-HJ-PR-Z]{3}[ -]?[1-9]\d{0,2}[ -]?[A-HJ-NPR-TV-Y]\b"#, 0.1),
        ], context: ["vrn", "vrm", "vehicle", "vehicle registration", "registration", "registration number", "registration plate", "number plate", "licence plate", "license plate", "reg", "reg number", "car", "dvla", "v5c", "logbook", "insured vehicle"], verifies: false, separators: " -", check: { characters in
            String(characters).range(of: #"^(?:[A-HJ-PR-Y]{2}(?:0[2-9]|[12]\d|5[1-9]|[67]\d)[A-HJ-PR-Z]{3}|[A-HJ-NPR-TV-Y][1-9]\d{0,2}[A-HJ-PR-Y][A-HJ-PR-Z]{2}|[A-HJ-PR-Z]{3}[1-9]\d{0,2}[A-HJ-NPR-TV-Y])$"#, options: .regularExpression) != nil
        }, draw: { like, rng in
            let memory = "ABCDEFGHJKLMNOPRSTUVWXY", random = "ABCDEFGHJKLMNOPRSTUVWXYZ", year = "ABCDEFGHJKLMNPRSTVWXY"
            let count = min(3, max(1, like.count - 4))
            let number = characters([Int.random(in: 1...9, using: &rng)] + randomDigits(count - 1, &rng))
            // Prefix (1983-2001): a year letter, 1-3 digits, three letters.
            if like.count >= 5, like[1].isNumber, like.first?.isLetter == true, like.last?.isLetter == true, like[like.count - 2].isLetter {
                return [pick(year, &rng)] + number + [pick(memory, &rng), pick(random, &rng), pick(random, &rng)]
            }
            // Suffix (1963-1983): three letters, 1-3 digits, a year letter.
            if like.count >= 5, like.prefix(3).allSatisfy(\.isLetter), like[3].isNumber {
                return [pick(random, &rng), pick(random, &rng), pick(random, &rng)] + number + [pick(year, &rng)]
            }
            // Current (2001 on): a memory tag, an age identifier (March 02-29 or September 51-79), three letters.
            let age = (Array(2...29) + Array(51...79)).randomElement(using: &rng) ?? 51
            return [pick(memory, &rng), pick(memory, &rng)] + characters(twoDigits(age)) + [pick(random, &rng), pick(random, &rng), pick(random, &rng)]
        }),
        Recognizer("PRIOR_AUTHORIZATION", keys: ["priorauthorization", "priorauthorizationnumber", "priorauthnumber", "priorauth", "preauthorization", "preauthorizationnumber", "preauthnumber"], forms: [
            .init(#"\bPA-?\d{6,12}\b"#, 0.3),
        ], context: ["prior authorization", "prior auth", "preauthorization", "pre authorization", "preauth", "authorization number"], verifies: false, separators: "-", check: { characters in
            String(characters).range(of: #"^PA[0-9]{6,12}$"#, options: .regularExpression) != nil
        }, draw: { like, rng in
            like.isEmpty ? Array("PA") + characters(randomDigits(9, &rng)) : like.map { $0.isNumber ? pick(digits, &rng) : $0 }
        }),
        Recognizer("CLAIM_NUMBER", keys: ["claimnumber", "claimid", "claimno", "claimref", "claimreference"], forms: [
            .init(#"\bCLM-?\d{6,15}\b"#, 0.3),
        ], context: ["claim"], verifies: false, separators: "-", check: { characters in
            String(characters).range(of: #"^CLM[0-9]{6,15}$"#, options: .regularExpression) != nil
        }, draw: { like, rng in
            like.isEmpty ? Array("CLM") + characters(randomDigits(10, &rng)) : like.map { $0.isNumber ? pick(digits, &rng) : $0 }
        }),
        Recognizer("PRESCRIPTION_NUMBER", keys: ["rxnumber", "rxno", "rxid", "prescriptionnumber", "prescriptionid"], forms: [
            .init(#"\bRX-?\d{6,12}\b"#, 0.3),
        ], context: ["rx", "prescription"], verifies: false, separators: "-", check: { characters in
            String(characters).range(of: #"^RX[0-9]{6,12}$"#, options: .regularExpression) != nil
        }, draw: { like, rng in
            like.isEmpty ? Array("RX") + characters(randomDigits(7, &rng)) : like.map { $0.isNumber ? pick(digits, &rng) : $0 }
        }),
        Recognizer("REFERRAL_NUMBER", keys: ["referralnumber", "referralno"], forms: [
            .init(#"\b(?:REF|INF)-?\d{6,12}\b"#, 0.3),
        ], context: ["referral"], verifies: false, separators: "-", check: { characters in
            String(characters).range(of: #"^(?:REF|INF)[0-9]{6,12}$"#, options: .regularExpression) != nil
        }, draw: { like, rng in
            like.isEmpty ? Array("REF") + characters(randomDigits(8, &rng)) : like.map { $0.isNumber ? pick(digits, &rng) : $0 }
        }),
        Recognizer("EIN", keys: ["ein", "fein", "einnumber", "federalein", "employeridentificationnumber", "federaltaxid", "providertaxid", "billingprovidertaxid"], forms: [
            .init(#"\b(?:0[1-6]|1[0-6]|2[0-7]|3\d|4[0-8]|5\d|6[0-8]|7[1-7]|8[0-8]|9[0-5]|9[89])-\d{7}\b"#, 0.3),
        ], context: ["ein", "fein", "employer identification number", "employer identification", "federal tax id", "provider tax id", "tax id", "tin"], verifies: false, separators: "-", check: { characters in
            guard let d = numbers(characters), d.count == 9 else { return false }
            return einPrefixes.contains(d[0] * 10 + d[1])
        }, draw: { like, rng in
            let given = like.count >= 2 ? numbers(Array(like.prefix(2))).map(number) : nil
            let lead = given.flatMap { einPrefixes.contains($0) ? $0 : nil } ?? einPrefixes.randomElement(using: &rng) ?? 12
            return characters(twoDigits(lead) + randomDigits(7, &rng))
        }),
        Recognizer("US_HEALTH_MEMBER_ID", keys: ["insurancememberid", "healthinsurancememberid", "healthplanmemberid", "subscriberid", "insurancesubscriberid", "insuranceid"], forms: [
            .init(#"\b(?=[A-Z0-9-]{6,20}\b)(?=[A-Z0-9-]*\d)[A-Z]{1,5}-?[A-Z0-9]{5,14}\b"#, 0.1),
        ], context: ["member id", "member number", "member no", "subscriber", "subscriber id", "subscriber number", "insurance id", "insurance member id", "health plan id", "policy number"], verifies: false, separators: "-", check: { characters in
            String(characters).range(of: #"^(?=[A-Z0-9]*[0-9])[A-Z]{1,5}[A-Z0-9]{5,14}$"#, options: .regularExpression) != nil
        }, draw: { like, rng in
            guard !like.isEmpty else { return Array("MB") + characters(randomDigits(7, &rng)) }
            // A payer's prefix (up to three letters before the first digit) names the plan, not the member: it stays.
            let prefix = min(3, like.prefix { $0.isLetter }.count)
            return Array(like.prefix(prefix)) + like.dropFirst(prefix).map { $0.isNumber ? pick(digits, &rng) : $0.isLetter ? pick(letters, &rng) : $0 }
        }),
    ]

    /// The kinds the registry finds.
    static let entities = Set(all.map(\.entity))
    /// The kinds whose stand-ins the registry draws: a postcode follows its stand-in place and a
    /// phone number its numbering, as `StandIns` draws them; the registry only finds those.
    static let drawn = entities.subtracting(["POSTAL_CODE", "PHONE_NUMBER"])
    /// Keys that name a kind ("umid card", "korean_brn"): a field's name, not a value in it. Only its keys and
    /// phrases of several words: a single context word may be someone's name too ("Nas", a key in a map of people).
    static let fieldNames = Set(all.flatMap { recognizer in
        recognizer.keys.union(recognizer.context.filter { $0.contains(" ") }.map { $0.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } })
    }.filter { $0.count >= 3 })
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
        // A short one only with a letter: "HRB 39" or "B-AB 1" is a kind's, five digits no one's to tell.
        guard length >= 7 || length >= 4 && trimmed.contains(where: \.isLetter), length <= 96 else { return [] }
        let matching = all.filter { $0.writes(trimmed) && $0.passes(trimmed) }
        return matching.filter(\.verifies) + matching.filter { !$0.verifies }
    }

    /// A fresh value of the kind `original` is, written as it is (its separators where they were, its letters in its case), which passes the same check in one of its forms.
    /// A kind known by its shape alone keeps its letters and digits where they were: its check can't tell another layout from a mistake.
    static func standIn(for original: String, preferring preferred: Recognizer? = nil, using rng: inout any RandomNumberGenerator) -> String? {
        // A value two kinds write ("ZN26148285": a passport, or by chance a German card's number) takes the
        // kind its words name, else the first that can draw one.
        let kinds = candidates(original).filter { drawn.contains($0.entity) }
        for recognizer in kinds.filter({ $0.name == preferred?.name }) + kinds.filter({ $0.name != preferred?.name }) {
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

    /// Words that sit between a value and the word naming it without changing what it names ("the", "my", "de");
    /// not "no" or "nr", which a phrase may hold ("pass nr").
    private static let stopwords: Set<String> = ["the", "a", "an", "is", "are", "was", "my", "your", "his", "her", "their", "our", "its", "of", "for", "to", "de", "del", "la", "el", "le", "les", "der", "die", "das", "des", "und", "y", "e", "et", "du", "da", "do", "dos", "di", "il", "van", "het", "och", "og", "i"]
    /// Whether one of `context` is among `words`: a single word as written, several in a row.
    static func names(_ context: Set<String>, in words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        return context.contains { entry in
            // Split as the text's words are: "v5c" is v, c and "multi-purpose" multi, purpose.
            let parts = entry.split(whereSeparator: { !$0.isLetter }).map(String.init)
            guard parts.count > 1 else { return words.contains { mentions($0, entry) } }
            guard parts.count <= words.count else { return false }
            return (0...(words.count - parts.count)).contains { start in zip(words[start..<(start + parts.count)], parts).allSatisfy(mentions) }
        }
    }
    /// Whether any of `words` (unordered, as a key's are) names one of `context`, each word of a phrase by some word.
    static func named(_ context: Set<String>, among words: Set<String>) -> Bool {
        context.contains { entry in parts(entry).contains { $0.allSatisfy { part in words.contains { mentions($0, part) } } } }
    }
    /// A context entry's words as a key's or a type field's are read: "driver's license" is driver, s, license;
    /// "v5c" is itself as a key writes it, and v5, c as a type field does ("V5C").
    private static func parts(_ entry: String) -> [[String]] {
        entry.allSatisfy { $0.isLetter || $0 == " " } ? [entry.split(separator: " ").map(String.init)] : [KeyHints.words(entry), KeyHints.words(entry.uppercased())]
    }
    /// Words a short name ends in when written as one word with it ("cprnummer", "nhsno", "panid").
    private static let numberWords: Set<String> = ["number", "nummer", "numero", "número", "no", "nr", "num", "id", "code", "card", "karte"]
    /// Whether `word` names `part`, as substring matching reads a context word inside a
    /// longer one ("card" in "creditcard"), but only at a compound's edge ("steuer" opens
    /// "steuernummer"; "license" isn't in the middle of anything), and a name of three letters
    /// or fewer only as a whole word or before a word for "number" ("cpr" in "cprnummer", not "cprs").
    static func mentions(_ word: String, _ part: String) -> Bool {
        if word == part { return true }
        // At a compound's end only after a word of its own ("numberplate", "kundensteuernummer"), not a syllable ("template").
        if part.count >= 4 { return word.hasPrefix(part) || word.hasSuffix(part) && word.count - part.count >= 4 }
        return word.hasPrefix(part) && numberWords.contains(String(word.dropFirst(part.count)))
    }
    /// The words before `range` that may name it, stopwords left out, nearest five.
    static func before(_ range: Range<Int>, in text: String) -> [String] {
        Array(Context.words(before: range.lowerBound, in: text, limit: 10).map { $0.lowercased() }.filter { !stopwords.contains($0) }.suffix(5))
    }

    /// Identifiers in `text`: one passing its check in a form that needs no
    /// naming word scores 0.85, one named by a word before it or by its key
    /// scores 1, as validated and context-supported results do, a
    /// bare one keeps its form's score, and one failing its check is none.
    static func find(_ text: String, ns: NSString, units: [UInt16], contextWords: Set<String>, isCancelled: () -> Bool) -> [Span] {
        var spans: [Span] = []
        // The text with its small letters capitalised, offsets unchanged, for kinds written in capitals
        // that someone typed small ("my nie is x9613851n"): read so only where a word names the kind.
        let small = units.contains { (97...122).contains($0) }
        let upperUnits = small ? units.map { (97...122).contains($0) ? $0 - 32 : $0 } : units
        let upper = small ? String(utf16CodeUnits: upperUnits, count: upperUnits.count) as NSString : ns
        let lower = small ? text.lowercased() : ""
        for recognizer in all {
            if isCancelled() { return spans }
            let keyed = Self.named(recognizer.context, among: contextWords)
            let capitalised = small && recognizer.folds && (keyed || recognizer.context.contains { entry in entry.split(whereSeparator: { !$0.isLetter }).first.map { lower.contains($0) } ?? false })
            for form in recognizer.forms {
                guard let regex = form.pattern.regex else { continue }
                for match in Patterns.matches(regex, in: ns, units: units, isCancelled: isCancelled) {
                    let range = match.range.location..<NSMaxRange(match.range)
                    guard recognizer.passes(ns.substring(with: match.range)) else { continue }
                    // A key's words name it in any order ("number_nhs"); words in text, in theirs.
                    let isNamed = keyed || names(recognizer.context, in: before(range, in: text))
                    let score = isNamed ? 1 : form.alone ? 0.85 : form.score
                    if score >= 0.4 { spans.append(Span(range: range, entity: recognizer.entity, score: score)) }
                }
                guard capitalised else { continue }
                for match in Patterns.matches(regex, in: upper, units: upperUnits, isCancelled: isCancelled) {
                    let range = match.range.location..<NSMaxRange(match.range)
                    let value = ns.substring(with: match.range)
                    guard value != upper.substring(with: match.range), recognizer.passes(value),
                          keyed || names(recognizer.context, in: before(range, in: text)),
                          !spans.contains(where: { $0.range == range && $0.entity == recognizer.entity }) else { continue }
                    spans.append(Span(range: range, entity: recognizer.entity, score: 1))
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
    private static let thaiProvinces = Set(Array(10...27) + Array(30...49) + Array(50...58) + Array(60...67) + Array(70...77) + Array(80...86) + Array(90...96))
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

    // MARK: Ported kinds

    /// KBV Arztnummern-Richtlinie Anlage 1: the KV Landes- and Bezirksstellen opening a BSNR, with 35 and 75 for its special ranges (§ 6 Abs. 3).
    private static let bsnrAreas: [Int] = [1, 2, 3, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 24, 25, 27, 28, 31, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 75, 78, 79, 80, 81, 83, 85, 86, 87, 88, 89, 90, 91, 93, 94, 95, 96, 98]
    /// The Länder's prefixes in the federal 13-digit Steuernummer (BW 28, BY 9, BE 11, BB 30, HB 24, HH 22, HE 26, MV 40, NI 23, NW 5, RP 27, SL 10, SN 32, ST 31, SH 21, TH 41).
    private static let steuernummerPrefixes: [[Int]] = [[2, 8], [9], [1, 1], [3, 0], [2, 4], [2, 2], [2, 6], [4, 0], [2, 3], [5], [2, 7], [1, 0], [3, 2], [3, 1], [2, 1], [4, 1]]
    /// The LANR's seventh digit: its first six weighed 4, 9, 4, 9, 4, 9, the sum's distance to the next ten.
    private static func lanrDigit(_ digits: [Int]) -> Int {
        (10 - zip(digits, [4, 9, 4, 9, 4, 9]).reduce(0) { $0 + $1.0 * $1.1 } % 10) % 10
    }
    /// A driving licence's tenth character: its first nine weighed 9 down to 1 (a letter worth 10 to 35), mod 11, 10 written X.
    private static func licenceMark(_ characters: [Character]) -> Character? {
        guard characters.count == 9 else { return nil }
        var sum = 0
        for (offset, character) in characters.enumerated() {
            guard let value = alnumValue(character) else { return nil }
            sum += value * (9 - offset)
        }
        let rest = sum % 11
        return rest == 10 ? "X" : Character(String(rest))
    }

    /// GSTIN state codes: 01-38 (38 Ladakh), 97 Other Territory, 99 Centre Jurisdiction.
    private static let gstStates: Set<Int> = Set(1...38).union([97, 99])
    /// A PAN's fourth letter, the kind of holder (Income Tax Department).
    private static let panHolders = "ABCFGHJLPT"
    /// Luhn mod 36 over 0-9A-Z: from the left, every second character doubled, a product folded as its base-36 digits.
    private static func gstinMark(_ body: [Character]) -> Character? {
        var sum = 0
        for (offset, character) in body.enumerated() {
            guard let value = alnumValue(character) else { return nil }
            let product = value * (offset % 2 == 0 ? 1 : 2)
            sum += product / 36 + product % 36
        }
        return Array(digits + letters)[(36 - sum % 36) % 36]
    }
    /// Each state's or territory's district numbers on a plate (AP widened to its pre-2014 codes).
    private static let plateStates: [String: ClosedRange<Int>] = [
        "AN": 1...1, "AP": 1...40, "AR": 1...22, "AS": 1...34, "BR": 1...56, "CG": 1...30, "CH": 1...4, "DD": 1...3, "DN": 9...9, "DL": 1...13,
        "GA": 1...12, "GJ": 1...39, "HP": 1...99, "HR": 1...99, "JH": 1...24, "JK": 1...22, "KA": 1...71, "KL": 1...99, "LA": 1...2, "LD": 1...9,
        "MH": 1...51, "ML": 1...10, "MN": 1...7, "MP": 1...71, "MZ": 1...8, "NL": 1...10, "OD": 1...35, "OR": 1...31, "PB": 1...99, "PY": 1...5,
        "RJ": 1...58, "SK": 1...8, "TN": 1...99, "TR": 1...8, "TS": 1...38, "UK": 1...20, "UP": 11...96, "WB": 1...98,
    ]
    /// Foreign missions' codes on a diplomatic plate past the first 80.
    private static let plateMissions: Set<Int> = [84, 85, 89, 93, 94, 95, 97, 98, 99, 102, 104, 105, 106, 109, 111, 112, 113, 117, 119, 120, 121, 122, 123, 125, 126, 128, 133, 134, 135, 137, 141, 145, 147, 149, 152, 153, 155, 156, 157, 159, 160]
    private static let plateMarks = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    /// An Indian plate: a state's (MH 12 AB 1234), the Bharat series' (22 BH 1234 AA), or a mission's (77 CD 12).
    private static func plateValid(_ c: [Character]) -> Bool {
        let lead = c.prefix { $0.isASCII && $0.isNumber }.count
        if lead > 0 {
            if c.count == 10, lead == 2, c[2] == "B", c[3] == "H" {
                guard let d = numbers(Array(c[0..<2]) + Array(c[4..<8])), (2...9).contains(d[0]), d[1] != 0, number(Array(d[2...])) > 0 else { return false }
                return c[8...].allSatisfy { plateMarks.contains($0) }
            }
            guard lead <= 3, c.count >= lead + 3, ["CD", "CC", "UN"].contains(String(c[lead..<lead + 2])),
                  let mission = numbers(Array(c[0..<lead])), let tail = numbers(Array(c[(lead + 2)...])), tail.count <= 4, tail[0] != 0 else { return false }
            return (1...80).contains(number(mission)) || plateMissions.contains(number(mission))
        }
        guard c.count >= 8, let range = plateStates[String(c.prefix(2))] else { return false }
        let district = Array(c.dropFirst(2).prefix { $0.isASCII && $0.isNumber })
        let series = c.dropFirst(2 + district.count).prefix { letters.contains($0) }
        guard let d = numbers(district), let serial = numbers(Array(c.dropFirst(2 + district.count + series.count))), serial.count == 4, number(serial) > 0 else { return false }
        guard (district.count == 1 && (1...3).contains(series.count)) || (district.count == 2 && (1...2).contains(series.count)) else { return false }
        return range.contains(number(d))
    }
    private static func plateDraw(_ like: [Character], _ rng: inout any RandomNumberGenerator) -> [Character] {
        let serial = Array(String(format: "%04d", Int.random(in: 1...9999, using: &rng)))
        if like.count == 10, like[0].isNumber, like[2] == "B", like[3] == "H" {
            return ["2", Character(String(Int.random(in: 1...6, using: &rng))), "B", "H"] + serial + [pick(plateMarks, &rng), pick(plateMarks, &rng)]
        }
        let lead = like.prefix { $0.isASCII && $0.isNumber }.count
        if lead > 0, like.count >= lead + 2 {
            let code = String(like[lead..<lead + 2])
            let tail = max(1, min(4, like.count - lead - 2))
            return Array(String(Int.random(in: 1...80, using: &rng))) + Array(["CD", "CC", "UN"].contains(code) ? code : "CD") + characters([Int.random(in: 1...9, using: &rng)] + randomDigits(tail - 1, &rng))
        }
        let one = like.count > 3 && like[3].isLetter
        let series = like.count >= 8 ? max(1, min(one ? 3 : 2, like.count - (one ? 7 : 8))) : 2
        let state = plateStates.keys.filter { !one || (plateStates[$0]?.lowerBound ?? 10) <= 9 }.sorted().randomElement(using: &rng) ?? "MH"
        let range = plateStates[state] ?? 1...9
        let district = one ? [Int.random(in: range.lowerBound...min(range.upperBound, 9), using: &rng)] : twoDigits(Int.random(in: range, using: &rng))
        return Array(state) + characters(district) + (0..<series).map { _ in pick(letters, &rng) } + serial
    }
    /// What the seven characters after "U1" on an Italian licence may be.
    private static let italianLicenceMarks = "BCDEFGHJKLMNPRSTUWXYZ0123456789"
    /// Korean licence regions: 11-26 and 28.
    private static let koreanLicenceRegions: [Int] = Array(11...26) + [28]
    /// Weights 1,3,7,1,3,7,1,3,5; the ninth's product adds its tens too.
    private static func brnDigit(_ d: [Int]) -> Int {
        let sum = zip(d[0..<8], [1, 3, 7, 1, 3, 7, 1, 3]).reduce(0) { $0 + $1.0 * $1.1 } + d[8] * 5 + d[8] * 5 / 10
        return (10 - sum % 10) % 10
    }

    private static var currentYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }
    /// Letters seen on South African private plates: no vowels.
    private static let plateConsonants = "BCDFGHJKLMNPQRSTVWXYZ"
    private static let zaProvinces: Set<String> = ["GP", "ZN", "WP", "EC", "NC", "FS", "LP", "MP", "NW"]
    /// A plate ending in a province's code, with a letter and a digit before it.
    private static func zaPlate(_ characters: [Character]) -> Bool {
        guard (5...12).contains(characters.count), characters.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) }) else { return false }
        let body = characters.dropLast(2)
        return zaProvinces.contains(String(characters.suffix(2))) && body.contains { $0.isLetter } && body.contains { $0.isNumber }
    }
    /// Whether 13 digits read as a South African ID: a date of birth in either century and Luhn.
    private static func southAfricanIDLike(_ d: [Int]) -> Bool {
        guard d.count == 13 else { return false }
        let year = d[0] * 10 + d[1], month = d[2] * 10 + d[3], day = d[4] * 10 + d[5]
        return (realDate(year: 1900 + year, month: month, day: day) || realDate(year: 2000 + year, month: month, day: day)) && Patterns.luhn(d)
    }
    /// Turkish plate letters: the Latin alphabet less Q, W and X.
    private static let turkishPlateLetters = "ABCDEFGHIJKLMNOPRSTUVYZ"
    /// A Turkish plate's province, letter count and digit count: 1 letter and 4–5 digits, 2 and 3–4, or 3 and 2–3.
    private static func turkishPlate(_ characters: [Character]) -> (province: [Character], letters: Int, digits: Int)? {
        guard characters.count >= 5, let province = numbers(Array(characters.prefix(2))), (1...81).contains(number(province)) else { return nil }
        let letterCount = characters.dropFirst(2).prefix { turkishPlateLetters.contains($0) }.count
        let digitCount = characters.count - 2 - letterCount
        guard numbers(Array(characters.suffix(digitCount))) != nil, [1: 4...5, 2: 3...4, 3: 2...3][letterCount]?.contains(digitCount) == true else { return nil }
        return (Array(characters.prefix(2)), letterCount, digitCount)
    }
    /// A weighted mod 11 for a Philippine TIN's ninth digit (unverified; used only to draw).
    private static func phTinRest(_ body: [Int]) -> Int {
        zip(body, [9, 8, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11
    }
    /// ACRA's entity-type indicators for a UEN of the third layout.
    private static let uenEntityTypes: Set<String> = ["LP", "LL", "FC", "PF", "RF", "MQ", "MM", "NB", "CC", "CS", "MB", "FM", "GS", "DP", "CP", "NR", "CM", "CD", "MD", "HS", "VH", "CH", "MH", "CL", "XL", "CX", "RP", "TU", "TC", "FB", "FN", "PA", "PB", "SS", "MC", "SM", "GA", "GB"]
    private static let uenAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWX0123456789")
    /// A UEN's check letter over its body: 8 digits (business), 9 digits (local company), or a letter, digits and a type (others).
    private static func uenLetter(_ body: [Character]) -> Character? {
        if let d = numbers(body), d.count == 8 {
            return Array("XMKECAWLJDB")[zip(d, [10, 4, 9, 3, 8, 2, 7, 1]).reduce(0) { $0 + $1.0 * $1.1 } % 11]
        }
        if let d = numbers(body), d.count == 9 {
            return Array("ZKCMDNERGWH")[zip(d, [10, 8, 6, 4, 9, 7, 5, 3, 1]).reduce(0) { $0 + $1.0 * $1.1 } % 11]
        }
        guard body.count == 9 else { return nil }
        let values = body.compactMap { uenAlphabet.firstIndex(of: $0) }
        guard values.count == 9 else { return nil }
        let sum = zip(values, [4, 3, 5, 3, 10, 2, 2, 5, 7]).reduce(0) { $0 + $1.0 * $1.1 }
        return uenAlphabet[((sum - 5) % 11 + 11) % 11]
    }

    /// ABR's ABN check: 1 off the first digit, weights 10, 1, 3, 5 … 19, the sum a multiple of 89.
    /// The two leading check digits (10-99) for a nine-digit body: 10·c1 + c2 ≡ 10 − Σ (mod 89).
    private static func abnLead(_ body: [Int]) -> Int {
        let rest = zip(body, [3, 5, 7, 9, 11, 13, 15, 17, 19]).reduce(0) { $0 + $1.0 * $1.1 }
        let target = ((10 - rest) % 89 + 89) % 89
        return target < 10 ? target + 89 : target
    }
    /// ASIC's ACN check: weights 8 … 1 over the first eight digits, the complement of the sum mod 10.
    private static func acnDigit(_ body: [Int]) -> Int {
        (10 - zip(body, [8, 7, 6, 5, 4, 3, 2, 1]).reduce(0) { $0 + $1.0 * $1.1 } % 10) % 10
    }
    /// An ABA routing number's first two digits: the US government, the twelve Federal Reserve districts, thrifts, electronic, traveller's cheques.
    private static let abaPrefixes: Set<Int> = Set(0...12).union(21...32).union(61...72).union([80])
    /// Weights 3, 7, 1 repeated, the sum with the check digit a multiple of 10.
    private static func abaDigit(_ body: [Int]) -> Int {
        (10 - zip(body, [3, 7, 1, 3, 7, 1, 3, 7]).reduce(0) { $0 + $1.0 * $1.1 } % 10) % 10
    }
    /// The IRS's valid EIN prefixes (campus and internet assignments).
    private static let einPrefixes: Set<Int> = Set(1...6).union(10...16).union(20...27).union(30...39).union(40...48).union(50...59).union(60...68).union(71...77).union(80...88).union(90...95).union([98, 99])

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
