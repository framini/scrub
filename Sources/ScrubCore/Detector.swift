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
            let plainWord = text.allSatisfy { $0.isASCII && $0.isLowercase }
                && !Names.firstFolded.contains(text) && !Names.lastFolded.contains(text)
            guard !plainWord else { return [] }
            var spans = Patterns.find(text, contextWords: Set(KeyHints.words(key)).union(contextWords), isCancelled: isCancelled)
            spans.append(contentsOf: system(text))
            spans.append(contentsOf: NameTagger.find(text, using: tagger, isCancelled: isCancelled))
            return spans
        }
    }
    func combined(_ base: [Span], text: String, matcher: GazetteerMatcher) -> [Span] {
        autoreleasepool {
            if let first = base.first, first.score == 1, first.range == 0..<(text as NSString).length,
               base.count == 1 { return base }
            var spans = base
            for match in matcher.matcher.matches(in: text, accepting: { wholeWord($0, in: text) }) {
                spans.append(Span(range: match.range, entity: matcher.entities[match.index], score: 0.95))
            }
            return Self.resolve(spans)
        }
    }
    private func system(_ text: String) -> [Span] {
        guard let detector = systemDetector else { return [] }
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        return matches.compactMap { match in
            let entity: String
            let score: Double
            switch match.resultType {
            case .phoneNumber: entity = "PHONE_NUMBER"; score = 0.75
            case .address: entity = "ADDRESS"; score = 0.6
            default: return nil
            }
            return Span(range: match.range.location..<NSMaxRange(match.range), entity: entity, score: score)
        }
    }
    private func wholeWord(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        func word(before index: Int) -> Bool {
            guard index > 0 else { return false }
            let end = index - 1
            let unit = ns.character(at: end)
            let start = (0xDC00...0xDFFF).contains(unit) && end > 0 ? end - 1 : end
            guard let scalar = String(ns.substring(with: NSRange(location: start, length: index - start))).unicodeScalars.first else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        func word(after index: Int) -> Bool {
            guard index < ns.length else { return false }
            let unit = ns.character(at: index)
            let length = (0xD800...0xDBFF).contains(unit) && index + 1 < ns.length ? 2 : 1
            guard let scalar = String(ns.substring(with: NSRange(location: index, length: length))).unicodeScalars.first else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        return !word(before: range.lowerBound) && !word(after: range.upperBound)
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
    let matcher: Matcher
    let entities: [String]

    init(_ gazetteer: [String: Set<String>]) {
        let (literals, labels) = Self.entries(gazetteer)
        matcher = Matcher(literals)
        entities = labels
    }

    private static func entries(_ gazetteer: [String: Set<String>]) -> ([String], [String]) {
        var literals: [String] = []
        var labels: [String] = []
        var seen: Set<[UInt16]> = []
        for entity in ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER"] {
            for entry in (gazetteer[entity] ?? []).sorted() where !entry.isEmpty {
                if seen.insert(Matcher.fold(entry)).inserted {
                    literals.append(entry)
                    labels.append(entity)
                }
            }
        }
        return (literals, labels)
    }
}
