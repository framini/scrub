import Foundation

/// Names the government's name lists support where a cue says a name stands:
/// the person a message greets ("Hi Holly,", "Scott:") or is signed by
/// ("Regards,⏎Greg Elliott"), and a known first name before a known surname
/// ("Greg Elliott" in a signature block), or two first names joined ("Wade &
/// Heidi"). A list alone proves nothing, so
/// each needs the position or the pair, and a name that is also an ordinary
/// word ("Will", "Rose") counts only in a greeting or above a sign-off, where
/// nothing else could stand.
enum ListedNames {
    static let cuedScore = 0.9
    static let pairScore = 0.8

    private static let greeting = TextPattern(#"(?m)^[ \t>]*(?:((?i:hi|hello|hey|dear|morning|good morning|good afternoon|good evening|hiya|greetings|thanks|thank you))[ \t,]+)?(\p{L}[\p{L}'’.-]*(?:[ \t]+(?:(?:&|and)[ \t]+)?\p{L}[\p{L}'’.-]*){0,2})[ \t]*([,:!]|—|–|-|$)"#)
    private static let closing = TextPattern(#"(?im)^[ \t>]*(?:thanks|thank you|many thanks|thanks again|thx|cheers|regards|best regards|kind regards|warm regards|best|best wishes|all the best|sincerely|yours|yours truly|yours sincerely|love|take care|talk soon|ciao)[ \t]*[,.!]*[ \t]*\r?$"#)
    private static let signature = TextPattern(#"^[ \t>]*(?:-{1,2}|~|—)?[ \t]*(\p{L}[\p{L}'’.-]*(?:[ \t]+\p{L}[\p{L}'’.-]*){0,2})[ \t]*\r?$"#)
    private static let pair = TextPattern(#"(?<![\p{L}\p{N}'’.@/_-])(\p{Lu}\p{Ll}+)(?:[ \t]+\p{Lu}\.)?[ \t]+(\p{Lu}\p{Ll}+(?:-\p{Lu}\p{Ll}+)?)(?![\p{L}\p{N}'’@/_-])"#)
    /// Two first names joined: "Wade & Heidi", "Holly and Grace".
    private static let joined = TextPattern(#"(?<![\p{L}\p{N}'’.@/_-])(\p{Lu}\p{Ll}+)[ \t]+(?:&|and)[ \t]+(\p{Lu}\p{Ll}+)(?![\p{L}\p{N}'’@/_-])"#)
    private static let places = Set(Places.all.map { $0.city.lowercased() })
    /// A verb that asks for someone, opening a sentence or a line, then the
    /// name it asks for: "Ask Brisa for…", "Call Odalys Ferriter on…".
    private static let instructed = TextPattern(#"(?:^|[.!?][ \t]+|\n)[ \t>*•-]*(\p{Lu}\p{Ll}+)[ \t]+(\p{Lu}\p{Ll}+(?:[ \t]+\p{Lu}\p{Ll}+(?:-\p{Lu}\p{Ll}+)?)?)(?![\p{L}\p{N}'’@/_-])"#)
    /// The verbs of `NameShape.commands` that take a person: "Call Support" and "Update Legal" name no one either way.
    private static let askingFor: Set<String> = ["call", "email", "ask", "ping", "tell", "text", "message", "contact", "phone", "ring", "telephone", "remind",
                                                 "thank", "invite", "notify", "inform", "cc", "bcc", "dm", "meet", "brief", "nudge", "warn"]

    /// A capitalised given name, then a surname of two joined by a hyphen or a
    /// dash: "Brisa Smith-Jones", "Brisa Smith–Jones".
    private static let hyphenated = TextPattern(#"(?<![\p{L}\p{N}'’.@/_-])(\p{Lu}\p{Ll}+)[ \t]+(\p{Lu}\p{Ll}+[-‐‑–]\p{Lu}\p{Ll}+)(?![\p{L}\p{N}'’@/_]|[-‐‑–]\p{L})"#)

    /// People written with a hyphenated surname in prose, which the tagger
    /// reads in pieces ("Smith" a person, "Jones" a place) and so leaves the
    /// given name behind. The given name must be a known first name that is
    /// no ordinary word, or, beside a person `people` holds inside it or a
    /// title before it, a word no dictionary holds but as a name; each part
    /// of the surname a surname or no word, and the whole no place or
    /// organisation, nor a surname the tagger read whole as one in `organisations`
    /// ("Hewlett-Packard"). "Rolls-Royce", "Winston-Salem" or "Coca-Cola" has no
    /// given name before it, and "the Mercedes-Benz" none written as one.
    static func hyphenated(in text: String, people: [Range<Int>], organisations: [Range<Int>] = [], isCancelled: () -> Bool = { false }) -> [Span] {
        guard text.contains(where: { "-‐‑–".contains($0) }) else { return [] }
        let ns = text as NSString
        var spans: [Span] = []
        for match in TextRanges.matches(hyphenated, in: text, isCancelled: isCancelled) {
            let given = ns.substring(with: match.range(at: 1)), surname = ns.substring(with: match.range(at: 2))
            let range = match.range.location..<NSMaxRange(match.range)
            let pieces = surname.split(whereSeparator: { "-‐‑–".contains($0) }).map(String.init)
            guard !People.isTitle(given), !NameShape.isRole(given), !NameShape.joining.contains(given.lowercased()),
                  pieces.allSatisfy({ NameLists.isSurname($0) && !NameLists.isOrdinary($0) || !NameLists.isWord($0) }) else { continue }
            let known = NameLists.isFirst(given) && !NameLists.isWordlike(given) && !NameLists.isOrdinary(given)
            let before = Context.words(before: range.lowerBound, in: text, limit: 1).first
            let cued = people.contains { $0.overlaps(range) } || before.map(People.isTitle) == true
            let named = !NameLists.isWord(given) || NameLists.isName(given) && !NameLists.isOrdinary(given)
            guard known || cued && named else { continue }
            let plain = surname.replacingOccurrences(of: #"[‐‑–]"#, with: "-", options: .regularExpression).lowercased()
            guard !places.contains(plain), !places.contains(ns.substring(with: match.range).lowercased()), Places.region(surname) == nil,
                  !NameTagger.partOfOrganisation(range, in: text) else { continue }
            let last = match.range(at: 2).location..<NSMaxRange(match.range(at: 2))
            guard !organisations.contains(where: { $0.lowerBound <= last.lowerBound && last.upperBound <= $0.upperBound }) else { continue }
            spans.append(Span(range: range, entity: "PERSON", score: cuedScore))
        }
        return spans
    }

    static func scan(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        var spans: [Span] = []
        let ns = text as NSString
        if text.contains(where: \.isNewline) || text.contains(",") || text.contains(":") {
            for match in TextRanges.matches(greeting, in: text, isCancelled: isCancelled) {
                let greeted = match.range(at: 1).location != NSNotFound
                let names = match.range(at: 2)
                // Without "Hi" or "Dear", the line holds the name and its comma only ("Holly,").
                if !greeted {
                    // "Best," and "Thanks," close a message; they greet no one.
                    let line = ns.substring(with: ns.lineRange(for: NSRange(location: match.range.location, length: 0))).trimmingCharacters(in: .newlines)
                    if !TextRanges.matches(closing, in: line).isEmpty { continue }
                    let end = NSMaxRange(match.range)
                    let rest = ns.substring(with: NSRange(location: end, length: NSMaxRange(ns.lineRange(for: NSRange(location: max(0, end - 1), length: 0))) - end))
                    guard ns.substring(with: match.range(at: 3)) != "", rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, [",", ":"].contains(ns.substring(with: match.range(at: 3))) else { continue }
                }
                spans += people(in: names, ns, greeted: greeted, capitals: greeted)
            }
        }
        if text.contains(where: \.isNewline) {
            for match in TextRanges.matches(closing, in: text, isCancelled: isCancelled) {
                var at = NSMaxRange(ns.lineRange(for: NSRange(location: match.range.location, length: 0)))
                // The next line with anything on it.
                while at < ns.length {
                    let line = ns.lineRange(for: NSRange(location: at, length: 0))
                    if !ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || NSMaxRange(line) <= at { break }
                    at = NSMaxRange(line)
                }
                guard at < ns.length else { continue }
                let line = ns.lineRange(for: NSRange(location: at, length: 0))
                let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
                guard let signed = TextRanges.matches(signature, in: content).first else { continue }
                let names = NSRange(location: line.location + signed.range(at: 1).location, length: signed.range(at: 1).length)
                spans += people(in: names, ns, greeted: true, capitals: false)
            }
        }
        if text.contains("&") || text.contains(" and ") {
            for match in TextRanges.matches(joined, in: text, isCancelled: isCancelled) {
                let names = [match.range(at: 1), match.range(at: 2)]
                let words = names.map { ns.substring(with: $0) }
                guard words.allSatisfy(NameLists.isFirst), words.contains(where: { !NameLists.isWordlike($0) && !NameLists.isOrdinary($0) }),
                      !NameTagger.partOfOrganisation(match.range(at: 1).location..<NSMaxRange(match.range), in: text) else { continue }
                spans += names.map { Span(range: $0.location..<NSMaxRange($0), entity: "PERSON", score: pairScore) }
            }
        }
        // Each word after the verb must be a first name or surname that is no word, or no word any list holds:
        // "Ask Brisa", but not "Ask Legal" or "Call Support".
        for match in TextRanges.matches(instructed, in: text, isCancelled: isCancelled) where askingFor.contains(ns.substring(with: match.range(at: 1)).lowercased()) {
            let names = match.range(at: 2)
            let words = ns.substring(with: names).split(separator: " ").map(String.init)
            guard words.allSatisfy({ !NameLists.isWord($0) || NameLists.isName($0) && !NameLists.isOrdinary($0) }), NameLists.isFirst(words[0]) || !NameLists.isWord(words[0]),
                  !places.contains(words.joined(separator: " ").lowercased()), Places.region(words[0]) == nil,
                  !NameTagger.partOfOrganisation(names.location..<NSMaxRange(names), in: text) else { continue }
            spans.append(Span(range: names.location..<NSMaxRange(names), entity: "PERSON", score: cuedScore))
        }
        for match in TextRanges.matches(pair, in: text, isCancelled: isCancelled) {
            let first = ns.substring(with: match.range(at: 1)), last = ns.substring(with: match.range(at: 2))
            guard NameLists.isFirst(first), NameLists.isSurname(last.split(separator: "-").first.map(String.init) ?? last),
                  ![first, last].contains(where: { NameLists.isWordlike($0) || NameLists.isOrdinary($0) }) else { continue }
            let range = match.range.location..<NSMaxRange(match.range)
            let value = ns.substring(with: match.range)
            guard !places.contains(value.lowercased()), Places.region(value) == nil, !NameTagger.partOfOrganisation(range, in: text) else { continue }
            spans.append(Span(range: range, entity: "PERSON", score: pairScore))
        }
        return spans
    }

    /// The people a greeting or signature names: one, or two joined by "&" or
    /// "and" ("Wade & Heidi"). Every word must be name-shaped and one of them
    /// listed; none may be an ordinary word that is no name ("Team", "All"),
    /// a title or a role. A word in capitals stands only where `greeted`
    /// (see `CapitalNames`): any after a greeting's word with `capitals`
    /// ("Hi JINX,"), and above a sign-off only one the lists hold or no
    /// ordinary word ("Thanks,⏎ODALYS").
    /// A word run together with "am", "have", "are", "will", "would" or "not"
    /// ("I'm", "We've", "Can't"): a greeting goes on to say who, it names no one.
    /// "O'Neil" and "D'Souza" are names.
    static func contraction(_ word: String) -> Bool {
        guard let mark = word.firstIndex(where: { $0 == "'" || $0 == "’" }) else { return false }
        return ["m", "ve", "re", "ll", "d", "t"].contains(word[word.index(after: mark)...].lowercased())
    }
    private static func people(in range: NSRange, _ ns: NSString, greeted: Bool, capitals: Bool) -> [Span] {
        let value = ns.substring(with: range)
        var groups: [[(String, Int)]] = [[]]
        var offset = 0
        for word in value.split(separator: " ", omittingEmptySubsequences: false) {
            let text = String(word)
            if text == "&" || text == "and" { groups.append([]) }
            else if !text.isEmpty { groups[groups.count - 1].append((text.trimmingCharacters(in: .whitespaces), offset)) }
            offset += (text as NSString).length + 1
        }
        var spans: [Span] = []
        for group in groups where !group.isEmpty {
            let words = group.map(\.0)
            if NameTagger.namesOrganisation(words.joined(separator: " ")) { continue }
            let lower = words.allSatisfy { $0 == $0.lowercased() }
            guard words.count <= 3, words.allSatisfy({ word in
                let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ".'’"))
                guard !bare.isEmpty, !People.isTitle(bare), !NameShape.isRole(bare), !NameShape.joining.contains(bare.lowercased()), !contraction(bare) else { return false }
                // An initial ("J.") or a name-shaped word; lowercase only as a whole ("hey beatriz").
                if bare.count == 1 { return bare.first!.isUppercase }
                if lower { return NameLists.isFirst(bare) && !NameLists.isWordlike(bare) && !NameLists.isOrdinary(bare) }
                if bare.count >= 2, bare == bare.uppercased(), bare != bare.lowercased() {
                    if CapitalNames.acronyms.contains(bare.lowercased()) { return false }
                    if bare.count >= 4 {
                        guard greeted, CapitalNames.mayName(bare) else { return false }
                        return capitals || NameLists.isName(bare) || !NameLists.isOrdinary(bare)
                    }
                }
                guard bare.first!.isUppercase, bare.dropFirst().contains(where: \.isLowercase) || bare.count <= 3 else { return false }
                // An ordinary word stands as a name only as a first name ("Holly,"), never as a surname alone ("Best,").
                return !NameLists.isOrdinary(bare) || NameLists.isFirst(bare) || words.count > 1 && NameLists.isSurname(bare)
            }), greeted || words.contains(where: { NameLists.isFirst($0) || NameLists.isSurname($0) }) else { continue }
            if lower && words.count > 1 { continue }
            let start = range.location + group.first!.1
            let end = range.location + group.last!.1 + (group.last!.0 as NSString).length
            var span = start..<end
            // A full stop after the last word is the line's ("Thanks, Holly.").
            if ns.substring(with: NSRange(location: end - 1, length: 1)) == ".", (group.last!.0.count > 2) { span = start..<(end - 1) }
            spans.append(Span(range: span, entity: "PERSON", score: cuedScore))
        }
        return spans
    }
}
