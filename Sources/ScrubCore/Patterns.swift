import Foundation
import Darwin

enum Patterns {
    private static let definitions: [(String, String, Double, Set<String>, NSRegularExpression.Options)] = [
        // In any script, as internationalised mail writes it: "ιωάννης@εεττ.gr", "jeff@臺網中心.tw".
        ("EMAIL_ADDRESS", #"(?<![\p{L}\p{M}\p{N}])[\p{L}\p{N}!#$%&'*+/=?^_`{|}~-][\p{L}\p{M}\p{N}!#$%&'*+/=?^_`{|}~-]*(?:\.[\p{L}\p{M}\p{N}!#$%&'*+/=?^_`{|}~-]+)*@[\p{L}\p{N}](?:[\p{L}\p{M}\p{N}-]*[\p{L}\p{M}\p{N}])?(?:\.[\p{L}\p{N}](?:[\p{L}\p{M}\p{N}-]*[\p{L}\p{M}\p{N}])?)+(?![\p{L}\p{M}\p{N}])"#, 1, [], []),
        // Written into a link's query, its "@" escaped ("jo.pratt%40example.org").
        ("EMAIL_ADDRESS", #"(?<![\w.%+-])[a-zA-Z0-9][a-zA-Z0-9._+-]*%40[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}\b"#, 1, [], []),
        ("CREDIT_CARD", #"(?<![\w-])(?:\d[ -]?){12,18}\d(?![\w-])"#, 0.6, ["card", "credit", "visa", "mastercard", "payment"], []),
        ("IBAN_CODE", #"(?<![A-Z0-9])[A-Z]{2} ?\d{2}(?:[ -]?[A-Z0-9]{4}){2,6}(?:[ -]?[A-Z0-9]{4})?(?:[ -]?[A-Z0-9]{1,3})?(?![A-Z0-9])"#, 0.6, ["iban", "bank", "account"], []),
        // Its country set apart and its check digits opening the first group ("ME 2551 0000 0000 0623 4133").
        ("IBAN_CODE", #"(?<![A-Z0-9])[A-Z]{2}(?: [A-Z0-9]{4}){3,8}(?: [A-Z0-9]{1,3})?(?![A-Z0-9])"#, 0.6, ["iban", "bank", "account"], []),
        // In its bank's own grouping ("ES10 0075 0080 11 0600658108", "ES72 2013-0692-81-0201150993").
        ("IBAN_CODE", #"(?<![A-Z0-9])[A-Z]{2}\d{2}(?:[ -][A-Z0-9]{1,10}){2,8}(?![A-Z0-9])"#, 0.6, ["iban", "bank", "account"], []),
        // Digits grouped however their writer grouped them, by spaces, dots or dashes, its country set apart
        // ("NO 19 4920 06 96270", "NO07.8380.08.06006", "MK072 5012 0000 0589 84", "TL 38 008 00123456789101 57").
        ("IBAN_CODE", #"(?<![A-Z0-9])[A-Z]{2} ?\d{2,30}(?: ?[ .-] ?\d{1,30}){1,9}(?![A-Z0-9.-])"#, 0.6, ["iban", "bank", "account"], []),
        ("IP_ADDRESS", #"(?<![\w:.]|[A-Za-z]/)(?:[0-9A-Fa-f:]+:)?(?:\d{1,3}\.){3}\d{1,3}(?![\w:.])|(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f:]{0,4}(?![\w:])"#, 0.6, ["ip", "address"], []),
        // A client's address written into its host's name ("198-51-100-23.cust.example.net"), as reverse DNS writes it.
        ("IP_ADDRESS", #"(?<![\w.-])(?:\d{1,3}-){3}\d{1,3}(?=\.[A-Za-z][\w-]*\.[A-Za-z])"#, 0.85, [], []),
        ("US_SSN", #"(?<![\d-])\d{3}([- ])\d{2}\1\d{4}(?![\d-])"#, 0.85, ["ssn", "social", "security"], []),
        ("US_SSN", #"\b\d{5}-\d{4}\b|\b\d{3}-\d{6}\b|\b\d{9}\b|\b\d{3}[- .]\d{2}[- .]\d{4}\b"#, 0.05, ["ssn", "ssns", "ssid", "social", "security"], []),
        ("US_SSN", #"\b\d{3}[- .]\d{2}[- .]\d{4}\b"#, 0.5, ["ssn", "ssns", "ssid", "social", "security"], []),
        ("SECRET", #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})\b|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bxox[abposr]-[A-Za-z0-9-]{10,}\b|\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}|\beyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*|(?<=[Bb]earer )[A-Za-z0-9._~+/=-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#, 0.9, [], [.dotMatchesLineSeparators]),
        ("SECRET", #"(?<=(?:password|passwd|pwd|passphrase|secret|api[_-]?key|access[_-]?key|private[_-]?key|account[_-]?key|token|session[_-]?id)["']?\s{0,3}[:=]\s{0,3}["']?)[^\s"',;`}\])]{4,}(?!`)"#, 0.9, [], [.caseInsensitive]),
        // The display name in "Priya Raghunathan <priya@northwind.io>" is a person
        // even when the name model has never seen it, also quoted or as "Raghunathan, Priya";
        // never the time a reply's header gives before it ("at 4:12 PM Priya…", "07:34 AM, Priya…").
        ("PERSON", #"(?<![\p{L}'’.-])(?![AaPp]\.?[Mm]\.?(?![\p{L}'’-]))\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*){1,3}(?="?[ \t]*<[^<>\s@]+@[^<>\s]+>)|(?<![\p{L}'’.,-][ \t]{0,3})(?![AaPp]\.?[Mm]\.?(?![\p{L}'’-]))\p{Lu}[\p{L}'’.-]*,[ \t]*\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*)?(?="?[ \t]*<[^<>\s@]+@[^<>\s]+>)"#, 0.9, [], []),
        // Ten digits with no separators ("Best number is 5129867535") are a phone number only near a word that says so.
        ("PHONE_NUMBER", #"(?<![\w+-])(?:\+?1)?[2-9]\d{2}[2-9]\d{6}(?![\w-])"#, 0.3, ["phone", "call", "called", "cell", "mobile", "tel", "telephone", "number", "text", "reach", "fax", "sms", "whatsapp", "dial"], []),
        // "Thandiwe Haddad (thandiwe.haddad@gmail.com) called": the name an email is given beside.
        ("PERSON", #"(?<![\p{L}'’.-])\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*){1,3}(?=[ \t]*\([ \t]*[^()\s@]+@[^()\s]+[ \t]*\))"#, 0.9, [], []),
        // A party to a case written as a person ("NORTHWIND COLLECTIONS LLC Et Al VS NELL TORVIK"); a business there is left to others.
        ("PARTY", #"(?<=\b(?:VS|Vs|vs|V|v)\.?[ \t])\p{Lu}[\p{L}'’-]+(?:[ \t]\p{Lu}\.?)?(?:[ \t]\p{Lu}[\p{L}'’-]+){1,2}(?=[ \t]*(?:$|[,;)\]]|[ \t](?:ET|Et|et)[ \t]+(?:AL|Al|al)\b))"#, 0.9, [], []),
        ("DATE_OF_BIRTH", #"\b\d{4}([-/.])\d{1,2}\1\d{1,2}\b|\b\d{1,2}([-/.])\d{1,2}\2\d{4}\b"#, 0.1, Context.birth, []),
        ("ADDRESS", #"\b\d{1,6}[A-Z]?\s+(?:(?:N|S|E|W|NE|NW|SE|SW)\.?\s+)?(?:[A-Z][a-z]+\.?\s+){1,4}(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Way|Lane|Ln|Drive|Dr|Court|Ct|Place|Pl|Terrace|Ter|Parkway|Pkwy|Highway|Hwy|Circle|Cir|Square|Sq|Trail|Trl|Alley|Row|Crescent|Close)\b\.?(?:\s+(?:N|S|E|W|NE|NW|SE|SW)\b)?(?:,?\s+(?:Apt|Apartment|Suite|Ste|Unit|Floor|Fl|#)\.?\s*[A-Za-z0-9-]+)?"#, 0.6, [], []),
        // // A street written all in capitals, as forms and mailing lists do ("6190 TURKEY RUN COURT", "111 ELMWOOD TERR"):
        // its words no small ones ("404 ON STREET") and its type ending the line or before a comma or another capital ("3 BIG DR units" is none).
        ("ADDRESS", #"\b\d{1,6}[A-Z]?\s+(?:(?:N|S|E|W|NE|NW|SE|SW)\.?\s+)?(?:(?!(?:ON|IN|AT|OF|THE|TO|FOR|AND|OR|IS|BY|FROM|WITH|NOT|NO|AN|A|AS|IT|BE|ARE|WAS|WE|OUR|YOUR|ALL|NEW|ITEMS?|UNITS?|PCS|QTY)\b)[A-Z][A-Z'’-]+\.?\s+){1,4}(?:STREET|ST|AVENUE|AVE|AV|ROAD|RD|BOULEVARD|BLVD|WAY|LANE|LN|DRIVE|DR|COURT|CT|PLACE|PL|TERRACE|TERR|TER|PARKWAY|PKWY|PY|HIGHWAY|HWY|CIRCLE|CIR|SQUARE|SQ|TRAIL|TRL|ALLEY|CRESCENT|CLOSE|VIEW|VW|PIKE|LOOP|PLAZA|RIDGE|COVE|CV|CROSSING|XING)\b\.?(?:\s+(?:N|S|E|W|NE|NW|SE|SW)\b)?(?:,?\s+(?:APT|APARTMENT|SUITE|STE|UNIT|FL|#)\.?\s*[A-Z0-9-]+)?(?=[ \t]*(?:$|\r?\n|[,;)]|[ \t][A-Z0-9#]))"#, 0.6, [], [.anchorsMatchLines]),
        // A numbered road: "1234 West U.S. Hwy 50", "173 IL Rte. 2"; its short names only beside a direction or a state ("217 N. Rt. 31", "1947 CR 2700 E", not "version 2 RT 5").
        ("ADDRESS", #"\b\d{1,6}\s+(?:(?:(?:N|S|E|W|North|South|East|West|NORTH|SOUTH|EAST|WEST)\.?\s+)?(?:(?:U\.\s?S\.|US|State|STATE|[A-Z]{2})\s+)?(?:Highway|HIGHWAY|Hwy|HWY|Route|ROUTE|Rte|RTE|County Road|COUNTY ROAD)\.?|(?:(?:N|S|E|W|North|South|East|West|NORTH|SOUTH|EAST|WEST)\.?\s+|(?:U\.\s?S\.|US|State|STATE|[A-Z]{2})\s+)(?:Rt|RT|CR|FM|SR)\.?|(?:Rt|RT|CR|FM|SR)(?=\s+\d{1,5}\s+(?:N|S|E|W)\b))\s+(?:No\.?\s+)?\d{1,5}[A-Z]?\b(?:\s+(?:N|S|E|W|North|South|East|West|NORTH|SOUTH|EAST|WEST)\b)?"#, 0.6, [], []),
        // A rural route's or highway contract's box: "RR 1 Box 54", "HC 284 Box 27", "Highway Contract Route 56 Box 45C".
        ("ADDRESS", #"(?i)\b(?:RR|R\.R\.|HCR?|Rural Route|Highway Contract(?: Route)?|Hwy Contract(?: Route)?)\s*#?\s*\d+[A-Z]?\s+Box\s*#?\s*[A-Z0-9]{1,6}\b"#, 0.6, [], []),
        // A passport's, ID card's or visa's machine-readable zone: all its lines, or one (see `MachineZone`).
        ("MRZ", #"(?<![A-Za-z0-9<])(?:[A-Z0-9<]{30}(?:\r?\n|\\n|\\r\\n| )[A-Z0-9<]{30}(?:\r?\n|\\n|\\r\\n| )[A-Z0-9<]{30}|[A-Z0-9<]{44}(?:\r?\n|\\n|\\r\\n| )[A-Z0-9<]{44}|[A-Z0-9<]{36}(?:\r?\n|\\n|\\r\\n| )[A-Z0-9<]{36}|[A-Z0-9<]{44}|[A-Z0-9<]{36}|[A-Z0-9<]{30})(?![A-Za-z0-9<])"#, 0.97, [], []),
        ("US_BANK_NUMBER", #"\b\d{8,17}\b"#, 0.05, ["check", "account", "acct", "bank", "save", "debit"], []),
        ("US_DRIVER_LICENSE", #"\b(?:[A-Z]\d{1,12}|[A-Z]{1,2}\d{5,6}|[A-Z]{2}\d{3,7}|\d{2}[A-Z]{3}\d{5,6}|[A-Z]\d{13,14}|[A-Z]\d{18}|[A-Z]\d{6}R|\d{9}[A-Z]|[A-Z]{2}\d{6}[A-Z]|\d{8}[A-Z]{2}|\d{3}[A-Z]{2}\d{4}|[A-Z]\d[A-Z]\d[A-Z]|\d{7,8}[A-Z])\b"#, 0.3, ["driver", "license", "permit", "lic", "identification", "dl", "dls", "cdls", "driving"], []),
        ("US_DRIVER_LICENSE", #"\b(?:\d{6,14}|\d{16})\b"#, 0.01, ["driver", "license", "permit", "lic", "identification", "dl", "dls", "cdls", "driving"], []),
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
    /// `naming`: the words that may name an identifier, where fewer than `contextWords`.
    static func find(_ text: String, contextWords: Set<String> = [], naming: Set<String>? = nil, isCancelled: () -> Bool = { Task.isCancelled }) -> [Span] {
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
                // A day with its time of day ("[2026-09-14 14:03:05]") stamps a line or an event; one at midnight may be a birth date stored as a time.
                if entity == "DATE_OF_BIRTH", range.upperBound < length,
                   case let after = TextRanges.substring(text, range.upperBound..<min(length, range.upperBound + 6)),
                   after.range(of: #"^[ T]\d\d:\d\d"#, options: .regularExpression) != nil, !after.hasSuffix("00:00") { return }
                if entity == "SECRET", let cut = URLs.queryValueEnd(ns, range) { range = range.lowerBound..<cut }
                if entity == "EMAIL_ADDRESS", let start = addressStart(ns, range) { range = start..<range.upperBound }
                // A piece of a longer identifier ("O72" of "O72-2331-924-76") is that identifier: replaced
                // alone, it would leave the rest written as it was, so the whole is read.
                if Self.pieceKinds.contains(entity) { range = Self.whole(range, of: units) }
                let value = TextRanges.substring(text, range)
                if entity == "PERSON" && NameTagger.namesOrganisation(value) { return }
                if entity == "PARTY" {
                    let words = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    guard let first = words.first, NameLists.isFirst(first), !NameTagger.namesOrganisation(value),
                          !words.contains(where: { NameTagger.organisationWords.contains($0.lowercased()) }) else { return }
                    spans.append(Span(range: range, entity: "PERSON", score: base))
                    return
                }
                // "token": null is no secret, nor "pwd": undefined.
                if entity == "SECRET", Detector.literals.contains(value) { return }
                // An object's reference under a key an API calls its "token" ("entity_token": "P-MSBW…") unlocks nothing (see `KeyHints.fits`).
                if entity == "SECRET", let key = keyBefore(ns, range.lowerBound), KeyHints.hint(key) == "SECRET", !KeyHints.fits(key, value) { return }
                // "https://deploy:hunter2@git.example.test" holds a password and a host, no address.
                if entity == "EMAIL_ADDRESS", inURLCredentials(text, at: range.lowerBound) { return }
                // "social.example/@odalys.ferriter" is a link to a handle (see `URLs`), no address.
                if entity == "EMAIL_ADDRESS", value.contains("/@") { return }
                guard valid(value, entity: entity), !(entity == "US_SSN" && base <= 0.5 && invalidSSN(value)) else { return }
                let score = context.isDisjoint(with: contextWords) ? Context.enhanced(base, words: context, range: range, text: text) : min(1, max(0.4, base + 0.35))
                if score >= 0.4 { spans.append(Span(range: range, entity: entity, score: score)) }
            }
            for match in matches(regex, in: ns, units: units, isCancelled: isCancelled) { take(match) }
        }
        return spans + Recognizers.find(text, ns: ns, units: units, contextWords: naming ?? contextWords, isCancelled: isCancelled)
    }
    /// Kinds whose bare shapes ("A1234567", a run of digits) also fit a piece of a longer identifier.
    private static let pieceKinds: Set<String> = ["US_DRIVER_LICENSE", "US_PASSPORT", "US_BANK_NUMBER", "US_ITIN"]
    /// `range` with the pieces holding a digit that a dash joins to it on either side, up to 48 units
    /// in all; a type's code of letters ("MRN-") stays, as a record's ID keeps its prefix.
    private static func whole(_ range: Range<Int>, of units: [UInt16]) -> Range<Int> {
        func alphanumeric(_ index: Int) -> Bool {
            index >= 0 && index < units.count && ((48...57).contains(units[index]) || (65...90).contains(units[index]) || (97...122).contains(units[index]))
        }
        var lower = range.lowerBound, upper = range.upperBound
        while lower >= 2, upper - lower < 48, units[lower - 1] == 45, alphanumeric(lower - 2) {
            var start = lower - 1
            while alphanumeric(start - 1) { start -= 1 }
            guard units[start..<(lower - 1)].contains(where: { (48...57).contains($0) }) else { break }
            lower = start
        }
        while upper + 1 < units.count, upper - lower < 48, units[upper] == 45, alphanumeric(upper + 1) {
            var end = upper + 1
            while alphanumeric(end) { end += 1 }
            guard units[(upper + 1)..<end].contains(where: { (48...57).contains($0) }) else { break }
            upper = end
        }
        return lower..<upper
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
    private static let keyTail = TextPattern(#"([A-Za-z0-9_-]+)["']?\s{0,3}[:=]\s{0,3}["']?$"#)
    /// The key written just before a value: "entity_token" of `"entity_token": "P-…"`.
    static func keyBefore(_ ns: NSString, _ start: Int) -> String? {
        let from = max(0, start - 64)
        let before = ns.substring(with: NSRange(location: from, length: start - from))
        guard let match = TextRanges.matches(keyTail, in: before).last else { return nil }
        return (before as NSString).substring(with: match.range(at: 1))
    }
    /// Before a key's or a query's value: "user=", "/reset?email=", "uid=7|", "/users/".
    private static let joinedKey = TextPattern(#"^(?:/[^@\s]*[/?&=]|[A-Za-z_][A-Za-z0-9_.-]{0,31}[=|](?:[^@\s]*[=|&])?)(?=[^@/?&=|]+@)"#)
    /// Where an address read with a key, a path or a query before it starts: the marks
    /// that join them are allowed in an address's local part, but a local part written
    /// so is a key and its value ("user=ofelia@…"), not one address. Nil when it starts where read.
    private static func addressStart(_ ns: NSString, _ range: Range<Int>) -> Int? {
        let value = ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
        guard value.contains(where: { "=/?&|".contains($0) }), let match = TextRanges.matches(joinedKey, in: value).first else { return nil }
        return range.lowerBound + NSMaxRange(match.range)
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
            if prefix.last == " " || prefix.last == "-" || prefix.last == "." { continue }
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
            // No issuer's number opens with a 0, and the only cards opening with a 1 (an airline's) are 15
            // digits: an 18- or 19-digit ID opening with a 1 ("1592876430…") passing Luhn by chance is no card.
            guard let first = digits.first, first != 0, first != 1 || digits.count == 15 else { return false }
            return (13...19).contains(digits.count) && luhn(digits) && !Self.epochMilliseconds(digits)
        case "IBAN_CODE": return iban(value)
        case "MRZ": return MachineZone.isZone(value)
        case "DATE_OF_BIRTH":
            // A day of a month, written year first or last, day before or after its month.
            let parts = value.split(whereSeparator: { "-/.".contains($0) }).compactMap { Int($0) }
            guard parts.count == 3 else { return false }
            let (a, b) = parts[0] > 31 ? (parts[1], parts[2]) : (parts[0], parts[1])
            return (1...12).contains(a) && (1...31).contains(b) || (1...12).contains(b) && (1...31).contains(a)
        case "IP_ADDRESS":
            // "::" alone is the unspecified address: no host's.
            guard value.contains(where: \.isHexDigit) else { return false }
            var v4 = in_addr(); var v6 = in6_addr()
            if !value.contains("."), !value.contains(":") { return value.replacingOccurrences(of: "-", with: ".").withCString { inet_pton(AF_INET, $0, &v4) == 1 } }
            return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
        default: return true
        }
    }
    /// Only a Visa card is 13 digits, and it opens with a 4; 13 digits opening
    /// with a 1 is a time in milliseconds ("sent_at": 1668455936404).
    static func epochMilliseconds(_ digits: [Int]) -> Bool { digits.count == 13 && digits.first != 4 }
    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, digit) in digits.reversed().enumerated() {
            let doubled = i.isMultiple(of: 2) ? digit : digit * 2
            sum += doubled > 9 ? doubled - 9 : doubled
        }
        return sum.isMultiple(of: 10)
    }
    /// Each country's IBAN length: the IBAN registry's, then the countries that write one outside it.
    private static let ibanLengths: [String: Int] = ["AL": 28, "AD": 24, "AT": 20, "AZ": 28, "BH": 22, "BY": 28, "BE": 16, "BA": 20, "BR": 29, "BG": 22, "BI": 27, "CR": 22, "HR": 21, "CY": 28, "CZ": 24, "DK": 18, "DJ": 27, "DO": 28, "TL": 23, "EG": 29, "SV": 28, "EE": 20, "FO": 18, "FI": 18, "FR": 27, "GE": 22, "DE": 22, "GI": 23, "GR": 27, "GL": 18, "GT": 28, "HU": 28, "IS": 26, "IQ": 23, "IE": 22, "IL": 23, "IT": 27, "JO": 30, "KZ": 20, "XK": 20, "KW": 30, "LV": 21, "LB": 28, "LY": 25, "LI": 21, "LT": 20, "LU": 20, "MK": 19, "MT": 31, "MR": 27, "MU": 30, "MC": 27, "MD": 24, "MN": 20, "ME": 22, "NL": 18, "NI": 28, "NO": 15, "PK": 24, "PS": 29, "PL": 28, "PT": 25, "QA": 29, "RO": 24, "RU": 33, "LC": 32, "SM": 27, "ST": 25, "SA": 24, "RS": 22, "SC": 31, "SK": 24, "SI": 19, "SO": 23, "ES": 24, "SD": 18, "SE": 24, "CH": 21, "TN": 24, "TR": 26, "UA": 29, "AE": 23, "GB": 22, "VA": 22, "VG": 24, "YE": 30, "OM": 23, "FK": 18,
        "AO": 25, "BF": 28, "BJ": 28, "CF": 27, "CG": 27, "CI": 28, "CM": 27, "CV": 25, "DZ": 26, "GA": 27, "GQ": 27, "HN": 28, "IR": 26, "KM": 27, "MA": 28, "MG": 27, "ML": 28, "MZ": 25, "NE": 28, "SN": 28, "TD": 27, "TG": 28]
    static func iban(_ value: String) -> Bool {
        let raw = value.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "." }
        guard (15...34).contains(raw.count), raw.prefix(2).allSatisfy(\.isLetter), raw.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return false }
        // A country's IBANs are all one length; one of another length is none, whatever its remainder, nor is one of no country's.
        guard let length = ibanLengths[String(raw.prefix(2))], raw.count == length else { return false }
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
