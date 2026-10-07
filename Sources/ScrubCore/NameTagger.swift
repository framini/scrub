import Foundation
import NaturalLanguage

enum NameTagger {
    private static let lowercaseWord = TextPattern(#"\b[a-z]+\b"#)
    private static let leadingWord = TextPattern(#"^\s+\p{L}+"#)
    private static let asciiWord = TextPattern(#"[A-Za-z]+"#)
    private static let letterWord = TextPattern(#"\p{L}[\p{L}'’-]*"#)
    private static let loneLine = TextPattern(#"(?m)^[ \t]*(\p{Lu}\p{Ll}+)[ \t]*\r?$"#)
    static let organisationWords: Set<String> = ["foundation", "inc", "llc", "ltd", "corp", "company", "group", "university", "bank", "institute", "hospital", "team", "teams", "ops", "bot", "desk", "helpdesk", "office", "region", "network", "report", "folder", "notes", "billing", "support", "platform", "data", "sales", "admin", "service", "services", "department", "dept", "engineering", "finance", "marketing", "security", "alerts", "notifications", "infra", "squad", "committee", "board", "council", "staff", "center", "centre", "labs", "systems", "solutions", "partners", "government", "administration", "agency", "bureau", "records", "utility", "telco", "carrier", "credit", "education", "probate", "usps", "holdings", "consulting", "associates", "llp", "plc", "gmbh", "industries", "enterprises"]
    /// What a firm says it does, after the name it trades under ("Fernhill Robotics", "Halberd Capital"):
    /// an organisation's word only written with its capital, as "shipping" or "capital" in a sentence is not.
    static let tradeWords: Set<String> = ["robotics", "capital", "analytics", "logistics", "supply", "supplies", "bakery", "healthcare", "software", "technologies", "ventures", "pharmaceuticals", "insurance", "realty", "freight", "manufacturing", "investments", "advisors", "advisory", "studios", "aerospace", "biosciences", "therapeutics", "outfitters", "brewing", "brewery", "motors", "airlines", "shipping", "trading", "traders", "wholesale", "telecom", "telecoms", "retail", "utilities", "energy", "foods", "pharmacy", "payments", "lending", "mortgage", "mortgages", "media", "health"]
    static func namesOrganisation(_ text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter }).contains { organisationWords.contains($0.lowercased()) || $0.first?.isUppercase == true && tradeWords.contains($0.lowercased()) }
    }
    /// Whether the words at `range` name an organisation: they hold an
    /// organisation word, the next word is one ("Okafor Logistics"), or the
    /// capitalised run they start ends in one ("Northwind Traders LLC").
    static func partOfOrganisation(_ range: Range<Int>, in text: String) -> Bool {
        // Only the next few words matter; the rest of a long text would make each check cost its length.
        let following = TextRanges.substring(text, range.upperBound..<min((text as NSString).length, range.upperBound + 120))
        let written = TextRanges.matches(leadingWord, in: following).first.map {
            TextRanges.substring(following, $0.range.location..<NSMaxRange($0.range)).trimmingCharacters(in: .whitespaces)
        }
        let nextWord = written.map { $0.first?.isUppercase == true && tradeWords.contains($0.lowercased()) ? "company" : $0.lowercased() }
        // The run stops at the line's end; "L.L.C." and "Inc." read as "llc" and "inc".
        let line = following.prefix { !$0.isNewline }
        let run = line.split(whereSeparator: \.isWhitespace).prefix(4).prefix { word in
            word.first?.isUppercase == true || ["&", "and", "of"].contains(word.lowercased())
        }
        // After a comma only a legal suffix continues the name ("Tamsley II, L.L.C."):
        // "Ms Lind, Home Office" is a person and her employer.
        let suffixed = line.range(of: #"^(?:[ \t]+[IVX]{1,3}|[ \t]+[A-Z])?,[ \t]*(?i:l\.?l\.?c|inc|ltd|corp|co|plc|gmbh|l\.?l\.?p|l\.?p|limited|incorporated)\b"#, options: .regularExpression) != nil
        return namesOrganisation(TextRanges.substring(text, range)) || nextWord.map({ organisationWords.contains($0) }) == true || suffixed
            || run.contains(where: { organisationWords.contains($0.lowercased().filter(\.isLetter)) || $0.first?.isUppercase == true && tradeWords.contains($0.lowercased().filter(\.isLetter)) })
    }
    /// Person and place names in `text`. What the tagger reads as an
    /// organisation goes into `organisations`, so a guess made elsewhere
    /// ("Morgan Stanley" as two names) does not overrule it.
    static func find(_ text: String, using tagger: NLTagger, organisations: inout [Range<Int>], isCancelled: () -> Bool) -> [Span] {
        if !text.contains(where: { $0.isUppercase || $0.isWhitespace }) && !Names.firstFolded.contains(text.lowercased()) && !Names.lastFolded.contains(text.lowercased()) { return [] }
        var spans = tag(text, mappedTo: text, variant: false, tagger: tagger, organisations: &organisations, isCancelled: isCancelled)
        // Each pass below reads the whole text before it can look again.
        if isCancelled() { return spans }
        let variant = titleCaseLowercaseWords(text)
        var ignored: [Range<Int>] = []
        spans.append(contentsOf: tag(variant, mappedTo: text, variant: true, tagger: tagger, organisations: &ignored, isCancelled: isCancelled))
        if isCancelled() { return spans }
        for (index, match) in TextRanges.matches(lowercaseWord, in: text).enumerated() {
            if index.isMultiple(of: 64) && isCancelled() { return spans }
            let range = match.range.location..<NSMaxRange(match.range)
            if Names.firstFolded.contains(TextRanges.substring(text, range)), cued(range, in: text) {
                // A name opening a handle ("maria.gonzalez", "maria_g") is the whole handle's,
                // so the rest of it goes too; one in a file's name ("maria-cli.js") is no one's.
                if let handle = handle(around: range, in: text) {
                    if let span = handle { spans.append(span) }
                    continue
                }
                spans.append(Span(range: range, entity: "PERSON", score: 0.85))
            }
        }
        spans.append(contentsOf: signOffs(in: text))
        return spans
    }
    /// The handle a name is joined into by a dot, an underscore or a dash, as a span (a person's
    /// where only names are joined), or nil inside where it names a file; nil (no handle) where
    /// the name stands alone or in an email.
    private static func handle(around range: Range<Int>, in text: String) -> Span?? {
        let ns = text as NSString
        func joins(_ unit: unichar) -> Bool { unit < 128 && (CharacterSet.alphanumerics.contains(Unicode.Scalar(unit)!) || unit == 46 || unit == 95 || unit == 45) }
        var start = range.lowerBound, end = range.upperBound
        while start > 0, joins(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, joins(ns.character(at: end)) { end += 1 }
        // A sentence's full stop or a dash closing it is no part of the handle.
        while end > range.upperBound, [46, 45].contains(ns.character(at: end - 1)) { end -= 1 }
        while start < range.lowerBound, [46, 45].contains(ns.character(at: start)) { start += 1 }
        guard start < range.lowerBound || end > range.upperBound else { return nil }
        if start > 0, [64, 47].contains(ns.character(at: start - 1)) || end < ns.length && ns.character(at: end) == 64 { return nil }
        let token = ns.substring(with: NSRange(location: start, length: end - start))
        if let dot = token.lastIndex(of: "."), ContextStage.fileExtensions.contains(token[token.index(after: dot)...].lowercased()) { return .some(nil) }
        // Names joined by a dash are one person's ("maria-jose").
        let parts = token.split(separator: "-")
        if !token.contains(where: { $0 == "." || $0 == "_" || $0.isNumber }), parts.count > 1,
           parts.allSatisfy({ Names.firstFolded.contains($0.lowercased()) || Names.lastFolded.contains($0.lowercased()) }) {
            return .some(Span(range: start..<end, entity: "PERSON", score: 0.85))
        }
        return .some(Span(range: start..<end, entity: "USERNAME", score: 0.85))
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
    private static let articles: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "our", "your", "my", "its", "their", "every", "each", "some", "any", "no"]
    private static func cued(_ range: Range<Int>, in text: String) -> Bool {
        let value = TextRanges.substring(text, range).lowercased()
        let next = Context.words(after: range.upperBound, in: text, limit: 1, pattern: asciiWord).first?.lowercased()
        let before = Context.before(range, in: text, limit: 3)
        // "saw an amber alert", "the will power": after an article a word is a thing, whatever cue stands further back.
        if let previous = Context.words(before: range.lowerBound, in: text, limit: 1, pattern: asciiWord).first?.lowercased(), articles.contains(previous) { return false }
        if !before.isDisjoint(with: strongBefore) || next.map({ reporting.contains($0) }) == true { return true }
        if Names.ambiguousFirst.contains(value) { return false }
        if next == "from" && value == TextRanges.substring(text, range) { return true }
        if !before.isDisjoint(with: informalBefore.subtracting(["with", "w"])) { return true }
        if before.contains("with") || before.contains("w") { return next == nil || next.map { reporting.contains($0) } == true }
        return false
    }
    private static func tag(_ input: String, mappedTo original: String, variant: Bool, tagger: NLTagger, organisations: inout [Range<Int>], isCancelled: () -> Bool) -> [Span] {
        tagger.string = input
        var result: [Span] = []
        tagger.enumerateTags(in: input.startIndex..<input.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if isCancelled() { return false }
            if tag == .organizationName {
                let found = NSRange(range, in: input)
                organisations.append(found.location..<NSMaxRange(found))
            }
            guard let tag, tag == .personalName || tag == .placeName else { return true }
            let lower = input.utf16.distance(from: input.utf16.startIndex, to: range.lowerBound.samePosition(in: input.utf16) ?? input.utf16.startIndex)
            let upper = input.utf16.distance(from: input.utf16.startIndex, to: range.upperBound.samePosition(in: input.utf16) ?? input.utf16.endIndex)
            var mapped = lower..<upper
            if partOfOrganisation(mapped, in: original) { return true }
            if tag == .personalName { mapped = trimmedToWrittenCapitals(mapped, in: original) }
            // A name is a word of its own. The tagger splits "Qz7m9rx5l1ba2ms6" at
            // its digits and can call "Qz" a name; that is the head of a token.
            if glued(mapped, in: original) { return true }
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
                // A known first name before a word that is no name ("amber alert", "will power") is no full name.
                let knownFullName = tokens.count >= 2 && tokens.first.map { Names.firstFolded.contains($0) && !NameLists.isWordlike($0) } == true
                    && !tokens.contains { NameLists.isOrdinary($0) && !NameLists.isFirst($0) && !NameLists.isSurname($0) }
                guard knownFullName || cued(mapped, in: original) else { return true }
            }
            let found = TextRanges.substring(original, mapped)
            // Acronyms and names in capitals ("PEM", "NORTHWIND") get tagged as places.
            if tag == .placeName, found == found.uppercased(), !found.contains(" "), !Names.citiesFolded.contains(found.lowercased()) { return true }
            // "San Francisco" reads as a first name and a surname; the city list knows better.
            let isCity = tag == .personalName && Names.citiesFolded.contains(found.lowercased())
            // A country ("Canada", "United States") is where millions live; it names no one.
            if tag == .placeName, let country = Places.country(found), country != "other" { return true }
            // An ordinary word opening a sentence ("Hi, I'm…", read as Hawaii) is the word, unless it is a city's or a person's name too.
            if tag == .placeName, !found.contains(" "), opensSentence(mapped, in: original), NameLists.isWord(found.lowercased()) && !NameLists.isName(found) || found.count <= 2,
               !Names.citiesFolded.contains(found.lowercased()) { return true }
            result.append(Span(range: mapped, entity: tag == .personalName && !isCity ? "PERSON" : "LOCATION", score: tag == .personalName && !isCity ? 0.85 : 0.6))
            return true
        }
        return result
    }
    /// Whether `range` opens its line or a sentence: only space, quotes or a
    /// list's marks since the last full stop, question or exclamation mark.
    static func opensSentence(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        var at = range.lowerBound - 1
        while at >= 0, let scalar = Unicode.Scalar(ns.character(at: at)) {
            if CharacterSet.newlines.contains(scalar) || ".!?".unicodeScalars.contains(scalar) { return true }
            guard CharacterSet.whitespaces.contains(scalar) || "\"'“‘>*-•".unicodeScalars.contains(scalar) else { return false }
            at -= 1
        }
        return true
    }
    /// Whether a letter or digit runs straight into either end of `range`.
    static func glued(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        func alphanumeric(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = Unicode.Scalar(ns.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return !range.isEmpty && (alphanumeric(range.lowerBound - 1) || alphanumeric(range.upperBound))
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
