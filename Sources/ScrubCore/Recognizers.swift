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
    let forms: [Form]
    let context: Set<String>
    /// What its spelling may write between characters, dropped before the check.
    let separators: Set<Character>
    /// Its check, over the value's characters other than separators, in capitals.
    let check: @Sendable ([Character]) -> Bool
    /// A fresh value passing `check`, as many characters long as the given count where its kind allows.
    let draw: @Sendable (Int, inout any RandomNumberGenerator) -> [Character]

    init(_ name: String, forms: [Form], context: Set<String>, separators: String = " .-/", check: @escaping @Sendable ([Character]) -> Bool, draw: @escaping @Sendable (Int, inout any RandomNumberGenerator) -> [Character]) {
        self.name = name
        self.forms = forms
        self.context = context
        self.separators = Set(separators)
        self.check = check
        self.draw = draw
    }

    func kept(_ value: String) -> [Character] {
        value.uppercased().filter { !separators.contains($0) }
    }
    func passes(_ value: String) -> Bool {
        let characters = kept(value)
        return !characters.isEmpty && check(characters)
    }
}

enum Recognizers {
    static let entity = "ID_NUMBER"

    static let all: [Recognizer] = [
        Recognizer("CPF", forms: [
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
        Recognizer("CUIL", forms: [
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
        Recognizer("RUT", forms: [
            .init(#"\b\d{1,2}\.\d{3}\.\d{3}-[\dkK](?![\w-])"#, 0.5, alone: true),
            .init(#"\b\d{7,8}-[\dkK](?![\w-])"#, 0.1),
        ], context: ["rut", "run"], check: { characters in
            guard (8...9).contains(characters.count), let body = numbers(Array(characters.dropLast())) else { return false }
            return characters.last == rutDigit(body)
        }, draw: { count, rng in
            let body = [Int.random(in: 1...9, using: &rng)] + randomDigits(max(6, min(7, count - 2)), &rng)
            return characters(body) + [rutDigit(body)]
        }),
        Recognizer("CURP", forms: [
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
        Recognizer("RFC", forms: [
            .init(#"\b[A-ZÑ&]{4}\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[A-Z\d]{2}[\dA]\b"#, 0.4, alone: true),
        ], context: ["rfc"], separators: " -", check: { characters in
            characters.count == 13 && rfcDigit(characters[0..<12]) == characters[12]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            var c = [pick(consonants, &rng), pick("AEIOU", &rng), pick(letters, &rng), pick(letters, &rng)]
            c += characters(twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day))
            c += [pick(letters + digits, &rng), pick(letters + digits, &rng)]
            return c + [rfcDigit(c[...])]
        }),
        Recognizer("CODICE_FISCALE", forms: [
            .init(#"(?i)\b(?:[A-Z][AEIOU][AEIOUX]|[AEIOU]X{2}|[B-DF-HJ-NP-TV-Z]{2}[A-Z]){2}[\dLMNP-V]{2}[A-EHLMPR-T](?:[04LQ][1-9MNP-V]|[15MR][\dLMNP-V]|[26NS][0-8LMNP-U]|[37PT][01LM])[A-MZ][1-9MNP-V][\dLMNP-V]{2}[A-Z]\b"#, 0.6, alone: true),
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
        Recognizer("DNI", forms: [
            .init(#"\b\d{8}-?[A-HJ-NP-TV-Z]\b"#, 0.5, alone: true),
        ], context: ["dni", "nif", "documento", "identidad"], check: { characters in
            guard characters.count == 9, let d = numbers(Array(characters.prefix(8))) else { return false }
            return dniLetter(number(d)) == characters[8]
        }, draw: { _, rng in
            let d = [Int.random(in: 1...9, using: &rng)] + randomDigits(7, &rng)
            return characters(d) + [dniLetter(number(d))]
        }),
        Recognizer("NIE", forms: [
            .init(#"\b[XYZ]-?\d{7}-?[A-HJ-NP-TV-Z]\b"#, 0.5, alone: true),
        ], context: ["nie", "extranjero"], check: { characters in
            guard characters.count == 9, let lead = "XYZ".firstIndex(of: characters[0]), let d = numbers(Array(characters[1..<8])) else { return false }
            return dniLetter("XYZ".distance(from: "XYZ".startIndex, to: lead) * 10_000_000 + number(d)) == characters[8]
        }, draw: { _, rng in
            let lead = Int.random(in: 0...1, using: &rng)
            let d = randomDigits(7, &rng)
            return [Array("XY")[lead]] + characters(d) + [dniLetter(lead * 10_000_000 + number(d))]
        }),
        Recognizer("NIR", forms: [
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
        Recognizer("BELGIAN_NATIONAL_NUMBER", forms: [
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
        Recognizer("BSN", forms: [
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
        Recognizer("STEUER_ID", forms: [
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
        Recognizer("PESEL", forms: [
            .init(#"\b\d{2}(?:[02468][1-9]|[13579][012])(?:0[1-9]|[12]\d|3[01])\d{5}\b"#, 0.05),
        ], context: ["pesel"], check: { characters in
            guard let d = numbers(characters), d.count == 11 else { return false }
            return (10 - zip(d[0..<10], [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]).reduce(0) { $0 + $1.0 * $1.1 } % 10) % 10 == d[10]
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(4, &rng)
            return characters(d + [(10 - zip(d, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]).reduce(0) { $0 + $1.0 * $1.1 } % 10) % 10])
        }),
        Recognizer("PERSONNUMMER", forms: [
            .init(#"\b(?:19|20)?\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01]|[6-8]\d|9[01])[-+]\d{4}\b"#, 0.5, alone: true),
            .init(#"\b(?:19|20)?\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01]|[6-8]\d|9[01])\d{4}\b"#, 0.05),
        ], context: ["personnummer", "samordningsnummer"], separators: " -+", check: { characters in
            guard let all = numbers(characters), all.count == 10 || all.count == 12 else { return false }
            let d = Array(all.suffix(10))
            let day = d[4] * 10 + d[5]
            return (1...12).contains(d[2] * 10 + d[3]) && ((1...31).contains(day) || (61...91).contains(day)) && Patterns.luhn(d)
        }, draw: { count, rng in
            let date = randomDate(&rng)
            let body = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(3, &rng)
            return characters((count == 12 ? [1, 9] : []) + body + [luhnDigit(body)])
        }),
        Recognizer("FODSELSNUMMER", forms: [
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
        Recognizer("CPR", forms: [
            .init(#"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}-\d{4}\b"#, 0.1),
        ], context: ["cpr", "personnummer"], check: { characters in
            guard let d = numbers(characters), d.count == 10 else { return false }
            return realDate(year: 1900 + d[4] * 10 + d[5], month: d[2] * 10 + d[3], day: d[0] * 10 + d[1])
        }, draw: { _, rng in
            let date = randomDate(&rng)
            return characters(twoDigits(date.day) + twoDigits(date.month) + twoDigits(date.year % 100) + randomDigits(4, &rng))
        }),
        Recognizer("HETU", forms: [
            .init(#"\b\d{6}[-+ABCDEFUVWXY]\d{3}[0-9A-FHJ-NPR-Y]\b"#, 0.5, alone: true),
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
        Recognizer("NINO", forms: [
            .init(#"\b(?!BG|GB|NK|KN|NT|TN|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?\d{2} ?\d{2} ?\d{2} ?[A-D]\b"#, 0.3),
        ], context: ["nino", "insurance"], check: { $0.count == 9 }, draw: { _, rng in
            [pick("ABCEGHJKLMPRSTWXY", &rng), pick("ABCEHJLMPRSTWXY", &rng)] + characters(randomDigits(6, &rng)) + [pick("ABCD", &rng)]
        }),
        Recognizer("NHS_NUMBER", forms: [
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
        Recognizer("SIN", forms: [
            .init(#"\b[1-79]\d{2}[- ]?\d{3}[- ]?\d{3}\b"#, 0.05),
        ], context: ["sin", "nas", "insurance"], check: { characters in
            guard let d = numbers(characters), d.count == 9 else { return false }
            return Patterns.luhn(d)
        }, draw: { _, rng in
            let d = [Int.random(in: 1...7, using: &rng)] + randomDigits(7, &rng)
            return characters(d + [luhnDigit(d)])
        }),
        Recognizer("AADHAAR", forms: [
            .init(#"\b[2-9]\d{3}[- ]?\d{4}[- ]?\d{4}\b"#, 0.05),
        ], context: ["aadhaar", "aadhar", "uidai"], check: { characters in
            guard let d = numbers(characters), d.count == 12, d[0] >= 2, d != Array(d.reversed()) else { return false }
            return verhoeff(d) == 0
        }, draw: { _, rng in
            let d = [Int.random(in: 2...9, using: &rng)] + randomDigits(10, &rng)
            return characters(d + [verhoeffDigit(d)])
        }),
        Recognizer("PAN", forms: [
            .init(#"\b[A-Z]{3}[ABCFGHLJPT][A-Z]\d{4}[A-Z]\b"#, 0.3),
        ], context: ["pan", "permanent"], check: { $0.count == 10 }, draw: { _, rng in
            [pick(letters, &rng), pick(letters, &rng), pick(letters, &rng), "P", pick(letters, &rng)] + characters(randomDigits(4, &rng)) + [pick(letters, &rng)]
        }),
        Recognizer("RESIDENT_ID", forms: [
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
        Recognizer("RRN", forms: [
            .init(#"(?<!\d)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])-[1-8]\d{6}(?!\d)"#, 0.5, alone: true),
            .init(#"(?<!\d)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[1-8]\d{6}(?!\d)"#, 0.05),
        ], context: ["rrn", "주민등록번호", "외국인등록번호"], check: { characters in
            guard let d = numbers(characters), d.count == 13 else { return false }
            let century = [9: 1800, 0: 1800, 1: 1900, 2: 1900, 5: 1900, 6: 1900, 3: 2000, 4: 2000, 7: 2000, 8: 2000][d[6]] ?? 1900
            return realDate(year: century + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5])
        }, draw: { _, rng in
            let date = randomDate(&rng)
            var d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + [Int.random(in: 1...2, using: &rng)] + randomDigits(5, &rng)
            d.append((11 - zip(d, [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5]).reduce(0) { $0 + $1.0 * $1.1 } % 11) % 10)
            return characters(d)
        }),
        Recognizer("SOUTH_AFRICAN_ID", forms: [
            .init(#"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{4}[01][89]\d\b"#, 0.05),
        ], context: ["identity", "rsa"], check: { characters in
            guard let d = numbers(characters), d.count == 13 else { return false }
            return realDate(year: 1900 + d[0] * 10 + d[1], month: d[2] * 10 + d[3], day: d[4] * 10 + d[5]) && Patterns.luhn(d)
        }, draw: { _, rng in
            let date = randomDate(&rng)
            let d = twoDigits(date.year % 100) + twoDigits(date.month) + twoDigits(date.day) + randomDigits(4, &rng) + [0, 8]
            return characters(d + [luhnDigit(d)])
        }),
        Recognizer("TCKN", forms: [
            .init(#"\b[1-9]\d{10}\b"#, 0.05),
        ], context: ["tckn", "kimlik"], check: { characters in
            guard let d = numbers(characters), d.count == 11, d[0] != 0 else { return false }
            return d[9] == tcknTenth(d) && d[10] == d[0..<10].reduce(0, +) % 10
        }, draw: { _, rng in
            var d = [Int.random(in: 1...9, using: &rng)] + randomDigits(8, &rng)
            d.append(tcknTenth(d))
            return characters(d + [d.reduce(0, +) % 10])
        }),
    ]

    /// The recognizer a whole value is written as and passes the check of.
    static func recognizing(_ value: String) -> Recognizer? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let length = (trimmed as NSString).length
        guard length >= 8, length <= 24, trimmed.contains(where: \.isNumber) else { return nil }
        return all.first { recognizer in
            recognizer.forms.contains { form in
                TextRanges.matches(form.pattern, in: trimmed).contains { $0.range.location == 0 && $0.range.length == length }
            } && recognizer.passes(trimmed)
        }
    }

    /// A fresh value of the kind `original` is, written as it is (its separators where they were, its letters in its case), which passes the same check.
    static func standIn(for original: String, using rng: inout any RandomNumberGenerator) -> String? {
        guard let recognizer = recognizing(original) else { return nil }
        let kept = recognizer.kept(original.trimmingCharacters(in: .whitespaces))
        for _ in 0..<8 {
            let drawn = recognizer.draw(kept.count, &rng)
            guard drawn.count == kept.count, drawn != kept else { continue }
            var next = drawn.makeIterator()
            let written = String(original.map { character -> Character in
                guard !recognizer.separators.contains(character), let made = next.next() else { return character }
                return character.isLowercase ? Character(made.lowercased()) : made
            })
            if recognizer.passes(written) { return written }
        }
        return nil
    }

    /// Identifiers in `text`: one passing its check in a form that needs no
    /// naming word scores 0.85, one named by a word before it or by its key
    /// scores as its context gives it, and one failing its check is none.
    static func find(_ text: String, ns: NSString, units: [UInt16], contextWords: Set<String>, isCancelled: () -> Bool) -> [Span] {
        guard units.contains(where: { (48...57).contains($0) }) else { return [] }
        var spans: [Span] = []
        for recognizer in all {
            if isCancelled() { return spans }
            for form in recognizer.forms {
                guard let regex = form.pattern.regex else { continue }
                for match in Patterns.matches(regex, in: ns, units: units, isCancelled: isCancelled) {
                    let range = match.range.location..<NSMaxRange(match.range)
                    guard recognizer.passes(ns.substring(with: match.range)) else { continue }
                    let named = !recognizer.context.isDisjoint(with: contextWords)
                        || !Context.before(range, in: text, limit: 5).isDisjoint(with: recognizer.context)
                    let score = named ? 1 : form.alone ? 0.85 : form.score
                    if score >= 0.4 { spans.append(Span(range: range, entity: entity, score: score)) }
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
