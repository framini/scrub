import CryptoKit
import Foundation
import Synchronization

/// An identifier a country gives a person, described as data (see
/// THIRD_PARTY_NOTICES): the forms it is written in, the
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
    /// Whether its check passes so many numbers by chance (one in eleven) that it tells a value's kind only where words name it:
    /// a stand-in is drawn as another kind it passes first.
    let weak: Bool
    /// Its check, over the value's characters other than separators, in capitals.
    let check: @Sendable ([Character]) -> Bool
    /// A fresh value passing `check`, shaped like the given one (as long, the same version) where its kind allows.
    let draw: @Sendable ([Character], inout any RandomNumberGenerator) -> [Character]

    init(_ name: String, entity: String = "ID_NUMBER", keys: Set<String> = [], forms: [Form], context: Set<String>, folds: Bool = true, verifies: Bool = true, weak: Bool = false, separators: String = " .-/", check: @escaping @Sendable ([Character]) -> Bool, draw: @escaping @Sendable ([Character], inout any RandomNumberGenerator) -> [Character]) {
        self.name = name
        self.entity = entity
        self.forms = forms
        self.context = context
        self.keys = keys
        self.folds = folds
        self.verifies = verifies
        self.weak = weak
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
            .init(#"\b(?:2[0347]|3[034]|5[015])-\d{8}-\d\b"#, 0.5, alone: true),
            .init(#"\b(?:2[0347]|3[034]|5[015])\d{9}\b"#, 0.05),
        ], context: ["cuit", "cuil"], check: { characters in
            // AFIP's types: a person's 20, 23, 24, 27, a company's 30, 33, 34, and 50, 51, 55 for others; a type whose check
            // would be 10 is issued as 23 or 33 instead, so 10 is no check.
            guard let d = numbers(characters), d.count == 11, cuitTypes.contains(d[0] * 10 + d[1]), let last = cuilDigit(d[0..<10]) else { return false }
            return d[10] == last
        }, draw: { like, rng in
            // Its type kept: a person's stays a person's, a company's a company's.
            let given = numbers(like).flatMap { $0.count == 11 && cuitTypes.contains($0[0] * 10 + $0[1]) ? Array($0.prefix(2)) : nil }
            while true {
                let d = (given ?? (Int.random(in: 0...1, using: &rng) == 0 ? [2, 0] : [2, 7])) + randomDigits(8, &rng)
                if let last = cuilDigit(d[...]) { return characters(d + [last]) }
            }
        }),
        Recognizer("RUT", keys: ["rut", "rutnumber", "numerorut"], forms: [
            .init(#"\b\d{1,2}\.\d{3}\.\d{3}-[\dkK](?![\w-])"#, 0.5, alone: true),
            .init(#"\b\d{7,8}-[\dkK](?![\w-])"#, 0.1),
            .init(#"\b\d{7,8}[\dkK]\b"#, 0.05),
            .init(#"\bCL ?(?:\d{1,2}\.\d{3}\.\d{3}|\d{7,8})-?[\dK](?![\w-])"#, 0.3),
        ], context: ["rut"], check: { characters in
            // Chile's RUT, its country written before it or not.
            let characters = characters.starts(with: ["C", "L"]) ? Array(characters.dropFirst(2)) : characters
            guard (8...9).contains(characters.count), let body = numbers(Array(characters.dropLast())) else { return false }
            return characters.last == rutDigit(body)
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["C", "L"]) ? ["C", "L"] : []
            let count = like.count - prefix.count
            // Its check a K where the original's was, a digit where it was one.
            var made: [Character] = []
            for _ in 0..<64 {
                let body = [Int.random(in: 1...9, using: &rng)] + randomDigits(max(6, min(7, count - 2)), &rng)
                made = prefix + characters(body) + [rutDigit(body)]
                if like.last.map({ ($0 == "K") == (made.last == "K") }) ?? true { break }
            }
            return made
        }),
        Recognizer("CURP", keys: ["curp"], forms: [
            .init(#"\b[A-Z][AEIOUX][A-Z]{2}\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[HMX](?:AS|BC|BS|CC|CL|CM|CS|CH|DF|DG|GT|GR|HG|JC|MC|MN|MS|NT|NL|OC|PL|QT|QR|SP|SL|SR|TC|TS|TL|VZ|YN|ZS|NE)[B-DF-HJ-NP-TV-Z]{3}[A-Z\d]\d\b"#, 0.6, alone: true),
        ], context: ["curp"], check: { characters in
            // Never one of RENAPO's inconvenient words: its second letter is written X instead.
            guard characters.count == 18, let last = characters[17].wholeNumberValue, !curpBlocked.contains(String(characters.prefix(4))) else { return false }
            return curpDigit(characters[0..<17]) == last
        }, draw: { _, rng in
            let date = randomDate(&rng)
            var c = [pick(consonants, &rng), pick("AEIOU", &rng), pick(letters, &rng), pick(letters, &rng)]
            if curpBlocked.contains(String(c)) { c[1] = "X" }
            c += characters(twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day))
            c += [pick("HM", &rng)] + Array(["JC", "NL", "DF", "PL", "GT", "VZ", "CH", "SR"][Int.random(in: 0..<8, using: &rng)])
            c += [pick(consonants, &rng), pick(consonants, &rng), pick(consonants, &rng), Character(String(Int.random(in: 0...9, using: &rng)))]
            return c + [Character(String(curpDigit(c[...])))]
        }),
        Recognizer("RFC", keys: ["rfc"], forms: [
            .init(#"(?<![\w&])[A-ZÑ&]{4}[ -]?\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[ -]?[A-Z\d]{2}[\dA](?![\w&])"#, 0.3),
            .init(#"(?<![\w&])[A-ZÑ&]{3}[ -]?\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[ -]?[A-Z\d]{2}[\dA](?![\w&])"#, 0.3),
            // A person's before SAT gave the homoclave.
            .init(#"(?<![\w&])[A-ZÑ&]{4}[ -]?\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?![\w&-])"#, 0.3),
        ], context: ["rfc", "registro federal de contribuyentes"], verifies: false, separators: " -", check: { characters in
            // Mexico's RFC: a person's four letters or a company's three, a real date, a homoclave and a check character
            // SAT computes but numbers in use don't all carry, so the kind is known by its shape.
            rfcValid(characters)
        }, draw: { like, rng in
            rfcDraw(like, &rng)
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
            .init(#"\bES[ -]{0,2}\d{8}-?[A-HJ-NP-TV-Z]\b"#, 0.3),
        ], context: ["dni", "nif", "documento", "identidad", "tax", "fiscal", "vat", "vatin"], check: { characters in
            // As a Spanish VAT number, written after ES.
            let body = characters.count == 11 && characters.starts(with: ["E", "S"]) ? Array(characters.dropFirst(2)) : characters
            guard body.count == 9, let d = numbers(Array(body.prefix(8))) else { return false }
            return dniLetter(number(d)) == body[8]
        }, draw: { like, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            return (like.count == 11 && like.starts(with: ["E", "S"]) ? ["E", "S"] : []) + characters(d) + [dniLetter(number(d))]
        }),
        Recognizer("NIE", keys: ["nie", "nienumber"], forms: [
            .init(#"\b[XYZ]-?\d{7}-?[A-HJ-NP-TV-Z]\b"#, 0.3),
            .init(#"\bES[ -]{0,2}[XYZ]-?\d{7}-?[A-HJ-NP-TV-Z]\b"#, 0.3),
        ], context: ["nie", "nif", "extranjero", "tax", "fiscal", "vat", "vatin"], check: { characters in
            // As a Spanish VAT number, written after ES.
            let body = characters.count == 11 && characters.starts(with: ["E", "S"]) ? Array(characters.dropFirst(2)) : characters
            guard body.count == 9, let lead = "XYZ".firstIndex(of: body[0]), let d = numbers(Array(body[1..<8])) else { return false }
            return dniLetter("XYZ".distance(from: "XYZ".startIndex, to: lead) * 10_000_000 + number(d)) == body[8]
        }, draw: { like, rng in
            let prefixed = like.count == 11 && like.starts(with: ["E", "S"])
            // X, Y or Z, as the original's.
            let lead = like.dropFirst(prefixed ? 2 : 0).first.flatMap { "XYZ".firstIndex(of: $0) }.map { "XYZ".distance(from: "XYZ".startIndex, to: $0) } ?? Int.random(in: 0...1, using: &rng)
            let d = randomDigits(7, &rng)
            return (prefixed ? ["E", "S"] : []) + [Array("XYZ")[lead]] + characters(d) + [dniLetter(lead * 10_000_000 + number(d))]
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
        Recognizer("BELGIAN_NATIONAL_NUMBER", keys: ["rijksregisternummer", "insz", "niss", "registrenational", "bis", "bisnummer", "numerobis", "nn"], forms: [
            .init(#"\b\d{2}\.\d{2}\.\d{2}-\d{3}\.\d{2}\b"#, 0.5, alone: true),
            .init(#"\b\d{2}[. ]\d{2}[. ]\d{2}[- ]\d{3}[. ]\d{2}\b"#, 0.1),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["rijksregisternummer", "rijksregister", "insz", "niss", "rrn", "ssn", "social security", "sociale zekerheid", "sécurité sociale", "numéro national", "registre national"], check: { characters in
            // Belgium's national (or BIS) number: a birth date whose month may carry 20 or 40, a serial, and 97 less the first nine mod 97 (a 2 before them from 2000).
            guard let d = numbers(characters), d.count == 11, (d[2] * 10 + d[3]) % 20 <= 12 else { return false }
            let body = number(Array(d[0..<9])), key = d[9] * 10 + d[10]
            return key == 97 - body % 97 || 2000 + d[0] * 10 + d[1] <= currentYear && key == 97 - (2_000_000_000 + body) % 97
        }, draw: { like, rng in
            let date = randomDate(&rng)
            // A BIS number's month has 20 or 40 added; one born since 2000 is checked with a 2 before it: both kept so.
            let added = like.count == 11 ? ((like[2].wholeNumberValue ?? 0) / 2) * 20 : 0
            let since2000: Bool = {
                guard let d = numbers(like), d.count == 11 else { return false }
                return d[9] * 10 + d[10] != 97 - number(Array(d[0..<9])) % 97
            }()
            let year = since2000 ? Int.random(in: 2000...max(2000, currentYear - 1), using: &rng) : date.year
            let body = twoDigits(year % 100) + twoDigits(date.month + (added == 20 || added == 40 ? added : 0)) + twoDigits(date.day) + [0] + twoDigits(Int.random(in: 1...97, using: &rng))
            return characters(body + twoDigits(97 - (number(body) + (since2000 ? 2_000_000_000 : 0)) % 97))
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
            .init(#"\b[1-9]\d{9} \d\b"#, 0.05),
        ], context: ["steuerid", "steueridentifikationsnummer", "idnr", "identifikationsnummer"], check: { characters in
            guard let d = numbers(characters), d.count == 11, d[0] != 0 else { return false }
            // Exactly one digit written twice or three times, the three never all side by side (the BZSt's rule).
            let counts = Dictionary(grouping: d[0..<10], by: { $0 }).mapValues(\.count)
            let repeated = counts.filter { $0.value > 1 }
            guard repeated.count == 1, let (digit, times) = repeated.first, times <= 3 else { return false }
            if times == 3, (0..<8).contains(where: { d[$0] == digit && d[$0 + 1] == digit && d[$0 + 2] == digit }) { return false }
            return steuerDigit(d[0..<10]) == d[10]
        }, draw: { _, rng in
            // Ten distinct digits, none leading 0, then one of them written again in another place.
            var d = Array(0...9).shuffled(using: &rng)
            if d[0] == 0 { d.swapAt(0, 1) }
            d[Int.random(in: 1...9, using: &rng)] = d[0]
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
            .init(#"\b(?:[0-6]\d|7[01])(?:[04][1-9]|[15][0-2])\d{7}\b"#, 0.05),
            .init(#"\b(?:[0-6]\d|7[01])(?:[04][1-9]|[15][0-2])\d{2}[- ]\d{5}\b"#, 0.1),
            // Grouped otherwise ("10 04 87 44 732", "13-04-99-58441"): only where named.
            .init(#"\b(?:[0-6]\d|7[01])[- ]?(?:[04][1-9]|[15][0-2])(?:[- ]?\d){7}\b"#, 0.05),
        ], context: ["fødselsnummer", "fodselsnummer", "personnummer"], check: { characters in
            guard let d = numbers(characters), d.count == 11, let first = norwayDigit(d[0..<9], [3, 7, 6, 1, 8, 9, 4, 5, 2]),
                  let second = norwayDigit(d[0..<10], [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) else { return false }
            return first == d[9] && second == d[10] && norwayBirth(d)
        }, draw: { like, rng in
            // A D-number (40 added to its day) stays one.
            let added = numbers(like).map { $0.count == 11 && $0[0] >= 4 ? 40 : 0 } ?? 0
            while true {
                let date = randomDate(&rng)
                // Born 1950–1999: an individual number from 000 to 499.
                var d = twoDigits(date.day + added) + twoDigits(date.month) + twoDigits(date.year % 100) + digitsOf(Int.random(in: 0...499, using: &rng), 3)
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
            .init(#"\b[2-9]\d{3}([-: ]?)\d{4}\1\d{4}\b"#, 0.05),
        ], context: ["aadhaar", "aadhar", "uidai"], separators: " -:", check: { characters in
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
        Recognizer("RESIDENT_ID", keys: ["residentid", "residentidnumber", "shenfenzheng", "ric"], forms: [
            .init(#"\b[1-8]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]\b"#, 0.5, alone: true),
        ], context: ["身份证", "身份证号", "shenfenzheng"], check: { characters in
            guard characters.count == 18, let d = numbers(Array(characters[0..<17])),
                  realDate(year: number(Array(d[6..<10])), month: d[10] * 10 + d[11], day: d[12] * 10 + d[13]) else { return false }
            return residentMark(d) == characters[17]
        }, draw: { like, rng in
            // A random birth date and a county from a fixed set in use through every year the draw gives (1950 to 1999);
            // nothing of the original's date or place is kept.
            residentDraw(like, &rng)
        }),
        Recognizer("RRN", keys: ["rrn", "residentregistrationnumber"], forms: [
            .init(#"(?<!\d)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])-\d{7}(?!\d)"#, 0.3),
            .init(#"(?<!\d)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{7}(?!\d)"#, 0.05),
        ], context: ["rrn", "주민등록번호", "외국인등록번호", "주민번호", "외국인번호", "resident registration number", "foreigner registration number", "frn"], verifies: false, check: { characters in
            guard let d = numbers(characters), d.count == 13 else { return false }
            let century = [9: 1800, 0: 1800, 1: 1900, 2: 1900, 5: 1900, 6: 1900, 3: 2000, 4: 2000, 7: 2000, 8: 2000][d[6]] ?? 1900
            return realDate(year: century + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5])
        }, draw: { like, rng in
            // Its seventh digit says citizen or foreigner and the century: kept. A place of birth from 00 to 95 follows it, and
            // one check digit closes citizen's and foreigner's alike, as numbers in use carry it.
            let kind = like.count == 13 ? like[6].wholeNumberValue : nil
            let date = randomDate(&rng)
            let seventh = kind ?? Int.random(in: 1...2, using: &rng)
            var d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + [seventh] + twoDigits(Int.random(in: 0...95, using: &rng)) + randomDigits(3, &rng)
            let sum = zip(d, [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5]).reduce(0) { $0 + $1.0 * $1.1 }
            d.append((11 - sum % 11) % 10)
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
        ], context: ["tckn", "kimlik", "tc no", "t.c.", "nüfus cüzdanı", "turkish id", "türk kimlik"], check: { characters in
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
        ], context: ["身分證", "身分證字號", "taiwan"], check: { characters in
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
        Recognizer("KVNR", keys: ["kvnr", "krankenversichertennummer", "versichertennummer", "krankenversicherungsnummer", "healthinsurance", "healthinsurancenumber", "egk", "egknummer"], forms: [
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
        ], context: ["npi", "national provider", "provider identifier", "provider id"], check: { characters in
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
            // Its last digit as validators compute it (Luhn over the seven), though the Election Commission publishes no check.
            let body = randomDigits(6, &rng)
            return [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng)] + characters(body + [luhnDigit(body)])
        }),
        Recognizer("THAI_ID", keys: ["thaiid", "thainationalid"], forms: [
            .init(#"\b[1-8]-\d{4}-\d{5}-\d{2}-\d\b"#, 0.5, alone: true),
            .init(#"\b[1-8] \d{4} \d{5} \d{2} \d\b"#, 0.5, alone: true),
            // A person's taxpayer number written as a company's is (1-2-1-3-5-1).
            .init(#"\b[1-8]-\d{2}-\d-\d{3}-\d{5}-\d\b"#, 0.3),
            .init(#"\b[1-8]\d{12}\b"#, 0.05),
            // Spaced however a form spaced it ("3   451  000  50     5414"): only where named.
            .init(#"\b[1-8](?: {0,6}\d){12}\b"#, 0.05),
        ], context: ["บัตรประชาชน", "เลขประจำตัวประชาชน", "เลขบัตรประชาชน", "thai", "tnin", "thai national id", "pin", "tin", "เลขประจำตัวผู้เสียภาษี", "เลขประจำตัวผู้เสียภาษีอากร"], check: { characters in
            // Its second and third digits are a province's code (ISO 3166-2:TH).
            guard let d = numbers(characters), d.count == 13, thaiProvinces.contains(d[1] * 10 + d[2]) else { return false }
            return thaiDigit(Array(d[0..<12])) == d[12]
        }, draw: { _, rng in
            let province = thaiProvinces.sorted().randomElement(using: &rng) ?? 10
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
        Recognizer("TEUDAT_ZEHUT", keys: ["teudatzehut", "zehut", "israeliid", "misparzehut"], forms: [
            .init(#"\b\d{9}\b"#, 0.05),
            .init(#"\b\d{7,8}\b"#, 0.05),
            .init(#"\b\d{6,8}-\d\b"#, 0.1),
        ], context: ["zehut", "teudat", "mispar zehut", "תעודת", "זהות", "מספר זהות"], separators: " -", check: { characters in
            // Israel's: nine digits with a Luhn check, written without the zeros that lead it ("3933742-3" is 039337423).
            guard let d = numbers(characters), (7...9).contains(d.count), d.contains(where: { $0 != 0 }) else { return false }
            return Patterns.luhn(d)
        }, draw: { like, rng in
            let count = (7...9).contains(like.count) ? like.count : 9
            let d = (count < 9 ? [Int.random(in: 1...9, using: &rng)] : [Int.random(in: 0...3, using: &rng)]) + randomDigits(count - 2, &rng)
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
        // Europe, the Americas, Asia and Africa: people's own numbers.
        Recognizer("ES_NIF_KLM", keys: ["nif", "nifnumber"], forms: [
            .init(#"\b[KLM]-?\d{7}-?[A-HJ-NP-TV-Z]\b"#, 0.3),
        ], context: ["nif", "tax", "fiscal"], check: { characters in
            // A resident under 14 (K), a Spaniard abroad (L) or a foreigner without a NIE (M): a DNI's letter over its seven digits.
            guard characters.count == 9, "KLM".contains(characters[0]), let d = numbers(Array(characters[1..<8])) else { return false }
            return dniLetter(number(d)) == characters[8]
        }, draw: { like, rng in
            let d = randomDigits(7, &rng)
            return [like.first.flatMap { "KLM".contains($0) ? $0 : nil } ?? "L"] + characters(d) + [dniLetter(number(d))]
        }),
        Recognizer("BG_EGN", keys: ["egn", "egnnumber"], forms: [
            .init(#"\b\d{2}(?:[024]\d|[135][0-2])(?:0[1-9]|[12]\d|3[01])\d{4}\b"#, 0.05),
            .init(#"\b\d{2}(?:[024]\d|[135][0-2])(?:0[1-9]|[12]\d|3[01]) \d{3} \d\b"#, 0.1),
        ], context: ["egn", "егн", "единен граждански номер"], check: { characters in
            guard let d = numbers(characters), d.count == 10 else { return false }
            // Its month carries its century: 21–32 the 1800s, 41–52 the 2000s.
            let coded = d[2] * 10 + d[3], century = coded > 40 ? 2000 : coded > 20 ? 1800 : 1900
            guard realDate(year: century + d[0] * 10 + d[1], month: coded % 20, day: d[4] * 10 + d[5]) else { return false }
            return zip(d[0..<9], [2, 4, 8, 5, 10, 9, 7, 3, 6]).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10 == d[9]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(3, &rng)
            return characters(d + [zip(d, [2, 4, 8, 5, 10, 9, 7, 3, 6]).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10])
        }),
        Recognizer("CH_AHV", keys: ["ahv", "ahvnummer", "ahvnr", "avs", "avsnumber", "numeroavs", "ahvn13", "avsn13"], forms: [
            .init(#"\b756\.\d{4}\.\d{4}\.\d{2}\b"#, 0.5, alone: true),
            .init(#"\b756\d{10}\b"#, 0.1),
        ], context: ["ahv", "avs", "ahv-nr", "ahv-nummer", "n° avs", "numéro avs", "sozialversicherungsnummer", "social security", "ssn"], check: { characters in
            // Switzerland's 756, then an EAN-13's check.
            guard let d = numbers(characters), d.count == 13, d.prefix(3) == [7, 5, 6] else { return false }
            return eanDigit(Array(d[0..<12])) == d[12]
        }, draw: { _, rng in
            let body = [7, 5, 6] + randomDigits(9, &rng)
            return characters(body + [eanDigit(body)])
        }),
        Recognizer("RODNE_CISLO", keys: ["rodnecislo", "rc", "birthnumber"], forms: [
            .init(#"\b\d{2}(?:[0156]\d|[2378][0-2])(?:0[1-9]|[12]\d|3[01])/\d{3,4}\b"#, 0.3),
            .init(#"\b\d{2}(?:[0156]\d|[2378][0-2])(?:0[1-9]|[12]\d|3[01])\d{3,4}\b"#, 0.05),
        ], context: ["rodné číslo", "rodne cislo", "rodné čislo", "r.č.", "rč", "birth number"], separators: " /", check: { characters in
            // Czech and Slovak: a woman's month has 50 added, a late number's 20; nine digits before 1954, ten with a check after.
            guard let d = numbers(characters), d.count == 9 || d.count == 10 else { return false }
            var year = 1900 + d[0] * 10 + d[1]
            if d.count == 9 { if year >= 1980 { year -= 100 }; guard year <= 1953 else { return false } } else if year < 1954 { year += 100 }
            guard realDate(year: year, month: (d[2] * 10 + d[3]) % 50 % 20, day: d[4] * 10 + d[5]) else { return false }
            return d.count == 9 || number(Array(d[0..<9])) % 11 % 10 == d[9]
        }, draw: { like, rng in
            let year = like.count == 9 ? Int.random(in: 1920...1953, using: &rng) : Int.random(in: 1955...1999, using: &rng)
            let date = randomDate(&rng)
            let month = date.month + (Bool.random(using: &rng) ? 50 : 0)
            let body = twoDigits(year % 100) + twoDigits(month) + twoDigits(date.day) + randomDigits(3, &rng)
            return characters(like.count == 9 ? body : body + [number(body) % 11 % 10])
        }),
        Recognizer("ISIKUKOOD", keys: ["isikukood", "asmenskodas", "asmens", "ik"], forms: [
            .init(#"\b[1-8]\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{4}\b"#, 0.05),
        ], context: ["isikukood", "asmens kodas", "personal code", "isikukoodi"], check: { characters in
            // Estonia's and Lithuania's: the first digit says the century and sex.
            guard let d = numbers(characters), d.count == 11, (1...8).contains(d[0]) else { return false }
            guard realDate(year: 1800 + (d[0] - 1) / 2 * 100 + d[1] * 10 + d[2], month: d[3] * 10 + d[4], day: d[5] * 10 + d[6]) else { return false }
            return isikukoodDigit(Array(d[0..<10])) == d[10]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let body = [Int.random(in: 3...4, using: &rng)] + twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(3, &rng)
            return characters(body + [isikukoodDigit(body)])
        }),
        Recognizer("AMKA", keys: ["amka"], forms: [
            .init(#"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{7}\b"#, 0.05),
        ], context: ["amka", "αμκα", "α.μ.κ.α."], check: { characters in
            // Greece's: a birth date, then a Luhn check.
            guard let d = numbers(characters), d.count == 11, Patterns.luhn(d) else { return false }
            return [1900, 2000].contains { realDate(year: $0 + d[4] * 10 + d[5], month: d[2] * 10 + d[3], day: d[0] * 10 + d[1]) }
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let body = twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + randomDigits(4, &rng)
            return characters(body + [luhnDigit(body)])
        }),
        Recognizer("PPS", keys: ["pps", "ppsn", "ppsnumber", "ppsno", "personalpublicservicenumber"], forms: [
            .init(#"\b\d{7}[A-W][ABHWTX]?\b"#, 0.1),
        ], context: ["pps", "ppsn", "personal public service"], separators: " -", check: { characters in
            // Ireland's: a letter checking the seven digits, and a second letter's weight since 2013.
            guard characters.count == 8 || characters.count == 9, let d = numbers(Array(characters.prefix(7))) else { return false }
            let second = characters.count == 9 && "ABH".contains(characters[8]) ? characters[8] : nil
            return ppsLetter(d, second) == characters[7] && (characters.count == 8 || "ABHWTX".contains(characters[8]))
        }, draw: { like, rng in
            let d = randomDigits(7, &rng)
            let second: Character? = like.count == 9 ? (like[8] == "W" ? "W" : "A") : nil
            return characters(d) + [ppsLetter(d, second == "W" ? nil : second)] + (second.map { [$0] } ?? [])
        }),
        Recognizer("KENNITALA", keys: ["kennitala", "kt"], forms: [
            .init(#"\b(?:[0-2]\d|3[01]|[4-6]\d|7[01])(?:0[1-9]|1[0-2])\d{2}-?\d{3}[09]\b"#, 0.1),
        ], context: ["kennitala", "kt.", "kt"], separators: "-", check: { characters in
            // Iceland's: a birth date (a company's founding, its day plus 40), a check over it, and its century (9 the 1900s, 0 the 2000s).
            guard let d = numbers(characters), d.count == 10, d[9] == 9 || d[9] == 0 else { return false }
            let day = d[0] * 10 + d[1]
            guard realDate(year: (d[9] == 9 ? 1900 : 2000) + d[4] * 10 + d[5], month: d[2] * 10 + d[3], day: day > 40 ? day - 40 : day) else { return false }
            return zip(d, [3, 2, 7, 6, 5, 4, 3, 2, 1, 0]).reduce(0) { $0 + $1.0 * $1.1 } % 11 == 0
        }, draw: { like, rng in
            // A company's stays a company's, and its century stays.
            let company = like.first.map { "4567".contains($0) } ?? false
            let century = like.count == 10 && like[9] == "0" ? 0 : 9
            while true {
                let date = randomDate(&rng)
                let year = century == 0 ? Int.random(in: 2000...max(2000, currentYear - 1), using: &rng) : date.year
                let body = twoDigits(date.day + (company ? 40 : 0)) + twoDigits(date.month) + twoDigits(year % 100) + randomDigits(2, &rng)
                let check = (11 - zip(body, [3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 11
                if check < 10 { return characters(body + [check, century]) }
            }
        }),
        Recognizer("CNP", keys: ["cnp", "codnumericpersonal"], forms: [
            .init(#"\b[1-8]\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?:[0-4]\d|5[12]|70|8[0-3])\d{4}\b"#, 0.1),
        ], context: ["cnp", "cod numeric personal", "codul numeric personal"], check: { characters in
            // Romania's: sex and century, birth date, county, then a weighted check.
            guard let d = numbers(characters), d.count == 13 else { return false }
            let century = [1: 1900, 2: 1900, 3: 1800, 4: 1800, 5: 2000, 6: 2000][d[0]] ?? 1900
            let county = d[7] * 10 + d[8]
            guard realDate(year: century + d[1] * 10 + d[2], month: d[3] * 10 + d[4], day: d[5] * 10 + d[6]), (1...48).contains(county) || [51, 52, 70, 80, 81, 82, 83].contains(county) else { return false }
            return cnpDigit(Array(d[0..<12])) == d[12]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let body = [Int.random(in: 1...2, using: &rng)] + twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + twoDigits(Int.random(in: 1...46, using: &rng)) + [Int.random(in: 0...9, using: &rng)] + twoDigits(Int.random(in: 1...99, using: &rng))
            return characters(body + [cnpDigit(body)])
        }),
        Recognizer("EMSO", keys: ["emso", "emšo", "jmbg", "emsonumber"], forms: [
            .init(#"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])[09]\d{2}\d{6}\b"#, 0.05),
        ], context: ["emšo", "emso", "jmbg", "enotna matična številka občana", "matični broj"], check: { characters in
            // Slovenia's (and the other Yugoslav states'): birth date with three-digit year, region, serial, mod 11.
            guard let d = numbers(characters), d.count == 13 else { return false }
            let short = d[4] * 100 + d[5] * 10 + d[6]
            guard realDate(year: short < 800 ? 2000 + short : 1000 + short, month: d[2] * 10 + d[3], day: d[0] * 10 + d[1]) else { return false }
            return emsoDigit(Array(d[0..<12])) == d[12]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let body = twoDigits(date.day) + twoDigits(date.month) + [9] + twoDigits(date.year % 100) + [5, 0] + randomDigits(3, &rng)
            return characters(body + [emsoDigit(body)])
        }),
        Recognizer("AT_SVNR", keys: ["svnr", "svnummer", "versicherungsnummer", "sozialversicherungsnummer", "vsnr", "vnr"], forms: [
            .init(#"\b[1-9]\d{3} ?(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}\b"#, 0.05),
        ], context: ["svnr", "sv-nr", "sv-nummer", "versicherungsnummer", "sozialversicherungsnummer"], check: { characters in
            // Austria's: a serial, its check, then the birth date.
            guard let d = numbers(characters), d.count == 10, d[0] != 0 else { return false }
            return svnrDigit(d) == d[3]
        }, draw: { _, rng in
            while true {
                let date = randomDate(&rng)
                var d = [Int.random(in: 1...9, using: &rng)] + randomDigits(2, &rng) + [0] + twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100)
                d[3] = svnrDigit(d)
                if d[3] < 10 { return characters(d) }
            }
        }),
        Recognizer("PT_CC", keys: ["cartaodecidadao", "cartaocidadao", "numerocc", "ccnumber"], forms: [
            .init(#"\b\d{8} ?\d ?[A-Z]{2}\d\b"#, 0.3, alone: true),
        ], context: ["cartão de cidadão", "cartao de cidadao", "cartão do cidadão", "citizen card"], check: { characters in
            // Portugal's citizen card: the civil number with its check, two letters, and a check over all.
            guard characters.count == 12, numbers(Array(characters.prefix(9))) != nil, characters[9].isLetter, characters[10].isLetter, let last = characters[11].wholeNumberValue else { return false }
            return ccDigit(Array(characters.prefix(11))) == last
        }, draw: { like, rng in
            let body = characters(randomDigits(9, &rng)) + [pick("ABCDEFGHIJKLMNOPQRSTUVWXYZ", &rng), pick("ABCDEFGHIJKLMNOPQRSTUVWXYZ", &rng)]
            return body + characters([ccDigit(body)])
        }),
        Recognizer("FR_NIF", keys: ["numerofiscal", "spi", "numerospi", "numfiscal"], forms: [
            .init(#"\b[0-3]\d \d{2} \d{3} \d{3} \d{3}\b"#, 0.3),
            .init(#"\b[0-3]\d{12}\b"#, 0.05),
        ], context: ["numéro fiscal", "numero fiscal", "spi", "référence de l'avis", "numéro fiscal de référence"], check: { characters in
            // France's tax number: its last three digits are the first ten's remainder by 511.
            guard let d = numbers(characters), d.count == 13, d[0] <= 3 else { return false }
            return number(Array(d[0..<10])) % 511 == number(Array(d[10...]))
        }, draw: { _, rng in
            let body = [Int.random(in: 0...3, using: &rng)] + randomDigits(9, &rng)
            let check = number(body) % 511
            return characters(body + [check / 100, check / 10 % 10, check % 10])
        }),
        Recognizer("LV_PERSONAS_KODS", keys: ["personaskods", "personaskodas", "pvn"], forms: [
            .init(#"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}-?[0-2]\d{4}\b"#, 0.1),
            .init(#"\b32\d{4}-?\d{5}\b"#, 0.1),
        ], context: ["personas kods", "personas kodu", "p.k."], check: { characters in
            // Latvia's: a birth date and its century, or since 2017 a 32 and no date; a weighted check either way.
            guard let d = numbers(characters), d.count == 11 else { return false }
            if !(d[0] == 3 && d[1] == 2) {
                guard realDate(year: 1800 + d[6] * 100 + d[4] * 10 + d[5], month: d[2] * 10 + d[3], day: d[0] * 10 + d[1]) else { return false }
            }
            return latvianDigit(Array(d[0..<10])) == d[10]
        }, draw: { like, rng in
            let date = randomDate(&rng)
            let body = like.starts(with: ["3", "2"]) ? [3, 2] + randomDigits(8, &rng) : twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + [1] + randomDigits(3, &rng)
            return characters(body + [latvianDigit(body)])
        }),
        Recognizer("CU_NI", keys: ["carnetidentidad", "carnetdeidentidad", "numeroidentidad"], forms: [
            .init(#"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{5}\b"#, 0.05),
        ], context: ["carné de identidad", "carnet de identidad", "número de identidad permanente"], verifies: false, check: { characters in
            // Cuba's: a birth date whose century the seventh digit says.
            guard let d = numbers(characters), d.count == 11 else { return false }
            let century = d[6] == 9 ? 1800 : d[6] <= 5 ? 1900 : 2000
            return realDate(year: century + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5])
        }, draw: { _, rng in
            let date = randomDate(&rng)
            return characters(twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + [Int.random(in: 0...5, using: &rng)] + randomDigits(4, &rng))
        }),
        Recognizer("DO_CEDULA", keys: ["cedula", "cedulaidentidad", "cedulanumber", "numerocedula"], forms: [
            .init(#"\b\d{3}-\d{7}-\d\b"#, 0.3),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["cédula", "cedula", "cédula de identidad", "cedula de identidad"], verifies: false, check: { characters in
            // The Dominican Republic's: a municipality, a serial and a Luhn check, which a few thousand early ones fail.
            numbers(characters)?.count == 11
        }, draw: { like, rng in
            // Its municipality kept: a place, nobody's own.
            let place = numbers(Array(like.prefix(3))) ?? [0, 0, 1]
            let body = place + randomDigits(7, &rng)
            return characters(body + [luhnDigit(body)])
        }),
        Recognizer("EC_CI", keys: ["cedula", "cedulaidentidad", "ci", "cedulaciudadania"], forms: [
            .init(#"\b(?:0[1-9]|1\d|2[0-4]|30|50)[0-5]\d{6}-?\d\b"#, 0.05),
        ], context: ["cédula", "cedula", "cédula de ciudadanía", "cédula de identidad", "ci"], check: { characters in
            // Ecuador's: a province, a person's third digit, and a check folding doubled digits.
            guard let d = numbers(characters), d.count == 10 else { return false }
            let province = d[0] * 10 + d[1]
            guard (1...24).contains(province) || province == 30 || province == 50, d[2] < 6 else { return false }
            return ecuadorSum(d) == 0
        }, draw: { like, rng in
            let place = numbers(Array(like.prefix(2))) ?? [1, 7]
            let body = place + [Int.random(in: 0...5, using: &rng)] + randomDigits(6, &rng)
            return characters(body + [(10 - ecuadorSum(body + [0])) % 10])
        }),
        Recognizer("ID_NIK", keys: ["nik", "nomorindukkependudukan", "noktp", "ktp", "nomorktp"], forms: [
            .init(#"\b\d{6}(?:[0-6]\d|7[01])(?:0[1-9]|1[0-2])\d{6}\b"#, 0.05),
        ], context: ["nik", "ktp", "nomor induk kependudukan", "no. ktp"], verifies: false, check: { characters in
            // Indonesia's: a place, a birth date (a woman's day has 40 added), a serial.
            guard let d = numbers(characters), d.count == 16 else { return false }
            let day = (d[6] * 10 + d[7]) % 40, month = d[8] * 10 + d[9], year = d[10] * 10 + d[11]
            return d[0] != 0 && [1900, 2000].contains { realDate(year: $0 + year, month: month, day: day) }
        }, draw: { like, rng in
            let place = numbers(Array(like.prefix(6))) ?? [3, 1, 7, 1, 0, 1]
            let date = randomDate(&rng)
            return characters(place + twoDigits(date.day + (Bool.random(using: &rng) ? 40 : 0)) + twoDigits(date.month) + twoDigits(date.year % 100) + [0] + randomDigits(3, &rng))
        }),
        Recognizer("MY_NRIC", keys: ["mykad", "mykadnumber", "nricmy", "icnumber", "kadpengenalan", "nombormykad"], forms: [
            .init(#"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])-\d{2}-\d{4}\b"#, 0.4, alone: true),
            .init(#"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{6}\b"#, 0.05),
        ], context: ["mykad", "nric", "kad pengenalan", "no. k/p", "ic number", "no. ic"], verifies: false, check: { characters in
            // Malaysia's: a birth date, a birthplace, a serial.
            guard let d = numbers(characters), d.count == 12 else { return false }
            return [1900, 2000].contains { realDate(year: $0 + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5]) } && !(d[6] == 0 && d[7] == 0)
        }, draw: { like, rng in
            let date = randomDate(&rng)
            // Its birthplace kept: a state, nobody's own.
            let place = numbers(Array(like.dropFirst(6).prefix(2))) ?? [1, 4]
            return characters(twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + place + randomDigits(4, &rng))
        }),
        Recognizer("PK_CNIC", keys: ["cnic", "cnicnumber", "cnicno", "nicop"], forms: [
            .init(#"\b[1-7]\d{4}-\d{7}-\d\b"#, 0.4, alone: true),
            .init(#"\b[1-7]\d{11}[1-9]\b"#, 0.05),
        ], context: ["cnic", "nicop", "computerized national identity card", "شناختی کارڈ"], verifies: false, check: { characters in
            // Pakistan's: a province, a serial, and a last digit saying the sex.
            guard let d = numbers(characters), d.count == 13 else { return false }
            return (1...7).contains(d[0]) && d[12] != 0
        }, draw: { like, rng in
            let province = numbers(Array(like.prefix(1))) ?? [3]
            return characters(province + randomDigits(11, &rng) + [Int.random(in: 1...9, using: &rng)])
        }),
        Recognizer("MU_NID", keys: ["nid", "nidnumber", "nationalidentitycard", "nic"], forms: [
            .init(#"\b[A-Z](?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}\d{6}[0-9A-Z]\b"#, 0.1),
        ], context: ["nid", "national identity card", "mauritius"], check: { characters in
            // Mauritius's: the surname's initial, a birth date, a serial and a check over all.
            guard characters.count == 14, characters[0].isLetter, numbers(Array(characters[1..<13])) != nil else { return false }
            return mauritiusMark(Array(characters.prefix(13))) == characters[13]
        }, draw: { like, rng in
            let date = randomDate(&rng)
            let body = [like.first.flatMap { $0.isLetter ? $0 : nil } ?? "A"] + characters(twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + randomDigits(6, &rng))
            return body + [mauritiusMark(body)]
        }),
        Recognizer("KE_PIN", keys: ["kra", "krapin", "pinnumber", "pin"], forms: [
            .init(#"\b[AP]\d{9}[A-Z]\b"#, 0.3),
            .init(#"\b[AP] ?\d{9} ?-? ?[A-Z]\b"#, 0.1),
        ], context: ["kra", "kra pin", "pin"], verifies: false, check: { characters in
            // Kenya's tax PIN: A for a person, P for a company, nine digits, a letter.
            characters.count == 11 && "AP".contains(characters[0]) && numbers(Array(characters[1..<10])) != nil && characters[10].isLetter
        }, draw: { like, rng in
            [like.first.flatMap { "AP".contains($0) ? $0 : nil } ?? "A"] + characters([0] + randomDigits(8, &rng)) + [pick("ABCDEFGHJKLMNPQRSTUVWXYZ", &rng)]
        }),
        Recognizer("AADHAAR_VID", keys: ["virtualid", "aadhaarvid", "aadhaarvirtualid"], forms: [
            .init(#"\b[2-9]\d{3} ?\d{4} ?\d{4} ?\d{4}\b"#, 0.05),
        ], context: ["virtual id", "aadhaar vid", "aadhaar virtual id"], check: { characters in
            // India's virtual ID for an Aadhaar: sixteen digits, a Verhoeff check, never a palindrome.
            guard let d = numbers(characters), d.count == 16, d[0] >= 2, d != d.reversed() else { return false }
            return verhoeff(d) == 0
        }, draw: { _, rng in
            let body = [Int.random(in: 2...9, using: &rng)] + randomDigits(14, &rng)
            return characters(body + [verhoeffDigit(body)])
        }),
        Recognizer("BC_PHN", keys: ["phn", "personalhealthnumber", "bcphn", "carecardnumber"], forms: [
            .init(#"\b9\d{3} ?\d{3} ?\d{3}\b"#, 0.05),
        ], context: ["phn", "personal health number", "care card", "bc services card"], check: { characters in
            // British Columbia's personal health number: a 9, eight digits and a weighted check.
            guard let d = numbers(characters), d.count == 10, d[0] == 9, let check = bcDigit(Array(d[1..<9])) else { return false }
            return check == d[9]
        }, draw: { _, rng in
            while true {
                let body = randomDigits(8, &rng)
                if let check = bcDigit(body) { return characters([9] + body + [check]) }
            }
        }),
        Recognizer("CR_DIMEX", keys: ["dimex", "dimexnumber", "cedularesidencia"], forms: [
            .init(#"\b1\d{10,11}\b"#, 0.05),
        ], context: ["dimex", "cédula de residencia", "documento de identidad migratorio"], verifies: false, check: { characters in
            // Costa Rica's foreigners' document: a 1 and ten or eleven digits.
            guard let d = numbers(characters) else { return false }
            return (d.count == 11 || d.count == 12) && d[0] == 1
        }, draw: { like, rng in
            characters([1] + randomDigits(like.count == 12 ? 11 : 10, &rng))
        }),
        Recognizer("PE_CUI", keys: ["cui", "dniperu"], forms: [
            .init(#"\b\d{8}-?[0-9A-K]\b"#, 0.1),
        ], context: ["cui", "dni", "documento nacional de identidad"], check: { characters in
            // Peru's DNI with its check, written as a digit or a letter.
            guard characters.count == 9, let d = numbers(Array(characters.prefix(8))) else { return false }
            return peruMarks(d).contains(characters[8])
        }, draw: { like, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            let marks = peruMarks(d)
            return characters(d) + [like.last?.isLetter == true ? marks[1] : marks[0]]
        }),
        Recognizer("US_PTIN", keys: ["ptin", "preparertin", "preparerptin"], forms: [
            .init(#"\bP-?\d{8}\b"#, 0.3),
        ], context: ["ptin", "preparer tax identification number", "preparer"], verifies: false, check: { characters in
            characters.count == 9 && characters[0] == "P" && numbers(Array(characters.dropFirst())) != nil
        }, draw: { _, rng in
            ["P"] + characters([0] + randomDigits(7, &rng))
        }),
        // An individual taxpayer number the IRS gives those who can't have an SSN: nine
        // digits, the first a 9 (no SSN's area), the middle two in the ranges it issues.
        Recognizer("US_ITIN", keys: ["itin", "itinnumber", "individualtaxpayeridentificationnumber"], forms: [
            .init(#"\b9\d{2}([- ]?)(?:5\d|6[0-5]|7\d|8[0-8]|9[0-2]|9[4-9])\1\d{4}\b"#, 0.3),
        ], context: ["itin", "individual taxpayer identification number", "taxpayer identification number"], verifies: false, check: { characters in
            guard let d = numbers(characters), d.count == 9, d[0] == 9 else { return false }
            let group = d[3] * 10 + d[4]
            return (50...65).contains(group) || (70...88).contains(group) || (90...92).contains(group) || (94...99).contains(group)
        }, draw: { _, rng in
            // The ranges issued longest, which every check of one accepts.
            let groups = Array(70...88) + Array(90...92) + Array(94...99)
            let group = groups[Int.random(in: 0..<groups.count, using: &rng)]
            return characters([9] + randomDigits(2, &rng) + [group / 10, group % 10] + [Int.random(in: 1...9, using: &rng)] + randomDigits(3, &rng))
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
            // Pairs standing as words of their own: the "ac" of "mac" opens none.
            .init(#"(?<![0-9A-Za-z])[0-9A-Fa-f]{2}(?: [0-9A-Fa-f]{2}){5}(?![0-9A-Za-z])"#, 0.05),
        ], context: ["mac", "hardware", "ethernet", "bssid", "wifi"], verifies: false, separators: ":-. ", check: { characters in
            characters.count == 12 && characters.allSatisfy(\.isHexDigit) && Set(characters).count > 1
        }, draw: { like, rng in
            // Its maker's three octets kept (a manufacturer's registered prefix, nobody's own), the device's three drawn,
            // each a letter or a digit where the original's was; with none to keep, locally administered and unicast.
            guard like.count == 12, like.allSatisfy(\.isHexDigit) else {
                return Array(String(format: "%02X", Int.random(in: 0...63, using: &rng) << 2 | 2)) + (0..<10).map { _ in pick("0123456789ABCDEF", &rng) }
            }
            return Array(like.prefix(6)) + like.dropFirst(6).map { $0.isNumber ? pick(digits, &rng) : pick("ABCDEF", &rng) }
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
            .init(#"(?i)(?<![\p{L}\d])(?:"# + registerCourtPattern + #")[ ,]{1,4}(?:HRA|HRB) {0,3}[1-9]\d{0,5}(?: {0,3}(?-i:[A-ZÖ]{1,3}))?(?![\p{L}\d])"#, 0.5, alone: true),
            .init(#"(?i)(?<![\p{L}\d])(?:"# + registerCourtPattern + #")[ ,]{1,4}(?:PR|GnR|VR) {0,3}[1-9]\d{0,5}(?: {0,3}(?-i:[A-ZÖ]{1,3}))?(?![\p{L}\d])"#, 0.3),
            .init(#"(?i)\b(?:HRA|HRB|PR|GnR|VR) {0,3}[1-9]\d{0,5}(?: {0,3}(?-i:[A-ZÖ]{1,3}))?,? {1,3}(?:"# + registerCourtPattern + #")(?![\p{L}\d])"#, 0.3),
            .init(#"(?i)\bHR[AB] ?[1-9]\d{0,5}\b"#, 0.3),
        ], context: ["handelsregister", "handelsregisternummer", "amtsgericht", "registergericht", "registernummer", "vereinsregister", "genossenschaftsregister", "partnerschaftsregister"], folds: false, verifies: false, separators: " ,", check: { characters in
            // A register court of the Länder (a real one, by name), the register (HRA, HRB, GnR, PR, VR), and a number of one to six digits with up to three letters after it.
            registerParts(characters) != nil
        }, draw: { like, rng in
            guard let parts = registerParts(like) else { return ["H", "R", "B"] + characters([Int.random(in: 1...9, using: &rng)] + randomDigits(4, &rng)) }
            var made = like
            let count = parts.number.count
            for (offset, digit) in ([Int.random(in: 1...9, using: &rng)] + randomDigits(count - 1, &rng)).enumerated() { made[parts.number.lowerBound + offset] = Character(String(digit)) }
            // A court of one word may become another written as long; one of several words, or with a letter after the number, stays.
            if let court = parts.court, !parts.qualified, let other = registerCourtSwap(Array(like[court]), &rng) { made.replaceSubrange(court, with: other) }
            return made
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
            .init(#"\b[Dd][Ee][ .:-]{0,3}\d(?:[ .,]?\d){8}\b"#, 0.3),
        ], context: ["ust", "ustidnr", "umsatzsteuer", "vat", "mehrwertsteuer", "mwst", "vatin"], separators: " .-,:/", check: { characters in
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
            .init(#"\bIT[ :-]{0,3}\d(?: ?\d){10}\b"#, 0.3),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["piva", "partita iva", "p iva", "iva", "vat", "vatin"], separators: " -:", check: { characters in
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
            .init(#"\b[01239]\d{3}/\d{3}/\d{2}/\d\b"#, 0.3),
            .init(#"\b[01239]\d{8}-\d\b"#, 0.1),
        ], context: ["sars", "tin", "tax reference", "tax reference number", "income tax", "income tax number", "tax number", "itr", "tax registration"], separators: " -/", check: { characters in
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
            // Spaced otherwise ("211 082 588 59"): only where named.
            .init(#"\b\d(?: ?\d){10}\b"#, 0.05),
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
            let lead = given.flatMap { abaPrefixes.contains($0) ? $0 : nil } ?? abaPrefixes.sorted().randomElement(using: &rng) ?? 1
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
            let lead = given.flatMap { einPrefixes.contains($0) ? $0 : nil } ?? einPrefixes.sorted().randomElement(using: &rng) ?? 12
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
        // americas
        Recognizer("CO_NIT", forms: [
            .init(#"(?<![\d.,])\d{1,3}[., ]\d{3}[., -]\d{3}(?:[.—]| ?-?—? ?)\d(?![\d.,—-])"#, 0.3),
            .init(#"\b\d{7,10} ?[-—] ?\d\b"#, 0.1),
            .init(#"\b\d{8,11}\b"#, 0.05),
        ], context: ["nit", "número de identificación tributaria", "numero de identificacion tributaria", "nit colombia"], separators: " .,-—", check: { characters in
            // Colombia's NIT: a body of seven to ten digits and DIAN's weighted mod 11 check.
            guard let d = numbers(characters), (8...11).contains(d.count) else { return false }
            return coNitDigit(Array(d.dropLast())) == d.last
        }, draw: { like, rng in
            let count = (8...11).contains(like.count) ? like.count : 10
            let body = [Int.random(in: 1...9, using: &rng)] + randomDigits(count - 2, &rng)
            return characters(body + [coNitDigit(body)])
        }),
        Recognizer("VE_RIF", keys: ["rif", "rifnumber", "numerorif", "nrorif"], forms: [
            .init(#"\b[VEJPG]-?\d{8}-?\d\b"#, 0.3),
            .init(#"\b[VEJPG] ?[-–] ?\d{3} ?\d{5} ?[-–] ?\d\b"#, 0.3),
        ], context: ["rif", "registro de información fiscal", "registro de informacion fiscal", "registro único de información fiscal", "registro unico de informacion fiscal"], separators: " -–", check: { characters in
            // Venezuela's RIF: a holder's type (V, E, J, P, G), eight digits and SENIAT's mod 11 check.
            guard characters.count == 10, let d = numbers(Array(characters.dropFirst())), let mark = rifDigit(characters[0], Array(d.prefix(8))) else { return false }
            return mark == d[8]
        }, draw: { like, rng in
            // Its type kept: a person's stays a person's, a company's a company's.
            let type = like.first.flatMap { "VEJPG".contains($0) ? $0 : nil } ?? "V"
            let body = randomDigits(8, &rng)
            return [type] + characters(body + [rifDigit(type, body) ?? 0])
        }),
        Recognizer("EC_RUC", forms: [
            .init(#"\b(?:0[1-9]|1\d|2[0-4]|30|50)\d{8}-?\d{3}\b"#, 0.05),
        ], context: ["ruc", "registro único de contribuyentes", "registro unico de contribuyentes"], separators: " -", check: { characters in
            // Ecuador's RUC: a province, a third digit for the holder (a person below 6, 6 the state, 9 a company), its check, an establishment.
            guard let d = numbers(characters), d.count == 13 else { return false }
            return ecRucValid(d)
        }, draw: { like, rng in
            let given = numbers(like).flatMap { $0.count == 13 && ecRucValid($0) ? $0 : nil }
            let province = given.map { Array($0.prefix(2)) } ?? [1, 7]
            switch given?[2] {
            case 6?:
                // The state's establishment is its last four digits, which a stand-in never keeps: another one drawn.
                let kept = given.map { Array($0.suffix(4)) } ?? [0, 0, 0, 1]
                var establishment = kept
                while establishment == kept { establishment = [0, 0, 0, Int.random(in: 1...9, using: &rng)] }
                while true {
                    let body = province + [6] + randomDigits(5, &rng)
                    let rest = zip(body, [3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11
                    if rest != 1 { return characters(body + [rest == 0 ? 0 : 11 - rest] + establishment) }
                }
            case 9?:
                let establishment = given.map { Array($0.suffix(3)) } ?? [0, 0, 1]
                while true {
                    let body = province + [9] + randomDigits(6, &rng)
                    let rest = zip(body, [4, 3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11
                    if rest != 1 { return characters(body + [rest == 0 ? 0 : 11 - rest] + establishment) }
                }
            default:
                let establishment = given.map { Array($0.suffix(3)) } ?? [0, 0, 1]
                let body = province + [Int.random(in: 0...5, using: &rng)] + randomDigits(6, &rng)
                return characters(body + [(10 - ecuadorSum(body + [0])) % 10] + establishment)
            }
        }),
        Recognizer("GT_NIT", forms: [
            .init(#"\b\d{3,11}-[\dK](?![\w-])"#, 0.1),
            .init(#"\b\d-\d{5}-[\dK](?![\w-])"#, 0.1),
            .init(#"\b\d{4,11}[\dK]\b"#, 0.05),
        ], context: ["nit", "número de identificación tributaria", "numero de identificacion tributaria", "nit guatemala"], weak: true, separators: " -", check: { characters in
            // Guatemala's NIT: up to eleven digits and SAT's mod 11 check, ten written K.
            guard (2...12).contains(characters.count), let body = numbers(Array(characters.dropLast())) else { return false }
            return gtNitMark(body) == characters.last
        }, draw: { like, rng in
            let count = (5...12).contains(like.count) ? like.count : 8
            // Its check a K where the original's was, a digit where it was one.
            var made: [Character] = []
            for _ in 0..<64 {
                let body = [Int.random(in: 1...9, using: &rng)] + randomDigits(count - 2, &rng)
                made = characters(body) + [gtNitMark(body)]
                if like.last.map({ ($0 == "K") == (made.last == "K") }) ?? true { break }
            }
            return made
        }),
        Recognizer("BR_CNPJ", keys: ["cnpj", "cnpjnumber", "numerocnpj", "nrcnpj"], forms: [
            .init(#"(?<![\w.])[\dA-Z]{2}\. ?[\dA-Z]{3}\. ?[\dA-Z]{3} ?[/.] ?[\dA-Z]{4} ?[-–] ?\d{2}(?![\w-])"#, 0.6, alone: true),
            .init(#"\b\d{14}\b"#, 0.05),
        ], context: ["cnpj", "cadastro nacional da pessoa jurídica", "cadastro nacional da pessoa juridica", "cadastro nacional de pessoa jurídica", "cadastro nacional de pessoa juridica"], separators: " .-/–", check: { characters in
            // Brazil's CNPJ: a root of eight and a branch of four (letters too from July 2026), and two mod 11 checks.
            guard characters.count == 14, numbers(Array(characters.suffix(2))) != nil, Set(characters.prefix(12)).count > 1 else { return false }
            let values = characters.prefix(12).compactMap { cnpjValue($0) }
            guard values.count == 12, let first = cnpjDigit(values), let second = cnpjDigit(values + [first]) else { return false }
            return characters[12].wholeNumberValue == first && characters[13].wholeNumberValue == second
        }, draw: { like, rng in
            // A letter where the original had one; its branch kept (0001 is the head office, no one's own).
            let root: [Character] = (0..<8).map { index in index < like.count && like[index].isLetter ? pick(letters, &rng) : pick(digits, &rng) }
            let given = like.count == 14 ? Array(like[8..<12]) : []
            let branch = given.count == 4 && given.allSatisfy({ cnpjValue($0) != nil }) ? given : Array("0001")
            let values = (root + branch).compactMap { cnpjValue($0) }
            let first = cnpjDigit(values) ?? 0
            return root + branch + characters([first, cnpjDigit(values + [first]) ?? 0])
        }),
        Recognizer("CR_CPJ", keys: ["cedulajuridica", "cpj", "numerocedulajuridica"], forms: [
            .init(#"\b[2-5][- ]\d{3}[- ]\d{6}\b"#, 0.3),
            .init(#"\b[2-5]\d{9}\b"#, 0.05),
        ], context: ["cédula jurídica", "cedula juridica", "cédula de persona jurídica", "cedula de persona juridica", "cpj"], verifies: false, separators: " -", check: { characters in
            // Costa Rica's cédula jurídica: a class, a type the Registro Nacional lists for it, a six-digit sequence.
            guard let d = numbers(characters), d.count == 10 else { return false }
            return crCpjTypes[d[0]]?.contains(number(Array(d[1..<4]))) == true
        }, draw: { like, rng in
            // Its class and type kept: a kind of company, nobody's own.
            let given = numbers(like).flatMap { $0.count == 10 && crCpjTypes[$0[0]]?.contains(number(Array($0[1..<4]))) == true ? Array($0.prefix(4)) : nil }
            return characters((given ?? [3, 1, 0, 1]) + randomDigits(6, &rng))
        }),
        Recognizer("CR_CPF", keys: ["cedulafisica", "cedulapersonafisica"], forms: [
            .init(#"\b0?[1-9]-\d{3,4}-\d{3,4}\b"#, 0.3),
            .init(#"\b0?[1-9]\d{8}\b"#, 0.05),
        ], context: ["cédula de persona física", "cedula de persona fisica", "cédula física", "cedula fisica", "cédula", "cedula", "cédula de identidad", "cedula de identidad"], verifies: false, separators: "-", check: { characters in
            // Costa Rica's cédula de identidad: a province, a volume and an entry (0P-TTTT-AAAA), its zeros often left out.
            guard let d = numbers(characters), (7...10).contains(d.count) else { return false }
            return d.count == 10 ? d[0] == 0 && d[1] != 0 : d[0] != 0
        }, draw: { like, rng in
            // Its province kept, and the zero before it where there was one.
            guard numbers(like) != nil, (7...10).contains(like.count) else { return characters([Int.random(in: 1...7, using: &rng)] + randomDigits(8, &rng)) }
            let lead = like.first == "0" ? 2 : 1
            return Array(like.prefix(lead)) + characters(randomDigits(like.count - lead, &rng))
        }),
        Recognizer("UY_RUT", forms: [
            .init(#"\bUY ?\d{2} ?\d{6} ?\d{3} ?\d\b"#, 0.5, alone: true),
            .init(#"\b\d{2}-\d{6}-\d{3}-\d\b"#, 0.3),
            .init(#"\b(?:0[1-9]|1\d|2[0-2])\d{10}\b"#, 0.05),
        ], context: ["rut", "registro único tributario", "registro unico tributario", "rut uruguay"], separators: " -", check: { characters in
            // Uruguay's RUT: a register (01-22), a six-digit sequence, 001 and DGI's mod 11 check.
            let characters = characters.starts(with: ["U", "Y"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(characters), d.count == 12, (1...22).contains(d[0] * 10 + d[1]), d[2..<8].contains(where: { $0 != 0 }),
                  Array(d[8..<11]) == [0, 0, 1], let mark = uyRutDigit(Array(d.prefix(11))) else { return false }
            return mark == d[11]
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["U", "Y"]) ? ["U", "Y"] : []
            // Its register kept: a place of registration, nobody's own.
            let given = numbers(Array(like.dropFirst(prefix.count).prefix(2))).map(number)
            let register = given.flatMap { (1...22).contains($0) ? $0 : nil } ?? 21
            while true {
                let body = twoDigits(register) + [Int.random(in: 1...9, using: &rng)] + randomDigits(5, &rng) + [0, 0, 1]
                if let mark = uyRutDigit(body) { return prefix + characters(body + [mark]) }
            }
        }),
        Recognizer("SV_NIT", forms: [
            .init(#"\bSV ?[019]\d{3}-?\d{6}-?\d{3}-?\d\b"#, 0.3),
            .init(#"\b[019]\d{3}-\d{6}-\d{3}-\d\b"#, 0.3),
            .init(#"\b[019]\d{13}\b"#, 0.05),
        ], context: ["nit", "número de identificación tributaria", "numero de identificacion tributaria", "nit el salvador"], separators: " -", check: { characters in
            // El Salvador's NIT: a municipality, a date (DDMMYY), a sequence and the Ministerio de Hacienda's mod 11 check.
            let characters = characters.starts(with: ["S", "V"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(characters), d.count == 14, [0, 1, 9].contains(d[0]),
                  realDate(year: 2000 + d[8] * 10 + d[9], month: d[6] * 10 + d[7], day: d[4] * 10 + d[5]) else { return false }
            return svNitDigit(Array(d.prefix(13))) == d[13]
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["S", "V"]) ? ["S", "V"] : []
            let given = numbers(Array(like.dropFirst(prefix.count)))
            // Its municipality kept, a place; the sequence old (up to 100) or new as the original's.
            let place = given.flatMap { $0.count == 14 && [0, 1, 9].contains($0[0]) ? Array($0.prefix(4)) : nil } ?? [0, 6, 1, 4]
            let old = given.map { $0.count == 14 && number(Array($0[10..<13])) <= 100 } ?? false
            let date = randomDate(&rng)
            let body = place + twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + digitsOf(Int.random(in: old ? 1...100 : 101...999, using: &rng), 3)
            return prefix + characters(body + [svNitDigit(body)])
        }),
        Recognizer("PY_RUC", forms: [
            .init(#"\b\d{4,8}-\d\b"#, 0.1),
            .init(#"\b\d{6,9}\b"#, 0.05),
        ], context: ["ruc", "registro único del contribuyente", "registro unico del contribuyente", "registro único de contribuyentes", "registro unico de contribuyentes"], weak: true, separators: " -", check: { characters in
            // Paraguay's RUC: a person's cédula or a company's number (from 80000000), and SET's mod 11 check.
            guard let d = numbers(characters), (5...9).contains(d.count), d[0] != 0 else { return false }
            return pyRucDigit(Array(d.dropLast())) == d.last
        }, draw: { like, rng in
            let count = (5...9).contains(like.count) ? like.count : 8
            // A company's 80 kept.
            let lead = like.starts(with: ["8", "0"]) && count >= 8 ? [8, 0] : [Int.random(in: 1...9, using: &rng)]
            let body = lead + randomDigits(count - 1 - lead.count, &rng)
            return characters(body + [pyRucDigit(body)])
        }),
        Recognizer("DO_RNC", keys: ["rnc", "rncnumber", "numerornc"], forms: [
            .init(#"\b[1-5]-\d{2}-\d{5}-\d\b"#, 0.3),
            .init(#"\b[1-5]\d{8}\b"#, 0.05),
        ], context: ["rnc", "registro nacional del contribuyente", "registro nacional de contribuyentes", "registro nacional de contribuyente"], separators: " -", check: { characters in
            // The Dominican Republic's RNC: nine digits, the last DGII's weighted mod 11 check.
            guard let d = numbers(characters), d.count == 9 else { return false }
            return rncDigit(Array(d.prefix(8))) == d[8]
        }, draw: { like, rng in
            // Its first digit kept: the kind of holder.
            let lead = like.first?.wholeNumberValue.flatMap { (1...5).contains($0) ? $0 : nil } ?? 1
            let body = [lead] + randomDigits(7, &rng)
            return characters(body + [rncDigit(body)])
        }),
        Recognizer("AR_CBU", keys: ["cbu", "cbunumber", "numerocbu", "nrocbu"], forms: [
            .init(#"\b\d{8}(?: | ?[-–] ?)\d{14}\b"#, 0.3),
            .init(#"\b\d{7}-\d-\d{13}-\d\b"#, 0.3),
            .init(#"\b\d(?: \d){21}\b"#, 0.3),
            // Spaced however a form or a scan spaced it ("0 1400 236 – 01 5068 0262 5874"): only where named.
            .init(#"\b\d(?:(?: {1,4}| ?[-–] ?)?\d){21}\b"#, 0.05),
            .init(#"\b\d{22}\b"#, 0.05),
        ], context: ["cbu", "clave bancaria uniforme"], separators: " -–", check: { characters in
            // Argentina's CBU: a bank and branch with their check, an account of thirteen with its own (BCRA).
            guard let d = numbers(characters), d.count == 22 else { return false }
            return cbuDigit(Array(d[0..<7])) == d[7] && cbuDigit(Array(d[8..<21])) == d[21]
        }, draw: { like, rng in
            // Its bank and branch kept: the bank's, nobody's own.
            let given = numbers(like).flatMap { $0.count == 22 ? Array($0.prefix(7)) : nil } ?? [0, 1, 1, 0, 0, 0, 1]
            let account = randomDigits(13, &rng)
            return characters(given + [cbuDigit(given)] + account + [cbuDigit(account)])
        }),
        Recognizer("CA_BN", keys: ["bn9", "bn15", "crabusinessnumber", "canadianbusinessnumber", "canadabusinessnumber"], forms: [
            .init(#"\b\d{9} ?(?:RC|RM|RP|RT|RR|RZ) ?\d{4}\b"#, 0.3),
            .init(#"\b\d{5} \d{4} (?:RC|RM|RP|RT|RR|RZ) \d{4}\b"#, 0.3),
            .init(#"\b\d{5} \d{4}\b"#, 0.05),
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["business number", "bn", "numéro d'entreprise", "numero d'entreprise", "gst/hst number", "hst number", "program account number"], separators: " -", check: { characters in
            // Canada's business number: nine digits with a Luhn check, and for a program account its program and a reference.
            guard characters.count == 9 || characters.count == 15, let d = numbers(Array(characters.prefix(9))), Patterns.luhn(d) else { return false }
            return characters.count == 9 || caPrograms.contains(String(characters[9..<11])) && numbers(Array(characters.suffix(4))) != nil
        }, draw: { like, rng in
            let body = randomDigits(8, &rng)
            let head = characters(body + [luhnDigit(body)])
            guard like.count == 15 else { return head }
            // Its program and reference kept: an account of the business, not the business.
            let program = caPrograms.contains(String(like[9..<11])) ? Array(like[9..<11]) : Array("RC")
            // A reference of its own: the original's would keep its last four.
            return head + program + characters([Int.random(in: 1...9, using: &rng)] + randomDigits(3, &rng))
        }),
        Recognizer("PE_RUC", forms: [
            .init(#"\b(?:10|15|17|20)\d{9}\b"#, 0.05),
        ], context: ["ruc", "registro único de contribuyentes", "registro unico de contribuyentes"], separators: " ", check: { characters in
            // Peru's RUC: 10, 15 or 17 for a person, 20 for a company, eight digits (a person's DNI) and SUNAT's mod 11 check.
            guard let d = numbers(characters), d.count == 11, [10, 15, 17, 20].contains(d[0] * 10 + d[1]) else { return false }
            return peRucDigit(Array(d.prefix(10))) == d[10]
        }, draw: { like, rng in
            let given = numbers(Array(like.prefix(2))).map(number)
            let kind = given.flatMap { [10, 15, 17, 20].contains($0) ? $0 : nil } ?? 20
            let body = twoDigits(kind) + randomDigits(8, &rng)
            return characters(body + [peRucDigit(body)])
        }),
        // registers_west
        Recognizer("AT_FIRMENBUCHNUMMER", keys: ["firmenbuchnummer", "firmenbuchnr"], forms: [
            .init(#"\bFN ?\d{1,6}[a-zA-Z]\b"#, 0.5, alone: true),
            .init(#"\b\d{4,6}[a-zA-Z]\b"#, 0.05),
        ], context: ["firmenbuch", "firmenbuchnummer", "firmenbuchgericht"], check: { characters in
            // Austria's company register: up to six digits and a check letter over them (weights 6, 4, 14, 15, 10, 1, mod 17).
            let body = characters.count > 2 && characters[0] == "F" && characters[1] == "N" ? Array(characters.dropFirst(2)) : characters
            guard (2...7).contains(body.count), let d = numbers(Array(body.dropLast())), d[0] != 0 else { return false }
            return firmenbuchLetter(d) == body.last
        }, draw: { like, rng in
            let prefixed = like.count > 2 && like[0] == "F" && like[1] == "N"
            let count = max(1, min(6, like.count - (prefixed ? 3 : 1)))
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(count - 1, &rng)
            return (prefixed ? ["F", "N"] : []) + characters(d) + [firmenbuchLetter(d)]
        }),
        Recognizer("AT_ABGABENKONTONUMMER", keys: ["abgabenkontonummer", "abgabenkontonr"], forms: [
            .init(#"\b\d{2}(?:[- ]| - )\d{3}/\d{4}\b"#, 0.3),
            .init(#"\b\d{2} \d{3} \d{4}\b"#, 0.1),
            .init(#"\b\d{2} \d{7}\b"#, 0.1),
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["abgabenkontonummer", "abgabenkonto", "steuernummer", "finanzamt", "stnr", "tin"], separators: " -/", check: { characters in
            // Austria's: a tax office's two digits, seven of the account, the last a Luhn check over all nine.
            guard let d = numbers(characters), d.count == 9, atTaxOffices.contains(d[0] * 10 + d[1]) else { return false }
            return Patterns.luhn(d)
        }, draw: { like, rng in
            let kept = numbers(Array(like.prefix(2))).map { $0[0] * 10 + $0[1] }
            let office = kept.flatMap { atTaxOffices.contains($0) ? $0 : nil } ?? atTaxOffices.sorted().randomElement(using: &rng) ?? 46
            let body = twoDigits(office) + randomDigits(6, &rng)
            return characters(body + [luhnDigit(body)])
        }),
        Recognizer("FR_RCS", keys: ["rcsnumber", "numerorcs", "immatriculationrcs"], forms: [
            .init(#"(?i)\bRCS +\p{L}[\p{L}'-]*(?: \p{L}[\p{L}'-]*){0,3} +[AB] ?\d{3} ?\d{3} ?\d{3}\b"#, 0.6, alone: true),
        ], context: ["rcs", "registre du commerce", "registre du commerce et des sociétés", "greffe"], separators: " ", check: { characters in
            // "RCS", the registry's town, A (a trader) or B (a company), and the company's SIREN, its last digit a Luhn check.
            guard characters.count >= 14, characters[0] == "R", characters[1] == "C", characters[2] == "S",
                  let siren = numbers(Array(characters.suffix(9))) else { return false }
            let letter = characters[characters.count - 10], town = characters[3..<(characters.count - 10)]
            guard letter == "A" || letter == "B", !town.isEmpty, town.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return false }
            return Patterns.luhn(siren)
        }, draw: { like, rng in
            // The town and the letter stay: only the SIREN is the company's own.
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            return (like.count >= 14 ? Array(like.dropLast(9)) : Array("RCSPARISB")) + characters(d + [luhnDigit(d)])
        }),
        Recognizer("NL_ONDERWIJSNUMMER", keys: ["onderwijsnummer"], forms: [
            .init(#"\b10\d{2}\.\d{2}\.\d{3}\b"#, 0.3),
            .init(#"\b10\d{7}\b"#, 0.05),
        ], context: ["onderwijsnummer"], separators: " .", check: { characters in
            // A pupil's number where they have no BSN: "10", and the BSN's eleven-test leaving 5.
            guard let d = numbers(characters), d.count == 9, d[0] == 1, d[1] == 0 else { return false }
            return ((zip(d[0..<8], (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } - d[8]) % 11 + 11) % 11 == 5
        }, draw: { _, rng in
            while true {
                let body = [1, 0] + randomDigits(6, &rng)
                let last = ((zip(body, (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } - 5) % 11 + 11) % 11
                if last < 10 { return characters(body + [last]) }
            }
        }),
        Recognizer("NL_DOCUMENT_NUMBER", keys: ["identiteitskaartnummer", "paspoortnummer", "documentnummer"], forms: [
            .init(#"\b[A-NP-Z]{2}[A-NP-Z\d]{6}\d\b"#, 0.3),
            .init(#"\b[A-NP-Z]{2} [A-NP-Z\d]{6} \d\b"#, 0.3),
        ], context: ["identiteitskaartnummer", "identiteitskaart", "paspoortnummer", "documentnummer"], verifies: false, separators: " ", check: { characters in
            // A Dutch passport's or identity card's: two letters, six letters or digits, a digit; never the letter O.
            guard characters.count == 9, characters.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) && $0 != "O" }) else { return false }
            return characters[0].isLetter && characters[1].isLetter && characters[8].isNumber
        }, draw: { like, rng in
            let shape = like.count == 9 ? like : Array("XX0000000")
            return shape.map { $0.isLetter ? pick(dutchDocumentLetters, &rng) : pick(digits, &rng) }
        }),
        Recognizer("GB_UTR", keys: ["utr", "utrnumber", "uniquetaxpayerreference", "sautr", "ctutr"], forms: [
            .init(#"\b\d{5} \d{5}\b"#, 0.1),
            .init(#"\b\d{10}\b"#, 0.05),
        ], context: ["utr", "unique taxpayer reference", "sa utr", "ct utr"], separators: " ", check: { characters in
            // HMRC's Unique Taxpayer Reference: its first digit checks the nine after it.
            guard let d = numbers(characters), d.count == 10 else { return false }
            return d[0] == utrDigit(Array(d[1...]))
        }, draw: { _, rng in
            let body = randomDigits(9, &rng)
            return characters([utrDigit(body)] + body)
        }),
        Recognizer("GB_UPN", keys: ["uniquepupilnumber", "pupilnumber", "upnnumber"], forms: [
            .init(#"\b[A-HJ-NP-RT-Z]\d{11}[\dA-HJ-NP-RT-Z]\b"#, 0.3),
        ], context: ["upn", "unique pupil number", "pupil number"], separators: " ", check: { characters in
            // England's Unique Pupil Number: a check letter, a local authority, a school, a year, a serial (or two digits and a letter when temporary).
            guard characters.count == 13, let middle = numbers(Array(characters[1..<12])), upnAlphabet.contains(characters[12]),
                  upnAuthorities.contains(middle[0] * 100 + middle[1] * 10 + middle[2]) else { return false }
            return upnLetter(Array(characters[1...])) == characters[0]
        }, draw: { like, rng in
            let authority = upnAuthorities.sorted().randomElement(using: &rng) ?? 801
            let temporary = like.count == 13 && like[12].isLetter
            var body = characters([authority / 100, authority / 10 % 10, authority % 10] + randomDigits(temporary ? 8 : 9, &rng))
            if temporary { body.append(pick("ABCDEFGHJKLMNPQRTUVWXYZ", &rng)) }
            return [upnLetter(body) ?? "A"] + body
        }),
        Recognizer("BE_EID", keys: ["eidnumber", "eidnummer", "eidcardnumber"], forms: [
            .init(#"\b\d{3}-\d{7}-\d{2}\b"#, 0.3),
            .init(#"\b\d{12}\b"#, 0.05),
        ], context: ["eid", "eid card", "eid number", "eid-kaart", "eid kaart", "carte eid", "kaartnummer", "identiteitskaart", "carte d'identité"], separators: " -./", check: { characters in
            // A Belgian identity card's number: its first ten digits mod 97, a remainder of 0 written 97.
            guard let d = numbers(characters), d.count == 12 else { return false }
            return d[10] * 10 + d[11] == eidCheck(Array(d[0..<10]))
        }, draw: { like, rng in
            let series = like.count == 12 ? numbers(Array(like.prefix(3))) ?? randomDigits(3, &rng) : [5, 9, Int.random(in: 1...2, using: &rng)]
            let body = series + randomDigits(7, &rng)
            return characters(body + twoDigits(eidCheck(body)))
        }),
        Recognizer("IL_COMPANY_NUMBER", keys: ["israelicompanynumber", "ilcompanynumber"], forms: [
            .init(#"\b5\d{3}[ -]\d{5}\b"#, 0.1),
            .init(#"\b5\d{8}\b"#, 0.05),
        ], context: ["hp", "ח.פ", "ח״פ", "מספר חברה", "israeli company", "israeli company number"], separators: " -", check: { characters in
            // An Israeli company's: nine digits, a 5 first, the last a Luhn check.
            guard let d = numbers(characters), d.count == 9, d[0] == 5 else { return false }
            return Patterns.luhn(d)
        }, draw: { like, rng in
            // Its first two digits are the kind of company: kept.
            let kind = like.count == 9 && like[0] == "5" ? like[1].wholeNumberValue ?? 1 : 1
            let body = [5, kind] + randomDigits(6, &rng)
            return characters(body + [luhnDigit(body)])
        }),
        Recognizer("NO_KONTONUMMER", keys: ["kontonr", "kontonummer", "bankkontonummer"], forms: [
            .init(#"\b\d{4}\.\d{2}\.\d{5}\b"#, 0.3),
            .init(#"\b0000\.\d{7}\b"#, 0.3),
            .init(#"\b\d{4} \d{2} \d{5}\b"#, 0.1),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["kontonummer", "kontonr", "konto nr", "bankkonto", "bankkontonummer"], separators: " .", check: { characters in
            // Norway's: a bank's four digits and a mod 11 check over the ten before the last (weights 5, 4, 3, 2, 7 … 2);
            // the postal giro's, after 0000, seven digits with a Luhn check.
            guard let d = numbers(characters), d.count == 11 else { return false }
            if d[0..<4].allSatisfy({ $0 == 0 }) { return Patterns.luhn(Array(d[4...])) }
            return norwayDigit(d[0..<10], [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) == d[10]
        }, draw: { like, rng in
            if like.count == 11, like.prefix(4).allSatisfy({ $0 == "0" }) {
                let body = [Int.random(in: 1...9, using: &rng)] + randomDigits(5, &rng)
                return Array("0000") + characters(body + [luhnDigit(body)])
            }
            let bank = like.count == 11 ? numbers(Array(like.prefix(4))).flatMap { $0.allSatisfy { $0 == 0 } ? nil : $0 } : nil
            while true {
                let body = (bank ?? [Int.random(in: 1...9, using: &rng)] + randomDigits(3, &rng)) + randomDigits(6, &rng)
                if let last = norwayDigit(body[...], [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) { return characters(body + [last]) }
            }
        }),
        Recognizer("CZ_BANK_ACCOUNT", keys: ["cislouctu", "czbankaccount"], forms: [
            .init(#"\b(?:\d{1,6}-)?\d{2,10}/\d{4}\b"#, 0.3),
        ], context: ["číslo účtu", "cislo uctu", "bankovní účet", "bankovni ucet", "účet", "ucet", "bank account", "bankaccount"], separators: " ", check: { characters in
            // A Czech account: an optional prefix, a number, each passing the Czech National Bank's mod 11, and a bank's code.
            guard let parts = czAccountParts(characters), let bank = numbers(parts.bank), czBanks.contains(number(bank)),
                  let root = numbers(parts.root), root.contains(where: { $0 != 0 }), czWeighted(root) % 11 == 0 else { return false }
            guard let prefix = parts.prefix else { return true }
            guard let p = numbers(prefix) else { return false }
            return czWeighted(p) % 11 == 0
        }, draw: { like, rng in
            let parts = czAccountParts(like) ?? (prefix: nil, root: Array("0000000000"), bank: Array("0800"))
            // Another bank's code: the original's would keep its last four.
            let original = numbers(parts.bank).map(number)
            let bank = Array(String(format: "%04d", czBanks.filter { $0 != original }.sorted().randomElement(using: &rng) ?? 800))
            func part(_ count: Int, _ rng: inout any RandomNumberGenerator) -> [Character] {
                while true {
                    let body = (count > 1 ? [Int.random(in: 1...9, using: &rng)] + randomDigits(count - 2, &rng) : [])
                    let last = (11 - czWeighted(body + [0]) % 11) % 11
                    if last < 10, count > 1 || last > 0 { return characters(body + [last]) }
                }
            }
            let root = part(max(2, min(10, parts.root.count)), &rng)
            let prefix = parts.prefix.map { part(max(2, min(6, $0.count)), &rng) + ["-"] } ?? []
            return prefix + root + ["/"] + bank
        }),
        Recognizer("NZ_BANK_ACCOUNT", keys: ["nzbankaccount", "nzbankaccountnumber"], forms: [
            .init(#"\b\d{2}([- ‐])\d{3,4}\1\d{7}\1\d{1,3}\b"#, 0.3),
            .init(#"\b\d{2}[- ]\d{4}[- ]\d{7}[- ]\d{2,3}\b"#, 0.3),
            .init(#"\b\d{2}-\d{4}-\d{4}-\d{3}-\d{2,3}\b"#, 0.3),
            .init(#"\b\d{15,16}\b"#, 0.05),
        ], context: ["bank account", "bankaccount", "nz bank account", "account number nz"], separators: " -‐–", check: { characters in
            // New Zealand's: a bank, a branch, the account's base and its suffix, checked by the bank's algorithm (Inland Revenue's table).
            guard let d = numbers(characters) else { return false }
            return nzAccountLayouts(d).contains { nzAccountValid($0, strict: false) }
        }, draw: { like, rng in
            let d = numbers(like) ?? [0, 1, 0, 9, 0, 2] + randomDigits(10, &rng)
            let lead = d.count >= 14 ? Array(d.prefix(d.count == 14 ? 5 : 6)) : [0, 1, 0, 9, 0, 2]
            let tail = d.count >= 14 ? Array(d.suffix(d.count - lead.count - 7)) : [0, 0]
            for _ in 0..<4000 {
                let made = lead + randomDigits(7, &rng) + tail
                // Every way its digits are read passes, by the table and by its common reading.
                let layouts = nzAccountLayouts(made)
                if !layouts.isEmpty, layouts.allSatisfy({ nzAccountValid($0, strict: false) && nzAccountValid($0, strict: true) }) { return characters(made) }
            }
            return characters(d)
        }),
        Recognizer("NZ_IRD", keys: ["ird", "irdnumber", "irdno", "nzird"], forms: [
            .init(#"\b(?:NZ ?)?\d{2,3}-\d{3}-\d{3}\b"#, 0.3),
            .init(#"\b\d{7,8}-\d\b"#, 0.3),
            .init(#"\b\d{8,9}\b"#, 0.05),
        ], context: ["ird", "ird number", "inland revenue", "ird no"], separators: " -", check: { characters in
            // Inland Revenue's: 8 or 9 digits between 10,000,000 and 150,000,000, the last a mod 11 check (a second set of weights where the first gives 10).
            let body = characters.count > 2 && characters[0] == "N" && characters[1] == "Z" ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 8 || d.count == 9, (10_000_001...149_999_999).contains(number(d)) else { return false }
            return irdDigit(Array(d.dropLast())) == d.last
        }, draw: { like, rng in
            let prefixed = like.count > 2 && like[0] == "N" && like[1] == "Z"
            let nine = like.count - (prefixed ? 2 : 0) == 9
            while true {
                let lead: [Int] = nine && like[prefixed ? 2 : 0] == "1" ? [1, Int.random(in: 0...4, using: &rng)] : [0, Int.random(in: 1...9, using: &rng)]
                let body = nine ? lead + randomDigits(6, &rng)
                    : [Int.random(in: 1...9, using: &rng)] + randomDigits(6, &rng)
                guard let last = irdDigit(body), (10_000_001...149_999_999).contains(number(body + [last])) else { continue }
                return (prefixed ? ["N", "Z"] : []) + characters(body + [last])
            }
        }),
        // east_europe
        Recognizer("BG_VAT", keys: ["ddsnomer", "innozdds"], forms: [
            .init(#"\bBG[ -]?\d{3}[ .-]?\d{3}[ .-]?\d{3,4}\b"#, 0.3),
            .init(#"\b\d{9,10}\b"#, 0.05),
        ], context: ["vat", "ддс", "ин по ддс", "идентификационен номер по ддс", "булстат", "bulstat", "еик"], separators: " .-", check: { characters in
            // Bulgaria's: nine digits a company's UIC with its two-pass check, ten a person's EGN, a foreigner's LNCh or another's number.
            let body = characters.starts(with: ["B", "G"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body) else { return false }
            if d.count == 9 { return bgLegalDigit(Array(d[0..<8])) == d[8] }
            guard d.count == 10 else { return false }
            let head = Array(d[0..<9])
            return bgPersonValid(d) || eastWeighted(head, [21, 19, 17, 13, 11, 9, 7, 3, 1]) % 10 == d[9] || (11 - eastWeighted(head, [4, 3, 2, 7, 6, 5, 4, 3, 2]) % 11) % 11 == d[9]
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["B", "G"]) ? ["B", "G"] : []
            if like.count - prefix.count == 10 {
                let date = randomDate(&rng)
                let d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(3, &rng)
                return prefix + characters(d + [eastWeighted(d, [2, 4, 8, 5, 10, 9, 7, 3, 6]) % 11 % 10])
            }
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            return prefix + characters(d + [bgLegalDigit(d)])
        }),
        Recognizer("CZ_DIC", keys: ["danoveidentifikacnicislo"], forms: [
            .init(#"\bCZ ?\d{8,10}\b"#, 0.3),
            .init(#"\b\d{8,10}\b"#, 0.05),
        ], context: ["vat", "dič", "dic", "daňové identifikační číslo", "danove identifikacni cislo"], separators: " ", check: { characters in
            // Czechia's: eight digits a company's IČO, nine opening with 6 a person's without a birth number, else a birth number.
            let body = characters.starts(with: ["C", "Z"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body) else { return false }
            if d.count == 8 { return d[0] != 9 && czIcoDigit(Array(d[0..<7])) == d[7] }
            if d.count == 9, d[0] == 6 { return czSpecialDigit(Array(d[1..<8])) == d[8] }
            return birthNumberValid(d)
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["C", "Z"]) ? ["C", "Z"] : []
            let body = Array(like.dropFirst(prefix.count))
            if body.count == 9, body.first == "6" {
                let d = randomDigits(7, &rng)
                return prefix + characters([6] + d + [czSpecialDigit(d)])
            }
            if body.count == 9 || body.count == 10 {
                let year = body.count == 9 ? Int.random(in: 1920...1953, using: &rng) : Int.random(in: 1955...1999, using: &rng)
                let date = randomDate(&rng)
                let month = date.month + (Bool.random(using: &rng) ? 50 : 0)
                let d = twoDigits(year % 100) + twoDigits(month) + twoDigits(date.day) + randomDigits(3, &rng)
                return prefix + characters(body.count == 9 ? d : d + [number(d) % 11 % 10])
            }
            let d = [Int.random(in: 1...8, using: &rng)] + randomDigits(6, &rng)
            return prefix + characters(d + [czIcoDigit(d)])
        }),
        Recognizer("EE_KMKR", keys: ["kmkr", "kmkrnumber", "kmkrnr"], forms: [
            .init(#"\bEE ?10\d ?\d{3} ?\d{3}\b"#, 0.3),
            .init(#"\b10\d{7}\b"#, 0.05),
        ], context: ["vat", "kmkr", "käibemaksukohustuslase number", "kmkr number", "kmkr nr"], separators: " ", check: { characters in
            // Estonia's VAT number: 10, then weights 3, 7, 1 summing to a multiple of 10.
            let body = characters.starts(with: ["E", "E"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 9, d[0] == 1, d[1] == 0 else { return false }
            return eastWeighted(d, [3, 7, 1, 3, 7, 1, 3, 7, 1]) % 10 == 0
        }, draw: { like, rng in
            let d = [1, 0] + randomDigits(6, &rng)
            return (like.first == "E" ? ["E", "E"] : []) + characters(d + [(10 - eastWeighted(d, [3, 7, 1, 3, 7, 1, 3, 7]) % 10) % 10])
        }),
        Recognizer("HR_OIB", keys: ["oib", "oibbroj", "osobniidentifikacijskibroj"], forms: [
            .init(#"\bHR ?\d{11}\b"#, 0.3),
            .init(#"\b\d{11}\b"#, 0.05),
        ], context: ["vat", "oib", "osobni identifikacijski broj", "pdv"], separators: " -", check: { characters in
            // Croatia's OIB, a person's or a company's: ISO 7064 MOD 11,10.
            let body = characters.starts(with: ["H", "R"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 11 else { return false }
            return steuerDigit(d[0..<10]) == d[10]
        }, draw: { like, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(9, &rng)
            return (like.first == "H" ? ["H", "R"] : []) + characters(d + [steuerDigit(d[...])])
        }),
        Recognizer("HU_ANUM", keys: ["kozossegiadoszam", "kozossegiadoszama"], forms: [
            .init(#"\bHU[ -]?\d{8}\b"#, 0.3),
            .init(#"\b\d{8}\b"#, 0.05),
        ], context: ["vat", "közösségi adószám", "kozossegi adoszam", "anum", "áfa"], separators: " -", check: { characters in
            // Hungary's community tax number: weights 9, 7, 3, 1 summing to a multiple of 10.
            let body = characters.starts(with: ["H", "U"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 8 else { return false }
            return eastWeighted(d, [9, 7, 3, 1, 9, 7, 3, 1]) % 10 == 0
        }, draw: { like, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(6, &rng)
            return (like.first == "H" ? ["H", "U"] : []) + characters(d + [(10 - eastWeighted(d, [9, 7, 3, 1, 9, 7, 3]) % 10) % 10])
        }),
        Recognizer("LT_PVM", keys: ["pvm", "pvmkodas", "pvmmoketojokodas"], forms: [
            .init(#"\bLT ?(?:\d{7}1\d|\d{10}1\d)\b"#, 0.3),
            .init(#"\b\d{7}1\d\b"#, 0.05),
            .init(#"\b\d{10}1\d\b"#, 0.05),
        ], context: ["vat", "pvm", "pvm kodas", "pvm mokėtojo kodas", "pvm moketojo kodas"], separators: " -", check: { characters in
            // Lithuania's: nine digits a company's, twelve a person's, a 1 before the check, which is the personal code's.
            let body = characters.starts(with: ["L", "T"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), (d.count == 9 && d[7] == 1) || (d.count == 12 && d[10] == 1) else { return false }
            return isikukoodDigit(Array(d.dropLast())) == d[d.count - 1]
        }, draw: { like, rng in
            let prefix: [Character] = like.first == "L" ? ["L", "T"] : []
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(like.count - prefix.count == 12 ? 9 : 6, &rng) + [1]
            return prefix + characters(d + [isikukoodDigit(d)])
        }),
        Recognizer("LV_PVN", keys: ["pvn", "pvnnumurs", "pvnregistracijasnumurs"], forms: [
            .init(#"\bLV ?\d{4} ?\d{4} ?\d{3}\b"#, 0.3),
            .init(#"\bLV ?\d{6}-\d{5}\b"#, 0.3),
            .init(#"\b[4-9]\d{10}\b"#, 0.05),
        ], context: ["vat", "pvn", "pvn numurs", "pvn reģistrācijas numurs", "pvn registracijas numurs", "reģistrācijas numurs"], separators: " -", check: { characters in
            // Latvia's: a company's registration number (first digit above 3, weighted sum 3 mod 11), or a person's code.
            let body = characters.starts(with: ["L", "V"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 11 else { return false }
            if d[0] > 3 { return eastWeighted(d, [9, 1, 4, 8, 3, 10, 2, 5, 7, 6, 1]) % 11 == 3 }
            if !(d[0] == 3 && d[1] == 2) {
                guard realDate(year: 1800 + d[6] * 100 + d[4] * 10 + d[5], month: d[2] * 10 + d[3], day: d[0] * 10 + d[1]) else { return false }
            }
            return latvianDigit(Array(d[0..<10])) == d[10]
        }, draw: { like, rng in
            let prefix: [Character] = like.first == "L" ? ["L", "V"] : []
            let lead = like.dropFirst(prefix.count).first?.wholeNumberValue ?? 4
            guard lead > 3 else {
                let date = randomDate(&rng)
                let body = lead == 3 ? [3, 2] + randomDigits(8, &rng) : twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + [1] + randomDigits(3, &rng)
                return prefix + characters(body + [latvianDigit(body)])
            }
            while true {
                let d = [lead] + randomDigits(9, &rng)
                let last = ((3 - eastWeighted(d, [9, 1, 4, 8, 3, 10, 2, 5, 7, 6]) % 11) + 11) % 11
                if last < 10 { return prefix + characters(d + [last]) }
            }
        }),
        Recognizer("PL_NIP", keys: ["nip", "numernip", "nipnumber"], forms: [
            .init(#"\bPL ?\d{10}\b"#, 0.3),
            .init(#"\b\d{3}-\d{3}-\d{2}-\d{2}\b"#, 0.3),
            .init(#"\b\d{3}-\d{2}-\d{2}-\d{3}\b"#, 0.3),
            .init(#"\b\d{10}\b"#, 0.05),
        ], context: ["vat", "nip", "numer identyfikacji podatkowej", "vat-ue"], separators: " -", check: { characters in
            // Poland's tax number: weights 6, 5, 7, 2, 3, 4, 5, 6, 7 mod 11 is its last digit (never 10).
            let body = characters.starts(with: ["P", "L"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 10 else { return false }
            return eastWeighted(d, [6, 5, 7, 2, 3, 4, 5, 6, 7]) % 11 == d[9]
        }, draw: { like, rng in
            while true {
                let office = Int.random(in: 101...999, using: &rng)
                let d = [office / 100, office / 10 % 10, office % 10] + randomDigits(6, &rng)
                let last = eastWeighted(d, [6, 5, 7, 2, 3, 4, 5, 6, 7]) % 11
                if last < 10 { return (like.first == "P" ? ["P", "L"] : []) + characters(d + [last]) }
            }
        }),
        Recognizer("RO_CUI", keys: ["cif", "codfiscal", "codidentificarefiscala", "cuicif"], forms: [
            .init(#"\bRO ?[1-9]\d{1,9}\b"#, 0.3),
            .init(#"\b(?:RO ?)?[1-9]\d{2} \d{3} \d{1,4}\b"#, 0.3),
            .init(#"\b[1-9]\d{1,9}\b"#, 0.05),
        ], context: ["vat", "cui", "cif", "cod fiscal", "cod unic de înregistrare", "cod unic de inregistrare", "cod de identificare fiscală", "cod de identificare fiscala"], separators: " -", check: { characters in
            // Romania's CUI or CIF: two to ten digits, weights 7, 5, 3, 2, 1, 7, 5, 3, 2 from the right, ten times their sum mod 11.
            let body = characters.starts(with: ["R", "O"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), (2...10).contains(d.count), d[0] != 0 else { return false }
            return roCuiDigit(Array(d.dropLast())) == d[d.count - 1]
        }, draw: { like, rng in
            let prefix: [Character] = like.first == "R" ? ["R", "O"] : []
            let count = min(10, max(2, like.count - prefix.count))
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(count - 2, &rng)
            return prefix + characters(d + [roCuiDigit(d)])
        }),
        Recognizer("SI_DDV", keys: ["ddv", "idzaddv", "ddvstevilka", "davcnastevilka"], forms: [
            .init(#"\bSI ?[1-9]\d{3} ?\d{4}\b"#, 0.3),
            .init(#"\b[1-9]\d{7}\b"#, 0.05),
        ], context: ["vat", "ddv", "id za ddv", "identifikacijska številka za ddv", "davčna številka", "davcna stevilka"], separators: " -", check: { characters in
            // Slovenia's tax number: weights 8 … 2, eleven less the sum mod 11 (10 written 0, 11 none).
            let body = characters.starts(with: ["S", "I"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 8, d[0] != 0, let last = siDdvDigit(Array(d[0..<7])) else { return false }
            return last == d[7]
        }, draw: { like, rng in
            while true {
                let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(6, &rng)
                if let last = siDdvDigit(d) { return (like.first == "S" ? ["S", "I"] : []) + characters(d + [last]) }
            }
        }),
        Recognizer("SK_DPH", keys: ["icdph", "icdphnumber"], forms: [
            .init(#"\bSK ?[1-9]\d[234789] ?\d{3} ?\d{2} ?\d{2}\b"#, 0.3),
            .init(#"\b[1-9]\d[234789]\d{7}\b"#, 0.05),
        ], context: ["vat", "ič dph", "ic dph", "dph", "identifikačné číslo pre daň"], separators: " -", check: { characters in
            // Slovakia's VAT number: ten digits, the third 2, 3, 4, 7, 8 or 9, the whole a multiple of 11.
            let body = characters.starts(with: ["S", "K"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 10, d[0] != 0, [2, 3, 4, 7, 8, 9].contains(d[2]) else { return false }
            return number(d) % 11 == 0
        }, draw: { like, rng in
            while true {
                let d = [Int.random(in: 1...9, using: &rng), Int.random(in: 0...9, using: &rng), [2, 3, 4, 7, 8, 9][Int.random(in: 0..<6, using: &rng)]] + randomDigits(6, &rng)
                let last = (11 - number(d) * 10 % 11) % 11
                if last < 10 { return (like.first == "S" ? ["S", "K"] : []) + characters(d + [last]) }
            }
        }),
        Recognizer("UA_EDRPOU", keys: ["edrpou", "kodedrpou", "yedrpou", "edrpoucode"], forms: [
            .init(#"\b\d{8}\b"#, 0.05),
        ], context: ["edrpou", "єдрпоу", "едрпоу", "код єдрпоу", "код едрпоу", "yedrpou"], separators: " ", check: { characters in
            // Ukraine's EDRPOU: weights by the code's range, a second pass with each two more when the first leaves 10.
            guard let d = numbers(characters), d.count == 8 else { return false }
            return uaEdrpouDigit(Array(d[0..<7])) == d[7]
        }, draw: { like, rng in
            let d = [like.first?.wholeNumberValue ?? Int.random(in: 0...4, using: &rng)] + randomDigits(6, &rng)
            return characters(d + [uaEdrpouDigit(d)])
        }),
        Recognizer("UA_RNTRC", keys: ["rnokpp", "rntrc", "ipn", "identyfikatsiinyikod"], forms: [
            .init(#"\b\d{10}\b"#, 0.05),
            .init(#"\b\d{2} \d{2} \d{2} \d{2} \d{2}\b"#, 0.05),
        ], context: ["рнокпп", "rnokpp", "rntrc", "іпн", "ідентифікаційний код", "ідентифікаційний номер", "реєстраційний номер облікової картки платника податків"], separators: " ", check: { characters in
            // Ukraine's taxpayer card number: the birth date as days since 31 December 1899, a serial, a weighted check.
            guard let d = numbers(characters), d.count == 10 else { return false }
            return uaRntrcDigit(Array(d[0..<9])) == d[9]
        }, draw: { _, rng in
            let days = Int.random(in: 20000...39999, using: &rng)
            let d = [days / 10000, days / 1000 % 10, days / 100 % 10, days / 10 % 10, days % 10] + randomDigits(4, &rng)
            return characters(d + [uaRntrcDigit(d)])
        }),
        Recognizer("MD_IDNO", keys: ["idnomd", "codulfiscal"], forms: [
            .init(#"\b\d{13}\b"#, 0.05),
        ], context: ["idno", "număr de identificare de stat", "numar de identificare de stat", "cod fiscal"], separators: " ", check: { characters in
            // Moldova's state identification number: weights 7, 3, 1 repeated, the sum's last digit.
            guard let d = numbers(characters), d.count == 13 else { return false }
            return eastWeighted(d, [7, 3, 1, 7, 3, 1, 7, 3, 1, 7, 3, 1]) % 10 == d[12]
        }, draw: { like, rng in
            let d = [like.first?.wholeNumberValue ?? 1] + randomDigits(11, &rng)
            return characters(d + [eastWeighted(d, [7, 3, 1, 7, 3, 1, 7, 3, 1, 7, 3, 1]) % 10])
        }),
        Recognizer("RO_ONRC", keys: ["onrc", "nrregcom", "numarregcom", "nrordineregcom", "numarordineregistrulcomertului"], forms: [
            .init(#"\b[JFC](?:/| ?)\d{1,2}(?: ?[/-] ?| )\d{1,5}(?: ?[/-] ?| )(?:\d{2}\.\d{2}\.)?\d{4}\b"#, 0.3),
            .init(#"\b[JFC]\d{13}\b"#, 0.3),
        ], context: ["onrc", "registrul comerțului", "registrul comertului", "reg com", "nr reg com", "număr de ordine", "numar de ordine"], verifies: false, separators: " ", check: { characters in
            // Romania's trade register: a type letter, then county, serial and year (to 2024), or since July 2024 year, serial, county and a check digit.
            guard let lead = characters.first, "JFC".contains(lead) else { return false }
            if characters.count == 14, let d = numbers(Array(characters.dropFirst())) { return onrcNewValid(lead, d) }
            return onrcSplits(characters).contains { onrcValid(characters, $0) }
        }, draw: { like, rng in
            let lead: Character = like.first.flatMap { "JFC".contains($0) ? $0 : nil } ?? "J"
            if like.count == 14, numbers(Array(like.dropFirst())) != nil {
                let year = Int.random(in: 1990...2023, using: &rng)
                let county = onrcCounties.sorted()[Int.random(in: 0..<onrcCounties.count, using: &rng)]
                let d = [year / 1000, year / 100 % 10, year / 10 % 10, year % 10] + randomDigits(6, &rng) + twoDigits(county)
                return [lead] + characters(d + [onrcNewDigit(lead, d)])
            }
            let splits = onrcSplits(like)
            // County and serial run together ("F01 587 2023" without its spaces): a two-digit county from 10 on reads as a
            // county and a serial whichever way the original's spaces split them.
            let ambiguous = splits.count == 2 && (1...5).contains(splits[1].serial.count)
            guard let fields = ambiguous ? splits[1] : splits.first(where: { onrcValid(like, $0) }) ?? splits.first else { return Array("J40/1234/2015") }
            var c = like
            c[0] = lead
            let counties = fields.county.count == 1 ? Array(1...9) : onrcCounties.sorted().filter { !ambiguous || $0 >= 10 }
            onrcPut(&c, fields.county, counties[Int.random(in: 0..<counties.count, using: &rng)])
            let size = fields.serial.count
            onrcPut(&c, fields.serial, Int.random(in: (size == 1 ? 1 : eastPower(size - 1))...(eastPower(size) - 1), using: &rng))
            onrcPut(&c, fields.year, Int.random(in: 1990...2024, using: &rng))
            if let day = fields.date {
                onrcPut(&c, day..<(day + 2), Int.random(in: 1...28, using: &rng))
                onrcPut(&c, (day + 3)..<(day + 5), Int.random(in: 1...12, using: &rng))
            }
            return c
        }),
        Recognizer("ME_PIB", keys: ["pib", "pibbroj"], forms: [
            .init(#"\b\d{8}\b"#, 0.05),
        ], context: ["pib", "poreski identifikacioni broj", "poreski broj", "пиб"], separators: " ", check: { characters in
            // Montenegro's tax number: weights 8 … 2, the sum's complement mod 11 (10 written 0).
            guard let d = numbers(characters), d.count == 8 else { return false }
            return (11 - eastWeighted(d, [8, 7, 6, 5, 4, 3, 2]) % 11) % 11 % 10 == d[7]
        }, draw: { like, rng in
            let d = [0, like.count == 8 ? like[1].wholeNumberValue ?? 2 : 2] + randomDigits(5, &rng)
            return characters(d + [(11 - eastWeighted(d, [8, 7, 6, 5, 4, 3, 2]) % 11) % 11 % 10])
        }),
        Recognizer("RS_PIB", keys: ["pib", "pibbroj"], forms: [
            .init(#"\b[1-9]\d{8}\b"#, 0.05),
        ], context: ["pib", "poreski identifikacioni broj", "пиб", "порески идентификациони број"], separators: " .-", check: { characters in
            // Serbia's tax number: ISO 7064 MOD 11,10.
            guard let d = numbers(characters), d.count == 9, d[0] != 0 else { return false }
            return steuerDigit(d[0..<8]) == d[8]
        }, draw: { like, rng in
            let d = [like.first?.wholeNumberValue.flatMap { $0 == 0 ? nil : $0 } ?? 1] + randomDigits(7, &rng)
            return characters(d + [steuerDigit(d[...])])
        }),
        Recognizer("MK_EDB", keys: ["edb", "edbbroj", "danocenbroj"], forms: [
            .init(#"\b(?:MK|МК) ?\d{13}\b"#, 0.3),
            .init(#"\b\d{13}\b"#, 0.05),
        ], context: ["vat", "edb", "едб", "единствен даночен број", "даночен број", "ддв"], separators: " -", check: { characters in
            // North Macedonia's tax number: weights 7 … 2 twice, the sum's complement mod 11 (10 written 0).
            let prefixed = characters.count == 15 && (characters.starts(with: ["M", "K"]) || characters.starts(with: ["М", "К"]))
            guard let d = numbers(prefixed ? Array(characters.dropFirst(2)) : characters), d.count == 13 else { return false }
            return mkEdbDigit(Array(d[0..<12])) == d[12]
        }, draw: { like, rng in
            let prefix = like.count == 15 ? Array(like.prefix(2)) : []
            let d = [like.dropFirst(prefix.count).first?.wholeNumberValue ?? 4] + randomDigits(11, &rng)
            return prefix + characters(d + [mkEdbDigit(d)])
        }),
        Recognizer("AL_NIPT", keys: ["nipt", "nuis", "niptnumber"], forms: [
            .init(#"\b(?:AL ?)?[A-M] ?\d{8} ?[A-Z]\b"#, 0.3),
        ], context: ["nipt", "nuis", "numri i identifikimit", "numri unik i identifikimit"], verifies: false, separators: " ", check: { characters in
            // Albania's: a letter for the decade it was issued in (A to M), eight digits, a letter.
            let body = characters.count == 12 && characters.starts(with: ["A", "L"]) ? Array(characters.dropFirst(2)) : characters
            guard body.count == 10, let first = body.first?.asciiValue, (65...77).contains(first), numbers(Array(body[1..<9])) != nil, let last = body[9].asciiValue else { return false }
            return (65...90).contains(last)
        }, draw: { like, rng in
            let prefix: [Character] = like.count == 12 ? ["A", "L"] : []
            let first = like.dropFirst(prefix.count).first.flatMap { ("A"..."M").contains($0) ? $0 : nil } ?? "L"
            return prefix + [first] + characters(randomDigits(8, &rng)) + [pick(letters, &rng)]
        }),
        Recognizer("AD_NRT", keys: ["nrt", "nrtnumber"], forms: [
            .init(#"\b[ACDEFGLOPU][ -]?\d{3}[ .]?\d{3}(?: ?[-–] ?| )?[A-Z]\b"#, 0.3),
        ], context: ["nrt", "número de registre tributari", "numero de registre tributari", "registre tributari"], verifies: false, separators: " .-–", check: { characters in
            // Andorra's tax register: a letter for the holder's kind, six digits in its range, a letter.
            guard characters.count == 8, let first = characters.first, "ACDEFGLOPU".contains(first), let d = numbers(Array(characters[1..<7])), let last = characters[7].asciiValue, (65...90).contains(last) else { return false }
            let value = number(d)
            if first == "F" { return value <= 699_999 }
            if first == "A" || first == "L" { return (700_000...799_999).contains(value) }
            return true
        }, draw: { like, rng in
            let first = like.first.flatMap { "ACDEFGLOPU".contains($0) ? $0 : nil } ?? "U"
            let value = first == "F" ? Int.random(in: 0...699_999, using: &rng) : first == "A" || first == "L" ? Int.random(in: 700_000...799_999, using: &rng) : Int.random(in: 0...999_999, using: &rng)
            return [first] + characters((0..<6).map { value / eastPower(5 - $0) % 10 }) + [pick(letters, &rng)]
        }),
        Recognizer("EE_REGISTRIKOOD", keys: ["registrikood", "registrikoodi", "ariregistrikood"], forms: [
            .init(#"\b[1789]\d{7}\b"#, 0.05),
        ], context: ["registrikood", "registrikoodi", "äriregistri kood", "äriregistrikood", "registry code"], separators: " ", check: { characters in
            // Estonia's register code: its first digit the register, its check the personal code's.
            guard let d = numbers(characters), d.count == 8, [1, 7, 8, 9].contains(d[0]) else { return false }
            return isikukoodDigit(Array(d[0..<7])) == d[7]
        }, draw: { like, rng in
            let d = [like.first?.wholeNumberValue.flatMap { [1, 7, 8, 9].contains($0) ? $0 : nil } ?? 1] + randomDigits(6, &rng)
            return characters(d + [isikukoodDigit(d)])
        }),
        Recognizer("CZ_ICO", keys: ["identifikacnicislo", "identifikacnecislo", "icoorganizacie"], forms: [
            .init(#"\b\d{8}\b"#, 0.05),
            .init(#"\b\d{3} \d{2} \d{3}\b"#, 0.1),
            .init(#"\b\d{2} \d{3} \d{3}\b"#, 0.1),
        ], context: ["ičo", "ico", "identifikační číslo", "identifikačné číslo", "identifikační číslo osoby", "identifikačné číslo organizácie"], separators: " ", check: { characters in
            // Czechia's and Slovakia's organisation number: weights 8 … 2, eleven less the sum mod 11 (10 written 0, 11 written 1).
            guard let d = numbers(characters), d.count == 8 else { return false }
            return czIcoDigit(Array(d[0..<7])) == d[7]
        }, draw: { like, rng in
            let d = [like.first?.wholeNumberValue ?? Int.random(in: 0...9, using: &rng)] + randomDigits(6, &rng)
            return characters(d + [czIcoDigit(d)])
        }),
        Recognizer("RU_OGRN", keys: ["ogrn", "ogrnip"], forms: [
            .init(#"\b[1-9]\d{12}\b"#, 0.05),
            .init(#"\b[34]\d{14}\b"#, 0.05),
        ], context: ["огрн", "огрнип", "ogrn", "ogrnip", "основной государственный регистрационный номер"], separators: " ", check: { characters in
            // Russia's state registration number: thirteen digits (a company's) whose first twelve mod 11, fifteen (a sole trader's) whose first fourteen mod 13, give the last digit.
            guard let d = numbers(characters) else { return false }
            if d.count == 13 { return d[0] != 0 && number(Array(d[0..<12])) % 11 % 10 == d[12] }
            return d.count == 15 && (d[0] == 3 || d[0] == 4) && number(Array(d[0..<14])) % 13 % 10 == d[14]
        }, draw: { like, rng in
            while true {
                let year = Int.random(in: 3...25, using: &rng), region = Int.random(in: 1...89, using: &rng)
                if like.count == 15 {
                    let d = [3] + twoDigits(year) + twoDigits(region) + randomDigits(9, &rng)
                    let rest = number(d) % 13
                    if rest < 10 { return characters(d + [rest]) }
                } else {
                    let d = [like.first?.wholeNumberValue.flatMap { $0 == 5 ? 5 : nil } ?? 1] + twoDigits(year) + twoDigits(region) + randomDigits(7, &rng)
                    return characters(d + [number(d) % 11 % 10])
                }
            }
        }),
        Recognizer("RU_INN", keys: ["inn", "innnumber"], forms: [
            .init(#"\b\d{10}\b"#, 0.05),
            .init(#"\b\d{12}\b"#, 0.05),
        ], context: ["инн", "inn", "идентификационный номер налогоплательщика"], separators: " ", check: { characters in
            // Russia's taxpayer number: ten digits a company's with one check, twelve a person's with two.
            guard let d = numbers(characters) else { return false }
            if d.count == 10 { return eastWeighted(d, [2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11 % 10 == d[9] }
            guard d.count == 12 else { return false }
            return eastWeighted(d, [7, 2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11 % 10 == d[10] && eastWeighted(d, [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11 % 10 == d[11]
        }, draw: { like, rng in
            let region = twoDigits(Int.random(in: 1...89, using: &rng))
            if like.count == 12 {
                var d = region + randomDigits(8, &rng)
                d.append(eastWeighted(d, [7, 2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11 % 10)
                return characters(d + [eastWeighted(d, [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11 % 10])
            }
            let d = region + randomDigits(7, &rng)
            return characters(d + [eastWeighted(d, [2, 4, 10, 3, 5, 9, 4, 6, 8]) % 11 % 10])
        }),
        Recognizer("BY_UNP", keys: ["unp", "unpnumber"], forms: [
            .init(#"\b(?:UNP|УНП) ?[1-7ABCEHKMАВЕКМН][\dABCEHKMOPTАВЕКМНОРСТ]\d{7}\b"#, 0.3),
            .init(#"\b[ABCEHKMАВЕКМН][ABCEHKMOPTАВЕКМНОРСТ]\d{7}\b"#, 0.3),
            .init(#"\b[1-7]\d{8}\b"#, 0.05),
        ], context: ["унп", "unp", "учетный номер плательщика", "уліковы нумар плацельшчыка"], separators: " ", check: { characters in
            // Belarus's payer number: a region, a digit or a letter for its kind, seven digits, weights 29 … 3 mod 11.
            let prefixed = characters.count == 12 && (characters.starts(with: ["U", "N", "P"]) || characters.starts(with: ["У", "Н", "П"]))
            let body = (prefixed ? Array(characters.dropFirst(3)) : characters).map { unpLatin[$0] ?? $0 }
            guard body.count == 9, let d = numbers(Array(body[2...])) else { return false }
            return unpDigit(body[0], body[1], Array(d[0..<6])) == d[6]
        }, draw: { like, rng in
            let prefix = like.count == 12 ? Array(like.prefix(3)) : []
            let body = Array(like.dropFirst(prefix.count))
            let lettered = body.count == 9 && body[0].isLetter && body[1].isLetter
            // A lettered original's two letters stay (its kind); a head no number can follow falls back to digits.
            for attempt in 0..<64 {
                let head: [Character] = lettered && attempt < 48 ? [body[0], body[1]] : [Character(String(body.first?.wholeNumberValue.flatMap { (1...7).contains($0) ? $0 : nil } ?? 1)), pick(digits, &rng)]
                let d = randomDigits(6, &rng)
                if let last = unpDigit(unpLatin[head[0]] ?? head[0], unpLatin[head[1]] ?? head[1], d) { return prefix + head + characters(d + [last]) }
            }
            return prefix + Array("100000022")
        }),
        Recognizer("AZ_VOEN", keys: ["voen", "vergiodeyicisininidentifikasiyanomresi"], forms: [
            .init(#"\b\d{8,9}[12]\b"#, 0.05),
            .init(#"\b\d{3} \d{3} \d{3}[12]\b"#, 0.05),
        ], context: ["vöen", "voen", "vergi ödəyicisinin eyniləşdirmə nömrəsi"], separators: " ", check: { characters in
            // Azerbaijan's taxpayer number: ten digits (a leading zero may be dropped), weights 4, 1, 8, 6, 2, 7, 5, 3 mod 11 the ninth, the last 1 or 2.
            guard let given = numbers(characters), given.count == 9 || given.count == 10 else { return false }
            let d = given.count == 9 ? [0] + given : given
            return (d[9] == 1 || d[9] == 2) && eastWeighted(d, [4, 1, 8, 6, 2, 7, 5, 3]) % 11 == d[8]
        }, draw: { like, rng in
            let short = like.count == 9
            while true {
                let d = (short ? [0] : [Int.random(in: 0...9, using: &rng)]) + randomDigits(7, &rng)
                let check = eastWeighted(d, [4, 1, 8, 6, 2, 7, 5, 3]) % 11
                guard check < 10 else { continue }
                let full = d + [check, like.last == "2" ? 2 : 1]
                return characters(short ? Array(full.dropFirst()) : full)
            }
        }),
        Recognizer("TR_VKN", keys: ["vkn", "vergikimlikno", "vergino", "vergikimliknumarasi"], forms: [
            .init(#"\b\d{10}\b"#, 0.05),
        ], context: ["vkn", "vergi kimlik", "vergi no", "vergi numarası", "vergi numarasi", "vergi kimlik numarası", "vergi kimlik numarasi"], separators: " ", check: { characters in
            // Turkey's tax number: each of the first nine shifted by its place, doubled that many times mod 9, the sum's complement.
            guard let d = numbers(characters), d.count == 10 else { return false }
            return vknDigit(Array(d[0..<9])) == d[9]
        }, draw: { _, rng in
            let d = randomDigits(9, &rng)
            return characters(d + [vknDigit(d)])
        }),
        Recognizer("SI_MATICNA", keys: ["maticna", "maticnastevilka", "maticnastevilkapodjetja"], forms: [
            .init(#"\b\d{7}(?: ?[A-Z\d]\d{2})?\b"#, 0.05),
        ], context: ["matična številka", "maticna stevilka", "matična", "maticna"], separators: " .", check: { characters in
            // Slovenia's business register number: six digits and a check by weights 7 … 2 mod 11, then a unit's three.
            guard characters.count == 7 || characters.count == 10, let d = numbers(Array(characters.prefix(7))), let last = siMaticnaDigit(Array(d[0..<6])), last == d[6] else { return false }
            guard characters.count == 10 else { return true }
            return characters[7].isASCII && (characters[7].isLetter || characters[7].isNumber) && numbers(Array(characters[8...])) != nil
        }, draw: { like, rng in
            while true {
                let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(5, &rng)
                if let last = siMaticnaDigit(d) { return characters(d + [last]) + (like.count == 10 ? Array(like.suffix(3)) : []) }
            }
        }),
        Recognizer("PL_REGON", keys: ["regon", "numerregon", "regonnumber"], forms: [
            .init(#"\b\d{9}\b"#, 0.05),
            .init(#"\b\d{14}\b"#, 0.05),
        ], context: ["regon", "numer regon", "numer identyfikacyjny regon"], separators: " -", check: { characters in
            // Poland's statistical register: nine digits with a weighted check mod 11, fourteen a local unit's with a second.
            guard let d = numbers(characters), d.count == 9 || d.count == 14 else { return false }
            guard eastWeighted(d, [8, 9, 2, 3, 4, 5, 6, 7]) % 11 % 10 == d[8] else { return false }
            return d.count == 9 || eastWeighted(d, [2, 4, 8, 5, 0, 9, 7, 3, 6, 1, 2, 4, 8]) % 11 % 10 == d[13]
        }, draw: { like, rng in
            var d = [Int.random(in: 0...9, using: &rng)] + randomDigits(7, &rng)
            d.append(eastWeighted(d, [8, 9, 2, 3, 4, 5, 6, 7]) % 11 % 10)
            guard like.count == 14 else { return characters(d) }
            d += randomDigits(4, &rng)
            return characters(d + [eastWeighted(d, [2, 4, 8, 5, 0, 9, 7, 3, 6, 1, 2, 4, 8]) % 11 % 10])
        }),
        // vat_west
        Recognizer("AT_UID", keys: ["uidnummer", "uidnr", "atuid"], forms: [
            .init(#"\bAT ?U ?\d{3} ?\d{2} ?\d{3}\b"#, 0.5, alone: true),
        ], context: ["uid", "uid-nummer", "uid-nr", "umsatzsteuer-identifikationsnummer", "umsatzsteuer", "ust-idnr", "vat", "vatin"], separators: " .-/", check: { characters in
            // Austria's UID: "U", seven digits and a check over them (every second one doubled and its digits added, plus 4).
            let body = characters.starts(with: ["A", "T"]) ? Array(characters.dropFirst(2)) : characters
            guard body.count == 9, body[0] == "U", let d = numbers(Array(body[1...])) else { return false }
            return austrianUIDDigit(Array(d[0..<7])) == d[7]
        }, draw: { like, rng in
            let d = randomDigits(7, &rng)
            return (like.starts(with: ["A", "T"]) ? ["A", "T"] : []) + ["U"] + characters(d + [austrianUIDDigit(d)])
        }),
        Recognizer("BE_VAT", keys: ["ondernemingsnummer", "numerodentreprise", "kbonummer", "bcenumero", "btwnummer"], forms: [
            .init(#"\bBE[ -]?(?:\(0\) ?|[01] ?)?\d{3}[ .]?\d{3}[ .]?\d{3}\b"#, 0.3),
            .init(#"(?<![\w)])\(0\) ?\d{3}[ .]?\d{3}[ .]?\d{3}\b"#, 0.1),
            .init(#"\b[01]\d{3}\.\d{3}\.\d{3}\b"#, 0.1),
            .init(#"\b[01]\d{9}\b"#, 0.05),
        ], context: ["btw", "tva", "vat", "ondernemingsnummer", "numéro d'entreprise", "kbo", "bce", "enterprise number", "vatin"], separators: " .-()", check: { characters in
            // Belgium's enterprise number: ten digits, the first 0 or 1 (an old nine-digit one has its 0 left off),
            // the last two 97 less the first eight's remainder by 97.
            let body = characters.starts(with: ["B", "E"]) ? Array(characters.dropFirst(2)) : characters
            guard let written = numbers(body), written.count == 9 || written.count == 10 else { return false }
            let d = written.count == 9 ? [0] + written : written
            guard d[0] <= 1, number(d) > 0 else { return false }
            return 97 - number(Array(d[0..<8])) % 97 == d[8] * 10 + d[9]
        }, draw: { like, rng in
            let prefixed = like.starts(with: ["B", "E"])
            let body = Array(like.dropFirst(prefixed ? 2 : 0))
            let short = body.count == 9
            let lead = !short && body.first == "1" ? 1 : 0
            let head = [lead, lead == 0 ? Int.random(in: 1...9, using: &rng) : Int.random(in: 0...9, using: &rng)] + randomDigits(6, &rng)
            let d = head + twoDigits(97 - number(head) % 97)
            return (prefixed ? ["B", "E"] : []) + characters(short ? Array(d.dropFirst()) : d)
        }),
        Recognizer("CH_UID", keys: ["unternehmensidentifikationsnummer", "uidnummer", "mwstnummer", "mwstnr", "numeroide", "numeroidi"], forms: [
            .init(#"\bCHE[ -]?\d(?:[ .]?\d){8}(?:[ ]?(?:MWST|TVA|IVA|TPV)\b|\.(?!\w)|\b)"#, 0.6, alone: true),
            .init(#"\b\d{3}\.\d{3}\.\d{3}\b"#, 0.1),
        ], context: ["uid", "ide", "idi", "mwst", "mwst-nr", "tva", "iva", "unternehmens-identifikationsnummer", "numéro ide", "vat", "vatin"], separators: " .-", check: { characters in
            // Switzerland's UID (eCH-0097): nine digits, the last a modulus 11 check over the eight before it; for VAT, followed by MWST, TVA, IVA or TPV.
            var body = characters
            if body.starts(with: ["C", "H", "E"]) { body.removeFirst(3) }
            if body.count > 9, let suffix = ["MWST", "TVA", "IVA", "TPV"].first(where: { String(body.suffix($0.count)) == $0 }) { body.removeLast(suffix.count) }
            guard let d = numbers(body), d.count == 9 else { return false }
            return norwayDigit(d[0..<8], [5, 4, 3, 2, 7, 6, 5, 4]) == d[8]
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["C", "H", "E"]) ? ["C", "H", "E"] : []
            let suffix = like.count > 12 ? ["MWST", "TVA", "IVA", "TPV"].first { String(like.suffix($0.count)) == $0 }.map { Array($0) } ?? [] : []
            while true {
                let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
                if let last = norwayDigit(d[...], [5, 4, 3, 2, 7, 6, 5, 4]) { return prefix + characters(d + [last]) + suffix }
            }
        }),
        Recognizer("LI_PEID", keys: ["peidnumber", "peidnr", "personenidentifikationsnummer"], forms: [
            .init(#"\b\d{4,13}\b"#, 0.05),
            .init(#"\b\d{1,9}(?:[ .]\d{3}){1,3}\b"#, 0.05),
        ], context: ["peid", "pe-id", "personenidentifikationsnummer", "personen-identifikationsnummer"], verifies: false, separators: " .", check: { characters in
            // Liechtenstein's PEID (Amt für Statistik): four to twelve digits issued in turn, zeros sometimes written before them; no check.
            guard let d = numbers(characters), d.count <= 13 else { return false }
            return (4...12).contains(d.drop { $0 == 0 }.count)
        }, draw: { like, rng in
            // Its zeros before it kept, the number drawn as long.
            let zeros = like.prefix { $0 == "0" }.count
            let count = max(4, min(12, like.count - zeros))
            return Array(repeating: "0", count: like.count - zeros >= 4 ? zeros : 0) + characters([Int.random(in: 1...9, using: &rng)] + randomDigits(count - 1, &rng))
        }),
        Recognizer("CY_VAT", forms: [
            .init(#"\bCY[ -]{0,2}\d{8} ?[A-Z]\b"#, 0.3),
            .init(#"\b\d{8}[A-Z]\b"#, 0.05),
        ], context: ["vat", "φπα", "αριθμός φπα", "vat number", "vatin"], separators: " -", check: { characters in
            // Cyprus's: eight digits, not starting 12, and a letter checking them.
            let body = characters.starts(with: ["C", "Y"]) ? Array(characters.dropFirst(2)) : characters
            guard body.count == 9, let d = numbers(Array(body[0..<8])), !(d[0] == 1 && d[1] == 2) else { return false }
            return cyprusLetter(d) == body[8]
        }, draw: { like, rng in
            let prefixed = like.starts(with: ["C", "Y"])
            let lead = like.dropFirst(prefixed ? 2 : 0).first?.wholeNumberValue ?? 1
            let second = lead == 1 ? pick("013456789", &rng).wholeNumberValue ?? 0 : Int.random(in: 0...9, using: &rng)
            let d = [lead, second] + randomDigits(6, &rng)
            return (prefixed ? ["C", "Y"] : []) + characters(d) + [cyprusLetter(d)]
        }),
        Recognizer("DK_CVR", keys: ["cvr", "cvrnummer", "cvrnr", "cvrno", "cvrnumber", "senummer"], forms: [
            .init(#"\bDK[ :-]{0,2}\d{2} ?\d{2} ?\d{2} ?\d{2}\b"#, 0.3),
            .init(#"\b[1-9]\d \d{2} \d{2} \d{2}\b"#, 0.1),
            .init(#"\b[1-9]\d{7}\b"#, 0.05),
        ], context: ["cvr", "cvr-nummer", "cvr-nr", "momsnummer", "moms", "se-nummer", "vat", "vatin"], separators: " .-:", check: { characters in
            // Denmark's CVR: eight digits, the first not 0, weighted 2, 7, 6, 5, 4, 3, 2, 1 to a multiple of 11.
            let body = characters.starts(with: ["D", "K"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 8, d[0] != 0 else { return false }
            return zip(d, [2, 7, 6, 5, 4, 3, 2, 1]).reduce(0) { $0 + $1.0 * $1.1 } % 11 == 0
        }, draw: { like, rng in
            while true {
                let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(6, &rng)
                let rest = (11 - zip(d, [2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 11
                if rest < 10 { return (like.starts(with: ["D", "K"]) ? ["D", "K"] : []) + characters(d + [rest]) }
            }
        }),
        Recognizer("ES_CIF", keys: ["cifnumber", "numerocif", "cifempresa"], forms: [
            .init(#"\b(?:ES[ -]{0,3})?[A-HJNP-SUVW][ -]?\d(?: ?\d){6}[ -]?[\dA-J]\b"#, 0.3),
        ], context: ["cif", "nif", "código de identificación fiscal", "vat", "iva", "vatin"], separators: " -", check: { characters in
            // Spain's CIF: a letter for the kind of body, seven digits and a control, a digit or the letter of JABCDEFGHI in its place.
            let body = characters.count == 11 && characters.starts(with: ["E", "S"]) ? Array(characters.dropFirst(2)) : characters
            guard body.count == 9, "ABCDEFGHJNPQRSUVW".contains(body[0]), let d = numbers(Array(body[1..<8])) else { return false }
            let control = cifControl(d)
            let digit = Character(String(control)), letter = Array("JABCDEFGHI")[control]
            // A company (A, B, E, H) ends in the digit; a body with no share capital or a foreign one (N, P, Q, R, S, W) in the letter.
            if "ABEH".contains(body[0]) { return body[8] == digit }
            if "NPQRSW".contains(body[0]) { return body[8] == letter }
            return body[8] == digit || body[8] == letter
        }, draw: { like, rng in
            let prefixed = like.count == 11 && like.starts(with: ["E", "S"])
            let body = Array(like.dropFirst(prefixed ? 2 : 0))
            let type = body.first.flatMap { "ABCDEFGHJNPQRSUVW".contains($0) ? $0 : nil } ?? "B"
            let d = randomDigits(7, &rng)
            let control = cifControl(d)
            let lettered = "NPQRSW".contains(type) || !"ABEH".contains(type) && body.count == 9 && body[8].isLetter
            return (prefixed ? ["E", "S"] : []) + [type] + characters(d) + [lettered ? Array("JABCDEFGHI")[control] : Character(String(control))]
        }),
        Recognizer("FI_YTUNNUS", keys: ["ytunnus", "yritystunnus", "alvnumero", "alvnro", "alvtunnus"], forms: [
            .init(#"\bFI[ -]{0,2}\d(?: ?\d){6}[ -]?\d\b"#, 0.3),
            .init(#"\b\d{7}-\d\b"#, 0.1),
            .init(#"\b\d{8}\b"#, 0.05),
        ], context: ["y-tunnus", "ytunnus", "yritystunnus", "alv", "alv-numero", "arvonlisävero", "business id", "vat", "vatin"], separators: " -", check: { characters in
            // Finland's business ID: seven digits and a modulus 11 check (written after a dash; the VAT number is FI and all eight).
            let body = characters.starts(with: ["F", "I"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 8 else { return false }
            return norwayDigit(d[0..<7], [7, 9, 10, 5, 8, 4, 2]) == d[7]
        }, draw: { like, rng in
            while true {
                let d = randomDigits(7, &rng)
                if let last = norwayDigit(d[...], [7, 9, 10, 5, 8, 4, 2]) { return (like.starts(with: ["F", "I"]) ? ["F", "I"] : []) + characters(d + [last]) }
            }
        }),
        Recognizer("FR_SIREN", keys: ["sirennumber", "numerosiren", "sirennumero"], forms: [
            .init(#"\b\d{3} ?\d{3} ?\d{3}\b"#, 0.05),
            .init(#"\b\d(?: \d){8}\b"#, 0.05),
        ], context: ["siren", "numéro siren"], separators: " .", check: { characters in
            // France's SIREN (INSEE): nine digits, the last a Luhn check.
            guard let d = numbers(characters), d.count == 9 else { return false }
            return Patterns.luhn(d)
        }, draw: { _, rng in
            let body = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            return characters(body + [luhnDigit(body)])
        }),
        Recognizer("FR_SIRET", keys: ["siret", "siretnumber", "numerosiret", "siretnumero"], forms: [
            .init(#"\b\d(?:[ .]?\d){13}\b"#, 0.05),
        ], context: ["siret", "numéro siret"], separators: " .", check: { characters in
            // An establishment's SIRET: its SIREN and five digits, the whole a Luhn check; La Poste's, under SIREN 356 000 000, a sum of digits divisible by 5.
            guard let d = numbers(characters), d.count == 14, Patterns.luhn(Array(d[0..<9])) else { return false }
            if d[0..<9] == [3, 5, 6, 0, 0, 0, 0, 0, 0] { return d.reduce(0, +) % 5 == 0 || Patterns.luhn(d) }
            return Patterns.luhn(d)
        }, draw: { like, rng in
            if like.count == 14, Array(like.prefix(9)) == Array("356000000") {
                let nic = randomDigits(4, &rng)
                let last = (10 - (14 + nic.reduce(0, +)) % 5) % 5 + 5 * Int.random(in: 0...1, using: &rng)
                return Array("356000000") + characters(nic + [last])
            }
            let siren = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            let body = siren + [luhnDigit(siren)] + randomDigits(4, &rng)
            return characters(body + [luhnDigit(body)])
        }),
        Recognizer("FR_TVA", keys: ["numerotva", "tvaintracommunautaire", "tvaintracom", "numtva", "numerotvaintracommunautaire"], forms: [
            .init(#"\bFR[ -]{0,2}[\dA-HJ-NP-Z] ?[\dA-HJ-NP-Z](?:[ .-]?\d){9}\b"#, 0.5, alone: true),
            .init(#"\b(?:\d[\dA-HJ-NP-Z]|[A-HJ-NP-Z]\d)(?: ?\d){9}\b"#, 0.05),
        ], context: ["tva", "tva intracommunautaire", "numéro de tva", "n° tva", "vat", "vatin"], separators: " .-", check: { characters in
            // France's (and Monaco's) VAT number: a two-character key and a SIREN, or "000" and six digits for Monaco.
            let body = characters.count == 13 && characters.starts(with: ["F", "R"]) ? Array(characters.dropFirst(2)) : characters
            return frenchVATValid(body)
        }, draw: { like, rng in
            let prefixed = like.count == 13 && like.starts(with: ["F", "R"])
            let body = Array(like.dropFirst(prefixed ? 2 : 0))
            let monaco = body.count == 11 && Array(body[2..<5]) == ["0", "0", "0"]
            let numeric = body.count < 2 || body[0].isNumber && body[1].isNumber
            for _ in 0..<1000 {
                var siren: [Int]
                if monaco {
                    siren = [0, 0, 0] + randomDigits(6, &rng)
                } else {
                    let head = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
                    siren = head + [luhnDigit(head)]
                }
                if numeric { return (prefixed ? ["F", "R"] : []) + characters(twoDigits((number(siren) * 100 + 12) % 97) + siren) }
                // A key of letters and digits, each where the original's was.
                var key = body[0..<2].map { $0.isNumber ? pick(digits, &rng) : pick("ABCDEFGHJKLMNPQRSTUVWXYZ", &rng) }
                // Two letters only after FR: bare, a key of two letters is written by no form.
                if !prefixed, key.allSatisfy(\.isLetter) { key[1] = pick(digits, &rng) }
                if frenchVATValid(key + characters(siren)) { return (prefixed ? ["F", "R"] : []) + key + characters(siren) }
            }
            return Array("FR") + characters([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        }),
        Recognizer("GB_VAT", keys: ["ukvat", "gbvat", "ukvatnumber", "gbvatnumber", "ukvatno"], forms: [
            .init(#"\b(?:GB|XI) ?\d(?: ?\d){8}(?: ?\d{3})?\b"#, 0.3),
            .init(#"\b(?:(?:GB|XI) ?)?(?:GD|HA)8888\d{5}\b"#, 0.3),
            .init(#"\b\d{3} \d{4} \d{2}(?: \d{3})?\b"#, 0.1),
            .init(#"\b\d{9}(?:\d{3})?\b"#, 0.05),
        ], context: ["vat", "vat number", "vat no", "vat reg", "vat registration", "hmrc", "vatin"], separators: " .-", check: { characters in
            // The UK's VAT number (HMRC): nine digits weighted 8 to 2, then the last two as a number, to a multiple of 97,
            // or of 97 less 55 for numbers issued since 2010; a branch's three digits may follow. A government department's
            // (GD) or health authority's (HA) carries its own number's remainder by 97.
            var body = characters
            if body.count > 9, body.starts(with: ["G", "B"]) || body.starts(with: ["X", "I"]) { body.removeFirst(2) }
            if body.count == 11, body.starts(with: ["G", "D"]) || body.starts(with: ["H", "A"]) {
                guard Array(body[2..<6]) == ["8", "8", "8", "8"], let d = numbers(Array(body[6...])) else { return false }
                let unit = number(Array(d[0..<3]))
                return (body[0] == "G" ? unit < 500 : unit >= 500) && unit % 97 == d[3] * 10 + d[4]
            }
            guard let d = numbers(body), d.count == 9 || d.count == 12 else { return false }
            let rest = britishVATSum(Array(d[0..<9])) % 97
            return rest == 0 || rest == 42 && number(Array(d[0..<3])) >= 100
        }, draw: { like, rng in
            let prefix: [Character] = like.count > 9 && (like.starts(with: ["G", "B"]) || like.starts(with: ["X", "I"])) ? Array(like.prefix(2)) : []
            let body = Array(like.dropFirst(prefix.count))
            if body.count == 11, body.starts(with: ["G", "D"]) || body.starts(with: ["H", "A"]) {
                let unit = body[0] == "G" ? Int.random(in: 0...499, using: &rng) : Int.random(in: 500...999, using: &rng)
                return prefix + Array(body.prefix(2)) + Array("8888") + characters([unit / 100, unit / 10 % 10, unit % 10] + twoDigits(unit % 97))
            }
            // A number below 100 in its first three digits keeps the old scheme.
            let old = body.count >= 3 && body[0] == "0" && body[1].isNumber && body[2].isNumber
            let d = (old ? [0] : [Int.random(in: 1...9, using: &rng)]) + randomDigits(6, &rng)
            let added = !old && Int.random(in: 0...1, using: &rng) == 1 ? 55 : 0
            let check = (97 - (britishVATSum(d + [0, 0]) + added) % 97) % 97
            return prefix + characters(d + twoDigits(check) + (body.count == 12 ? randomDigits(3, &rng) : []))
        }),
        Recognizer("GR_AFM", keys: ["afm", "afmnumber"], forms: [
            .init(#"\b(?:EL|GR)[ :-]{0,2}\d{3} ?\d{3} ?\d{3}\b"#, 0.3),
            .init(#"\b(?:EL|GR)[ :-]{0,2}\d{8}\b"#, 0.3),
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["afm", "αφμ", "α.φ.μ", "φπα", "fpa", "vat", "vatin"], separators: " .-:/", check: { characters in
            // Greece's AFM: nine digits (a short one has its leading 0 left off), the last the first eight's weighted sum by powers of 2, modulo 11, modulo 10.
            var body = characters
            if body.starts(with: ["E", "L"]) || body.starts(with: ["G", "R"]) { body.removeFirst(2) }
            guard let written = numbers(body), written.count == 9 || written.count == 8 else { return false }
            let d = written.count == 8 ? [0] + written : written
            return greekVATDigit(Array(d[0..<8])) == d[8]
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["E", "L"]) || like.starts(with: ["G", "R"]) ? Array(like.prefix(2)) : []
            let short = like.count - prefix.count == 8
            let lead = short ? 0 : pick("01789", &rng).wholeNumberValue ?? 0
            let head = [lead, Int.random(in: 1...9, using: &rng)] + randomDigits(6, &rng)
            let d = head + [greekVATDigit(head)]
            return prefix + characters(short ? Array(d.dropFirst()) : d)
        }),
        Recognizer("IE_VAT", keys: ["ievat", "ievatnumber"], forms: [
            .init(#"\bIE[ -]?\d(?: ?\d){6} ?[A-W]{1,2}\b"#, 0.3),
            .init(#"\b(?:IE[ -]?)?\d[A-Z+*]\d{5}[A-W]\b"#, 0.3),
        ], context: ["vat", "vat number", "vat no", "cáin bhreisluacha", "vatin"], separators: " -", check: { characters in
            // Ireland's VAT number: seven digits, a check letter and, since 2013, a second letter weighing in; before, a
            // company's was a digit, a letter (or + or *), five digits and a check over 0, the five and the first.
            let body = characters.starts(with: ["I", "E"]) ? Array(characters.dropFirst(2)) : characters
            guard body.count == 8 || body.count == 9 else { return false }
            if let d = numbers(Array(body[0..<7])) {
                let second: Character? = body.count == 9 ? body[8] : nil
                guard second.map({ "WABCDEFGHIJKLMNOPQRSTUV".contains($0) }) ?? true else { return false }
                return ppsLetter(d, second) == body[7]
            }
            guard body.count == 8, body[0].isASCII, let first = body[0].wholeNumberValue, "ABCDEFGHIJKLMNOPQRSTUVWXYZ+*".contains(body[1]), let five = numbers(Array(body[2..<7])) else { return false }
            return ppsLetter([0] + five + [first], nil) == body[7]
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["I", "E"]) ? ["I", "E"] : []
            let body = Array(like.dropFirst(prefix.count))
            if body.count == 8, !body[1].isNumber {
                let first = Int.random(in: 0...9, using: &rng), five = randomDigits(5, &rng)
                let mark: Character = "+*".contains(body[1]) ? body[1] : pick(letters, &rng)
                return prefix + characters([first]) + [mark] + characters(five) + [ppsLetter([0] + five + [first], nil)]
            }
            let d = randomDigits(7, &rng)
            let second: Character? = body.count == 9 && "WABCDEFGHIJKLMNOPQRSTUV".contains(body[8]) ? body[8] : nil
            return prefix + characters(d) + [ppsLetter(d, second)] + (second.map { [$0] } ?? [])
        }),
        Recognizer("IS_VSK", keys: ["vsk", "vsknumer", "vsknumber", "virdisaukaskattsnumer"], forms: [
            .init(#"\bIS ?\d{5,6}\b"#, 0.3),
        ], context: ["vsk", "vsk-númer", "virðisaukaskattsnúmer", "virðisaukaskattur"], verifies: false, separators: " ", check: { characters in
            // Iceland's VAT number: five or six digits, no check.
            guard characters.starts(with: ["I", "S"]), let d = numbers(Array(characters.dropFirst(2))) else { return false }
            return d.count == 5 || d.count == 6
        }, draw: { like, rng in
            ["I", "S"] + characters(randomDigits(like.count == 8 ? 6 : 5, &rng))
        }),
        // "vn" names it only beside a value passing its check, never as a key alone.
        Recognizer("FO_VN", keys: ["vnumber", "vtal", "vinnutal", "fovn"], forms: [
            .init(#"\bFO[ -]?\d{3}[ .-]?\d{3}\b"#, 0.3),
            .init(#"\b\d{3}[ .-]?\d{3}\b"#, 0.05),
            .init(#"\b\d{2} \d{2} \d{2}\b"#, 0.05),
        ], context: ["vn", "v-tal", "vinnutal", "v-number", "v-nummar"], verifies: false, separators: " .-", check: { characters in
            // The Faroe Islands' V-number (TAKS): six digits issued in turn, FO before them as a VAT number; no check.
            let body = characters.starts(with: ["F", "O"]) ? Array(characters.dropFirst(2)) : characters
            return numbers(body)?.count == 6
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["F", "O"]) ? ["F", "O"] : []
            return prefix + characters([Int.random(in: 1...9, using: &rng)] + randomDigits(5, &rng))
        }),
        Recognizer("LU_TVA", keys: ["lutva", "lutvanumber"], forms: [
            .init(#"\bLU[ .:-]{0,2}\d(?:[ .]?\d){7}\b"#, 0.3),
            .init(#"\b\d{3} \d{3} \d{2}\b"#, 0.1),
            .init(#"\b\d{8}\b"#, 0.05),
        ], context: ["tva", "vat", "numéro tva", "numéro d'identification tva", "vatin"], separators: " .-:", check: { characters in
            // Luxembourg's: eight digits, the last two the first six's remainder by 89.
            let body = characters.starts(with: ["L", "U"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 8 else { return false }
            return number(Array(d[0..<6])) % 89 == d[6] * 10 + d[7]
        }, draw: { like, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(5, &rng)
            return (like.starts(with: ["L", "U"]) ? ["L", "U"] : []) + characters(d + twoDigits(number(d) % 89))
        }),
        Recognizer("MT_VAT", keys: ["mtvat", "mtvatnumber"], forms: [
            .init(#"\bMT ?[1-9]\d{3}[ -]?\d{4}\b"#, 0.3),
            .init(#"\b[1-9]\d{3}-\d{4}\b"#, 0.1),
            .init(#"\b[1-9]\d{7}\b"#, 0.05),
        ], context: ["vat", "vat number", "vat no", "vatin"], separators: " -", check: { characters in
            // Malta's: eight digits, the first not 0, weighted 3, 4, 6, 7, 8, 9, 10, 1 to a multiple of 37.
            let body = characters.starts(with: ["M", "T"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 8, d[0] != 0 else { return false }
            return zip(d, [3, 4, 6, 7, 8, 9, 10, 1]).reduce(0) { $0 + $1.0 * $1.1 } % 37 == 0
        }, draw: { like, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(5, &rng)
            let rest = (37 - zip(d, [3, 4, 6, 7, 8, 9]).reduce(0) { $0 + $1.0 * $1.1 } % 37) % 37
            let check = rest + 37 * Int.random(in: 0...((99 - rest) / 37), using: &rng)
            return (like.starts(with: ["M", "T"]) ? ["M", "T"] : []) + characters(d + twoDigits(check))
        }),
        Recognizer("NL_BTW", keys: ["btwnummer", "btwid", "btwidnummer", "btwidentificatienummer", "omzetbelastingnummer"], forms: [
            .init(#"\bNL[ .-]?\d(?:[ .]?\d){8}[ .]?B[ .]?\d{2}\b"#, 0.5, alone: true),
            .init(#"\bNL\d{7,8}B\d{2}\b"#, 0.3),
            .init(#"\b\d{9}B\d{2}\b"#, 0.3),
        ], context: ["btw", "btw-nummer", "btw-id", "btw-identificatienummer", "omzetbelastingnummer", "vat", "vatin"], separators: " .-", check: { characters in
            // The Netherlands' VAT number: nine digits (leading zeros may be left off), B and a two-digit branch. A sole trader's since 2020
            // passes ISO 7064 MOD 97-10 over all of it, NL and B as letters; older ones pass the eleven test over the nine digits.
            var body = characters
            if body.starts(with: ["N", "L"]) { body.removeFirst(2) }
            guard (10...12).contains(body.count), body[body.count - 3] == "B", let written = numbers(Array(body.prefix(body.count - 3))),
                  let branch = numbers(Array(body.suffix(2))), number(branch) > 0 else { return false }
            let d = Array(repeating: 0, count: 9 - written.count) + written
            guard number(d) > 0 else { return false }
            return dutchElevens(d) || dutchModern(d, branch)
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["N", "L"]) ? ["N", "L"] : []
            let body = Array(like.dropFirst(prefix.count))
            let fits = (10...12).contains(body.count) && body[body.count - 3] == "B"
            let count = fits ? body.count - 3 : 9
            let kept = fits ? numbers(Array(body.suffix(2))) ?? [0, 1] : [0, 1]
            let branch = number(kept) > 0 ? kept : [0, 1]
            let pad = Array(repeating: 0, count: 9 - count)
            // The original's scheme: the eleven test where it passes it, else MOD 97-10.
            let original = fits ? numbers(Array(body.prefix(count))).map { pad + $0 } : nil
            if let original, !dutchElevens(original) {
                let head = [Int.random(in: 1...9, using: &rng)] + randomDigits(count - 3, &rng)
                for end in 0...99 where dutchModern(pad + head + twoDigits(end), branch) {
                    return prefix + characters(head + twoDigits(end)) + ["B"] + characters(branch)
                }
            }
            while true {
                let head = [Int.random(in: 1...9, using: &rng)] + randomDigits(count - 2, &rng)
                let rest = zip(pad + head, (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 11
                if rest < 10 { return prefix + characters(head + [rest]) + ["B"] + characters(branch) }
            }
        }),
        Recognizer("NO_ORGNR", keys: ["organisasjonsnummer", "mvanummer", "mvanr", "foretaksnummer"], forms: [
            .init(#"\b(?:NO ?)?\d{3} ?\d{3} ?\d{3} ?MVA\b"#, 0.5, alone: true),
            .init(#"\bNO ?\d{3} ?\d{3} ?\d{3}\b"#, 0.3),
            .init(#"\b[89]\d{2} \d{3} \d{3}\b"#, 0.1),
            .init(#"\b[89]\d{8}\b"#, 0.05),
        ], context: ["organisasjonsnummer", "org.nr", "orgnr", "org nr", "mva", "mva-nummer", "enhetsregisteret", "foretaksregisteret", "vat", "vatin"], folds: false, separators: " .-", check: { characters in
            // Written in capitals only: "vat no 909225231" is a number after the word no, not Norway's.
            // Norway's organisation number (Brønnøysund): nine digits, the last a modulus 11 check; for VAT, followed by MVA.
            var body = characters
            if body.starts(with: ["N", "O"]) { body.removeFirst(2) }
            if body.count == 12, body.suffix(3) == ["M", "V", "A"] { body.removeLast(3) }
            guard let d = numbers(body), d.count == 9 else { return false }
            return norwayDigit(d[0..<8], [3, 2, 7, 6, 5, 4, 3, 2]) == d[8]
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["N", "O"]) ? ["N", "O"] : []
            let suffix: [Character] = like.count >= 12 && like.suffix(3) == ["M", "V", "A"] ? ["M", "V", "A"] : []
            while true {
                let d = [Int.random(in: 8...9, using: &rng)] + randomDigits(7, &rng)
                if let last = norwayDigit(d[...], [3, 2, 7, 6, 5, 4, 3, 2]) { return prefix + characters(d + [last]) + suffix }
            }
        }),
        Recognizer("PT_NIF", keys: ["nipc", "numerocontribuinte", "numerodecontribuinte", "nifpt"], forms: [
            .init(#"\bPT[ -]?\d{3}[ .]?\d{3}[ .]?\d{3}\b"#, 0.3),
            .init(#"\b[1-9]\d{2} \d{3} \d{3}\b"#, 0.1),
            .init(#"\b[1-9]\d{8}\b"#, 0.05),
        ], context: ["nif", "nipc", "contribuinte", "número de contribuinte", "número de identificação fiscal", "vat", "iva", "vatin"], separators: " .-", check: { characters in
            // Portugal's NIF and NIPC: nine digits, the first not 0, the last a modulus 11 check (10 written 0).
            let body = characters.starts(with: ["P", "T"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 9, d[0] != 0 else { return false }
            return portugueseDigit(Array(d[0..<8])) == d[8]
        }, draw: { like, rng in
            let prefixed = like.starts(with: ["P", "T"])
            // Its first digit, the kind of holder (a person, a company…), as the original's.
            let lead = like.dropFirst(prefixed ? 2 : 0).first?.wholeNumberValue.flatMap { $0 == 0 ? nil : $0 } ?? 5
            let head = [lead] + randomDigits(7, &rng)
            return (prefixed ? ["P", "T"] : []) + characters(head + [portugueseDigit(head)])
        }),
        Recognizer("SE_VAT", keys: ["momsregistreringsnummer", "momsregnr", "momsnr", "momsnummer"], forms: [
            .init(#"\bSE[ -]?\d(?:[ .-]?\d){9}[ .-]?01\b"#, 0.5, alone: true),
            .init(#"\b\d{10}01\b"#, 0.05),
        ], context: ["moms", "momsregistreringsnummer", "momsreg.nr", "momsnummer", "vat", "vatin"], separators: " .-", check: { characters in
            // Sweden's VAT number: an organisation or personal number (ten digits, Luhn) and 01.
            let body = characters.starts(with: ["S", "E"]) ? Array(characters.dropFirst(2)) : characters
            guard let d = numbers(body), d.count == 12, d[10] == 0, d[11] == 1 else { return false }
            return Patterns.luhn(Array(d[0..<10]))
        }, draw: { like, rng in
            let prefixed = like.starts(with: ["S", "E"])
            // The first digit is the group (legal form's family): kept.
            let group = like.dropFirst(prefixed ? 2 : 0).first?.wholeNumberValue.flatMap { $0 == 0 ? nil : $0 } ?? 5
            let body = [group] + randomDigits(8, &rng)
            return (prefixed ? ["S", "E"] : []) + characters(body + [luhnDigit(body), 0, 1])
        }),
        Recognizer("EU_OSS", keys: ["ossnumber", "ossid", "iossnumber", "iossid"], forms: [
            .init(#"\bEU ?\d{9}\b"#, 0.3),
            .init(#"\bIM ?\d{10}\b"#, 0.3),
        ], context: ["oss", "ioss", "one stop shop", "import one stop shop", "vat", "vatin"], verifies: false, separators: " -", check: { characters in
            // The EU's One-Stop Shop (EU, nine digits) and Import One-Stop Shop (IM, ten) numbers: the identifying member state's ISO 3166 numeric code first.
            guard characters.count >= 5, let d = numbers(Array(characters.dropFirst(2))) else { return false }
            let prefix = String(characters.prefix(2))
            guard prefix == "EU" && d.count == 9 || prefix == "IM" && d.count == 10 else { return false }
            return euMemberStates.contains(number(Array(d[0..<3])))
        }, draw: { like, rng in
            let prefix: [Character] = like.starts(with: ["I", "M"]) ? ["I", "M"] : ["E", "U"]
            let written = like.count >= 5 ? numbers(Array(like[2..<5])).map { number($0) } : nil
            let state = written.flatMap { euMemberStates.contains($0) ? $0 : nil } ?? 372
            return prefix + characters([state / 100, state / 10 % 10, state % 10] + randomDigits(prefix == ["I", "M"] ? 7 : 6, &rng))
        }),
        Recognizer("EU_CREDITOR_ID", keys: ["creditorid", "creditoridentifier", "sepacreditorid", "glaeubigerid", "glaubigerid", "glaeubigeridentifikationsnummer", "identifiantcreancier"], forms: [
            .init(#"\b[A-Z]{2} ?\d{2} ?ZZZ ?[A-Z0-9]{4,28}\b"#, 0.5, alone: true),
            .init(#"\b[A-Z]{2} ?\d{2} ?[A-Z0-9]{3} ?[A-Z0-9]{6,28}\b"#, 0.1),
        ], context: ["creditor identifier", "creditor id", "gläubiger-id", "gläubiger-identifikationsnummer", "glaeubiger-id", "identifiant créancier", "sepa creditor", "sepa", "ics"], separators: " -", check: { characters in
            // A SEPA creditor identifier (EPC262-08): country, two check digits, a three-character business code the check skips,
            // and the national identifier; ISO 7064 MOD 97-10 over the identifier, the country and the check digits.
            // One that is an IBAN, its country's length and its whole check, is an account, not a creditor.
            // At least four characters of national identifier, as its forms write it.
            guard (11...35).contains(characters.count), characters[0..<2].allSatisfy({ letters.contains($0) }), characters[2].isNumber, characters[3].isNumber,
                  iso7064Mod97(Array(characters[7...]) + Array(characters[0..<4])) == 1 else { return false }
            return !Patterns.iban(String(characters))
        }, draw: { like, rng in
            let fits = (11...35).contains(like.count) && like[0..<2].allSatisfy { letters.contains($0) } && like[4..<7].allSatisfy { alnumValue($0) != nil } && like[7...].allSatisfy { alnumValue($0) != nil }
            let country = fits ? Array(like[0..<2]) : ["D", "E"]
            let code = fits ? Array(like[4..<7]) : ["Z", "Z", "Z"]
            for _ in 0..<100 {
                // The national identifier, each character a digit or a letter where the original's was.
                let national = fits ? like[7...].map { $0.isNumber ? pick(digits, &rng) : pick(letters, &rng) } : characters([0] + randomDigits(10, &rng))
                let rest = iso7064Mod97(national + country + ["0", "0"]) ?? 0
                let made = country + characters(twoDigits(98 - rest)) + code + national
                if !Patterns.iban(String(made)) { return made }
            }
            return country + ["0", "0"] + code
        }),
        // asia_africa_global
        Recognizer("CN_USCC", keys: ["uscc", "usci", "unifiedsocialcreditcode", "unifiedsocialcreditidentifier", "socialcreditcode", "tongyishehuixinyongdaima"], forms: [
            // Named only: a stray value of this shape passes both checks about once in 3,000.
            .init(#"\b[1-9ANY] ?[1-9] ?\d{6} ?[0-9A-HJ-NP-RTUWXY]{10}\b"#, 0.3),
        ], context: ["uscc", "统一社会信用代码", "社会信用代码", "信用代码", "unified social credit code", "unified social credit identifier", "social credit code"], separators: " ", check: { characters in
            // China's (GB 32100-2015): an authority, a type, a region, a GB 11714 organisation code with its own check, and a mod-31 check over all.
            guard characters.count == 18, "123456789ANY".contains(characters[0]), let head = numbers(Array(characters[1..<8])), head[0] != 0,
                  chinaRegions.contains(head[1] * 10 + head[2]) else { return false }
            return organisationMark(Array(characters[8..<16])) == characters[16] && usccMark(Array(characters[0..<17])) == characters[17]
        }, draw: { like, rng in
            // Its authority, type and region kept: a place and a register, nobody's own.
            let keep = like.count == 18 && "123456789ANY".contains(like[0]) && numbers(Array(like[1..<8])).map { $0[0] != 0 && chinaRegions.contains($0[1] * 10 + $0[2]) } == true
            let head = keep ? Array(like.prefix(8)) : Array("91110000")
            return drawnLike(like, &rng) { rng in
                let body = (0..<8).map { index in keep && like[8 + index].isLetter ? pick(usccLetters, &rng) : pick(digits, &rng) }
                let code = head + body + [organisationMark(body) ?? "0"]
                return code + [usccMark(code) ?? "0"]
            }
        }),
        Recognizer("TW_UBN", keys: ["ubn", "unifiedbusinessnumber", "unifiedbusinessno", "businessaccountingno", "businessaccountingnumber", "tongyibianhao"], forms: [
            .init(#"\b\d{7}[ -]\d\b"#, 0.3),
            .init(#"\b\d{8}\b"#, 0.05),
        ], context: ["ubn", "統一編號", "統編", "營利事業統一編號", "unified business number", "unified business no", "business accounting number"], separators: " -", check: { characters in
            // Taiwan's: weights 1, 2, 1, 2, 1, 2, 4, 1, each product's digits summed; a multiple of 5 since April 2023 (of 10
            // before), and with a 7 seventh its product counts 10 or 1.
            guard let d = numbers(characters), d.count == 8 else { return false }
            let sum = ubnSum(d)
            return sum % 5 == 0 || d[6] == 7 && (sum + 1) % 5 == 0
        }, draw: { like, rng in
            let lead = like.first == "0" ? 0 : Int.random(in: 1...9, using: &rng)
            let body = [lead] + randomDigits(6, &rng)
            let last = (0...9).filter { ubnSum(body + [$0]) % 5 == 0 }.randomElement(using: &rng) ?? 0
            return characters(body + [last])
        }),
        Recognizer("ID_NPWP", keys: ["npwp", "nonpwp", "nomornpwp", "npwpnumber", "npwpno"], forms: [
            .init(#"\b\d{2,3}\.\d{3}\.\d{3}\.\d-\d{3}\.\d{3}\b"#, 0.5, alone: true),
            .init(#"\b\d{2,3} ?\. ?\d{3} ?\. ?\d{3} ?\. ?\d ?- ?\d{3} ?\. ?\d{3}\b"#, 0.3),
            .init(#"\b\d{15,16}\b"#, 0.05),
        ], context: ["npwp", "nomor pokok wajib pajak"], check: { characters in
            // Indonesia's: a taxpayer type, a serial, a Luhn digit over the nine before it, a tax office and a branch;
            // sixteen digits since 2024, the fifteen led by a zero (sixteen led otherwise are a NIK, its own kind).
            guard let d = numbers(characters) else { return false }
            if d.count == 15 { return Patterns.luhn(Array(d[0..<9])) }
            return d.count == 16 && d[0] == 0 && Patterns.luhn(Array(d[0..<10]))
        }, draw: { like, rng in
            // Its taxpayer type and branch kept (the head office's 000 or a branch's number); its tax office drawn
            // too, so a number of another kind passing this check by chance keeps little of itself.
            let long = like.count == 16 && like.first == "0"
            let d = numbers(like) ?? (long ? [0, 0, 1] : [0, 1]) + Array(repeating: 0, count: 13)
            let lead = long ? 3 : 2
            let body = Array(d.prefix(lead)) + randomDigits(6, &rng)
            return characters(body + [luhnDigit(body)] + randomDigits(3, &rng) + Array(d.suffix(3)))
        }),
        Recognizer("VN_MST", keys: ["mst", "masothue", "masodoanhnghiep", "mstnumber"], forms: [
            .init(#"\b\d{10} ?- ?\d{3}\b"#, 0.3),
            .init(#"\b\d{4} \d{3} \d{3}\b"#, 0.3),
            .init(#"\b\d{4} \d{2} \d{2} \d{2}(?: - \d{3})?\b"#, 0.3),
            .init(#"\b\d{2}\.\d{2}\.\d{3}\.\d{3}\b"#, 0.3),
            .init(#"\b\d{10}(?:\d{3})?\b"#, 0.05),
        ], context: ["mst", "mã số thuế", "ma so thue", "mã số doanh nghiệp", "ma so doanh nghiep"], check: { characters in
            // Viet Nam's: a province, a serial, a check digit (weights 31, 29, 23, 19, 17, 13, 7, 5, 3), and a branch's three digits.
            guard let d = numbers(characters), d.count == 10 || d.count == 13, d[2..<9].contains(where: { $0 != 0 }),
                  mstDigit(Array(d[0..<9])) == d[9] else { return false }
            return d.count == 10 || d[10..<13].contains { $0 != 0 }
        }, draw: { like, rng in
            // Its province and branch kept.
            let d = numbers(like) ?? [0, 1]
            let province = d.count >= 2 ? Array(d.prefix(2)) : [0, 1]
            let branch = d.count == 13 && d[10..<13].contains(where: { $0 != 0 }) ? Array(d.suffix(3)) : [0, 0, 1]
            while true {
                let body = province + randomDigits(7, &rng)
                guard body[2...].contains(where: { $0 != 0 }), let mark = mstDigit(body) else { continue }
                return characters(body + [mark] + (like.count == 13 ? branch : []))
            }
        }),
        Recognizer("JP_CORPORATE_NUMBER", keys: ["houjinbangou", "hojinbango", "houjinbango", "jpcorporatenumber"], forms: [
            .init(#"\b[1-9]-\d{4}-\d{4}-\d{4}\b"#, 0.3),
            .init(#"\b[1-9]\d{12}\b"#, 0.05),
        ], context: ["法人番号", "corporate number", "houjin bangou", "hojin bango", "cn"], check: { characters in
            // Japan's: a check digit first, nine less the twelve after it weighted 1 and 2 from the right, modulo 9.
            guard let d = numbers(characters), d.count == 13 else { return false }
            return d[0] == corporateDigit(Array(d[1...]))
        }, draw: { _, rng in
            let body = randomDigits(12, &rng)
            return characters([corporateDigit(body)] + body)
        }),
        Recognizer("TH_JURISTIC_ID", keys: ["juristicid", "juristicpersonid", "juristicnumber", "juristicpersonnumber", "juristicregistrationnumber"], forms: [
            .init(#"\b0-\d{2}-\d-\d{3}-\d{5}-\d\b"#, 0.5, alone: true),
            .init(#"\b0-\d{4}-\d{5}-\d{2}-\d\b"#, 0.5, alone: true),
            .init(#"\b0 \d{2} \d \d{3} \d{5} \d\b"#, 0.3),
            .init(#"\b0 \d{4} \d{5} \d{2} \d\b"#, 0.3),
            .init(#"\b0\d{12}\b"#, 0.05),
        ], context: ["tin", "juristic person", "juristic id", "เลขทะเบียนนิติบุคคล", "เลขประจำตัวผู้เสียภาษี", "เลขประจำตัวผู้เสียภาษีอากร"], check: { characters in
            // Thailand's juristic person (its taxpayer number too): a zero, an office, a type, a year, a serial, and the national ID's check.
            guard let d = numbers(characters), d.count == 13, d[0] == 0 else { return false }
            return thaiDigit(Array(d[0..<12])) == d[12]
        }, draw: { like, rng in
            // Its office and type kept.
            let head = numbers(like).flatMap { $0.count == 13 && $0[0] == 0 ? Array($0.prefix(4)) : nil } ?? [0, 1, 0, 5]
            let d = head + randomDigits(8, &rng)
            return characters(d + [thaiDigit(d)])
        }),
        Recognizer("GH_TIN", keys: ["ghtin", "gratin", "ghanatin"], forms: [
            .init(#"\b[PCGQV]00\d{7}[\dX]\b"#, 0.3),
        ], context: ["tin", "gra tin", "ghana tin"], verifies: false, separators: " ", check: { characters in
            // Ghana's (Ghana Revenue Authority): a holder's letter, two zeros, eight characters; no published check.
            guard characters.count == 11, "PCGQV".contains(characters[0]), characters[1] == "0", characters[2] == "0" else { return false }
            return numbers(Array(characters[3..<10])) != nil && "0123456789X".contains(characters[10])
        }, draw: { like, rng in
            let lead = like.first.flatMap { "PCGQV".contains($0) ? $0 : nil } ?? "P"
            // Its last character as validators compute it, so a stand-in passes theirs too.
            return drawnLike(like, &rng) { rng in
                let d = [0, 0] + randomDigits(7, &rng)
                return [lead] + characters(d) + [ghanaMark(d)]
            }
        }),
        Recognizer("SN_NINEA", keys: ["ninea", "nineacofi", "numeroninea"], forms: [
            .init(#"\b\d(?:[ ,]?\d){6}(?:(?:[ ,]?\d){2})?[ ,/-]{0,2}[012][ /]?[A-HJ-NP-WZ][ /]?\d\b"#, 0.3),
            .init(#"\b\d(?:[ ,]?\d){6}(?:(?:[ ,]?\d){2})?\b"#, 0.05),
        ], context: ["ninea", "cofi"], verifies: false, separators: " ,/-", check: { characters in
            // Senegal's: seven digits (nine in its long form), then a tax code: a regime, a tax centre, a legal form.
            let cofi = characters.count > 9 ? Array(characters.suffix(3)) : []
            let body = Array(characters.dropLast(cofi.count))
            guard body.count == 7 || body.count == 9, numbers(body) != nil else { return false }
            return cofi.isEmpty || "012".contains(cofi[0]) && nineaCentres.contains(cofi[1]) && numbers([cofi[2]]) != nil
        }, draw: { like, rng in
            let cofi = like.count > 9 ? Array(like.suffix(3)) : []
            let count = like.count - cofi.count == 9 ? 9 : 7
            let lead = like.first == "0" ? 0 : Int.random(in: 1...9, using: &rng)
            // Its last digit as validators compute it (weights 1 and 2), its tax code kept.
            let body = [lead] + randomDigits(count - 2, &rng)
            return characters(body + [nineaDigit(body)]) + (cofi.count == 3 && "012".contains(cofi[0]) && nineaCentres.contains(cofi[1]) ? cofi : [])
        }),
        Recognizer("TN_MF", keys: ["matriculefiscal", "matriculefiscale", "numeromatriculefiscal"], forms: [
            .init(#"\b\d{3,7}(?: ?[/-] ?| )?[A-HJ-NP-TV-Z](?:(?: ?[/.-] ?| )?[APBDN](?: ?[/.-] ?| )?[MPCNE](?: ?[/.-] ?| )?\d{3})?\b"#, 0.3),
            .init(#"\b\d{3} \d{3,4} ?[A-HJ-NP-TV-Z][APBDN][MPCNE] \d{3}\b"#, 0.3),
        ], context: ["matricule fiscal", "matricule fiscale", "mf", "identifiant fiscal", "المعرف الجبائي"], verifies: false, separators: " /.-", check: { characters in
            // Tunisia's: a serial, a control letter (never I, O or U), then a VAT code, a category and an establishment, 000 unless secondary (E).
            let count = characters.prefix { $0.isASCII && $0.isNumber }.count
            let rest = Array(characters.dropFirst(count))
            guard (1...7).contains(count), let key = rest.first, mfControlKeys.contains(key) else { return false }
            if rest.count == 1 { return true }
            guard rest.count == 6, "APBDN".contains(rest[1]), "MPCNE".contains(rest[2]), let establishment = numbers(Array(rest[3...])) else { return false }
            return rest[2] == "E" || establishment == [0, 0, 0]
        }, draw: { like, rng in
            let count = max(1, min(7, like.prefix { $0.isASCII && $0.isNumber }.count))
            let rest = Array(like.dropFirst(count))
            let lead = like.first == "0" ? 0 : Int.random(in: 1...9, using: &rng)
            let tail = rest.count == 6 ? Array(rest.dropFirst()) : []
            return characters([lead] + randomDigits(count - 1, &rng)) + [pick(mfControlKeys, &rng)] + tail
        }),
        Recognizer("MA_ICE", keys: ["icenumber", "numeroice", "identifiantcommundelentreprise"], forms: [
            .init(#"\b\d{15}\b"#, 0.05),
            .init(#"\b\d{1,14}(?: \d{1,14}){1,7}\b"#, 0.05),
        ], context: ["ice", "identifiant commun de l'entreprise", "identifiant commun de l’entreprise", "المعرف الموحد للمقاولة"], separators: " ", check: { characters in
            // Morocco's ICE: a company's nine digits, an establishment's four, and two making the whole a multiple of 97.
            guard let d = numbers(characters), d.count == 15 else { return false }
            return number(d) % 97 == 0
        }, draw: { like, rng in
            // Its zeros before the company and its establishment kept: a head office's 0000, nobody's own.
            let d = numbers(like).flatMap { $0.count == 15 ? $0 : nil } ?? [0, 0] + Array(repeating: 0, count: 13)
            let zeros = min(d.prefix { $0 == 0 }.count, 8)
            let body = Array(repeating: 0, count: zeros) + [Int.random(in: 1...9, using: &rng)] + randomDigits(8 - zeros, &rng) + Array(d[9..<13])
            return characters(body + twoDigits((97 - number(body) * 100 % 97) % 97))
        }),
        Recognizer("GN_NIFP", keys: ["nifpnumber", "numeronifp"], forms: [
            .init(#"\b\d{3}[ -]\d{3}[ -]\d{3}\b"#, 0.1),
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["nifp", "numéro d'identification fiscale permanent", "numero d'identification fiscale permanent"], separators: " -", check: { characters in
            // Guinea's NIFp: nine digits, the last a Luhn check.
            guard let d = numbers(characters), d.count == 9 else { return false }
            return Patterns.luhn(d)
        }, draw: { like, rng in
            let body = [like.first == "0" ? 0 : Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            return characters(body + [luhnDigit(body)])
        }),
        // "nuit" names it only beside a value passing its check, never as a key alone: a booking's "nuit" counts nights.
        Recognizer("MZ_NUIT", keys: ["nuitnumber", "numeronuit"], forms: [
            .init(#"\b\d{3}[ .]\d{3}[ .]\d{3}\b"#, 0.1),
            .init(#"\b\d{8}-\d\b"#, 0.1),
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["nuit", "número único de identificação tributária", "numero unico de identificacao tributaria"], separators: " .-", check: { characters in
            // Mozambique's NUIT: eight digits weighed 8, 9, 4, 5, 6, 7, 8, 9, the sum mod 11 its last (10 written 1).
            guard let d = numbers(characters), d.count == 9 else { return false }
            return nuitDigit(Array(d.prefix(8))) == d[8]
        }, draw: { like, rng in
            // Its first digit kept: the kind of taxpayer.
            let lead = like.first?.wholeNumberValue.flatMap { like.count == 9 ? $0 : nil } ?? 1
            let body = [lead] + randomDigits(7, &rng)
            return characters(body + [nuitDigit(body)])
        }),
        Recognizer("EG_TN", keys: ["egtn"], forms: [
            .init(#"\b\d{3}(?: ?[-–/] ?| )\d{3}(?: ?[-–/] ?| )\d{3}\b"#, 0.1),
            .init(#"\b\d{9}\b"#, 0.05),
        ], context: ["tn", "رقم التسجيل الضريبي", "الرقم الضريبي", "رقم التسجيل", "tax registration number egypt"], verifies: false, separators: " -–/", check: { characters in
            // Egypt's tax registration number: nine digits, no published check; written in Arabic-Indic digits too.
            characters.count == 9 && characters.allSatisfy { $0.wholeNumberValue != nil }
        }, draw: { like, rng in
            characters([like.first == "0" ? 0 : Int.random(in: 1...9, using: &rng)] + randomDigits(8, &rng))
        }),
        Recognizer("OM_VAT", keys: ["omvat", "omanvat", "omvatin"], forms: [
            .init(#"\bOM ?\d{4} ?\d{4} ?\d[\dX]\b"#, 0.3),
        ], context: ["vat", "vatin", "vat number", "oman vat", "الرقم الضريبي", "ضريبة القيمة المضافة"], verifies: false, separators: " -", check: { characters in
            // Oman's VAT number: OM, ten characters; its check digit isn't published.
            guard characters.count == 12, characters[0] == "O", characters[1] == "M" else { return false }
            return numbers(Array(characters[2..<11])) != nil && "0123456789X".contains(characters[11])
        }, draw: { like, rng in
            let head = like.count == 12 ? numbers(Array(like[2..<6])) ?? [1, 1, 0, 0] : [1, 1, 0, 0]
            // Its last character as the tax authority's validator computes it, so a stand-in passes it too.
            return drawnLike(like, &rng) { rng in
                let d = head + randomDigits(5, &rng)
                return Array("OM") + characters(d) + [omanMark(d)]
            }
        }),
        Recognizer("LEI", keys: ["leicode", "leinumber", "legalentityidentifier"], forms: [
            .init(#"\b[0-9A-Z]{18}\d{2}\b"#, 0.3),
        ], context: ["lei", "lei code", "legal entity identifier"], separators: " ", check: { characters in
            // ISO 17442: a issuer's prefix, the entity's characters, two ISO 7064 MOD 97-10 check digits.
            guard characters.count == 20, numbers(Array(characters[18...])) != nil else { return false }
            return leiRemainder(characters) == 1
        }, draw: { like, rng in
            // Its issuer's prefix kept: the registrar's, not the entity's.
            let shaped = like.count == 20 && like.allSatisfy { alnumValue($0) != nil }
            let body = (shaped ? Array(like.prefix(4)) : Array("5493")) + (4..<18).map { index in shaped && like[index].isLetter ? pick(letters, &rng) : pick(digits, &rng) }
            let check = 98 - (leiRemainder(body + ["0", "0"]) ?? 0)
            return body + characters(twoDigits(check))
        }),
        Recognizer("IMSI", keys: ["imsi", "imsinumber", "subscriberimsi", "simimsi"], forms: [
            .init(#"\b[2-7]\d{2} \d{2,3} \d{8,10}\b"#, 0.3),
            .init(#"\b[2-7]\d{13,14}\b"#, 0.05),
        ], context: ["imsi", "international mobile subscriber identity"], verifies: false, separators: " -", check: { characters in
            // A SIM's subscriber identity (ITU-T E.212): a country's mobile code, a network's, the subscriber's own; no check digit.
            guard let d = numbers(characters), (14...15).contains(d.count) else { return false }
            return (2...7).contains(d[0])
        }, draw: { like, rng in
            // Its country kept (the first three digits), the rest drawn: a shape-only kind keeps little of a value it takes by chance.
            let d = numbers(like).flatMap { (14...15).contains($0.count) && (2...7).contains($0[0]) ? $0 : nil } ?? [3, 1, 0] + Array(repeating: 0, count: 12)
            return characters(Array(d.prefix(3)) + randomDigits(d.count - 3, &rng))
        }),
        Recognizer("MEID", keys: ["meid", "meidhex", "meiddec", "meidnumber", "devicemeid"], forms: [
            .init(#"\b[0-9A-F]{2}(?: [0-9A-F]{2}){6}(?: [0-9A-F])?\b"#, 0.3),
            .init(#"\b\d{5} \d{5} \d{4} \d{4}(?: \d)?\b"#, 0.3),
            .init(#"\b\d{2}-\d{6}-\d{6}(?:-\d)?\b"#, 0.3),
            .init(#"\b[0-9A-F]{14,15}\b"#, 0.05),
            .init(#"\b\d{18,19}\b"#, 0.05),
        ], context: ["meid", "mobile equipment identifier"], verifies: false, separators: " -", check: { characters in
            // A CDMA device's identity (3GPP2 S.R0048): fourteen hex digits, a manufacturer's eight (A0 or above) and a
            // serial's six, or the same as eighteen decimal digits; a check digit after either is optional, so the
            // kind is known by its shape. Fourteen or fifteen decimal digits are an IMEI written in an MEID's place.
            switch characters.count {
            case 14, 15:
                let values = characters.compactMap { hexValue($0) }
                guard values.count == characters.count else { return false }
                if values.allSatisfy({ $0 < 10 }) { return characters.count == 14 || Patterns.luhn(values) }
                return values[0] >= 10 && (characters.count == 14 || hexLuhn(values))
            case 18, 19:
                guard let d = numbers(characters), number(Array(d[0..<10])) <= 0xFFFF_FFFF, number(Array(d[10..<18])) <= 0xFF_FFFF else { return false }
                return characters.count == 18 || Patterns.luhn(d)
            default: return false
            }
        }, draw: { like, rng in
            // Its region code kept (an MEID's A0 to FF), the rest drawn; its check digit computed where it had one.
            let values = like.compactMap { hexValue($0) }
            guard values.count == like.count else { return Array("A1000000") + characters(randomDigits(6, &rng)) }
            switch like.count {
            case 14, 15:
                let decimal = values.allSatisfy { $0 < 10 }
                return drawnLike(like, &rng) { rng in
                    let body = Array(like.prefix(2)) + (2..<14).map { index in like[index].isLetter ? pick("ABCDEF", &rng) : pick(digits, &rng) }
                    guard like.count == 15 else { return body }
                    let numbers = body.compactMap { hexValue($0) }
                    let mark = decimal ? luhnDigit(numbers) : (0..<16).first { hexLuhn(numbers + [$0]) } ?? 0
                    return body + [Array("0123456789ABCDEF")[mark]]
                }
            case 18, 19:
                // A manufacturer code below 2^32 led by the original's digit, a serial below 2^24.
                let lead = min(values[0], 4)
                var maker = lead * 1_000_000_000 + Int.random(in: 0...999_999_999, using: &rng)
                while maker > 0xFFFF_FFFF { maker = lead * 1_000_000_000 + Int.random(in: 0...999_999_999, using: &rng) }
                let serial = Int.random(in: 0...0xFF_FFFF, using: &rng)
                let body = [1_000_000_000, 100_000_000, 10_000_000, 1_000_000, 100_000, 10_000, 1000, 100, 10, 1].map { maker / $0 % 10 } + [10_000_000, 1_000_000, 100_000, 10_000, 1000, 100, 10, 1].map { serial / $0 % 10 }
                return characters(like.count == 19 ? body + [luhnDigit(body)] : body)
            default:
                return Array("A1000000") + characters(randomDigits(6, &rng))
            }
        }),
        Recognizer("IMEI", keys: ["imei", "imeinumber", "imei1", "imei2", "deviceimei"], forms: [
            .init(#"\b\d{2}-\d{6}-\d{6}-\d\b"#, 0.3),
            .init(#"\b\d{2} \d{6} \d{6} \d\b"#, 0.3),
            .init(#"\b\d{8} \d{6} \d\b"#, 0.3),
            .init(#"\b\d{6}-\d{2}-\d{6}-\d\b"#, 0.3),
            .init(#"\b\d{15}\b"#, 0.05),
        ], context: ["imei", "international mobile equipment identity"], separators: " -/", check: { characters in
            // A phone's identity (3GPP TS 23.003): a type allocation code, a serial, a Luhn digit.
            guard let d = numbers(characters), d.count == 15, d.contains(where: { $0 != 0 }) else { return false }
            return Patterns.luhn(d)
        }, draw: { like, rng in
            // Its reporting body kept (the first two digits), the rest drawn.
            let lead = numbers(like).flatMap { $0.count == 15 ? Array($0.prefix(2)) : nil } ?? [3, 5]
            let body = lead + randomDigits(12, &rng)
            return characters(body + [luhnDigit(body)])
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
        // A weak kind after every other it passes, unless it is the one named.
        let passing = candidates(original).filter { drawn.contains($0.entity) }
        var kinds = passing.filter { !$0.weak || $0.name == preferred?.name } + passing.filter { $0.weak && $0.name != preferred?.name }
        // A short one ("7108-0") is no kind's alone, but is the one its words name where it is written as that kind.
        if let preferred, !kinds.contains(where: { $0.name == preferred.name }), drawn.contains(preferred.entity),
           case let trimmed = original.trimmingCharacters(in: .whitespaces), preferred.writes(trimmed), preferred.passes(trimmed) { kinds.insert(preferred, at: 0) }
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
    /// Only a kind the words name scores 1 at the text's start (no word stands before it), so only those
    /// kinds are read, as `find` reads them, and the first whose match is the whole value names it.
    static func named(_ value: String, by words: Set<String>) -> String? {
        let ns = value as NSString
        let units = Array(value.utf16), whole = NSRange(location: 0, length: ns.length)
        let small = units.contains { (97...122).contains($0) }
        var capitals: (units: [UInt16], text: NSString)?
        let kinds = named(among: words)
        for (index, recognizer) in all.enumerated() where kinds[index] {
            for form in recognizer.forms {
                guard let regex = form.pattern.regex else { continue }
                if Patterns.matches(regex, in: ns, units: units, isCancelled: { false }).contains(where: { $0.range == whole }), recognizer.passes(value) { return recognizer.entity }
                guard small, recognizer.folds else { continue }
                if capitals == nil {
                    let upperUnits = units.map { (97...122).contains($0) ? $0 - 32 : $0 }
                    capitals = (upperUnits, String(utf16CodeUnits: upperUnits, count: upperUnits.count) as NSString)
                }
                guard let (upperUnits, upper) = capitals, value != upper as String,
                      Patterns.matches(regex, in: upper, units: upperUnits, isCancelled: { false }).contains(where: { $0.range == whole }), recognizer.passes(value) else { continue }
                return recognizer.entity
            }
        }
        return nil
    }

    /// Words that sit between a value and the word naming it without changing what it names ("the", "my", "de");
    /// not "no" or "nr", which a phrase may hold ("pass nr").
    private static let stopwords: Set<String> = ["the", "a", "an", "is", "are", "was", "my", "your", "his", "her", "their", "our", "its", "of", "for", "to", "de", "del", "la", "el", "le", "les", "der", "die", "das", "des", "und", "y", "e", "et", "du", "da", "do", "dos", "di", "il", "van", "het", "och", "og", "i", "l"]
    /// Whether one of `context` is among `words`: a single word as written, several in a row.
    static func names(_ context: Set<String>, in words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        // The text's words split as an entry's are, for a phrase: "l'avis" is l, avis.
        let split = words.allSatisfy { $0.allSatisfy(\.isLetter) } ? words : words.flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) }.filter { !stopwords.contains($0) }
        return context.contains { entry in
            // Split as the text's words are: "v5c" is v, c and "multi-purpose" multi, purpose; the text's
            // stopwords left out of it too ("cédula de residencia" is cédula, residencia).
            let parts = entry.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { !stopwords.contains($0) }
            // One word left of it ("y-tunnus" is tunnus) is read as that word.
            guard parts.count > 1 else { return words.contains { word in mentions(word, entry) || parts.first.map { $0 != entry && mentions(word, $0) } == true } }
            let words = split
            guard parts.count <= words.count else { return false }
            return (0...(words.count - parts.count)).contains { start in zip(words[start..<(start + parts.count)], parts).allSatisfy(mentions) }
        }
    }
    /// Whether any of `words` (unordered, as a key's are) names one of `context`, each word of a phrase by some word.
    static func named(_ context: Set<String>, among words: Set<String>) -> Bool {
        guard !words.isEmpty else { return false }
        return context.contains { entry in (entryParts[entry] ?? parts(entry)).contains { $0.allSatisfy { part in words.contains { mentions($0, part) } } } }
    }
    /// For each kind in `all`, whether one of `words` names it. The same keys' words come with
    /// every record, so each set is read once.
    static func named(among words: Set<String>) -> [Bool] {
        guard !words.isEmpty else { return unnamed }
        if let known = namedAmong.withLock({ $0[words] }) { return known }
        let found = all.map { named($0.context, among: words) }
        namedAmong.withLock { known in
            if known.count >= 4096 { known.removeAll() }
            known[words] = found
        }
        return found
    }
    private static let unnamed = [Bool](repeating: false, count: all.count)
    private static let namedAmong = Mutex<[Set<String>: [Bool]]>([:])
    /// Each kind's entries' first words, by its place in `all`: `find` asks whether the text writes them.
    private static let firstWords: [[String]] = all.map { recognizer in Array(Set(recognizer.context.compactMap { $0.split(whereSeparator: { !$0.isLetter }).first.map(String.init) })) }
    /// Every kind's entries read once: `named` asks for them on every value.
    private static let entryParts: [String: [[String]]] = Dictionary(all.flatMap(\.context).map { ($0, parts($0)) }, uniquingKeysWith: { first, _ in first })
    /// A context entry's words as a key's or a type field's are read: "driver's license" is driver, s, license;
    /// "v5c" is itself as a key writes it, and v5, c as a type field does ("V5C"); stopwords left out, as text's are.
    private static func parts(_ entry: String) -> [[String]] {
        let split = entry.allSatisfy { $0.isLetter || $0 == " " } ? [entry.split(separator: " ").map(String.init)] : [KeyHints.words(entry), KeyHints.words(entry.uppercased())]
        return split.map { $0.filter { !stopwords.contains($0) } }.filter { !$0.isEmpty }
    }
    /// Words a short name ends in when written as one word with it ("cprnummer", "nhsno", "panid").
    private static let numberWords: Set<String> = ["number", "nummer", "numero", "número", "no", "nr", "num", "id", "code", "card", "karte"]
    /// Whether `word` names `part`, as a context word is read inside a
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
        // As many as a kind's longest name holds ("реєстраційний номер облікової картки платника податків"), an elided article apart ("d'identité" is d, identité).
        Array(Context.words(before: range.lowerBound, in: text, limit: 12).flatMap { $0.lowercased().split(whereSeparator: { $0 == "'" || $0 == "’" }).map(String.init) }.filter { !stopwords.contains($0) }.suffix(8))
    }

    /// Identifiers in `text`: one passing its check in a form that needs no
    /// naming word scores 0.85, one named by a word before it or by its key
    /// scores 1, as a validated and context-supported result does, a
    /// bare one keeps its form's score, and one failing its check is none.
    static func find(_ text: String, ns: NSString, units: [UInt16], contextWords: Set<String>, isCancelled: () -> Bool) -> [Span] {
        var spans: [Span] = []
        // The text with its small letters capitalised, offsets unchanged, for kinds written in capitals
        // that someone typed small ("my nie is x9613851n"): read so only where a word names the kind.
        let small = units.contains { (97...122).contains($0) }
        let upperUnits = small ? units.map { (97...122).contains($0) ? $0 - 32 : $0 } : units
        let upper = small ? String(utf16CodeUnits: upperUnits, count: upperUnits.count) as NSString : ns
        // Searched as an NSString: a String's own search is slow over a long text, once per kind's word.
        let lower = (small ? text.lowercased() : "") as NSString
        // Each first word looked for once, whichever kinds share it.
        var held: [String: Bool] = [:]
        func holds(_ word: String) -> Bool {
            if let known = held[word] { return known }
            let found = lower.range(of: word, options: .literal).location != NSNotFound
            held[word] = found
            return found
        }
        let kinds = named(among: contextWords)
        for (index, recognizer) in all.enumerated() {
            if isCancelled() { return spans }
            let keyed = kinds[index]
            let capitalised = small && recognizer.folds && (keyed || firstWords[index].contains(where: holds))
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
    private static let cuitTypes: Set<Int> = [20, 23, 24, 27, 30, 33, 34, 50, 51, 55]
    private static func cuilDigit(_ digits: ArraySlice<Int>) -> Int? {
        let rest = 11 - zip(digits, [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest == 11 ? 0 : rest == 10 ? nil : rest
    }
    private static func rutDigit(_ body: [Int]) -> Character {
        let sum = body.reversed().enumerated().reduce(0) { $0 + $1.element * [2, 3, 4, 5, 6, 7][$1.offset % 6] }
        let rest = 11 - sum % 11
        return rest == 11 ? "0" : rest == 10 ? "K" : Character(String(rest))
    }
    /// RENAPO's inconvenient words, which a CURP's first four letters never spell.
    private static let curpBlocked: Set<String> = ["BACA", "BAKA", "BUEI", "BUEY", "CACA", "CACO", "CAGA", "CAGO", "CAKA", "CAKO", "COGE", "COGI", "COJA", "COJE", "COJI", "COJO", "COLA", "CULO", "FALO", "FETO", "GETA", "GUEI", "GUEY", "JETA", "JOTO", "KACA", "KACO", "KAGA", "KAGO", "KAKA", "KAKO", "KOGE", "KOGI", "KOJA", "KOJE", "KOJI", "KOJO", "KOLA", "KULO", "LILO", "LOCA", "LOCO", "LOKA", "LOKO", "MAME", "MAMO", "MEAR", "MEAS", "MEON", "MIAR", "MION", "MOCO", "MOKO", "MULA", "MULO", "NACA", "NACO", "PEDA", "PEDO", "PENE", "PIPI", "PITO", "POPO", "PUTA", "PUTO", "QULO", "RATA", "ROBA", "ROBE", "ROBO", "RUIN", "SENO", "TETA", "VACA", "VAGA", "VAGO", "VAKA", "VUEI", "VUEY", "WUEI", "WUEY"]
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
    /// Skatteetaten's individual numbers by century: 000–499 born 1900–1999, 500–749 1854–1899, 500–999 2000–2039,
    /// 900–999 1940–1999. A D-number adds 40 to the day, an H-number 40 to the month; nobody is born in the future.
    private static let norwayCenturies: [(numbers: ClosedRange<Int>, years: ClosedRange<Int>)] = [(0...499, 1900...1999), (500...749, 1854...1899), (500...999, 2000...2039), (900...999, 1940...1999)]
    private static func norwayBirth(_ d: [Int]) -> Bool {
        let written = d[0] * 10 + d[1], coded = d[2] * 10 + d[3]
        let day = written > 40 ? written - 40 : written, month = coded > 40 ? coded - 40 : coded
        let individual = number(Array(d[6..<9]))
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        let now = (today.year ?? 2026) * 10_000 + (today.month ?? 1) * 100 + (today.day ?? 1)
        return norwayCenturies.contains { range in
            let year = range.years.lowerBound / 100 * 100 + d[4] * 10 + d[5]
            let full = year < range.years.lowerBound ? year + 100 : year
            return range.numbers.contains(individual) && range.years.contains(full) && realDate(year: full, month: month, day: day) && full * 10_000 + month * 100 + day <= now
        }
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
    /// The two leading check digits (11-99, as the ABR issues them: 10 and 99 both close a sum, and 99 is the one given) for a nine-digit body: 10·c1 + c2 ≡ 10 − Σ (mod 89).
    private static func abnLead(_ body: [Int]) -> Int {
        let rest = zip(body, [3, 5, 7, 9, 11, 13, 15, 17, 19]).reduce(0) { $0 + $1.0 * $1.1 }
        let target = ((10 - rest) % 89 + 89) % 89
        return target <= 10 ? target + 89 : target
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

    private static func eanDigit(_ body: [Int]) -> Int { (10 - body.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) } % 10) % 10 }
    private static func isikukoodDigit(_ body: [Int]) -> Int {
        let first = body.enumerated().reduce(0) { $0 + ($1.offset % 9 + 1) * $1.element } % 11
        guard first == 10 else { return first }
        return body.enumerated().reduce(0) { $0 + (($1.offset + 2) % 9 + 1) * $1.element } % 11 % 10
    }
    private static func ppsLetter(_ digits: [Int], _ second: Character?) -> Character {
        let alphabet = Array("WABCDEFGHIJKLMNOPQRSTUV")
        let weight = second.flatMap { alphabet.firstIndex(of: $0) } ?? 0
        return alphabet[(zip(digits, (2...8).reversed()).reduce(0) { $0 + $1.0 * $1.1 } + 9 * weight) % 23]
    }
    private static func cnpDigit(_ body: [Int]) -> Int {
        let check = zip(body, [2, 7, 9, 1, 4, 6, 3, 5, 8, 2, 7, 9]).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return check == 10 ? 1 : check
    }
    private static func emsoDigit(_ body: [Int]) -> Int { (11 - zip(body, [7, 6, 5, 4, 3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 11 % 10 }
    private static func svnrDigit(_ d: [Int]) -> Int { zip(d, [3, 7, 9, 0, 5, 8, 4, 2, 1, 6]).reduce(0) { $0 + $1.0 * $1.1 } % 11 }
    private static func ccDigit(_ body: [Character]) -> Int {
        let sum = body.reversed().enumerated().reduce(0) { total, item in
            let value = alnumValue(item.element) ?? 0
            return total + (item.offset % 2 == 0 ? (value * 2 > 9 ? value * 2 - 9 : value * 2) : value)
        }
        return (10 - sum % 10) % 10
    }
    private static func latvianDigit(_ body: [Int]) -> Int { (1 + zip(body, [10, 5, 8, 4, 2, 1, 6, 3, 7, 9]).reduce(0) { $0 + $1.0 * $1.1 }) % 11 % 10 }
    private static func ecuadorSum(_ d: [Int]) -> Int {
        d.enumerated().reduce(0) { total, item in let value = (item.offset % 2 == 0 ? 2 : 1) * item.element; return total + (value > 9 ? value - 9 : value) } % 10
    }
    private static func mauritiusMark(_ body: [Character]) -> Character {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let sum = body.enumerated().reduce(0) { $0 + (14 - $1.offset) * (alnumValue($1.element) ?? 0) }
        return alphabet[((17 - sum) % 17 + 17) % 17]
    }
    private static func bcDigit(_ body: [Int]) -> Int? {
        let check = (11 - zip([2, 4, 8, 5, 10, 9, 7, 3], body).reduce(0) { $0 + $1.0 * $1.1 % 11 } % 11) % 11
        return check < 10 ? check : nil
    }
    private static func peruMarks(_ d: [Int]) -> [Character] {
        let c = zip([3, 2, 7, 6, 5, 4, 3, 2], d).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return [Array("65432110987")[c], Array("KJIHGFEDCBA")[c]]
    }
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

    // MARK: Registers

    /// DIAN's NIT check: the body's digits from the right weighed 3, 7, 13 … 71, the sum mod 11, 0 and 1 kept, else 11 less it.
    private static func coNitDigit(_ body: [Int]) -> Int {
        let rest = zip(body.reversed(), [3, 7, 13, 17, 19, 23, 29, 37, 41, 43, 47, 53, 59, 67, 71]).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest <= 1 ? rest : 11 - rest
    }
    /// SENIAT's RIF check: the type worth 4, 8, 12, 16 or 20, the digits weighed 3, 2, 7, 6, 5, 4, 3, 2, 11 less the sum mod 11 (10 and 11 written 0).
    private static func rifDigit(_ type: Character, _ body: [Int]) -> Int? {
        guard let start = ["V": 4, "E": 8, "J": 12, "P": 16, "G": 20][type], body.count == 8 else { return nil }
        let rest = (start + zip(body, [3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 }) % 11
        return rest <= 1 ? 0 : 11 - rest
    }
    /// SRI's RUC: a person's is their cédula (Ecuador's mod 10) and an establishment; the state's a mod 11 over nine digits and four more;
    /// a company's a mod 11 over ten and three more. An establishment is never all zeros.
    private static func ecRucValid(_ d: [Int]) -> Bool {
        guard d.count == 13 else { return false }
        let province = d[0] * 10 + d[1]
        guard (1...24).contains(province) || province == 30 || province == 50 else { return false }
        let person = ecuadorSum(Array(d.prefix(10))) == 0 && d.suffix(3).contains { $0 != 0 }
        let stateWeights: [Int] = [3, 2, 7, 6, 5, 4, 3, 2, 1], companyWeights: [Int] = [4, 3, 2, 7, 6, 5, 4, 3, 2, 1]
        let state = zip(d, stateWeights).reduce(0) { $0 + $1.0 * $1.1 } % 11 == 0 && d.suffix(4).contains { $0 != 0 }
        let company = zip(d, companyWeights).reduce(0) { $0 + $1.0 * $1.1 } % 11 == 0 && d.suffix(3).contains { $0 != 0 }
        // Numbers in use also carry a 6 on a person's cédula, and a 9 on a number checked as the state's.
        switch d[2] {
        case 0...5: return person
        case 6: return state || person
        case 9: return company || state
        default: return false
        }
    }
    /// SAT Guatemala's NIT check: the body's digits from the right weighed 2, 3, 4 …, the sum's distance to the next multiple of 11, 10 written K.
    private static func gtNitMark(_ body: [Int]) -> Character {
        let sum = body.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset + 2) }
        let mark = (11 - sum % 11) % 11
        return mark == 10 ? "K" : Character(String(mark))
    }
    /// A CNPJ character's value in its check: its code less 48 (a digit itself, A 17 … Z 42).
    private static func cnpjValue(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue, (48...57).contains(ascii) || (65...90).contains(ascii) else { return nil }
        return Int(ascii) - 48
    }
    /// Receita Federal's CNPJ check: weights 2 to 9 from the right, repeating; under 2 is 0, else 11 less the sum mod 11.
    private static func cnpjDigit(_ values: [Int]) -> Int? {
        guard values.count == 12 || values.count == 13 else { return nil }
        let rest = values.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 8 + 2) } % 11
        return rest < 2 ? 0 : 11 - rest
    }
    /// The Registro Nacional's classes of cédula jurídica and the types each holds.
    private static let crCpjTypes: [Int: Set<Int>] = [2: [100, 200, 300, 400], 3: Set(2...14).union(101...110), 4: [0], 5: [1]]
    /// DGI's RUT check: weights 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2, the sum's distance to the next multiple of 11; 10 is never issued.
    private static func uyRutDigit(_ body: [Int]) -> Int? {
        guard body.count == 11 else { return nil }
        let mark = (11 - zip(body, [4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 11
        return mark == 10 ? nil : mark
    }
    /// The NIT's check: a sequence up to 100 weighs its digits 14 down to 2 and keeps the sum mod 11; a later one weighs them
    /// 2, 7, 6, 5, 4, 3, 2 repeating and takes the sum's distance to the next multiple of 11; 10 written 0 in both.
    private static func svNitDigit(_ body: [Int]) -> Int {
        guard body.count == 13 else { return 0 }
        if number(Array(body[10..<13])) <= 100 {
            return zip(body, (2...14).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10
        }
        return (11 - zip(body, [2, 7, 6, 5, 4, 3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 11 % 10
    }
    /// `value`'s last `count` digits, zeros before.
    private static func digitsOf(_ value: Int, _ count: Int) -> [Int] {
        (0..<count).reversed().map { value / Int(pow(10, Double($0))) % 10 }
    }
    /// SET's RUC check (base 11): the body's digits from the right weighed 2, 3, 4 …, 11 less the sum mod 11, 10 and 11 written 0.
    private static func pyRucDigit(_ body: [Int]) -> Int {
        (11 - body.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset + 2) } % 11) % 11 % 10
    }
    /// DGII's RNC check: weights 7, 9, 8, 6, 5, 4, 3, 2; a rest of 0 gives 2, 1 gives 1, else 11 less it.
    private static func rncDigit(_ body: [Int]) -> Int {
        let rest = zip(body, [7, 9, 8, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest == 0 ? 2 : rest == 1 ? 1 : 11 - rest
    }
    /// BCRA's CBU check over a block: from its last digit back, weights 3, 1, 7, 9 repeating, the sum's distance to the next ten.
    private static func cbuDigit(_ block: [Int]) -> Int {
        (10 - block.reversed().enumerated().reduce(0) { $0 + $1.element * [3, 1, 7, 9][$1.offset % 4] } % 10) % 10
    }
    /// The CRA's program identifiers on a business number's program account.
    private static let caPrograms: Set<String> = ["RC", "RM", "RP", "RT", "RR", "RZ"]
    /// SUNAT's RUC check: weights 5, 4, 3, 2, 7, 6, 5, 4, 3, 2, 11 less the sum mod 11, its last digit.
    private static func peRucDigit(_ body: [Int]) -> Int {
        (11 - zip(body, [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 10
    }

    private static let rfcLetters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ&Ñ")
    /// The homoclave's first two characters as SAT assigns them.
    private static let rfcFirstMarks = "123456789ABCDEFGHIJKLMNPQRSTUV"
    private static let rfcSecondMarks = "123456789ABCDEFGHIJKLMNPQRSTUVWXYZ"
    /// Words SAT never lets a person's four letters spell (its last letter is changed to X instead).
    private static let rfcBlocked: Set<String> = ["BUEI", "BUEY", "CACA", "CACO", "CAGA", "CAGO", "CAKA", "CAKO", "COGE", "COJA", "COJE", "COJI", "COJO", "CULO", "FETO", "GUEY", "JOTO", "KACA", "KACO", "KAGA", "KAGO", "KAKA", "KOGE", "KOJO", "KULO", "MAME", "MAMO", "MEAR", "MEAS", "MEON", "MION", "MOCO", "MULA", "PEDA", "PEDO", "PENE", "PUTA", "PUTO", "QULO", "RATA", "RUIN"]
    /// A person's RFC (13, or 10 before its homoclave) or a company's (12): letters, a real date (YYMMDD), a homoclave,
    /// and a check character of SAT's (a digit or A); whether it is the one SAT's check gives is left open, as some issued aren't.
    private static func rfcValid(_ c: [Character]) -> Bool {
        guard [10, 12, 13].contains(c.count) else { return false }
        let name = c.count == 12 ? 3 : 4
        guard c.prefix(name).allSatisfy({ rfcLetters.contains($0) }), name == 3 || !rfcBlocked.contains(String(c.prefix(4))), let d = numbers(Array(c[name..<(name + 6)])),
              realDate(year: 2000 + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5]) else { return false }
        return c.count == 10 || c.suffix(3).allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) }) && c.last.map { $0.isNumber || $0 == "A" } == true
    }
    /// A fresh RFC of the original's kind (12 a company's, else a person's, 10 without its homoclave), its homoclave's letters and digits
    /// where the original's were, and the check character SAT's check gives.
    private static func rfcDraw(_ like: [Character], _ rng: inout any RandomNumberGenerator) -> [Character] {
        if like.count == 10 { return Array(rfcDraw(Array(like) + Array("000"), &rng).prefix(10)) }
        let company = like.count == 12
        let name = company ? 3 : 4
        let home = Array(like.dropFirst(name + 6))
        var made: [Character] = []
        for _ in 0..<64 {
            var c: [Character] = company ? (0..<3).map { _ in pick(letters, &rng) } : [pick(consonants, &rng), pick("AEIOU", &rng), pick(letters, &rng), pick(letters, &rng)]
            if rfcBlocked.contains(String(c)) { c[3] = "X" }
            let date = company ? (year: Int.random(in: 1960...2019, using: &rng), month: Int.random(in: 1...12, using: &rng), day: Int.random(in: 1...28, using: &rng)) : randomDate(&rng)
            c += characters(twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day))
            for (index, pool) in [Array(rfcFirstMarks), Array(rfcSecondMarks)].enumerated() {
                let options = index < home.count ? pool.filter { $0.isNumber == home[index].isNumber } : pool
                c.append(options.randomElement(using: &rng) ?? "1")
            }
            made = c + [rfcDigit(ArraySlice(Array(repeating: " ", count: 12 - c.count) + c))]
            if home.count < 3 || made.last?.isNumber == home[2].isNumber { break }
        }
        return made
    }

    /// Austria's company register check letter: six digits weighed 6, 4, 14, 15, 10, 1, the sum mod 17 read off this alphabet.
    private static func firmenbuchLetter(_ digits: [Int]) -> Character {
        let padded = Array(repeating: 0, count: max(0, 6 - digits.count)) + digits.suffix(6)
        return Array("ABDFGHIKMPSTVWXYZ")[zip(padded, [6, 4, 14, 15, 10, 1]).reduce(0) { $0 + $1.0 * $1.1 } % 17]
    }
    /// Austria's tax offices (Finanzamtsnummern) that open an Abgabenkontonummer.
    private static let atTaxOffices: Set<Int> = [3, 4, 6, 7, 8, 9, 10, 12, 15, 16, 18, 22, 23, 29, 33, 38, 41, 46, 51, 52, 53, 54, 57, 59, 61, 65, 67, 68, 69, 71, 72, 81, 82, 83, 84, 90, 91, 93, 97, 98]
    /// Letters on a Dutch travel document: any but O.
    private static let dutchDocumentLetters = "ABCDEFGHIJKLMNPQRSTUVWXYZ"
    /// A UTR's first digit: the nine after it weighed 6, 7, 8, 9, 10, 5, 4, 3, 2, mod 11, read off 2, 1, 9 … 1.
    private static func utrDigit(_ body: [Int]) -> Int {
        [2, 1, 9, 8, 7, 6, 5, 4, 3, 2, 1][zip(body, [6, 7, 8, 9, 10, 5, 4, 3, 2]).reduce(0) { $0 + $1.0 * $1.1 } % 11]
    }
    /// The UPN's alphabet: letters less I, O and S, then digits.
    private static let upnAlphabet = Array("ABCDEFGHJKLMNPQRTUVWXYZ0123456789")
    /// A UPN's check letter over its last twelve characters, weighed 2 to 13, mod 23.
    private static func upnLetter(_ body: [Character]) -> Character? {
        guard body.count == 12 else { return nil }
        var sum = 0
        for (offset, character) in body.enumerated() {
            guard let value = upnAlphabet.firstIndex(of: character) else { return nil }
            sum += (offset + 2) * value
        }
        return upnAlphabet[sum % 23]
    }
    /// England's local authority numbers that open a UPN (DfE's list of LA codes).
    private static let upnAuthorities: Set<Int> = [201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320, 330, 331, 332, 333, 334, 335, 336, 340, 341, 342, 343, 344, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 370, 371, 372, 373, 380, 381, 382, 383, 384, 390, 391, 392, 393, 394, 420, 800, 801, 802, 803, 805, 806, 807, 808, 810, 811, 812, 813, 815, 816, 821, 822, 823, 825, 826, 830, 831, 835, 836, 837, 840, 841, 845, 846, 850, 851, 852, 855, 856, 857, 860, 861, 865, 866, 867, 868, 869, 870, 871, 872, 873, 874, 876, 877, 878, 879, 880, 881, 882, 883, 884, 885, 886, 887, 888, 889, 890, 891, 892, 893, 894, 895, 896, 908, 909, 916, 919, 921, 925, 926, 928, 929, 931, 933, 935, 936, 937, 938]
    /// A Belgian card number's last two digits: its first ten mod 97, 97 for a remainder of 0.
    private static func eidCheck(_ body: [Int]) -> Int {
        let rest = number(body) % 97
        return rest == 0 ? 97 : rest
    }
    /// The Czech National Bank's weights over an account's part, right-aligned to ten.
    private static func czWeighted(_ digits: [Int]) -> Int {
        let padded = Array(repeating: 0, count: max(0, 10 - digits.count)) + digits.suffix(10)
        return zip(padded, [6, 3, 7, 9, 10, 5, 8, 4, 2, 1]).reduce(0) { $0 + $1.0 * $1.1 }
    }
    /// A Czech account's prefix (up to six digits before "-"), number (2 to 10) and bank (four after "/").
    private static func czAccountParts(_ c: [Character]) -> (prefix: [Character]?, root: [Character], bank: [Character])? {
        guard c.count >= 7, c[c.count - 5] == "/", c.filter({ $0 == "/" }).count == 1 else { return nil }
        let bank = Array(c.suffix(4)), head = Array(c.dropLast(5))
        let pieces = head.split(separator: "-", omittingEmptySubsequences: false).map(Array.init)
        switch pieces.count {
        case 1: return (2...10).contains(head.count) ? (nil, head, bank) : nil
        case 2: return (1...6).contains(pieces[0].count) && (2...10).contains(pieces[1].count) ? (pieces[0], pieces[1], bank) : nil
        default: return nil
        }
    }
    /// The Czech National Bank's payment-system bank codes.
    private static let czBanks: Set<Int> = [100, 300, 600, 710, 800, 2010, 2060, 2070, 2100, 2200, 2220, 2250, 2260, 2600, 2700, 3030, 3060, 3500, 4300, 5500, 5800, 6000, 6200, 6210, 6300, 6363, 6700, 6800, 7910, 7950, 7960, 7970, 7990, 8030, 8040, 8060, 8090, 8150, 8190, 8198, 8220, 8250, 8255, 8265, 8500, 8610, 8660]
    /// Every reading of a New Zealand account's digits as bank (2), branch (4), base (7) and suffix (3):
    /// 15 digits have a two-digit suffix; 14 a three-digit branch, or a one-digit suffix.
    private static func nzAccountLayouts(_ d: [Int]) -> [[Int]] {
        switch d.count {
        case 16: return [d]
        case 15: return [Array(d[0..<13]) + [0] + Array(d[13...])]
        case 14: return [Array(d[0..<2]) + [0] + Array(d[2..<12]) + [0] + Array(d[12...]), Array(d[0..<13]) + [0, 0] + [d[13]]]
        default: return []
        }
    }
    /// Inland Revenue's bank algorithms: each bank's, A turned B for a base from 0990000.
    private static let nzAlgorithms: [Int: Character] = [1: "A", 2: "A", 3: "A", 4: "A", 6: "A", 8: "D", 9: "E", 10: "A", 11: "A", 12: "A", 13: "A", 14: "A", 15: "A", 16: "A", 17: "A", 18: "A", 19: "A", 20: "A", 21: "A", 22: "A", 23: "A", 24: "A", 25: "F", 26: "G", 27: "A", 28: "G", 29: "G", 30: "A", 31: "X", 33: "F", 35: "A", 38: "A"]
    /// Whether 16 digits pass their bank's algorithm. For E and G a product's digits are added, and again
    /// (18 is 9); `strict` also turns away a product that is a multiple of 9 above 9, read 0 by another common reading.
    private static func nzAccountValid(_ d: [Int], strict: Bool) -> Bool {
        guard d.count == 16, var algorithm = nzAlgorithms[d[0] * 10 + d[1]] else { return false }
        if algorithm == "A", number(Array(d[6..<13])) >= 990_000 { algorithm = "B" }
        let weights: [Int], modulus: Int
        switch algorithm {
        case "A": (weights, modulus) = ([0, 0, 6, 3, 7, 9, 0, 10, 5, 8, 4, 2, 1, 0, 0, 0], 11)
        case "B": (weights, modulus) = ([0, 0, 0, 0, 0, 0, 0, 10, 5, 8, 4, 2, 1, 0, 0, 0], 11)
        case "D": (weights, modulus) = ([0, 0, 0, 0, 0, 0, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0], 11)
        case "E": (weights, modulus) = ([0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 4, 3, 2, 0, 0, 1], 11)
        case "F": (weights, modulus) = ([0, 0, 0, 0, 0, 0, 1, 7, 3, 1, 7, 3, 1, 0, 0, 0], 10)
        case "G": (weights, modulus) = ([0, 0, 0, 0, 0, 0, 1, 3, 7, 1, 3, 7, 1, 3, 7, 1], 10)
        default: return true
        }
        var sum = 0
        for (digit, weight) in zip(d, weights) {
            var product = digit * weight
            if algorithm == "E" || algorithm == "G" {
                if strict, product > 9, product % 9 == 0 { return false }
                product = crossSum(product)
                product = crossSum(product)
            }
            sum += product
        }
        return sum % modulus == 0
    }
    /// An IRD number's check over its body padded to eight: weights 3, 2, 7, 6, 5, 4, 3, 2, then 7, 4, 3, 2, 5, 2, 7, 6 where the first gives 10.
    private static func irdDigit(_ body: [Int]) -> Int? {
        guard body.count <= 8 else { return nil }
        let padded = Array(repeating: 0, count: 8 - body.count) + body
        for weights in [[3, 2, 7, 6, 5, 4, 3, 2], [7, 4, 3, 2, 5, 2, 7, 6]] {
            let rest = (11 - zip(padded, weights).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 11
            if rest != 10 { return rest }
        }
        return nil
    }
    /// The courts keeping a Handelsregister (handelsregister.de's Registergerichte), then names they are written by.
    private static let registerCourts: [String] = ["Aachen", "Altenburg", "Amberg", "Ansbach", "Apolda", "Arnsberg", "Arnstadt Zweigstelle Ilmenau", "Arnstadt", "Aschaffenburg", "Augsburg", "Aurich", "Bad Hersfeld", "Bad Homburg v.d.H.", "Bad Kreuznach", "Bad Oeynhausen", "Bad Salzungen", "Bamberg", "Bayreuth", "Berlin (Charlottenburg)", "Bielefeld", "Bochum", "Bonn", "Braunschweig", "Bremen", "Chemnitz", "Coburg", "Coesfeld", "Cottbus", "Darmstadt", "Deggendorf", "Dortmund", "Dresden", "Duisburg", "Düren", "Düsseldorf", "Eisenach", "Erfurt", "Eschwege", "Essen", "Flensburg", "Frankfurt am Main", "Frankfurt/Oder", "Freiburg", "Friedberg", "Fritzlar", "Fulda", "Fürth", "Gelsenkirchen", "Gera", "Gießen", "Gotha", "Greiz", "Göttingen", "Gütersloh", "Hagen", "Hamburg", "Hamm", "Hanau", "Hannover", "Heilbad Heiligenstadt", "Hildburghausen", "Hildesheim", "Hof", "Homburg", "Ingolstadt", "Iserlohn", "Jena", "Kaiserslautern", "Kassel", "Kempten (Allgäu)", "Kiel", "Kleve", "Koblenz", "Korbach", "Krefeld", "Köln", "Königstein", "Landau", "Landshut", "Langenfeld", "Lebach", "Leipzig", "Lemgo", "Limburg", "Ludwigshafen a.Rhein (Ludwigshafen)", "Lübeck", "Lüneburg", "Mainz", "Mannheim", "Marburg", "Meiningen", "Memmingen", "Merzig", "Montabaur", "Mönchengladbach", "Mühlhausen", "München", "Münster", "Neubrandenburg", "Neunkirchen", "Neuruppin", "Neuss", "Nordhausen", "Nürnberg", "Offenbach am Main", "Oldenburg (Oldenburg)", "Osnabrück", "Ottweiler", "Paderborn", "Passau", "Pinneberg", "Potsdam", "Pößneck Zweigstelle Bad Lobenstein", "Pößneck", "Recklinghausen", "Regensburg", "Rostock", "Rudolstadt Zweigstelle Saalfeld", "Rudolstadt", "Saarbrücken", "Saarlouis", "Schweinfurt", "Schwerin", "Siegburg", "Siegen", "Sondershausen", "Sonneberg", "St. Ingbert (St Ingbert)", "St. Wendel (St Wendel)", "Stadthagen", "Stadtroda", "Steinfurt", "Stendal", "Stralsund", "Straubing", "Stuttgart", "Suhl", "Sömmerda", "Tostedt", "Traunstein", "Ulm", "Völklingen", "Walsrode", "Weiden i. d. OPf.", "Weimar", "Wetzlar", "Wiesbaden", "Wittlich", "Wuppertal", "Würzburg", "Zweibrücken"]
    private static let registerCourtAliases: [String] = ["Berlin", "Charlottenburg", "Charlottenburg (Berlin)", "Bad Homburg", "Kempten", "Allgäu", "Ludwigshafen", "Ludwigshafen am Rhein", "Ludwigshafen am Rhein (Ludwigshafen)", "Oldenburg", "St. Ingbert", "St. Wendel", "Weiden", "Weiden in der Oberpfalz", "Paderborn früher Höxter"]
    /// A court's name as compared: mis-decoded umlauts mended, accents dropped, capitals, letters only.
    private static func registerCourtKey(_ name: String) -> String {
        let mended = [("Ã¤", "ä"), ("Ã¶", "ö"), ("Ã¼", "ü"), ("ÃŸ", "ß"), ("Ã„", "Ä"), ("Ã–", "Ö"), ("Ãœ", "Ü")].reduce(name) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        return String(mended.folding(options: .diacriticInsensitive, locale: nil).uppercased().filter { $0.isASCII && $0.isLetter })
    }
    private static let registerCourtKeys = Set((registerCourts + registerCourtAliases).map(registerCourtKey))
    /// Whether `name` is a court's, its umlauts written as one letter or as two ("Koeln").
    private static func isRegisterCourt(_ name: [Character]) -> Bool {
        let key = registerCourtKey(String(name))
        guard !key.isEmpty else { return false }
        if registerCourtKeys.contains(key) { return true }
        let plain = [("AE", "A"), ("OE", "O"), ("UE", "U")].reduce(key) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        return registerCourtKeys.contains(plain)
    }
    /// Every court's name as a pattern: any spaces between its words, its umlauts written either way, longest first.
    private static let registerCourtPattern: String = (registerCourts + registerCourtAliases).sorted { $0.count > $1.count }.map { name in
        name.map { character -> String in
            switch character {
            case " ": return " {1,3}"
            case "ä": return "(?:ä|ae|a|Ã¤)"
            case "ö": return "(?:ö|oe|o|Ã¶)"
            case "ü": return "(?:ü|ue|u|Ã¼)"
            case "ß": return "(?:ß|ss)"
            case ".", "(", ")", "/": return "\\" + String(character)
            default: return String(character)
            }
        }.joined()
    }.joined(separator: "|")
    private static let registerKinds: [[Character]] = ["HRA", "HRB", "GNR", "PR", "VR"].map(Array.init)
    private static func startsWithKind(_ c: ArraySlice<Character>) -> Int? {
        let upper = c.prefix(3).map { Character($0.uppercased()) }
        return registerKinds.first { upper.starts(with: $0) }?.count
    }
    /// A register entry's court, number and whether letters follow the number: "Aachen HRB 1234", "HRB 1234 B, Charlottenburg", or "HRB 1234" alone.
    private static func registerParts(_ c: [Character]) -> (court: Range<Int>?, number: Range<Int>, qualified: Bool)? {
        func isQualifier(_ s: ArraySlice<Character>) -> Bool { (0...3).contains(s.count) && s.allSatisfy { ("A"..."Z").contains($0) || $0 == "Ö" } }
        func digitsRun(from start: Int) -> Int {
            var end = start
            while end < c.count, c[end].isASCII, c[end].isNumber { end += 1 }
            return end
        }
        // The register first.
        if let kind = startsWithKind(c[...]) {
            let end = digitsRun(from: kind)
            if (1...6).contains(end - kind), c[kind] != "0" {
                let rest = c[end...]
                if rest.isEmpty { return kind == 3 && c[2].uppercased() != "R" && "AB".contains(c[2].uppercased()) ? (nil, kind..<end, false) : nil }
                for split in 0...min(3, rest.count - 1) where isQualifier(rest.prefix(split)) && isRegisterCourt(Array(rest.dropFirst(split))) {
                    return (end + split..<c.count, kind..<end, split > 0)
                }
            }
        }
        // The court first.
        for letters in 0...min(3, c.count) {
            let qualifier = c.suffix(letters)
            guard isQualifier(qualifier) else { continue }
            let end = c.count - letters
            var start = end
            while start > 0, c[start - 1].isASCII, c[start - 1].isNumber { start -= 1 }
            guard (1...6).contains(end - start), c[start] != "0" else { continue }
            for kind in registerKinds where start >= kind.count + 1 {
                let found = c[(start - kind.count)..<start].map { Character($0.uppercased()) }
                guard found == kind, isRegisterCourt(Array(c[0..<(start - kind.count)])) else { continue }
                return (0..<(start - kind.count), start..<end, letters > 0)
            }
        }
        return nil
    }
    /// Another court of one word, written as long and in the same case, for one of one word.
    private static func registerCourtSwap(_ court: [Character], _ rng: inout any RandomNumberGenerator) -> [Character]? {
        guard court.allSatisfy(\.isLetter), registerCourts.contains(where: { registerCourtKey($0) == registerCourtKey(String(court)) && !$0.contains(" ") }) else { return nil }
        let capitals = court.allSatisfy(\.isUppercase), titled = court.first?.isUppercase == true && court.dropFirst().allSatisfy(\.isLowercase)
        guard capitals || titled else { return nil }
        let pool = registerCourts.filter { $0.count == court.count && $0.allSatisfy(\.isLetter) && !$0.contains("ß") && registerCourtKey($0) != registerCourtKey(String(court)) }
        guard let name = pool.randomElement(using: &rng) else { return nil }
        return Array(capitals ? name.uppercased() : name)
    }

    /// A weighted sum of digits, as far as the shorter of the two runs.
    private static func eastWeighted(_ digits: [Int], _ weights: [Int]) -> Int { zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func eastPower(_ exponent: Int) -> Int { (0..<max(0, exponent)).reduce(1) { value, _ in value * 10 } }
    /// Bulgaria's UIC: weights 1 … 8 mod 11, or 3 … 10 where that leaves 10.
    private static func bgLegalDigit(_ body: [Int]) -> Int {
        let first = eastWeighted(body, [1, 2, 3, 4, 5, 6, 7, 8]) % 11
        return (first == 10 ? eastWeighted(body, [3, 4, 5, 6, 7, 8, 9, 10]) % 11 : first) % 10
    }
    /// Bulgaria's EGN: a birth date whose month carries its century (20 more the 1800s, 40 more the 2000s), weights 2 … 6 mod 11.
    private static func bgPersonValid(_ d: [Int]) -> Bool {
        guard d.count == 10 else { return false }
        let coded = d[2] * 10 + d[3]
        let (century, month) = coded > 40 ? (2000, coded - 40) : coded > 20 ? (1800, coded - 20) : (1900, coded)
        guard realDate(year: century + d[0] * 10 + d[1], month: month, day: d[4] * 10 + d[5]) else { return false }
        return eastWeighted(d, [2, 4, 8, 5, 10, 9, 7, 3, 6]) % 11 % 10 == d[9]
    }
    /// Czechia's IČO: eleven less the weighted sum (8 … 2) mod 11; 10 is written 0 and 11 is written 1.
    private static func czIcoDigit(_ body: [Int]) -> Int {
        let rest = (11 - eastWeighted(body, [8, 7, 6, 5, 4, 3, 2]) % 11) % 11
        return rest == 0 ? 1 : rest % 10
    }
    /// Czechia's VAT number for a person with no birth number: the seven digits after the 6, weights 8 … 2, through the tax office's table.
    private static func czSpecialDigit(_ body: [Int]) -> Int {
        let rest = eastWeighted(body, [8, 7, 6, 5, 4, 3, 2]) % 11
        return ((8 - (10 - rest) % 11) % 10 + 10) % 10
    }
    /// A Czech or Slovak birth number: a real date (50 added to a woman's month, 20 to a late one's), nine digits before 1954 and ten after, the ten a multiple of 11 but for a remainder 10 written 0.
    private static func birthNumberValid(_ d: [Int]) -> Bool {
        guard d.count == 9 || d.count == 10 else { return false }
        var year = 1900 + d[0] * 10 + d[1]
        if d.count == 9 {
            if year >= 1980 { year -= 100 }
            guard year <= 1953 else { return false }
        } else if year < 1954 { year += 100 }
        guard realDate(year: year, month: (d[2] * 10 + d[3]) % 50 % 20, day: d[4] * 10 + d[5]) else { return false }
        return d.count == 9 || number(Array(d[0..<9])) % 11 % 10 == d[9]
    }
    /// Romania's CUI: the body right-aligned under 7, 5, 3, 2, 1, 7, 5, 3, 2, ten times the sum mod 11 (10 written 0).
    private static func roCuiDigit(_ body: [Int]) -> Int {
        let padded = Array(repeating: 0, count: max(0, 9 - body.count)) + body.suffix(9)
        return eastWeighted(padded, [7, 5, 3, 2, 1, 7, 5, 3, 2]) * 10 % 11 % 10
    }
    /// Slovenia's tax number: eleven less the weighted sum (8 … 2) mod 11, 10 written 0; 11 is no number.
    private static func siDdvDigit(_ body: [Int]) -> Int? {
        let rest = 11 - eastWeighted(body, [8, 7, 6, 5, 4, 3, 2]) % 11
        return rest == 11 ? nil : rest % 10
    }
    /// Ukraine's EDRPOU: weights 1 … 7, or 7, 1 … 6 for codes from 30000000 to 59999999; each two more where the sum mod 11 is 10.
    private static func uaEdrpouDigit(_ body: [Int]) -> Int {
        guard let lead = body.first else { return 0 }
        let weights = (3...5).contains(lead) ? [7, 1, 2, 3, 4, 5, 6] : [1, 2, 3, 4, 5, 6, 7]
        let first = eastWeighted(body, weights) % 11
        return first < 10 ? first : eastWeighted(body, weights.map { $0 + 2 }) % 11 % 10
    }
    /// Ukraine's RNOKPP: weights −1, 5, 7, 9, 4, 6, 10, 5, 7, the sum mod 11 then mod 10.
    private static func uaRntrcDigit(_ body: [Int]) -> Int {
        (eastWeighted(body, [-1, 5, 7, 9, 4, 6, 10, 5, 7]) % 11 + 11) % 11 % 10
    }
    /// North Macedonia's EDB: weights 7 … 2 twice, the sum's complement mod 11, 10 written 0.
    private static func mkEdbDigit(_ body: [Int]) -> Int {
        (11 - eastWeighted(body, [7, 6, 5, 4, 3, 2, 7, 6, 5, 4, 3, 2]) % 11) % 11 % 10
    }
    /// Slovenia's register number: the weighted sum's (7 … 2) complement mod 11, 10 written 0; a remainder of 0 is no number.
    private static func siMaticnaDigit(_ body: [Int]) -> Int? {
        let rest = (11 - eastWeighted(body, [7, 6, 5, 4, 3, 2]) % 11) % 11
        return rest == 0 ? nil : rest % 10
    }
    /// Turkey's VKN: each digit of the first nine, from the right with place i, as (d + i) mod 10 times 2^i mod 9 (9 for a multiple), summed and complemented.
    private static func vknDigit(_ body: [Int]) -> Int {
        let sum = body.reversed().enumerated().reduce(0) { total, item in
            let place = item.offset + 1
            let shifted = (item.element + place) % 10
            guard shifted != 0 else { return total }
            let doubled = shifted * (1 << place) % 9
            return total + (doubled == 0 ? 9 : doubled)
        }
        return (10 - sum % 10) % 10
    }
    /// Cyrillic letters Belarus writes a payer number with, as the Latin ones they stand for.
    private static let unpLatin: [Character: Character] = ["А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T"]
    /// Belarus's UNP check: the first character's value (a letter 10 on), the second's (a letter its place in A, B, C, E, H, K, M, O, P, T), then six digits, weights 29, 23, 19, 17, 13, 7, 5, 3 mod 11; 10 is no number.
    private static func unpDigit(_ first: Character, _ second: Character, _ digits: [Int]) -> Int? {
        guard digits.count == 6, let lead = alnumValue(first), "1234567ABCEHKM".contains(first) else { return nil }
        let kind: Int
        if let digit = second.wholeNumberValue, second.isASCII {
            guard first.isNumber else { return nil }
            kind = digit
        } else {
            guard first.isLetter, let place = Array("ABCEHKMOPT").firstIndex(of: second) else { return nil }
            kind = place
        }
        let rest = eastWeighted([lead, kind] + digits, [29, 23, 19, 17, 13, 7, 5, 3]) % 11
        return rest < 10 ? rest : nil
    }
    /// Romania's trade register counties: 1 to 40, Bucharest 40 and its sectors 51, 52.
    private static let onrcCounties: Set<Int> = Set(1...40).union([51, 52])
    private typealias OnrcFields = (county: Range<Int>, serial: Range<Int>, date: Int?, year: Range<Int>)
    /// The places an old trade register number's county, serial and year may sit in, separators kept but spaces gone:
    /// "J52/750/2012", "J52/750/22.11.2012", "F261132/2007" (county and serial run together), "F015872023".
    private static func onrcSplits(_ c: [Character]) -> [OnrcFields] {
        guard c.count >= 7, c.count <= 24, let lead = c.first, "JFC".contains(lead) else { return [] }
        let start = c[1] == "/" || c[1] == "-" ? 2 : 1
        var tokens: [Range<Int>] = []
        var begin = start
        for index in start...c.count where index == c.count || c[index] == "/" || c[index] == "-" {
            guard index > begin else { return [] }
            tokens.append(begin..<index)
            begin = index + 1
        }
        guard let last = tokens.last else { return [] }
        let isDigits = { (range: Range<Int>) in c[range].allSatisfy { $0.isASCII && $0.isNumber } }
        var date: Int?
        let year: Range<Int>, head: [Range<Int>]
        if c[last].contains(".") {
            guard last.count == 10, c[last.lowerBound + 2] == ".", c[last.lowerBound + 5] == ".", isDigits(last.lowerBound..<(last.lowerBound + 2)), isDigits((last.lowerBound + 3)..<(last.lowerBound + 5)) else { return [] }
            date = last.lowerBound
            year = (last.upperBound - 4)..<last.upperBound
            head = Array(tokens.dropLast())
        } else if tokens.count > 1 {
            guard last.count == 4 else { return [] }
            year = last
            head = Array(tokens.dropLast())
        } else {
            guard last.count >= 6 else { return [] }
            year = (last.upperBound - 4)..<last.upperBound
            head = [last.lowerBound..<(last.upperBound - 4)]
        }
        guard isDigits(year), head.allSatisfy(isDigits) else { return [] }
        if head.count == 2 { return [(head[0], head[1], date, year)] }
        guard head.count == 1, let run = head.first else { return [] }
        return [1, 2].filter { run.count > $0 }.map { (run.lowerBound..<(run.lowerBound + $0), (run.lowerBound + $0)..<run.upperBound, date, year) }
    }
    private static func onrcValid(_ c: [Character], _ fields: OnrcFields) -> Bool {
        guard fields.year.upperBound <= c.count, let county = numbers(Array(c[fields.county])), let serial = numbers(Array(c[fields.serial])), let year = numbers(Array(c[fields.year])) else { return false }
        guard (1...2).contains(county.count), (1...5).contains(serial.count), onrcCounties.contains(number(county)), (1990...2024).contains(number(year)) else { return false }
        guard let day = fields.date else { return true }
        guard let dd = numbers(Array(c[day..<(day + 2)])), let mm = numbers(Array(c[(day + 3)..<(day + 5)])) else { return false }
        return realDate(year: number(year), month: number(mm), day: number(dd))
    }
    /// The type letter's code mod 10 (J 4, F 0, C 7) and the first twelve digits, summed mod 10.
    private static func onrcNewDigit(_ lead: Character, _ body: [Int]) -> Int { (Int(lead.asciiValue ?? 0) % 10 + body.prefix(12).reduce(0, +)) % 10 }
    /// The format since 26 July 2024: year, six-digit serial, county (00 for those registered after the change), check.
    private static func onrcNewValid(_ lead: Character, _ d: [Int]) -> Bool {
        guard d.count == 13 else { return false }
        let year = number(Array(d[0..<4])), county = d[10] * 10 + d[11]
        guard year >= 1990, year <= Calendar(identifier: .gregorian).component(.year, from: Date()) else { return false }
        guard year < 2024 ? onrcCounties.contains(county) : year == 2024 ? onrcCounties.contains(county) || county == 0 : county == 0 else { return false }
        return onrcNewDigit(lead, d) == d[12]
    }
    private static func onrcPut(_ c: inout [Character], _ range: Range<Int>, _ value: Int) {
        var value = value
        for index in range.reversed() where index < c.count {
            c[index] = Character(String(value % 10))
            value /= 10
        }
    }

    private static func austrianUIDDigit(_ d: [Int]) -> Int {
        let sum = d.enumerated().reduce(0) { $0 + ($1.offset % 2 == 0 ? $1.element : crossSum($1.element * 2)) }
        return (10 - (sum + 4) % 10) % 10
    }
    private static func cyprusLetter(_ d: [Int]) -> Character {
        let odd = [1, 0, 5, 7, 9, 13, 15, 17, 19, 21]
        return Array(letters)[d.enumerated().reduce(0) { $0 + ($1.offset % 2 == 0 ? odd[$1.element] : $1.element) } % 26]
    }
    private static func cifControl(_ d: [Int]) -> Int {
        let sum = d.enumerated().reduce(0) { $0 + ($1.offset % 2 == 0 ? crossSum($1.element * 2) : $1.element) }
        return (10 - sum % 10) % 10
    }
    private static let frenchVATAlphabet = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static func frenchVATValid(_ body: [Character]) -> Bool {
        guard body.count == 11, let d = numbers(Array(body[2...])), let a = frenchVATAlphabet.firstIndex(of: body[0]), let b = frenchVATAlphabet.firstIndex(of: body[1]) else { return false }
        // Monaco's numbers hold "000" where a French SIREN would be, and no Luhn check.
        guard d[0..<3] == [0, 0, 0] || Patterns.luhn(d) else { return false }
        let siren = number(d)
        if a < 10 && b < 10 { return a * 10 + b == (siren * 100 + 12) % 97 }
        // The newer key of letters and digits.
        let key = a < 10 ? a * 24 + b - 10 : a * 34 + b - 100
        return (siren + 1 + key / 11) % 11 == key % 11
    }
    private static func britishVATSum(_ d: [Int]) -> Int { zip(d, [8, 7, 6, 5, 4, 3, 2, 10, 1]).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func greekVATDigit(_ d: [Int]) -> Int { d.enumerated().reduce(0) { $0 + $1.element << (8 - $1.offset) } % 11 % 10 }
    private static func dutchElevens(_ d: [Int]) -> Bool {
        d.count == 9 && (zip(d[0..<8], (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } - d[8]) % 11 == 0
    }
    private static func dutchModern(_ d: [Int], _ branch: [Int]) -> Bool {
        let whole: [Character] = ["N", "L"] + characters(d) + ["B"] + characters(branch)
        return iso7064Mod97(whole) == 1
    }
    private static func portugueseDigit(_ d: [Int]) -> Int {
        let rest = 11 - zip(d, (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest >= 10 ? 0 : rest
    }
    /// ISO 7064 MOD 97-10's remainder over digits and capitals (A is 10, Z 35); nil for any other character.
    private static func iso7064Mod97(_ characters: [Character]) -> Int? {
        var rest = 0
        for character in characters {
            guard let value = alnumValue(character) else { return nil }
            rest = (value >= 10 ? rest * 100 + value : rest * 10 + value) % 97
        }
        return rest
    }
    /// The ISO 3166 numeric codes of the EU's member states, and 900 for Northern Ireland, that open an OSS number.
    private static let euMemberStates: Set<Int> = [40, 56, 100, 191, 196, 203, 208, 233, 246, 250, 276, 300, 348, 372, 380, 428, 440, 442, 470, 528, 616, 620, 642, 703, 705, 724, 752, 900]

    /// GB/T 2260's provinces, the first two digits of a region code (10 for a national register).
    private static let chinaRegions: Set<Int> = [10, 11, 12, 13, 14, 15, 21, 22, 23, 31, 32, 33, 34, 35, 36, 37, 41, 42, 43, 44, 45, 46, 50, 51, 52, 53, 54, 61, 62, 63, 64, 65, 71, 81, 82]
    /// GB 32100-2015's characters: digits and capitals but I, O, S, V and Z.
    private static let usccAlphabet = Array("0123456789ABCDEFGHJKLMNPQRTUWXY")
    private static let usccLetters = "ABCDEFGHJKLMNPQRTUWXY"
    /// GB 32100-2015's check: weights 3^i modulo 31 over its alphabet's values.
    private static func usccMark(_ body: [Character]) -> Character? {
        var sum = 0
        for (character, weight) in zip(body, [1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28]) {
            guard let value = usccAlphabet.firstIndex(of: character) else { return nil }
            sum += value * weight
        }
        return body.count == 17 ? usccAlphabet[(31 - sum % 31) % 31] : nil
    }
    /// GB 11714-1997's organisation code check: weights 3, 7, 9, 10, 5, 8, 4, 2, eleven less the sum modulo 11 (10 is X).
    private static func organisationMark(_ body: [Character]) -> Character? {
        guard body.count == 8 else { return nil }
        var sum = 0
        for (character, weight) in zip(body, [3, 7, 9, 10, 5, 8, 4, 2]) {
            guard let value = alnumValue(character) else { return nil }
            sum += value * weight
        }
        let rest = 11 - sum % 11
        return rest == 10 ? "X" : rest == 11 ? "0" : Character(String(rest))
    }
    private static func ubnSum(_ d: [Int]) -> Int {
        zip(d, [1, 2, 1, 2, 1, 2, 4, 1]).reduce(0) { total, pair in let product = pair.0 * pair.1; return total + product / 10 + product % 10 }
    }
    /// Viet Nam's check digit, none where the sum leaves no remainder.
    private static func mstDigit(_ body: [Int]) -> Int? {
        let rest = zip(body, [31, 29, 23, 19, 17, 13, 7, 5, 3]).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest == 0 ? nil : 10 - rest
    }
    private static func corporateDigit(_ body: [Int]) -> Int {
        9 - body.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 2) } % 9
    }
    private static func ghanaMark(_ d: [Int]) -> Character {
        let rest = d.enumerated().reduce(0) { $0 + ($1.offset + 1) * $1.element } % 11
        return rest == 10 ? "X" : Character(String(rest))
    }
    private static let nineaCentres: Set<Character> = Set("ABCDEFGHJKLMNPQRSTUVWZ")
    private static func nineaDigit(_ body: [Int]) -> Int {
        let padded = Array(repeating: 0, count: max(0, 8 - body.count)) + body
        return (10 - padded.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 2) } % 10) % 10
    }
    private static let mfControlKeys = "ABCDEFGHJKLMNPQRSTVWXYZ"
    /// Mozambique's NUIT check: weights 8, 9, 4, 5, 6, 7, 8, 9, the sum mod 11, a remainder of 10 written 1.
    private static func nuitDigit(_ body: [Int]) -> Int {
        let rest = zip(body, [8, 9, 4, 5, 6, 7, 8, 9]).reduce(0) { $0 + $1.0 * $1.1 } % 11
        return rest == 10 ? 1 : rest
    }
    private static func omanMark(_ d: [Int]) -> Character {
        let rest = (1 + zip(d.dropFirst(4), [1, 6, 3, 7, 9]).reduce(0) { $0 + $1.0 * $1.1 }) % 11
        return rest == 10 ? "X" : Character(String(rest))
    }
    /// ISO 7064 MOD 97-10 over digits and letters (A is 10), as ISO 17442 reads them.
    private static func leiRemainder(_ characters: [Character]) -> Int? {
        var rest = 0
        for character in characters {
            guard let value = alnumValue(character) else { return nil }
            rest = (rest * (value >= 10 ? 100 : 10) + value) % 97
        }
        return rest
    }
    private static func hexValue(_ character: Character) -> Int? {
        guard character.isASCII, let value = character.hexDigitValue else { return nil }
        return value
    }
    /// Luhn's check in base 16, as 3GPP2 gives an MEID's check digit.
    private static func hexLuhn(_ values: [Int]) -> Bool {
        values.reversed().enumerated().reduce(0) { total, item in
            let doubled = item.offset % 2 == 0 ? item.element : item.element * 2
            return total + doubled / 16 + doubled % 16
        } % 16 == 0
    }
    /// A draw whose letters and digits stand where `like`'s do, where a computed character may be either.
    private static func drawnLike(_ like: [Character], _ rng: inout any RandomNumberGenerator, _ make: (inout any RandomNumberGenerator) -> [Character]) -> [Character] {
        var made = make(&rng)
        for _ in 0..<512 {
            guard made.count == like.count, zip(made, like).contains(where: { $0.isLetter != $1.isLetter }) else { return made }
            made = make(&rng)
        }
        return made
    }

/// GB/T 2260 district codes of Beijing, Tianjin and Shanghai, each in use from 1950 through 1999.
    private static let residentCounties: [[Int]] = [[1, 1, 0, 1, 0, 1], [1, 1, 0, 1, 0, 2], [1, 1, 0, 1, 0, 5], [1, 1, 0, 1, 0, 8], [1, 2, 0, 1, 0, 1], [1, 2, 0, 1, 0, 3], [3, 1, 0, 1, 0, 1], [3, 1, 0, 1, 0, 4], [3, 1, 0, 1, 1, 0]]
    /// Its last character a digit or an X as the original's was.
    private static func residentDraw(_ like: [Character], _ rng: inout any RandomNumberGenerator) -> [Character] {
        drawnLike(like, &rng) { rng in
            let date = randomDate(&rng)
            let place = residentCounties.randomElement(using: &rng) ?? [1, 1, 0, 1, 0, 1]
            let d = place + [1, 9] + twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(3, &rng)
            return characters(d) + [residentMark(d)]
        }
    }
}
