import Foundation
import NaturalLanguage

enum NameTagger {
    static func find(_ text: String) -> [Span] {
        var spans = tag(text, mappedTo: text, variant: false)
        let variant = titleCaseLowercaseWords(text)
        spans.append(contentsOf: tag(variant, mappedTo: text, variant: true))
        for (index, match) in TextRanges.matches(#"\b[a-z]+\b"#, in: text).enumerated() {
            if index.isMultiple(of: 64) && Task.isCancelled { return spans }
            let range = match.range.location..<NSMaxRange(match.range)
            if Names.firstFolded.contains(TextRanges.substring(text, range)), cued(range, in: text) {
                spans.append(Span(range: range, entity: "PERSON", score: 0.85))
            }
        }
        return spans
    }
    private static func cued(_ range: Range<Int>, in text: String) -> Bool {
        if !Context.before(range, in: text, limit: 3).isDisjoint(with: Context.name) { return true }
        let suffix = TextRanges.substring(text, range.upperBound..<(text as NSString).length)
        guard let next = TextRanges.matches(#"[A-Za-z]+"#, in: suffix).first else { return false }
        let word = TextRanges.substring(suffix, next.range.location..<NSMaxRange(next.range)).lowercased()
        return ["called", "said", "asked", "wrote", "emailed", "phoned"].contains(word)
    }
    private static func tag(_ input: String, mappedTo original: String, variant: Bool) -> [Span] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = input
        var result: [Span] = []
        tagger.enumerateTags(in: input.startIndex..<input.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if Task.isCancelled { return false }
            guard let tag, tag == .personalName || tag == .placeName else { return true }
            let lower = input.utf16.distance(from: input.utf16.startIndex, to: range.lowerBound.samePosition(in: input.utf16) ?? input.utf16.startIndex)
            let upper = input.utf16.distance(from: input.utf16.startIndex, to: range.upperBound.samePosition(in: input.utf16) ?? input.utf16.endIndex)
            let mapped = lower..<upper
            if variant {
                guard tag == .personalName else { return true }
                let tokens = TextRanges.matches(#"[A-Za-z]+"#, in: TextRanges.substring(original, mapped)).map { TextRanges.substring(original, (mapped.lowerBound + $0.range.location)..<(mapped.lowerBound + NSMaxRange($0.range))).lowercased() }
                let knownFullName = tokens.count >= 2 && tokens.first.map { Names.firstFolded.contains($0) } == true
                guard knownFullName || cued(mapped, in: original) else { return true }
            }
            result.append(Span(range: mapped, entity: tag == .personalName ? "PERSON" : "LOCATION", score: tag == .personalName ? 0.85 : 0.6))
            return true
        }
        return result
    }
    static func titleCaseLowercaseWords(_ text: String) -> String {
        var units = Array(text.utf16)
        func word(_ value: UInt16) -> Bool { (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) || value == 95 }
        for index in units.indices where (97...122).contains(units[index]) {
            if index == 0 || !word(units[index - 1]) { units[index] -= 32 }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
