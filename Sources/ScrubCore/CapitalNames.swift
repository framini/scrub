import Foundation

/// Names written in capitals, which the tagger and the name model read as
/// shouting or acronyms: a word in capitals counts as a name only beside
/// something that says one stands there. A known first name before it
/// ("Julie BEET", "JULIE BEET") or a title ("Ms BEET") here; a greeting or a
/// sign-off ("Hi JINX,") in `ListedNames`. Acronyms and shouted words ("API",
/// "CEO", "NOW", "ASAP") never count.
enum CapitalNames {
    static let score = 0.9

    /// Capitals that are no one's name: acronyms, labels, and words shouted
    /// for emphasis. Joining words, roles and verbs are refused besides these.
    static let acronyms: Set<String> = [
        "api", "apis", "sdk", "cli", "ide", "url", "uri", "http", "https", "html", "css", "json", "xml", "csv", "pdf", "sql", "ssh", "ssl", "tls", "dns", "ip", "tcp", "udp",
        "vpn", "lan", "wan", "usb", "cpu", "gpu", "ram", "ssd", "os", "ui", "ux", "qa", "ci", "cd", "id", "ids", "pin", "otp", "sms", "mms", "faq", "crm", "erp",
        "ceo", "cfo", "cto", "coo", "cio", "ciso", "cmo", "vp", "svp", "evp", "hr", "it", "pr", "pa", "pm", "am", "md", "rn", "np", "cpa", "mba", "phd", "dds", "esq",
        "usa", "us", "uk", "eu", "un", "uae", "nasa", "nato", "nhs", "irs", "fbi", "cia", "dhs", "dmv", "hmrc", "ssn", "dob", "vat", "ein", "tin", "itin", "iban", "bic",
        "gdpr", "hipaa", "ccpa", "pii", "phi", "nda", "sla", "slo", "sow", "rfp", "rfq", "po", "kpi", "okr", "roi", "eta", "eod", "eow", "eom", "tbd", "tba", "tbc",
        "asap", "fyi", "aka", "diy", "rsvp", "ps", "pps", "nb", "re", "fw", "fwd", "cc", "bcc", "ok", "okay", "utc", "gmt", "est", "edt", "pst", "pdt", "cet", "cest",
        "ooo", "wfh", "pto", "lol", "omg", "btw", "imo", "imho", "tldr", "ai", "ml", "llm", "nlp", "dm", "dms", "atm", "vip", "na", "n/a", "aob", "wip", "poc", "mvp",
        "note", "notes", "urgent", "important", "todo", "fixme", "warning", "error", "info", "debug", "null", "none", "nil", "true", "false", "yes", "no", "not",
        "all", "team", "everyone", "everybody", "folks", "guys", "there", "world", "both", "again", "now", "today", "tomorrow", "tonight", "please", "pls",
        "thanks", "thank", "you", "must", "never", "always", "only", "very", "really", "also", "still", "just", "done", "new", "free", "sale", "stop", "help",
        "attention", "reminder", "update", "action", "required", "confidential", "draft", "final", "subject", "agenda", "summary", "inc", "ltd", "llc", "plc", "corp", "co",
    ]

    /// Whether a word in capitals may be a name: two letters or more, all
    /// capitals, no acronym, joining word, verb or role.
    static func mayName(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2, letters == letters.uppercased(), letters != letters.lowercased(),
              word.allSatisfy({ $0.isLetter || "-'’".contains($0) }) else { return false }
        let bare = word.lowercased()
        return !acronyms.contains(bare) && !NameShape.joining.contains(bare) && !NameShape.commands.contains(bare)
            && !NameShape.isRole(word) && !People.isTitle(word) && !NameShape.months.contains(bare) && !NameShape.weekdays.contains(bare)
            && !NameCues.verbs.contains(bare)
    }

    /// A known first name, written either way, then a word in capitals.
    private static let afterFirst = TextPattern(#"(?<![\p{L}\p{N}'’.@/_-])(\p{Lu}\p{Ll}+|\p{Lu}{2,})[ \t]+(\p{Lu}{2,}(?:[-'’]\p{Lu}{2,})?)(?![\p{L}\p{N}'’@/_-])"#)
    /// A title, then a surname in capitals: "Ms BEET", "Dr. JINX".
    private static let afterTitle = TextPattern(#"(?<![\p{L}\p{N}])(?:Mr|Mrs|Ms|Miss|Mx|Dr|Prof|Sir|Dame)\.?[ \t]+(\p{Lu}{2,}(?:[-'’]\p{Lu}{2,})?)(?![\p{L}\p{N}'’@/_-])"#)

    static func scan(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        // Only text with a run of two capitals can hold one.
        guard text.unicodeScalars.contains(where: { CharacterSet.uppercaseLetters.contains($0) }),
              TextRanges.matches(twoCapitals, in: text).first != nil else { return [] }
        let ns = text as NSString
        var spans: [Span] = []
        for match in TextRanges.matches(afterFirst, in: text, isCancelled: isCancelled) {
            let first = ns.substring(with: match.range(at: 1)), last = ns.substring(with: match.range(at: 2))
            // The first name is the cue, so it must be one and no ordinary word ("Will", "Grant").
            guard NameLists.isFirst(first), !NameLists.isWordlike(first), !NameLists.isOrdinary(first.lowercased()),
                  first != first.uppercased() || mayName(first), mayName(last) else { continue }
            let range = match.range.location..<NSMaxRange(match.range)
            guard !NameTagger.partOfOrganisation(range, in: text) else { continue }
            spans.append(Span(range: range, entity: "PERSON", score: score))
        }
        for match in TextRanges.matches(afterTitle, in: text, isCancelled: isCancelled) where mayName(ns.substring(with: match.range(at: 1))) {
            let range = match.range.location..<NSMaxRange(match.range)
            guard !NameTagger.partOfOrganisation(range, in: text) else { continue }
            spans.append(Span(range: range, entity: "PERSON", score: score))
        }
        return spans
    }
    private static let twoCapitals = TextPattern(#"\p{Lu}\p{Lu}"#)
}
