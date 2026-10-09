import Foundation

/// Names written where no sentence surrounds them, so a tagger reads them
/// poorly: the people a mail header lists ("To: Okafor, Ama; Lind, Per"), mail
/// addresses that start with a name ("Ama Okafor/HOU/CVN@CVN"), the sender
/// above a timestamp, a chat's speaker after one, and a title before initials
/// or a surname ("Ms E. Okafor", "Dr Lind").
enum WrittenNames {
    struct Found {
        var spans: [Span] = []
        /// What holds no name: an address's office path, a header's date.
        var quiet: [Range<Int>] = []
    }

    /// "Ama Okafor/HOU/CVN@CVN": a name, the offices it sits in, and the mail
    /// system. A long list wraps between a first name and a surname.
    private static let officePath = TextPattern(#"(?<![\p{L}\p{N}/@.])(\p{Lu}[\p{L}'’.-]*(?:(?:[ \t]+|[ \t]*\r?\n[ \t]*)\p{Lu}[\p{L}'’.-]*){1,3})(/[\p{L}\p{N}&. -]{1,40}(?:/[\p{L}\p{N}&. -]{1,40}){0,3}@[\p{L}\p{N}.-]+)"#)
    private static let listLabel = TextPattern(#"^[ \t>]*(?i:to|cc|bcc|from)[ \t]*:$"#)
    private static let header = TextPattern(#"(?m)^[ \t>]*(from|to|cc|bcc|sent by|reply-to|sender|sent|date)[ \t]*:[ \t]*(\S[^\r\n]*)$"#, options: [.caseInsensitive])
    /// A chat's speaker, after the time a line was sent: "[09:02] Cassius Wren: morning!".
    private static let speaker = TextPattern(#"(?m)^[ \t]*[\[(]?\d{1,2}:\d{2}(?::\d{2})?(?:[ \t]?[AaPp]\.?[Mm]\.?)?[\])]?[ \t]+(\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*){1,3})[ \t]*:"#)
    /// The sender written above the time they sent it.
    private static let sender = TextPattern(#"(?m)^[ \t]*(\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*){1,3})[ \t]*\r?\n[ \t]*\d{1,2}/\d{1,2}/\d{2,4}[ \t]+\d{1,2}:\d{2}"#)
    /// A title, then initials and a surname or a full name. A surname in
    /// capitals is one only after initials ("Ms E. STRADLING").
    /// An apostrophe joins a name only before a capital ("O’Brien"), never a possessive "’s".
    /// A given name of syllables after a family name keeps its small second one ("Mr. Kim Min-jun").
    private static let titled = TextPattern(#"(?<![\p{L}\p{N}])(?:Mr|Mrs|Ms|Miss|Mx|Dr|Prof|Sir|Dame|Corporal|Sergeant|Lieutenant|Captain|Colonel|Constable|Detective|Inspector|Superintendent|Trooper|Sheriff|Sgt|Cpl|Lt|Capt|Col|Pte|Pvt|Insp|Supt)\.?[ \t]+(?:(?:\p{Lu}\.[ \t]?){1,3}[ \t]*(?:\p{Lu}\p{Ll}+|\p{Lu}{2,}(?:-\p{Lu}{2,})?)|\p{Lu}\p{Ll}+)(?:['’]\p{Lu}\p{Ll}+)?(?:-\p{Lu}\p{Ll}+)?(?:[ \t]+(?:\p{Lu}\.[ \t]?)*\p{Lu}\p{Ll}+(?:['’]\p{Lu}\p{Ll}+)?(?:-\p{Lu}\p{Ll}+|(?<=[ \t]\p{Lu}\p{Ll}{1,3})-\p{Ll}{2,4})?){0,3}(?![\p{L}\p{N}])"#)
    /// A name's own place or business ("Dr Lind’s Surgery") is named after someone, not someone.
    private static let possessiveName = TextPattern(#"^['’]s[ \t]+\p{Lu}"#)
    /// "Okafor, Ama", "Okafor, Ama N.", "Bowen Jr., Raymond", "Leite, Francisco Pinto".
    private static let lastFirst = TextPattern(#"^(\p{Lu}[\p{L}'’-]+(?:[ \t]\p{Lu}[\p{L}'’-]+)?(?:[ \t]+(?:Jr|Sr|II|III|IV)\.?)?),[ \t]*\p{Lu}[\p{L}'’-]+(?:[ \t]+\p{Lu}(?:[\p{L}'’-]+|\.)?){0,2}$"#)
    private static let firstLast = TextPattern(#"^\p{Lu}[\p{L}'’-]*\.?(?:[ \t]+\p{Lu}[\p{L}'’-]*\.?){1,3}$"#)
    /// Words a title or a header can stand before that name no one.
    private static let notNames: Set<String> = roles.union(["the", "and", "of", "in", "on", "at", "all", "everyone", "undisclosed", "recipients", "list", "users", "employees", "staff", "announcements", "distribution", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december"])

    /// A word that names an office, not its holder ("Chair", "Justice").
    static func isRole(_ word: String) -> Bool { roles.contains(word.lowercased()) }
    /// Military and police ranks, and their short forms, that are no ordinary
    /// word: a title before a name ("Corporal Haddleton", "Sgt. Pryce"), never part of it.
    static let ranks: Set<String> = ["corporal", "sergeant", "lieutenant", "captain", "colonel", "commander", "admiral", "commodore", "brigadier",
                                     "constable", "detective", "inspector", "superintendent", "trooper", "sheriff", "marshal", "cadet", "ensign",
                                     "airman", "midshipman", "sgt", "cpl", "lcpl", "lt", "capt", "col", "cmdr", "cdr", "pte", "pvt", "insp", "supt", "det"]
    /// Ranks that are also ordinary words ("a private matter", "a major issue",
    /// "in general"): a rank only when written with a capital before a name.
    static let wordRanks: Set<String> = ["private", "major", "general"]
    private static let roles: Set<String> = Set(["justice", "president", "speaker", "chairman", "chair", "chairwoman", "secretary", "deputy", "chief", "mayor", "governor", "commissioner", "registrar", "agent", "adviser", "advisor", "counsel", "solicitor", "barrister", "lawyer", "attorney", "judge", "qc", "kc", "director", "manager", "officer", "esq",
                                              "advocate", "ambassador", "juror", "minister", "consul", "envoy", "senator", "rapporteur", "notary"]).union(ranks)

    static func scan(_ text: String, isCancelled: () -> Bool = { false }) -> Found {
        var found = Found()
        let ns = text as NSString
        if text.contains("@"), text.contains("/") {
            for match in TextRanges.matches(officePath, in: text, isCancelled: isCancelled) {
                var name = match.range(at: 1)
                // A wrapped name continues an address list; a subject ending in capitals
                // ("Subject: Storage⏎Ama Okafor/…") starts none, so the name is what follows the break.
                if ns.substring(with: name).contains(where: \.isNewline) {
                    let line = ns.lineRange(for: NSRange(location: name.location, length: 0))
                    let before = ns.substring(with: NSRange(location: line.location, length: name.location - line.location)).trimmingCharacters(in: .whitespaces)
                    if before.last.map({ ",;".contains($0) }) != true && TextRanges.matches(listLabel, in: before).isEmpty {
                        let broken = ns.range(of: "\n", options: .backwards, range: name)
                        var from = NSMaxRange(broken)
                        while from < NSMaxRange(name), ns.character(at: from) == 32 || ns.character(at: from) == 9 { from += 1 }
                        name = NSRange(location: from, length: NSMaxRange(name) - from)
                    }
                }
                guard isName(ns.substring(with: name)) else { continue }
                found.spans.append(Span(range: range(name), entity: "PERSON", score: 0.95))
                found.quiet.append(range(match.range(at: 2)))
            }
        }
        if text.contains(":") {
            for match in TextRanges.matches(header, in: text, isCancelled: isCancelled) {
                let label = ns.substring(with: match.range(at: 1)).lowercased(), value = match.range(at: 2)
                if label == "sent" || label == "date" { found.quiet.append(range(value)); continue }
                for item in listed(ns, value) where isName(ns.substring(with: item)) {
                    found.spans.append(Span(range: range(item), entity: "PERSON", score: 0.95))
                }
            }
        }
        for match in TextRanges.matches(sender, in: text, isCancelled: isCancelled) where isName(ns.substring(with: match.range(at: 1))) {
            found.spans.append(Span(range: range(match.range(at: 1)), entity: "PERSON", score: 0.95))
        }
        if text.contains(":") {
            // A speaker named with ordinary words ("[09:02] Support Bot:") is no one.
            for match in TextRanges.matches(speaker, in: text, isCancelled: isCancelled) where isName(ns.substring(with: match.range(at: 1))) {
                let words = ns.substring(with: match.range(at: 1)).split(whereSeparator: { !$0.isLetter }).map(String.init)
                guard words.allSatisfy({ NameLists.isFirst($0) || NameLists.isSurname($0) || !NameLists.isWord($0) }) else { continue }
                found.spans.append(Span(range: range(match.range(at: 1)), entity: "PERSON", score: 0.95))
            }
        }
        for match in TextRanges.matches(titled, in: text, isCancelled: isCancelled) {
            guard let name = titledName(ns, match.range) else { continue }
            found.spans.append(Span(range: name, entity: "PERSON", score: 0.95))
        }
        return found
    }

    private static func range(_ range: NSRange) -> Range<Int> { range.location..<NSMaxRange(range) }

    /// The people a header value lists: "Okafor, Ama; Lind, Per", "Ama Okafor,
    /// Per Lind", "Lind, Per   On Behalf Of Okafor, Ama", "\"Okafor, Ama\"
    /// <ama@corvane.test>". What follows a wide gap is the time it was sent;
    /// quotes and addresses around a name are no part of it.
    private static func listed(_ ns: NSString, _ value: NSRange) -> [NSRange] {
        let masked = NSMutableString(string: ns.substring(with: value))
        if let gap = (masked as String).range(of: #"\s{2,}(?=\d)"#, options: .regularExpression) {
            let cut = NSRange(gap, in: masked as String).location
            masked.replaceCharacters(in: NSRange(location: cut, length: masked.length - cut), with: String(repeating: " ", count: masked.length - cut))
        }
        // Blanked in place, so every offset still points into the original.
        for match in TextRanges.matches(enclosed, in: masked as String).reversed() {
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        let text = masked as String
        let whole = text.trimmingCharacters(in: CharacterSet.whitespaces.union(quotes))
        let separator = text.contains(";") || text.range(of: #"(?i)\s+on behalf of\s+"#, options: .regularExpression) != nil ? #";|(?i)\s+on behalf of\s+"#
            : TextRanges.matches(lastFirst, in: whole).isEmpty ? "," : nil
        var cuts: [NSRange] = [], start = 0
        if let separator {
            for match in TextRanges.matches(TextPattern(separator), in: text) {
                cuts.append(NSRange(location: start, length: match.range.location - start))
                start = NSMaxRange(match.range)
            }
        }
        cuts.append(NSRange(location: start, length: masked.length - start))
        return cuts.compactMap { cut in
            let item = masked.substring(with: cut)
            guard !item.contains("@"), !item.contains("/") else { return nil }
            let leading = item.prefix { $0.isWhitespace || quotes.contains($0.unicodeScalars.first!) }.utf16.count
            let trimmed = item.trimmingCharacters(in: CharacterSet.whitespaces.union(quotes))
            guard !trimmed.isEmpty else { return nil }
            return NSRange(location: value.location + cut.location + leading, length: trimmed.utf16.count)
        }
    }
    private static let enclosed = TextPattern(#"<[^<>\r\n]*>|\[mailto:[^\]\r\n]*\]"#, options: [.caseInsensitive])
    private static let quotes = CharacterSet(charactersIn: "\"'“”")

    /// Two to four capitalised words, or "Last, First": no organisation, no
    /// word that names a role, a day or a group, no word all in capitals
    /// beyond initials ("TK Abernathy", not "CORVANE NORTH AMERICA").
    private static func isName(_ value: String) -> Bool {
        let single = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !TextRanges.matches(lastFirst, in: single).isEmpty || !TextRanges.matches(firstLast, in: single).isEmpty else { return false }
        let words = single.split { $0 == " " || $0 == "," }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        guard !NameTagger.namesOrganisation(single), !words.contains(where: { notNames.contains($0.lowercased()) }) else { return false }
        return words.allSatisfy { $0.count <= 2 || $0.contains(where: \.isLowercase) || People.isSuffix($0) }
    }

    /// The title and the name after it. A role after the title ("Mr Justice
    /// Lind", "Madam Chair") is left to the tagger, and a word that ends the
    /// name is no part of it ("Dr Lind On Monday"). "Dr" after a street's name
    /// ("Wexford Dr Apt 4") is the street's.
    private static func titledName(_ ns: NSString, _ match: NSRange) -> Range<Int>? {
        let text = ns.substring(with: match) as NSString
        var words = (text as String).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // "Detective Inspector Quayle", "Lt. Col. Varga": the last of several titles and ranks starts the name.
        var start = 0
        while words.count > 2, People.isTitle(words[1]) {
            let after = start + (words[0] as NSString).length
            let next = text.range(of: words[1], options: [], range: NSRange(location: after, length: text.length - after))
            guard next.location != NSNotFound else { break }
            start = next.location
            words.removeFirst()
        }
        guard words.count >= 2, !notNames.contains(words[1].lowercased()) else { return nil }
        if words[0].hasPrefix("Dr") {
            var at = match.location
            while at > 0, ns.character(at: at - 1) == 32 || ns.character(at: at - 1) == 9 { at -= 1 }
            var start = at
            while start > 0, let scalar = Unicode.Scalar(ns.character(at: start - 1)), CharacterSet.alphanumerics.contains(scalar) { start -= 1 }
            if start < at, let first = ns.substring(with: NSRange(location: start, length: at - start)).first, first.isUppercase || first.isNumber { return nil }
        }
        // The name ends where a role or a word that is no name starts ("Mr J. Lind Adviser", "Dr Lind On Monday").
        if let role = words.indices.dropFirst().first(where: { notNames.contains(words[$0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }) { words = Array(words[..<role]) }
        guard words.count >= 2, !NameTagger.namesOrganisation(words.dropFirst().joined(separator: " ")) else { return nil }
        let end = text.range(of: words[words.count - 1], options: .backwards)
        let found = (match.location + start)..<(match.location + NSMaxRange(end))
        let after = ns.substring(with: NSRange(location: found.upperBound, length: min(8, ns.length - found.upperBound)))
        guard TextRanges.matches(possessiveName, in: after).isEmpty else { return nil }
        return NameTagger.partOfOrganisation(found, in: ns as String) ? nil : found
    }
}
