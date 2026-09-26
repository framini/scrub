import Foundation
import NaturalLanguage

enum NameTagger {
    static func find(_ text: String) -> [Span] {
        var spans = tag(text, mappedTo: text, variant: false)
        let variant = titleCaseLowercaseWords(text)
        spans.append(contentsOf: tag(variant, mappedTo: text, variant: true))
        // Apple's model misses some lowercase names even title-cased. A known
        // first name counts only with a cue nearby: many are also ordinary
        // words ("mark", "grace", "frank").
        for match in TextRanges.matches(#"\b[a-z]+\b"#, in: text) {
            let range = match.range.location..<NSMaxRange(match.range)
            if Names.firstFolded.contains(TextRanges.substring(text, range)), cued(range, in: text) {
                spans.append(Span(range: range, entity: "PERSON", score: 0.85))
            }
        }
        return spans
    }
    private static func cued(_ range: Range<Int>, in text: String) -> Bool {
        !Context.before(range, in: text, limit: 3).union(Context.after(range, in: text, limit: 3)).isDisjoint(with: Context.name)
    }
    private static func tag(_ input: String, mappedTo original: String, variant: Bool) -> [Span] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = input
        var result: [Span] = []
        tagger.enumerateTags(in: input.startIndex..<input.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            guard let tag, tag == .personalName || tag == .placeName else { return true }
            let lower = input.utf16.distance(from: input.utf16.startIndex, to: range.lowerBound.samePosition(in: input.utf16) ?? input.utf16.startIndex)
            let upper = input.utf16.distance(from: input.utf16.startIndex, to: range.upperBound.samePosition(in: input.utf16) ?? input.utf16.endIndex)
            let mapped = lower..<upper
            if variant {
                guard tag == .personalName else { return true }
                guard cued(mapped, in: original) else { return true }
            }
            result.append(Span(range: mapped, entity: tag == .personalName ? "PERSON" : "LOCATION", score: tag == .personalName ? 0.85 : 0.6))
            return true
        }
        return result
    }
    private static func titleCaseLowercaseWords(_ text: String) -> String {
        var result = text
        for match in TextRanges.matches(#"\b[a-z]+\b"#, in: text).reversed() {
            let range = match.range.location..<NSMaxRange(match.range)
            let word = TextRanges.substring(text, range)
            result = TextRanges.replace(result, range, with: word.prefix(1).uppercased() + word.dropFirst())
        }
        return result
    }
}
