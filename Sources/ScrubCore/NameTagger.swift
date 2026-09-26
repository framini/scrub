import Foundation
import NaturalLanguage

enum NameTagger {
    private static let organisationWords: Set<String> = ["foundation", "inc", "llc", "ltd", "corp", "company", "group", "university", "bank", "institute", "hospital"]
    static func find(_ text: String) -> [Span] {
        if !text.contains(where: { $0.isUppercase || $0.isWhitespace }) && !Names.firstFolded.contains(text.lowercased()) && !Names.lastFolded.contains(text.lowercased()) { return [] }
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
    private static let strongBefore: Set<String> = ["named", "called", "mr", "mrs", "ms", "dr", "contact", "owner", "customer", "patient", "employee"]
    private static let informalBefore: Set<String> = ["its", "it's", "im", "i'm", "with", "w", "spoke", "ask", "tell", "cc"]
    private static let reporting: Set<String> = ["said", "asked", "wrote", "emailed", "phoned", "called", "replied"]
    private static func cued(_ range: Range<Int>, in text: String) -> Bool {
        let value = TextRanges.substring(text, range).lowercased()
        let suffix = TextRanges.substring(text, range.upperBound..<(text as NSString).length)
        let next = TextRanges.matches(#"[A-Za-z]+"#, in: suffix).first.map { TextRanges.substring(suffix, $0.range.location..<NSMaxRange($0.range)).lowercased() }
        let before = Context.before(range, in: text, limit: 3)
        if !before.isDisjoint(with: strongBefore) || next.map({ reporting.contains($0) }) == true { return true }
        if Names.ambiguousFirst.contains(value) { return false }
        if next == "from" && value == TextRanges.substring(text, range) { return true }
        if !before.isDisjoint(with: informalBefore.subtracting(["with", "w"])) { return true }
        if before.contains("with") || before.contains("w") { return next == nil || next.map { reporting.contains($0) } == true }
        return false
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
            var mapped = lower..<upper
            let written = TextRanges.substring(original, mapped)
            let following = TextRanges.substring(original, mapped.upperBound..<(original as NSString).length)
            let nextWord = TextRanges.matches(#"^\s+\p{L}+"#, in: following).first.map {
                TextRanges.substring(following, $0.range.location..<NSMaxRange($0.range)).trimmingCharacters(in: .whitespaces).lowercased()
            }
            if written.split(whereSeparator: { !$0.isLetter }).contains(where: { organisationWords.contains($0.lowercased()) }) || nextWord.map({ organisationWords.contains($0) }) == true { return true }
            if tag == .personalName { mapped = trimmedToWrittenCapitals(mapped, in: original) }
            if tag == .personalName {
                let value = TextRanges.substring(original, mapped)
                let tokens = TextRanges.matches(#"[A-Za-z]+"#, in: value)
                if tokens.count == 1 {
                    let known = Names.firstFolded.contains(value.lowercased()) || Names.lastFolded.contains(value.lowercased())
                    let cue = cued(mapped, in: original)
                    if (!known && !cue) || (Names.ambiguousFirst.contains(value.lowercased()) && !cue) || (value == value.uppercased() && value.count >= 2 && !known) { return true }
                }
            }
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
    // The model sometimes joins the next word into a name ("Ana Pereira
    // called"). When the writer capitalised some of the name, the words they
    // left lowercase at either end are not part of it.
    private static func trimmedToWrittenCapitals(_ range: Range<Int>, in text: String) -> Range<Int> {
        let words = TextRanges.matches(#"\p{L}[\p{L}'’-]*"#, in: TextRanges.substring(text, range)).map { (range.lowerBound + $0.range.location)..<(range.lowerBound + NSMaxRange($0.range)) }
        let capitalised = words.filter { TextRanges.substring(text, $0).first?.isUppercase == true }
        guard let first = capitalised.first, let last = capitalised.last else { return range }
        return first.lowerBound..<last.upperBound
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
