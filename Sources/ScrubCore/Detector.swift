import Foundation

public final class Detector {
    public init() {}
    public func find(_ text: String, key: String? = nil, gazetteer: [String: Set<String>] = [:]) -> [Span] {
        if let entity = KeyHints.hint(key), !text.isEmpty { return [Span(range: 0..<(text as NSString).length, entity: entity, score: 1)] }
        var spans = Patterns.find(text)
        spans.append(contentsOf: system(text))
        spans.append(contentsOf: NameTagger.find(text))
        for (entity, entries) in gazetteer where ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER"].contains(entity) {
            for entry in entries where !entry.isEmpty {
                for range in TextRanges.ranges(of: entry, in: text) where wholeWord(range, in: text) {
                    spans.append(Span(range: range, entity: entity, score: 0.95))
                }
            }
        }
        return Self.resolve(spans)
    }
    private func system(_ text: String) -> [Span] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.address.rawValue) else { return [] }
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
        for span in ordered where !kept.contains(where: { $0.range.overlaps(span.range) }) { kept.append(span) }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
