import Foundation
import NaturalLanguage

public final class Detector {
    private let systemDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.address.rawValue)
    // Creating a tagger loads its model; one per document, not one per value.
    private let tagger = NLTagger(tagSchemes: [.nameType])
    private let isCancelled: @Sendable () -> Bool
    public init() { isCancelled = { Task.isCancelled } }
    init(isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
    public func find(_ text: String, key: String? = nil, gazetteer: [String: Set<String>] = [:], contextWords: Set<String> = []) -> [Span] {
        find(text, key: key, matcher: GazetteerMatcher(gazetteer), contextWords: contextWords)
    }
    func find(_ text: String, key: String? = nil, matcher: GazetteerMatcher, contextWords: Set<String> = []) -> [Span] {
        autoreleasepool { combined(base(text, key: key, contextWords: contextWords), text: text, matcher: matcher) }
    }
    func base(_ text: String, key: String? = nil, contextWords: Set<String> = []) -> [Span] {
        autoreleasepool {
            if let entity = KeyHints.hint(key), !text.isEmpty { return [Span(range: 0..<(text as NSString).length, entity: entity, score: 1)] }
            if KeyHints.isRole(key), let name = Self.writtenName(text) { return [Span(range: name, entity: "PERSON", score: 1)] }
            // A time zone ("America/New_York") names a region, not where someone lives.
            if text.contains("/"), text.count < 64, !TextRanges.matches(Self.timeZone, in: text).isEmpty { return [] }
            let plainWord = text.allSatisfy { $0.isASCII && $0.isLowercase }
                && !Names.firstFolded.contains(text) && !Names.lastFolded.contains(text)
            guard !plainWord else { return [] }
            var spans = Patterns.find(text, contextWords: Set(KeyHints.words(key)).union(contextWords), isCancelled: isCancelled)
            spans.append(contentsOf: system(text))
            spans.append(contentsOf: NameTagger.find(text, using: tagger, isCancelled: isCancelled))
            spans = Self.addressed(spans, in: text)
            // A title alone ("Mr.", "Ms") names no one.
            spans.removeAll { span in
                span.entity == "PERSON" && Self.titles.contains(TextRanges.substring(text, span.range).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
            }
            // A timestamp, ID or setting is read as written: its date is no birth
            // date, its digits no phone number, its region no place.
            if KeyHints.isStructural(key) { return spans.filter(Self.certain) }
            let keyed = KeyedValues.scan(text, isCancelled: isCancelled)
            var quiet = keyed.structural
            if text.contains("/") { quiet += TextRanges.matches(Self.zoneAnywhere, in: text).map { $0.range.location..<NSMaxRange($0.range) } }
            // No word inside a UUID is a name ("4ae18f24-cabe-…").
            if text.contains("-") { quiet += TextRanges.matches(Self.uuid, in: text).map { $0.range.location..<NSMaxRange($0.range) } }
            if !quiet.isEmpty {
                spans = spans.filter { span in Self.certain(span) || !quiet.contains { $0.overlaps(span.range) } }
            }
            spans.append(contentsOf: keyed.spans)
            return spans
        }
    }
    /// Found by what the value is, whatever it sits under: an email, a card that
    /// passes its check digit, an IBAN, an IP address, a key with a known prefix.
    private static func certain(_ span: Span) -> Bool {
        ["EMAIL_ADDRESS", "CREDIT_CARD", "IBAN_CODE", "IP_ADDRESS", "SECRET"].contains(span.entity) || span.entity == "US_SSN" && span.score >= 0.85
    }
    private static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "madam"]
    private static let uuid = TextPattern(#"(?i)(?<![0-9a-f-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f-])"#)
    private static let zoneAnywhere = TextPattern(#"(?<![A-Za-z])(?:Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific|Etc)/[A-Za-z_+-]+(?:/[A-Za-z_+-]+)?"#)
    func combined(_ base: [Span], text: String, matcher: GazetteerMatcher) -> [Span] {
        autoreleasepool {
            if let first = base.first, first.score == 1, first.range == 0..<(text as NSString).length,
               base.count == 1 { return base }
            var spans = base
            let ns = text as NSString
            func capital(_ index: Int) -> Bool {
                index < ns.length && Unicode.Scalar(ns.character(at: index)).map(CharacterSet.uppercaseLetters.contains) == true
            }
            // A lowercase name part counts only as the head of a camelCase word ("mariaGonzalez").
            for match in matcher.matcher.matches(in: text, accepting: { wholeWord($0, in: text) })
            where !matcher.capitalOnly[match.index] || capital(match.range.lowerBound) || capital(match.range.upperBound) {
                spans.append(Span(range: match.range, entity: matcher.entities[match.index], score: 0.95))
            }
            return Self.resolve(spans)
        }
    }
    private static let placeTail = TextPattern(#"^,[ \t]*([A-Z]{2}\b|[A-Z][a-z]+(?: [A-Z][a-z]+){0,3})(?:[ \t,]+(\d{5}(?:-\d{4})?|[A-Za-z]\d[A-Za-z] ?\d[A-Za-z]\d)\b)?"#)
    private static let cityLine = TextPattern(#"(?<![\p{L}-])(\p{Lu}[\p{Ll}'’.-]+(?: \p{Lu}[\p{Ll}'’.-]+){0,2}), ([A-Z]{2,3}) (\d{5}(?:-\d{4})?|[A-Z]\d[A-Z] ?\d[A-Z]\d|\d{4})(?![\w-])"#)
    private static let addressee = TextPattern(#"(\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*){1,4})[ \t]*(?:,|\r?\n)[ \t]*$"#)
    private static let labelWords: Set<String> = ["ship", "to", "bill", "attn", "attention", "deliver", "send", "mail", "address", "customer", "name", "dear", "from", "care", "of", "c/o", "recipient", "sold", "remit"]
    /// Written addresses carry more than the parts found on their own. A place
    /// takes the region and postcode after it ("Boise, ID 83702"), and the
    /// capitalised words before a street address ("Oluwaseun Brightwater,
    /// 4821 Juniper Hollow Rd") are the person it is for.
    static func addressed(_ spans: [Span], in text: String) -> [Span] {
        var result = spans
        let ns = text as NSString
        for (index, span) in spans.enumerated() where span.entity == "LOCATION" {
            let rest = ns.substring(with: NSRange(location: span.range.upperBound, length: min(48, ns.length - span.range.upperBound)))
            guard let match = TextRanges.matches(placeTail, in: rest).first else { continue }
            let region = (rest as NSString).substring(with: match.range(at: 1))
            guard Places.region(region) != nil else { continue }
            result[index] = Span(range: span.range.lowerBound..<(span.range.upperBound + NSMaxRange(match.range)), entity: "LOCATION", score: max(span.score, 0.8))
        }
        // "Boise, ID 83702" and "Laval, QC H7N 5H9" are a place however the sentence around them reads.
        if text.contains(",") {
            for match in TextRanges.matches(cityLine, in: text) {
                let region = ns.substring(with: match.range(at: 2)), postal = ns.substring(with: match.range(at: 3))
                guard let known = Places.region(region), Places.country(postal: postal) == known.country else { continue }
                result.append(Span(range: match.range.location..<NSMaxRange(match.range), entity: "LOCATION", score: 0.85))
            }
        }
        for span in spans where span.entity == "ADDRESS" && span.range.lowerBound > 0 {
            let start = max(0, span.range.lowerBound - 96)
            let before = ns.substring(with: NSRange(location: start, length: span.range.lowerBound - start))
            guard let match = TextRanges.matches(addressee, in: before).first else { continue }
            let window = before as NSString
            var words = window.substring(with: match.range(at: 1)).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var from = match.range(at: 1).location
            while let first = words.first, labelWords.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":."))) {
                from = NSMaxRange(window.range(of: words.removeFirst(), range: NSRange(location: from, length: window.length - from)))
            }
            let name = words.joined(separator: " ")
            guard words.count >= 2, !NameTagger.namesOrganisation(name), !Names.citiesFolded.contains(name.lowercased()) else { continue }
            let found = window.range(of: words[0], range: NSRange(location: from, length: window.length - from)).location
            guard found != NSNotFound else { continue }
            let end = start + NSMaxRange(match.range(at: 1))
            result.append(Span(range: (start + found)..<end, entity: "PERSON", score: 0.9))
        }
        return result
    }
    private static let timeZone = TextPattern(#"^\s*(?i:africa|america|antarctica|arctic|asia|atlantic|australia|europe|indian|pacific|etc)/[A-Za-z_+-]+(?:/[A-Za-z_+-]+)?\s*$"#)
    private static let decimal = TextPattern(#"^[-+]?\d+\.\d+$"#)
    private static let nameShape = TextPattern(#"^\s*(\p{Lu}[\p{L}'’.-]*(?:\s+\p{Lu}[\p{L}'’.-]*){1,3}|\p{Lu}[\p{L}'’.-]*,\s*\p{Lu}[\p{L}'’.-]*(?:\s+\p{Lu}[\p{L}'’.-]*)?)\s*(?:\([^()]*\))?\s*$"#)
    private static let loneFirst = TextPattern(#"^\s*(\p{Lu}\p{Ll}+)\s*$"#)
    /// The range of a value written as a name: two to four capitalised words, "Last, First",
    /// either with a trailing note like "(Support)", or a known first name alone.
    static func writtenName(_ text: String) -> Range<Int>? {
        let match = TextRanges.matches(nameShape, in: text).first
            ?? TextRanges.matches(loneFirst, in: text).first.flatMap { match in
                Names.unambiguousFirst.contains(TextRanges.substring(text, match.range(at: 1).location..<NSMaxRange(match.range(at: 1))).lowercased()) ? match : nil
            }
        guard let match else { return nil }
        let range = match.range(at: 1).location..<NSMaxRange(match.range(at: 1))
        return NameTagger.namesOrganisation(TextRanges.substring(text, range)) ? nil : range
    }
    private func system(_ text: String) -> [Span] {
        guard let detector = systemDetector else { return [] }
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        return matches.compactMap { match in
            let entity: String
            let score: Double
            switch match.resultType {
            case .phoneNumber:
                let value = TextRanges.substring(text, match.range.location..<NSMaxRange(match.range))
                // A coordinate like "-122.4443" is no phone number.
                guard TextRanges.matches(Self.decimal, in: value).isEmpty else { return nil }
                // Ten digits from 1 are a Unix time (2001 to 2033), never a North
                // American number, whose area code starts from 2.
                if value.count == 10 || value.count == 13, value.first == "1", value.allSatisfy({ $0.isASCII && $0.isNumber }) { return nil }
                // A bare run of digits may as well be an account, SSN or ID, so its
                // stand-in keeps the digits instead of becoming "+1 555-…".
                entity = value.allSatisfy(\.isNumber) ? "ID_NUMBER" : "PHONE_NUMBER"; score = 0.75
            case .address: entity = "ADDRESS"; score = 0.6
            default: return nil
            }
            return Span(range: match.range.location..<NSMaxRange(match.range), entity: entity, score: score)
        }
    }
    private func wholeWord(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        return !TextRanges.joinsWord(ns, at: range.lowerBound, underscore: true) && !TextRanges.joinsWord(ns, at: range.upperBound, underscore: true)
    }
    static func resolve(_ spans: [Span]) -> [Span] {
        let ordered = spans.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.range.count != b.range.count { return a.range.count > b.range.count }
            return a.range.lowerBound < b.range.lowerBound
        }
        var kept: [Span] = []
        for (index, span) in ordered.enumerated() {
            if index.isMultiple(of: 64) && Task.isCancelled { return kept }
            var low = 0, high = kept.count
            while low < high {
                let middle = (low + high) / 2
                if kept[middle].range.lowerBound < span.range.lowerBound { low = middle + 1 }
                else { high = middle }
            }
            let insertion = low
            var first = insertion
            if first > 0 && kept[first - 1].range.overlaps(span.range) { first -= 1 }
            var end = first
            while end < kept.count && kept[end].range.overlaps(span.range) { end += 1 }
            if first == end {
                kept.insert(span, at: insertion)
            } else if kept[first..<end].allSatisfy({
                span.range.lowerBound <= $0.range.lowerBound && span.range.upperBound >= $0.range.upperBound
                    && span.range != $0.range && span.entity != $0.entity
            }) {
                kept.replaceSubrange(first..<end, with: [span])
            }
        }
        return kept
    }
}

struct GazetteerMatcher {
    static let supportedEntities = ["FIRST_NAME", "LAST_NAME", "PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER"]
    let matcher: Matcher
    let entities: [String]
    let capitalOnly: [Bool]

    init(_ gazetteer: [String: Set<String>], nameParts: Set<String> = [], isCancelled: () -> Bool = { false }) {
        let (literals, labels) = Self.entries(gazetteer, isCancelled: isCancelled)
        matcher = Matcher(literals, isCancelled: isCancelled)
        entities = labels
        capitalOnly = zip(literals, labels).map { $1 == "PERSON" && nameParts.contains($0) }
    }

    private static func entries(_ gazetteer: [String: Set<String>], isCancelled: () -> Bool) -> ([String], [String]) {
        var literals: [String] = []
        var labels: [String] = []
        var seen: Set<[UInt16]> = []
        for entity in supportedEntities {
            for (index, entry) in (gazetteer[entity] ?? []).sorted().enumerated() where !entry.isEmpty {
                if index.isMultiple(of: 4096) && isCancelled() { return (literals, labels) }
                if seen.insert(Matcher.fold(entry)).inserted {
                    literals.append(entry)
                    labels.append(entity)
                }
            }
        }
        return (literals, labels)
    }
}
