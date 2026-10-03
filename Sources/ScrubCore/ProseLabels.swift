import Foundation

/// Values a sentence names before giving them: "born on March 5, 1971", "my NI
/// number is PK 93 30 50 C", "the wifi password is velvet-Cobalt-47", "PO Box
/// 4872". The value must look like what its label promises, so "the password
/// is incorrect" and "the MRN field is required" stay as written.
enum ProseLabels {
    struct Found {
        var spans: [Span] = []
        /// The labels themselves ("born", "d.o.b.", "passport number"): words that
        /// name a value are no one's name.
        var labels: [Range<Int>] = []
    }

    private static let month = #"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?"#
    private static let day = #"(?:[0-3]?\d)(?:st|nd|rd|th)?"#
    private static let year = #"(?:19|20)\d{2}"#
    /// A birth cue, then the date: longer forms first, so "March 5, 1971" is not cut to "March 5".
    private static let birth = TextPattern(
        #"\b(born(?:[ \t]+on|[ \t]+in)?|dob|d\.o\.b\.?|date[ \t]+of[ \t]+birth|birth[ \t]*date|birthday(?:[ \t]+is)?)(?:[ \t]*[:\-]|[ \t]+(?:is|was))?[ \t]*("#
        + "\(month)[ \\t]+\(day),?[ \\t]+\(year)|\(day)[ \\t]+\(month),?[ \\t]+\(year)|\(month)[ \\t]+\(year)|\(month)[ \\t]+\(day)\\b|\(day)[ \\t]+\(month)"
        + #"|\d{1,2}[/.\-]\d{1,2}[/.\-](?:\d{4}|\d{2})|\d{4}-\d{1,2}-\d{1,2})(?![\w/.\-]*\d)"#,
        options: [.caseInsensitive])
    private static let idLabel = TextPattern(
        #"\b(passport(?:[ \t]+(?:number|no\.?|#))?|national[ \t]+insurance[ \t]+number|ni[ \t]+number|nino|national[ \t]+id(?:[ \t]+number)?|id[ \t]+number|identity[ \t]+number|id[ \t]+card[ \t]+number|dni|nie|cpf|curp|sin|social[ \t]+insurance[ \t]+number|(?:employee|staff)[ \t]+(?:id|number|no\.?)|badge[ \t]+(?:number|#)|mrn|medical[ \t]+record[ \t]+number|patient[ \t]+(?:id|number)|nhs[ \t]+number|health[ \t]+card[ \t]+number|member(?:ship)?[ \t]+(?:number|id|no\.?)|tax[ \t]+(?:id|number)|tin|ein|student[ \t]+(?:number|id)|policy[ \t]+(?:number|no\.?)|(?:driver'?s|drivers|driving)[ \t]+licen[cs]e(?:[ \t]+(?:number|no\.?))?|licen[cs]e[ \t]+number|account[ \t]+number|customer[ \t]+(?:number|id))\b(?:[ \t]*[:#=]|[ \t]+(?:is|was))?[ \t]*"#,
        options: [.caseInsensitive])
    private static let secretLabel = TextPattern(
        #"\b(pass(?:word|wd|code|phrase)|pwd|pin(?:[ \t]+code)?|access[ \t]+code|(?:api|license|licence|product|access|secret|private)[ \t]+key|key|token|secret|[a-z][a-z0-9]*(?:_[a-z0-9]+)*_(?:key|token|secret|password|pass))\b((?:'s|’s)|[ \t]*[:=]|[ \t]+(?:is|was|to)\b)?[ \t]*"#,
        options: [.caseInsensitive])
    private static let poBox = TextPattern(
        #"\b(?:p\.?[ \t]?o\.?[ \t]?box|post[ \t]+office[ \t]+box|postfach|apartado(?:[ \t]+de[ \t]+correos)?|private[ \t]+bag)[ \t]+(\d{1,6})\b"#,
        options: [.caseInsensitive])
    /// A year alone after "born" ("born in 1948 and 1951 respectively") or
    /// "b." ("(b. 1962)"). Ideas and companies are born too, so the clause
    /// must be about someone.
    private static let birthYear = TextPattern(#"\b(born(?:[ \t]+in)?|b\.)[ \t]+((?:18|19|20)\d{2}(?:(?:[ \t]*,[ \t]*(?:and[ \t]+)?|[ \t]+and[ \t]+)(?:18|19|20)\d{2})*)(?![\w/.\-]*\d)"#, options: [.caseInsensitive])
    private static let year4 = TextPattern(#"(?:18|19|20)\d{2}"#)
    /// An age said as one: "aged 38", "age: 38", "38 years old", "a 38-year-old", "38 y/o".
    /// It moves only with a birth date near it (see `StandIns.age`), so one alone stays.
    private static let age = TextPattern(#"(?i)\b(?:aged|age:?)[ \t]+(\d{1,3})\b|\b(\d{1,3})(?:[ -]years?[ -]old\b|[ \t]?y/?o\b)"#)
    /// An age said after a birth date in the same sentence, with no word for
    /// an age: "born on 14 March 1987 and is 38", "…, now 38.". Read only
    /// after a birth date, so "the invoice is 38" stays.
    private static let bareAge = TextPattern(#"(?i)\b(?:is|was|turned|turns|turning|now)[ \t]+(?:now[ \t]+|just[ \t]+)?(\d{1,3})(?=[ \t]*(?:[.,;!?)]|\r?\n|$)|[ \t]+(?:and|but|now|today|this|so|which)\b)"#)
    /// An extension written after a number or alone: "x41872", "ext. 5-3310", "extension 4471".
    private static let phoneExtension = TextPattern(#"(?<![\p{L}\p{N}_./\-])((?i:ext)\.?[ \t]*|(?i:extension)[ \t]+|[xX]-?)(\d(?:-?\d){3,5})(?![\p{L}\p{N}-])"#)
    private static let someone: Set<String> = ["i", "he", "she", "they", "we", "who", "whom", "her", "his", "my", "our", "their", "both", "each", "applicant", "applicants", "patient", "patients", "client", "clients", "claimant", "claimants", "defendant", "defendants", "plaintiff", "appellant", "petitioner", "victim", "victims", "son", "daughter", "child", "children", "wife", "husband", "mother", "father", "brother", "sister", "baby", "twins", "man", "woman", "boy", "girl", "author", "member", "employee", "resident", "citizen", "national", "nationals", "mr", "mrs", "ms", "miss", "dr"]
    private static let something: Set<String> = ["idea", "ideas", "company", "firm", "project", "band", "movement", "concept", "brand", "product", "business", "organisation", "organization", "festival", "tradition", "it", "this", "that", "app", "startup", "team", "club", "series", "show", "genre"]
    /// The password in a URL: "postgres://admin:hunter2@db.internal/app". A
    /// capture, not a lookbehind, which ICU would try at every character of a long text.
    private static let urlPassword = TextPattern(#"\b[A-Za-z][A-Za-z0-9+.\-]{0,15}://[^\s/@:]{1,64}:([^\s/@]{1,128})@(?=[A-Za-z0-9])"#)
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)]}\"'")

    /// From `start` to the end of its sentence, at most 80 units on.
    private static func sentenceRest(_ ns: NSString, from start: Int) -> NSRange {
        var end = start
        while end < min(ns.length, start + 80) {
            let unit = ns.character(at: end)
            if unit == 10 || [46, 33, 63].contains(unit) && (end + 1 == ns.length || [32, 10, 13].contains(ns.character(at: end + 1))) { break }
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    static func scan(_ text: String, isCancelled: () -> Bool = { false }) -> Found {
        var found = Found()
        let ns = text as NSString
        guard ns.length >= 6 else { return found }
        for match in TextRanges.matches(birth, in: text, isCancelled: isCancelled) {
            if isCancelled() { return found }
            found.labels.append(range(match.range(at: 1)))
            found.spans.append(Span(range: range(match.range(at: 2)), entity: "DATE_OF_BIRTH", score: 0.9))
        }
        for match in TextRanges.matches(idLabel, in: text, isCancelled: isCancelled) {
            if isCancelled() { return found }
            guard let value = idValue(ns, from: NSMaxRange(match.range)) else { continue }
            found.labels.append(range(match.range(at: 1)))
            found.spans.append(Span(range: value, entity: "ID_NUMBER", score: 0.9))
        }
        for match in TextRanges.matches(secretLabel, in: text, isCancelled: isCancelled) {
            if isCancelled() { return found }
            let label = ns.substring(with: match.range(at: 1)).lowercased()
            let joined = match.range(at: 2).location != NSNotFound
            guard let value = token(ns, from: NSMaxRange(match.range)), secretLike(ns.substring(with: NSRange(location: value.lowerBound, length: value.count)), label: label, joined: joined) else { continue }
            found.labels.append(range(match.range(at: 1)))
            found.spans.append(Span(range: value, entity: "SECRET", score: 0.9))
        }
        for match in TextRanges.matches(birthYear, in: text, isCancelled: isCancelled) where aboutSomeone(ns, match) {
            found.labels.append(range(match.range(at: 1)))
            let years = match.range(at: 2)
            for year in TextRanges.matches(year4, in: ns.substring(with: years)) {
                found.spans.append(Span(range: (years.location + year.range.location)..<(years.location + NSMaxRange(year.range)), entity: "DATE_OF_BIRTH", score: 0.9))
            }
        }
        // Every age said as one holds "age", "year", or "y/o" or "yo" after a number: read only around those.
        let ageAnchors = TextRanges.occurrences(of: "age", in: ns) + TextRanges.occurrences(of: "year", in: ns) + TextRanges.occurrences(of: "y/o", in: ns)
            + TextRanges.occurrences(of: "yo", in: ns).filter { $0 > 0 && ([32, 9].contains(ns.character(at: $0 - 1)) || (48...57).contains(ns.character(at: $0 - 1))) }
        for match in TextRanges.matches(age, in: text, around: ageAnchors, before: 8, after: 64, isCancelled: isCancelled) {
            let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let years = Int(ns.substring(with: group)), (0...120).contains(years) else { continue }
            found.spans.append(Span(range: range(group), entity: "AGE", score: 0.9))
        }
        // After a birth date, the rest of its sentence may say the age bare.
        for birthDate in found.spans where birthDate.entity == "DATE_OF_BIRTH" {
            let rest = sentenceRest(ns, from: birthDate.range.upperBound)
            for match in TextRanges.matches(bareAge, in: ns.substring(with: rest)) {
                let group = NSRange(location: rest.location + match.range(at: 1).location, length: match.range(at: 1).length)
                guard let years = Int(ns.substring(with: group)), (0...120).contains(years), !found.spans.contains(where: { $0.range.overlaps(range(group)) }) else { continue }
                found.spans.append(Span(range: range(group), entity: "AGE", score: 0.9))
            }
        }
        for match in TextRanges.matches(phoneExtension, in: text, isCancelled: isCancelled) {
            found.labels.append(range(match.range(at: 1)))
            found.spans.append(Span(range: range(match.range(at: 2)), entity: "PHONE_NUMBER", score: 0.85))
        }
        if text.contains("://") {
            for match in TextRanges.matches(urlPassword, in: text, isCancelled: isCancelled) {
                found.spans.append(Span(range: range(match.range(at: 1)), entity: "SECRET", score: 0.95))
            }
        }
        for match in TextRanges.matches(poBox, in: text, isCancelled: isCancelled) {
            found.spans.append(Span(range: range(match.range(at: 1)), entity: "ADDRESS", score: 0.9))
        }
        return found
    }

    private static func range(_ range: NSRange) -> Range<Int> { range.location..<NSMaxRange(range) }

    /// Whether the clause around "born" is about a person: "the applicant
    /// was born in 1948", "Ms Lind (b. 1962)", "Born in 1955, she moved", not
    /// "the idea was born in 2019".
    private static func aboutSomeone(_ text: NSString, _ match: NSTextCheckingResult) -> Bool {
        let cue = match.range(at: 1)
        let line = text.lineRange(for: NSRange(location: cue.location, length: 0))
        let head = text.substring(with: NSRange(location: line.location, length: cue.location - line.location))
        let clause = head.components(separatedBy: CharacterSet(charactersIn: ".;!?")).last ?? head
        let tail = text.substring(with: NSRange(location: NSMaxRange(match.range), length: min(48, text.length - NSMaxRange(match.range))))
        let before = clause.lowercased().split { !$0.isLetter }.map(String.init)
        let after = tail.lowercased().split { !$0.isLetter }.prefix(4).map(String.init)
        if before.contains(where: something.contains) { return false }
        if text.substring(with: cue).lowercased() == "b." { return head.trimmingCharacters(in: .whitespaces).last.map { "(,".contains($0) } == true }
        let named = clause.split(separator: " ").dropFirst().contains { word in
            word.first?.isUppercase == true && (Names.firstFolded.contains(word.lowercased()) || Names.lastFolded.contains(word.lowercased()))
        }
        return named || before.contains(where: someone.contains) || after.contains(where: someone.contains)
    }

    /// An ID after its label: pieces split by single spaces, dots, dashes or
    /// slashes ("PK 93 30 50 C", "123.456.789-01", "EMP-104233"), each holding a
    /// digit or no more than three capitals, with four digits or more in all.
    private static func idValue(_ text: NSString, from start: Int) -> Range<Int>? {
        var at = start, end = start, digits = 0
        func isAlphanumeric(_ unit: unichar) -> Bool { (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) }
        while at < text.length {
            var piece = at
            while piece < text.length, isAlphanumeric(text.character(at: piece)) { piece += 1 }
            guard piece > at else { break }
            let chunk = text.substring(with: NSRange(location: at, length: piece - at))
            let count = chunk.filter(\.isNumber).count
            guard count > 0 || chunk.count <= 3 && chunk.allSatisfy(\.isUppercase) else { break }
            digits += count
            end = piece
            guard piece + 1 < text.length, " .-/".utf16.contains(text.character(at: piece)), isAlphanumeric(text.character(at: piece + 1)) else { break }
            at = piece + 1
        }
        return digits >= 4 && end - start >= 5 ? start..<end : nil
    }

    /// One token from `start`, without the punctuation that ends a sentence.
    private static func token(_ text: NSString, from start: Int) -> Range<Int>? {
        var end = start
        while end < text.length, let scalar = Unicode.Scalar(text.character(at: end)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        while end > start, let scalar = Unicode.Scalar(text.character(at: end - 1)), trailing.contains(scalar) { end -= 1 }
        return end > start ? start..<end : nil
    }

    /// A secret is no word: it has digits or symbols, or capitals inside it. A
    /// PIN is four to eight digits. Documentation names options and
    /// placeholders after the same labels ("--password password", "passwd
    /// user_path", "Preferences key: auto-fsck"), so a value starting like an
    /// option, a placeholder or a path is none, and without "is", ":" or "="
    /// only a long key or token of letters and digits counts ("the key 9f86…").
    private static func secretLike(_ value: String, label: String, joined: Bool) -> Bool {
        guard let first = value.first, !"-[(<{?$~/.'\"`".contains(first), !value.contains("://"), !value.contains(where: "`{}()".contains), !value.contains("/") || joined && !value.hasPrefix("~") else { return false }
        let hasDigit = value.contains(where: \.isNumber), hasLetter = value.contains(where: \.isLetter)
        if label.hasPrefix("pin") || label == "passcode" || label == "access code" {
            return joined && (4...8).contains(value.count) && value.allSatisfy { $0.isASCII && $0.isNumber }
        }
        guard joined else { return ["key", "token", "secret"].contains(label) && value.count >= 16 && hasDigit && hasLetter && !value.contains("_") }
        // An environment variable's name is a label of its own ("set CORVANE_API_KEY to …").
        let capitals = value.filter(\.isUppercase).count
        // A long token of mixed case needs no digit to be one.
        if label.contains("_") { return value.count >= 8 && (hasDigit || value.count >= 16 && capitals >= 2 && value.contains(where: \.isLowercase)) }
        if ["key", "token", "secret"].contains(label) || label.hasSuffix(" key") {
            // A field name ("key: dateOfBirth", "key: DATE_OF_BIRTH") is not a key.
            return value.count >= 8 && (hasDigit || capitals >= 2 && !value.allSatisfy { $0.isLetter || $0 == "_" })
        }
        guard value.count >= 6 else { return false }
        let hasSymbol = value.contains { !$0.isLetter && !$0.isNumber }
        let innerCapital = value.dropFirst().contains(where: \.isUppercase) && value.contains(where: \.isLowercase)
        return hasDigit || hasSymbol || innerCapital
    }
}
