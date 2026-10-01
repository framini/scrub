import Foundation
import NaturalLanguage

enum NameTagger {
    private static let lowercaseWord = TextPattern(#"\b[a-z]+\b"#)
    private static let leadingWord = TextPattern(#"^\s+\p{L}+"#)
    private static let asciiWord = TextPattern(#"[A-Za-z]+"#)
    private static let letterWord = TextPattern(#"\p{L}[\p{L}'’-]*"#)
    private static let loneLine = TextPattern(#"(?m)^[ \t]*(\p{Lu}\p{Ll}+)[ \t]*\r?$"#)
    static let organisationWords: Set<String> = ["foundation", "inc", "llc", "ltd", "corp", "company", "group", "university", "bank", "institute", "hospital", "team", "teams", "ops", "bot", "desk", "helpdesk", "office", "region", "network", "report", "folder", "notes", "billing", "support", "platform", "data", "sales", "admin", "service", "services", "department", "dept", "engineering", "finance", "marketing", "security", "alerts", "notifications", "infra", "squad", "committee", "board", "council", "staff", "center", "centre", "labs", "systems", "solutions", "partners", "government", "administration", "agency", "bureau", "records", "utility", "telco", "carrier", "credit", "education", "probate", "usps"]
    static func namesOrganisation(_ text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter }).contains { organisationWords.contains($0.lowercased()) }
    }
    static func find(_ text: String, using tagger: NLTagger, isCancelled: () -> Bool) -> [Span] {
        if !text.contains(where: { $0.isUppercase || $0.isWhitespace }) && !Names.firstFolded.contains(text.lowercased()) && !Names.lastFolded.contains(text.lowercased()) { return [] }
        var spans = tag(text, mappedTo: text, variant: false, tagger: tagger, isCancelled: isCancelled)
        let variant = titleCaseLowercaseWords(text)
        spans.append(contentsOf: tag(variant, mappedTo: text, variant: true, tagger: tagger, isCancelled: isCancelled))
        for (index, match) in TextRanges.matches(lowercaseWord, in: text).enumerated() {
            if index.isMultiple(of: 64) && isCancelled() { return spans }
            let range = match.range.location..<NSMaxRange(match.range)
            if Names.firstFolded.contains(TextRanges.substring(text, range)), cued(range, in: text) {
                spans.append(Span(range: range, entity: "PERSON", score: 0.85))
            }
        }
        spans.append(contentsOf: signOffs(in: text))
        return spans
    }
    // A known first name alone on the line after "Thanks," signs the message.
    // The model has no sentence to read it in, so it never tags it.
    private static func signOffs(in text: String) -> [Span] {
        TextRanges.matches(loneLine, in: text).compactMap { match in
            let name = match.range(at: 1)
            guard Names.unambiguousFirst.contains(TextRanges.substring(text, name.location..<NSMaxRange(name)).lowercased()) else { return nil }
            let ns = text as NSString
            var end = match.range.location
            while end > 0, let scalar = Unicode.Scalar(ns.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            guard end > 0, ns.character(at: end - 1) == 44 else { return nil }
            let line = ns.lineRange(for: NSRange(location: end - 1, length: 0))
            guard ns.substring(with: NSRange(location: line.location, length: end - line.location)).split(separator: " ").count <= 3 else { return nil }
            return Span(range: name.location..<NSMaxRange(name), entity: "PERSON", score: 0.85)
        }
    }
    private static let strongBefore: Set<String> = ["named", "called", "mr", "mrs", "ms", "dr", "contact", "owner", "customer", "patient", "employee"]
    private static let informalBefore: Set<String> = ["its", "it's", "im", "i'm", "with", "w", "spoke", "ask", "tell", "cc"]
    private static let reporting: Set<String> = ["said", "asked", "wrote", "emailed", "phoned", "called", "replied"]
    private static func cued(_ range: Range<Int>, in text: String) -> Bool {
        let value = TextRanges.substring(text, range).lowercased()
        let next = Context.words(after: range.upperBound, in: text, limit: 1, pattern: asciiWord).first?.lowercased()
        let before = Context.before(range, in: text, limit: 3)
        if !before.isDisjoint(with: strongBefore) || next.map({ reporting.contains($0) }) == true { return true }
        if Names.ambiguousFirst.contains(value) { return false }
        if next == "from" && value == TextRanges.substring(text, range) { return true }
        if !before.isDisjoint(with: informalBefore.subtracting(["with", "w"])) { return true }
        if before.contains("with") || before.contains("w") { return next == nil || next.map { reporting.contains($0) } == true }
        return false
    }
    private static func tag(_ input: String, mappedTo original: String, variant: Bool, tagger: NLTagger, isCancelled: () -> Bool) -> [Span] {
        tagger.string = input
        var result: [Span] = []
        tagger.enumerateTags(in: input.startIndex..<input.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if isCancelled() { return false }
            guard let tag, tag == .personalName || tag == .placeName else { return true }
            let lower = input.utf16.distance(from: input.utf16.startIndex, to: range.lowerBound.samePosition(in: input.utf16) ?? input.utf16.startIndex)
            let upper = input.utf16.distance(from: input.utf16.startIndex, to: range.upperBound.samePosition(in: input.utf16) ?? input.utf16.endIndex)
            var mapped = lower..<upper
            let written = TextRanges.substring(original, mapped)
            // Only the next few words matter; the rest of a long text would make each tag cost its length.
            let following = TextRanges.substring(original, mapped.upperBound..<min((original as NSString).length, mapped.upperBound + 120))
            let nextWord = TextRanges.matches(leadingWord, in: following).first.map {
                TextRanges.substring(following, $0.range.location..<NSMaxRange($0.range)).trimmingCharacters(in: .whitespaces).lowercased()
            }
            // The rest of a capitalised run names what the tagged words are part of: "Northwind Traders LLC".
            let run = following.split(separator: " ", omittingEmptySubsequences: true).prefix(4).prefix { word in
                word.first?.isUppercase == true || ["&", "and", "of"].contains(word.lowercased())
            }
            if namesOrganisation(written) || nextWord.map({ organisationWords.contains($0) }) == true
                || run.contains(where: { organisationWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }) { return true }
            if tag == .personalName { mapped = trimmedToWrittenCapitals(mapped, in: original) }
            if tag == .personalName {
                let value = TextRanges.substring(original, mapped)
                let tokens = TextRanges.matches(asciiWord, in: value)
                if tokens.count == 1 {
                    let known = Names.firstFolded.contains(value.lowercased()) || Names.lastFolded.contains(value.lowercased())
                    let cue = cued(mapped, in: original)
                    if (!known && !cue) || (Names.ambiguousFirst.contains(value.lowercased()) && !cue) || (value == value.uppercased() && value.count >= 2 && !known) { return true }
                }
            }
            if variant {
                guard tag == .personalName else { return true }
                let tokens = TextRanges.matches(asciiWord, in: TextRanges.substring(original, mapped)).map { TextRanges.substring(original, (mapped.lowerBound + $0.range.location)..<(mapped.lowerBound + NSMaxRange($0.range))).lowercased() }
                let knownFullName = tokens.count >= 2 && tokens.first.map { Names.firstFolded.contains($0) } == true
                guard knownFullName || cued(mapped, in: original) else { return true }
            }
            let found = TextRanges.substring(original, mapped)
            // Acronyms and names in capitals ("PEM", "NORTHWIND") get tagged as places.
            if tag == .placeName, found == found.uppercased(), !found.contains(" "), !Names.citiesFolded.contains(found.lowercased()) { return true }
            // "San Francisco" reads as a first name and a surname; the city list knows better.
            let isCity = tag == .personalName && Names.citiesFolded.contains(found.lowercased())
            // A country ("Canada", "United States") is where millions live; it names no one.
            if tag == .placeName, let country = Places.country(found), country != "other" { return true }
            result.append(Span(range: mapped, entity: tag == .personalName && !isCity ? "PERSON" : "LOCATION", score: tag == .personalName && !isCity ? 0.85 : 0.6))
            return true
        }
        return result
    }
    // The model sometimes joins the next word into a name ("Ana Pereira
    // called"). When the writer capitalised some of the name, the words they
    // left lowercase at either end are not part of it.
    private static func trimmedToWrittenCapitals(_ range: Range<Int>, in text: String) -> Range<Int> {
        let words = TextRanges.matches(letterWord, in: TextRanges.substring(text, range)).map { (range.lowerBound + $0.range.location)..<(range.lowerBound + NSMaxRange($0.range)) }
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
