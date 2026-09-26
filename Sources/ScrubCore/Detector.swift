import Foundation

public final class Detector {
    private let systemDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.address.rawValue)
    public init() {}
    public func find(_ text: String, key: String? = nil, gazetteer: [String: Set<String>] = [:], contextWords: Set<String> = []) -> [Span] {
        find(text, key: key, matcher: GazetteerMatcher(gazetteer), contextWords: contextWords)
    }
    func find(_ text: String, key: String? = nil, matcher: GazetteerMatcher, contextWords: Set<String> = []) -> [Span] {
        if let entity = KeyHints.hint(key), !text.isEmpty { return [Span(range: 0..<(text as NSString).length, entity: entity, score: 1)] }
        let plainWord = text.allSatisfy { $0.isASCII && $0.isLowercase }
            && !Names.firstFolded.contains(text) && !Names.lastFolded.contains(text)
        var spans: [Span] = []
        if !plainWord {
            spans = Patterns.find(text, contextWords: Set(KeyHints.words(key)).union(contextWords))
            spans.append(contentsOf: system(text))
            spans.append(contentsOf: NameTagger.find(text))
        }
        for match in matcher.matcher.matches(in: text) where wholeWord(match.range, in: text) {
            let entity = matcher.entities[match.index]
            spans.append(Span(range: match.range, entity: entity, score: 0.95))
        }
        return Self.resolve(spans)
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
        func word(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        return !word(range.lowerBound - 1) && !word(range.upperBound)
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
            let conflicts = kept.indices.filter { kept[$0].range.overlaps(span.range) }
            if conflicts.isEmpty { kept.append(span); continue }
            if conflicts.allSatisfy({ span.range.lowerBound <= kept[$0].range.lowerBound && span.range.upperBound >= kept[$0].range.upperBound && span.range != kept[$0].range && span.entity != kept[$0].entity }) {
                kept.removeAll { span.range.overlaps($0.range) }
                kept.append(span)
            }
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

struct GazetteerMatcher {
    let matcher: Matcher
    let entities: [String]

    init(_ gazetteer: [String: Set<String>]) {
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
        matcher = Matcher(literals)
        entities = labels
    }
}
