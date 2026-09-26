import Foundation
import Darwin

enum Patterns {
    private static let definitions: [(String, String, Double, Set<String>, NSRegularExpression.Options)] = [
        ("EMAIL_ADDRESS", #"\b[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+)*@[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)+\b"#, 1, [], []),
        ("CREDIT_CARD", #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, 0.6, ["card", "credit", "visa", "mastercard", "payment"], []),
        ("IBAN_CODE", #"(?<![A-Z0-9])[A-Z]{2}\d{2}(?:[ -]?[A-Z0-9]{4}){2,6}(?:[ -]?[A-Z0-9]{4})?(?:[ -]?[A-Z0-9]{1,3})?(?![A-Z0-9])"#, 0.6, ["iban", "bank", "account"], []),
        ("IP_ADDRESS", #"(?<![\w:.])(?:[0-9A-Fa-f:]+:)?(?:\d{1,3}\.){3}\d{1,3}(?![\w:.])|(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f:]{0,4}(?![\w:])"#, 0.6, ["ip", "address"], []),
        ("US_SSN", #"(?<![\d-])\d{3}([- ])\d{2}\1\d{4}(?![\d-])"#, 0.85, ["ssn", "social", "security"], []),
        ("US_SSN", #"\b\d{5}-\d{4}\b|\b\d{3}-\d{6}\b|\b\d{9}\b|\b\d{3}[- .]\d{2}[- .]\d{4}\b"#, 0.05, ["ssn", "ssns", "ssid", "social", "security"], []),
        ("US_SSN", #"\b\d{3}[- .]\d{2}[- .]\d{4}\b"#, 0.5, ["ssn", "ssns", "ssid", "social", "security"], []),
        ("SECRET", #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})\b|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bxox[abposr]-[A-Za-z0-9-]{10,}\b|\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}|(?<=[Bb]earer )[A-Za-z0-9._~+/=-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#, 0.9, [], [.dotMatchesLineSeparators]),
        ("DATE_OF_BIRTH", #"\b\d{4}([-/.])\d{1,2}\1\d{1,2}\b|\b\d{1,2}([-/.])\d{1,2}\2\d{4}\b"#, 0.1, Context.birth, []),
        ("ADDRESS", #"\b\d{1,6}[A-Z]?\s+(?:[A-Z][a-z]+\.?\s+){1,4}(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Way|Lane|Ln|Drive|Dr|Court|Ct|Place|Pl|Terrace|Ter|Parkway|Pkwy|Highway|Hwy|Circle|Cir|Square|Sq|Trail|Trl|Alley|Row|Crescent|Close)\b\.?(?:\s+(?:N|S|E|W|NE|NW|SE|SW)\b)?(?:,?\s+(?:Apt|Apartment|Suite|Ste|Unit|Floor|Fl|#)\.?\s*[A-Za-z0-9-]+)?"#, 0.6, [], []),
        ("US_BANK_NUMBER", #"\b\d{8,17}\b"#, 0.05, ["check", "account", "acct", "bank", "save", "debit"], []),
        ("US_DRIVER_LICENSE", #"\b(?:[A-Z]\d{1,12}|[A-Z]{1,2}\d{5,6}|[A-Z]{2}\d{3,7}|\d{2}[A-Z]{3}\d{5,6}|[A-Z]\d{13,14}|[A-Z]\d{18}|[A-Z]\d{6}R|\d{9}[A-Z]|[A-Z]{2}\d{6}[A-Z]|\d{8}[A-Z]{2}|\d{3}[A-Z]{2}\d{4}|[A-Z]\d[A-Z]\d[A-Z]|\d{7,8}[A-Z])\b"#, 0.3, ["driver", "license", "permit", "lic", "identification", "dls", "cdls", "driving"], []),
        ("US_DRIVER_LICENSE", #"\b(?:\d{6,14}|\d{16})\b"#, 0.01, ["driver", "license", "permit", "lic", "identification", "dls", "cdls", "driving"], []),
        ("US_PASSPORT", #"\b\d{9}\b"#, 0.05, ["passport"], []),
        ("US_PASSPORT", #"\b[A-Z]\d{8}\b"#, 0.1, ["passport"], []),
        ("US_ITIN", #"\b9\d{2}(?:[- ](?:5\d|6[0-5]|7\d|8[0-8]|9(?:[0-2]|[4-9]))\d{4}|(?:5\d|6[0-5]|7\d|8[0-8]|9(?:[0-2]|[4-9]))[- ]\d{4})\b"#, 0.05, ["individual", "taxpayer", "itin", "tax", "payer", "taxid", "tin"], []),
        ("US_ITIN", #"\b9\d{2}(?:5\d|6[0-5]|7\d|8[0-8]|9(?:[0-2]|[4-9]))\d{4}\b"#, 0.3, ["individual", "taxpayer", "itin", "tax", "payer", "taxid", "tin"], []),
        ("US_ITIN", #"\b9\d{2}[- ](?:5\d|6[0-5]|7\d|8[0-8]|9(?:[0-2]|[4-9]))[- ]\d{4}\b"#, 0.5, ["individual", "taxpayer", "itin", "tax", "payer", "taxid", "tin"], [])
    ]
    private static let compiled = definitions.compactMap { entity, pattern, base, context, options -> (String, NSRegularExpression, Double, Set<String>)? in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return (entity, regex, base, context)
    }
    static func find(_ text: String, contextWords: Set<String> = []) -> [Span] {
        var spans: [Span] = []
        for (entity, regex, base, context) in compiled {
            for (index, match) in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).enumerated() {
                if index.isMultiple(of: 64) && Task.isCancelled { return spans }
                var range = match.range.location..<NSMaxRange(match.range)
                if entity == "IBAN_CODE" {
                    guard let trimmed = longestIBAN(in: text, range: range) else { continue }
                    range = trimmed
                }
                if entity == "IP_ADDRESS", range.upperBound < (text as NSString).length {
                    let tail = TextRanges.substring(text, range.upperBound..<min((text as NSString).length, range.upperBound + 2))
                    if tail.range(of: #"^\.[0-9]|^:[0-9A-Fa-f]"#, options: .regularExpression) != nil { continue }
                }
                let value = TextRanges.substring(text, range)
                guard valid(value, entity: entity), !(entity == "US_SSN" && base <= 0.5 && invalidSSN(value)) else { continue }
                let score = context.isDisjoint(with: contextWords) ? Context.enhanced(base, words: context, range: range, text: text) : min(1, max(0.4, base + 0.35))
                if score >= 0.4 { spans.append(Span(range: range, entity: entity, score: score)) }
            }
        }
        return spans
    }
    private static func longestIBAN(in text: String, range: Range<Int>) -> Range<Int>? {
        let candidate = TextRanges.substring(text, range)
        for end in stride(from: candidate.utf16.count, through: 15, by: -1) {
            let prefix = TextRanges.substring(candidate, 0..<end)
            if prefix.last == " " || prefix.last == "-" { continue }
            if iban(prefix) { return range.lowerBound..<(range.lowerBound + end) }
        }
        return nil
    }
    private static func invalidSSN(_ value: String) -> Bool {
        let separators = Set(value.filter { ".- ".contains($0) })
        if separators.count > 1 { return true }
        let digits = value.filter(\.isNumber)
        guard digits.count == 9 else { return true }
        let area = String(digits.prefix(3))
        return Set(digits).count == 1 || area == "000" || area == "666" || area.first == "9" || String(digits.dropFirst(3).prefix(2)) == "00" || digits.suffix(4) == "0000" || ["123456789", "987654320", "078051120"].contains(digits)
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
        let raw = value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
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
