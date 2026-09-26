import Foundation
import Darwin

enum Patterns {
    private static let definitions: [(String, String, Double, Set<String>, NSRegularExpression.Options)] = [
        ("EMAIL_ADDRESS", #"\b[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+)*@[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)+\b"#, 1, [], []),
        ("CREDIT_CARD", #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, 0.6, ["card", "credit", "visa", "mastercard", "payment"], []),
        ("IBAN_CODE", #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#, 0.6, ["iban", "bank", "account"], []),
        ("IP_ADDRESS", #"(?<![\w:.])(?:\d{1,3}\.){3}\d{1,3}(?![\w:.])|(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f:]{0,4}(?![\w:])"#, 0.6, ["ip", "address"], []),
        ("US_SSN", #"(?<![\d-])\d{3}([- ])\d{2}\1\d{4}(?![\d-])"#, 0.85, ["ssn", "social", "security"], []),
        ("SECRET", #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})\b|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bxox[abposr]-[A-Za-z0-9-]{10,}\b|\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}|(?<=[Bb]earer )[A-Za-z0-9._~+/=-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#, 0.9, [], [.dotMatchesLineSeparators]),
        ("DATE_OF_BIRTH", #"\b\d{4}([-/.])\d{1,2}\1\d{1,2}\b|\b\d{1,2}([-/.])\d{1,2}\2\d{4}\b"#, 0.1, Context.birth, []),
        ("ADDRESS", #"\b\d{1,6}[A-Z]?\s+(?:[A-Z][a-z]+\.?\s+){1,4}(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Way|Lane|Ln|Drive|Dr|Court|Ct|Place|Pl|Terrace|Ter|Parkway|Pkwy|Highway|Hwy|Circle|Cir|Square|Sq|Trail|Trl|Alley|Row|Crescent|Close)\b\.?(?:\s+(?:N|S|E|W|NE|NW|SE|SW)\b)?(?:,?\s+(?:Apt|Apartment|Suite|Ste|Unit|Floor|Fl|#)\.?\s*[A-Za-z0-9-]+)?"#, 0.6, [], []),
        ("US_BANK_NUMBER", #"\b\d{8,17}\b"#, 0.05, ["bank", "account", "routing"], []),
        ("US_DRIVER_LICENSE", #"\b[A-Z]\d{7,12}\b"#, 0.05, ["driver", "license"], []),
        ("US_PASSPORT", #"\b\d{9}\b"#, 0.05, ["passport"], []),
        ("US_ITIN", #"\b9\d{2}-\d{2}-\d{4}\b"#, 0.05, ["itin", "tax"], [])
    ]
    static func find(_ text: String) -> [Span] {
        var spans: [Span] = []
        for (entity, regex, base, context, options) in definitions {
            for match in TextRanges.matches(regex, in: text, options: options) {
                let range = match.range.location..<NSMaxRange(match.range)
                let value = TextRanges.substring(text, range)
                guard valid(value, entity: entity) else { continue }
                let score = Context.enhanced(base, words: context, range: range, text: text)
                if score >= 0.4 { spans.append(Span(range: range, entity: entity, score: score)) }
            }
        }
        return spans
    }
    private static func valid(_ value: String, entity: String) -> Bool {
        switch entity {
        case "CREDIT_CARD":
            let digits = value.compactMap(\.wholeNumberValue)
            return (13...19).contains(digits.count) && luhn(digits)
        case "IBAN_CODE": return iban(value)
        case "IP_ADDRESS":
            var v4 = in_addr(); var v6 = in6_addr()
            return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
        default: return true
        }
    }
    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, digit) in digits.reversed().enumerated() {
            let doubled = i.isMultiple(of: 2) ? digit : digit * 2
            sum += doubled > 9 ? doubled - 9 : doubled
        }
        return sum.isMultiple(of: 10)
    }
    static func iban(_ value: String) -> Bool {
        let raw = value.uppercased().filter { !$0.isWhitespace }
        guard (15...34).contains(raw.count), raw.prefix(2).allSatisfy(\.isLetter), raw.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return false }
        let moved = String(raw.dropFirst(4)) + String(raw.prefix(4))
        var remainder = 0
        for char in moved {
            let encoded: String
            if let digit = char.wholeNumberValue { encoded = String(digit) }
            else if let scalar = char.asciiValue, scalar >= 65 && scalar <= 90 { encoded = String(Int(scalar) - 55) }
            else { return false }
            for digit in encoded.compactMap(\.wholeNumberValue) { remainder = (remainder * 10 + digit) % 97 }
        }
        return remainder == 1
    }
}
