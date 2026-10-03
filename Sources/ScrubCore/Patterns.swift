import Foundation
import Darwin

enum Patterns {
    private static let definitions: [(String, String, Double, Set<String>, NSRegularExpression.Options)] = [
        ("EMAIL_ADDRESS", #"\b[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+)*@[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)+\b"#, 1, [], []),
        ("CREDIT_CARD", #"(?<![\w-])(?:\d[ -]?){12,18}\d(?![\w-])"#, 0.6, ["card", "credit", "visa", "mastercard", "payment"], []),
        ("IBAN_CODE", #"(?<![A-Z0-9])[A-Z]{2}\d{2}(?:[ -]?[A-Z0-9]{4}){2,6}(?:[ -]?[A-Z0-9]{4})?(?:[ -]?[A-Z0-9]{1,3})?(?![A-Z0-9])"#, 0.6, ["iban", "bank", "account"], []),
        ("IP_ADDRESS", #"(?<![\w:.]|[A-Za-z]/)(?:[0-9A-Fa-f:]+:)?(?:\d{1,3}\.){3}\d{1,3}(?![\w:.])|(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f:]{0,4}(?![\w:])"#, 0.6, ["ip", "address"], []),
        ("US_SSN", #"(?<![\d-])\d{3}([- ])\d{2}\1\d{4}(?![\d-])"#, 0.85, ["ssn", "social", "security"], []),
        ("US_SSN", #"\b\d{5}-\d{4}\b|\b\d{3}-\d{6}\b|\b\d{9}\b|\b\d{3}[- .]\d{2}[- .]\d{4}\b"#, 0.05, ["ssn", "ssns", "ssid", "social", "security"], []),
        ("US_SSN", #"\b\d{3}[- .]\d{2}[- .]\d{4}\b"#, 0.5, ["ssn", "ssns", "ssid", "social", "security"], []),
        ("SECRET", #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})\b|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bxox[abposr]-[A-Za-z0-9-]{10,}\b|\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}|(?<=[Bb]earer )[A-Za-z0-9._~+/=-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#, 0.9, [], [.dotMatchesLineSeparators]),
        ("SECRET", #"(?<=(?:password|passwd|pwd|passphrase|secret|api[_-]?key|access[_-]?key|private[_-]?key|token|session[_-]?id)["']?\s{0,3}[:=]\s{0,3}["']?)[^\s"',;`]{4,}(?!`)"#, 0.9, [], [.caseInsensitive]),
        // The display name in "Priya Raghunathan <priya@northwind.io>" is a person
        // even when the name model has never seen it, also quoted or as "Raghunathan, Priya".
        ("PERSON", #"(?<![\p{L}'’.-])\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*){1,3}(?="?[ \t]*<[^<>\s@]+@[^<>\s]+>)|(?<![\p{L}'’.,-][ \t]{0,3})\p{Lu}[\p{L}'’.-]*,[ \t]*\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*)?(?="?[ \t]*<[^<>\s@]+@[^<>\s]+>)"#, 0.9, [], []),
        // Ten digits with no separators ("Best number is 5129867535") are a phone number only near a word that says so.
        ("PHONE_NUMBER", #"(?<![\w+-])(?:\+?1)?[2-9]\d{2}[2-9]\d{6}(?![\w-])"#, 0.3, ["phone", "call", "called", "cell", "mobile", "tel", "telephone", "number", "text", "reach", "fax", "sms", "whatsapp", "dial"], []),
        // "Thandiwe Haddad (thandiwe.haddad@gmail.com) called": the name an email is given beside.
        ("PERSON", #"(?<![\p{L}'’.-])\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*){1,3}(?=[ \t]*\([ \t]*[^()\s@]+@[^()\s]+[ \t]*\))"#, 0.9, [], []),
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
    static let compiled = definitions.compactMap { entity, pattern, base, context, options -> (String, NSRegularExpression, Double, Set<String>)? in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return (entity, regex, base, context)
    }
    /// Where a match of the two secret patterns can start. ICU tries a pattern
    /// at every position, and their look-behinds and long alternation cost
    /// seconds per 300 KB there, every time a text is checked. A match of the
    /// first starts at one of its literal prefixes or after "Bearer "; one of
    /// the second starts at most five units after a ":" or "=" that a key name
    /// may precede. Tried anchored at those positions only, with the text
    /// around them in view, they find exactly the matches a full scan does.
    static let starts: [String: @Sendable (UnsafeBufferPointer<UInt16>) -> [Int]] = [
        #"\b(?:sk|pk|rk)_"#: { units in prefixed(units, by: ["sk_", "pk_", "rk_", "gh", "github_pat_", "AKIA", "ASIA", "xox", "eyJ", "-----BEGIN "], after: ["Bearer ", "bearer "]) },
        #"(?<=(?:password|"#: { units in afterKeyedSeparator(units) },
    ]
    static func find(_ text: String, contextWords: Set<String> = [], isCancelled: () -> Bool = { Task.isCancelled }) -> [Span] {
        var spans: [Span] = []
        // One UTF-16 copy for every pattern: matching a native string copies it
        // into UTF-16 on every call, and the anchored tries below make many.
        let units = Array(text.utf16)
        let ns: NSString = units.withUnsafeBufferPointer { buffer in buffer.baseAddress.map { NSString(characters: $0, length: buffer.count) } ?? "" }
        let length = units.count
        for (entity, regex, base, context) in compiled {
            if isCancelled() { return spans }
            func take(_ match: NSTextCheckingResult) {
                var range = match.range.location..<NSMaxRange(match.range)
                if entity == "IBAN_CODE" {
                    guard let trimmed = longestIBAN(in: text, range: range) else { return }
                    range = trimmed
                }
                if entity == "IP_ADDRESS", range.upperBound < length {
                    let tail = TextRanges.substring(text, range.upperBound..<min(length, range.upperBound + 2))
                    if tail.range(of: #"^\.[0-9]|^:[0-9A-Fa-f]"#, options: .regularExpression) != nil { return }
                }
                if entity == "SECRET", let cut = URLs.queryValueEnd(ns, range) { range = range.lowerBound..<cut }
                let value = TextRanges.substring(text, range)
                if entity == "PERSON" && NameTagger.namesOrganisation(value) { return }
                // "https://deploy:hunter2@git.example.test" holds a password and a host, no address.
                if entity == "EMAIL_ADDRESS", inURLCredentials(text, at: range.lowerBound) { return }
                guard valid(value, entity: entity), !(entity == "US_SSN" && base <= 0.5 && invalidSSN(value)) else { return }
                let score = context.isDisjoint(with: contextWords) ? Context.enhanced(base, words: context, range: range, text: text) : min(1, max(0.4, base + 0.35))
                if score >= 0.4 { spans.append(Span(range: range, entity: entity, score: score)) }
            }
            for match in matches(regex, in: ns, units: units, isCancelled: isCancelled) { take(match) }
        }
        return spans
    }
    /// Every match a full scan finds, in order; a pattern with known start
    /// positions is tried only there.
    static func matches(_ regex: NSRegularExpression, in ns: NSString, units: [UInt16], isCancelled: () -> Bool) -> [NSTextCheckingResult] {
        var found: [NSTextCheckingResult] = []
        if let candidates = starts.first(where: { regex.pattern.hasPrefix($0.key) })?.value {
            var cursor = 0
            for start in units.withUnsafeBufferPointer(candidates) where start >= cursor {
                if isCancelled() { break }
                guard let match = regex.firstMatch(in: ns as String, options: [.anchored, .withTransparentBounds], range: NSRange(location: start, length: units.count - start)) else { continue }
                found.append(match)
                cursor = NSMaxRange(match.range)
            }
            return found
        }
        // Reports progress between matches as well, so a long text stops
        // partway through one pattern once cancelled.
        regex.enumerateMatches(in: ns as String, options: .reportProgress, range: NSRange(location: 0, length: units.count)) { match, _, stop in
            if isCancelled() { stop.pointee = true; return }
            if let match { found.append(match) }
        }
        return found
    }
    /// Positions, in order, where one of `literals` begins or one of `after` ends.
    private static func prefixed(_ units: UnsafeBufferPointer<UInt16>, by literals: [String], after: [String]) -> [Int] {
        let starting = literals.map { Array($0.utf16) }, ending = after.map { Array($0.utf16) }
        let firsts = Set(starting.map { $0[0] } + ending.map { $0[0] })
        func at(_ index: Int, _ literal: [UInt16]) -> Bool {
            index + literal.count <= units.count && literal.indices.allSatisfy { units[index + $0] == literal[$0] }
        }
        var found: [Int] = []
        for index in units.indices where firsts.contains(units[index]) {
            if starting.contains(where: { at(index, $0) }) { found.append(index) }
            for literal in ending where at(index, literal) { found.append(index + literal.count) }
        }
        return Array(Set(found)).sorted()
    }
    /// The five positions after each ":" or "=" whose fifteen units before may
    /// end in a key name (an ASCII key root, or any non-ASCII unit, which may
    /// fold to one under case-insensitive matching).
    private static func afterKeyedSeparator(_ units: UnsafeBufferPointer<UInt16>) -> [Int] {
        let roots = ["pass", "pwd", "secret", "key", "token", "session"].map { Array($0.utf16) }
        var found: [Int] = []
        for index in units.indices where units[index] == 58 || units[index] == 61 {
            let window = units[max(0, index - 15)..<index]
            guard window.contains(where: { $0 > 127 }) || roots.contains(where: { root in
                window.count >= root.count && (window.startIndex...(window.endIndex - root.count)).contains { start in
                    root.indices.allSatisfy { offset in
                        let unit = window[start + offset]
                        return (65...90).contains(unit) ? unit + 32 == root[offset] : unit == root[offset]
                    }
                }
            }) else { continue }
            found.append(contentsOf: (index + 1)...min(units.count, index + 5))
        }
        return Array(Set(found)).sorted()
    }
    private static let credentials = TextPattern(#"[A-Za-z][A-Za-z0-9+.\-]*://[^\s/@]*:$"#)
    /// Whether `start` follows a URL's scheme and user name ("https://deploy:").
    private static func inURLCredentials(_ text: String, at start: Int) -> Bool {
        let ns = text as NSString
        var from = start
        while from > 0, start - from < 96, let scalar = Unicode.Scalar(ns.character(at: from - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { from -= 1 }
        guard from < start else { return false }
        return !TextRanges.matches(credentials, in: ns.substring(with: NSRange(location: from, length: start - from))).isEmpty
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
