import Foundation
import NaturalLanguage

/// What a person's name can and cannot be made of, whichever detector found
/// it. A name holds no role ("Ambassador", "Judge Advocate"), no word that
/// only joins a sentence ("S. The", where "The" opens the next one), and no
/// date ("June 22"); and a guess made of ordinary words alone ("Gas Day",
/// "Article 32", "art. 47") needs something around it that says it is a name.
enum NameShape {
    /// Words that join a sentence and end no name: "S. The" is an initial and
    /// the next sentence's first word.
    static let joining: Set<String> = ["the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from", "as", "is", "was",
                                       "are", "were", "be", "been", "this", "that", "these", "those", "it", "its", "he", "she", "they", "we", "you", "i",
                                       "his", "her", "their", "our", "my", "your", "not", "no", "so", "if", "then", "than", "when", "while", "after", "before"]
    static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
                                      "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static let word = TextPattern(#"\p{L}[\p{L}\p{M}'’]*\.?"#)

    struct Word {
        let range: Range<Int>
        let text: String
        var bare: String { text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".'’")).replacingOccurrences(of: "’s", with: "").replacingOccurrences(of: "'s", with: "") }
    }

    static func words(_ range: Range<Int>, in text: String) -> [Word] {
        let value = TextRanges.substring(text, range)
        return TextRanges.matches(word, in: value).map { match in
            Word(range: (range.lowerBound + match.range.location)..<(range.lowerBound + NSMaxRange(match.range)), text: (value as NSString).substring(with: match.range))
        }
    }

    /// Verbs that open an instruction about someone: "Call Odalys on …",
    /// "Ask Ama", "Ping Per". Opening a sentence, such a word is never the
    /// first of the name after it, whichever detector read the two together.
    static let commands: Set<String> = ["call", "email", "mail", "ask", "ping", "tell", "text", "message", "contact", "phone", "ring", "telephone",
                                        "remind", "thank", "invite", "notify", "inform", "cc", "bcc", "dm", "meet", "brief", "nudge", "warn", "alert",
                                        "update", "forward", "loop", "reach", "help", "pay", "send", "let", "get", "have", "see", "visit",
                                        "welcome", "congratulate", "thanks", "escalate", "assign", "add", "tag", "mention", "include", "introduce"]
    /// What a record calls the person it is about, written before their name
    /// as a label is ("Customer Tomasz Brightwater", "Patient Odalys"): never
    /// the first of the name after it.
    static let parties: Set<String> = ["customer", "client", "patient", "tenant", "applicant", "claimant", "defendant", "plaintiff", "appellant",
                                       "petitioner", "respondent", "witness", "victim", "suspect", "member", "employee", "resident", "caller", "user",
                                       "subscriber", "borrower", "lender", "debtor", "creditor", "buyer", "purchaser", "seller", "passenger", "student",
                                       "candidate", "contractor", "visitor", "donor", "beneficiary", "landlord", "insured", "policyholder", "cardholder",
                                       "accountholder", "payee", "payer", "recipient", "requester", "requestor", "attendee", "participant", "volunteer",
                                       "homeowner", "renter", "lessee", "lessor", "traveler", "traveller", "guarantor", "complainant", "inmate"]
    /// Whether the word is such a verb opening its sentence or line.
    static func commands(_ word: Word, in text: String) -> Bool {
        commands.contains(word.bare) && word.text.first?.isUppercase == true && NameCues.opens(word.range, in: text)
    }

    /// A person read with the verb that opens its sentence ("Call Odalys"),
    /// cut to the name after it; nil when the verb was all there was. Any
    /// other span is returned as it is.
    static func withoutCommand(_ span: Span, in text: String) -> Span? {
        guard span.entity == "PERSON" else { return span }
        let parts = words(span.range, in: text)
        guard let first = parts.first, commands(first, in: text) else { return span }
        guard let rest = parts.dropFirst().first(where: { !joining.contains($0.bare) }) else { return nil }
        // "Call Center" was never anyone: what is left must hold a name or a word no list calls ordinary.
        let kept = parts.filter { $0.range.lowerBound >= rest.range.lowerBound }
        guard kept.contains(where: { NameLists.isName($0.bare) || !NameLists.isOrdinary($0.bare) }) else { return nil }
        return Span(range: rest.range.lowerBound..<span.range.upperBound, entity: span.entity, score: span.score)
    }

    /// Words a reader takes in with the name after them that are none of it: a speaker
    /// introducing themself ("I'm Bartholomew Ng") and a time's half of the day ("4:12 PM Jasper Thornquist").
    private static let openers: Set<String> = ["i'm", "i’m", "im", "i've", "i’ve", "i'd", "i’d", "i'll", "i’ll", "here", "there", "that", "who", "what"]
    private static func opener(_ word: Word) -> Bool {
        openers.contains(word.bare) && word.text.contains(where: { $0 == "'" || $0 == "’" }) || ["AM", "PM"].contains(word.text)
    }

    static func isRole(_ word: String) -> Bool {
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".'’"))
        // "Private Ellery", "Major Quist": a rank that is also a word counts only with its capital.
        if WrittenNames.wordRanks.contains(bare) { return word.first?.isUppercase == true }
        return WrittenNames.isRole(bare) || bare.hasSuffix("s") && WrittenNames.isRole(String(bare.dropLast()))
    }

    /// A person found by a detector that reads words, trimmed of what no name
    /// holds, or nil when nothing of a name is left. Titles stay: the stand-in
    /// keeps them ("Ms E. Okafor" becomes "Ms K. Andrews").
    static func trimmed(_ span: Span, in text: String) -> Span? {
        guard span.entity == "PERSON" else { return span }
        var parts = words(span.range, in: text)
        guard !parts.isEmpty else { return span }
        // "Wing Commander Rodgers": a rank before a name is no part of it, nor a role after one.
        if let role = parts.lastIndex(where: { isRole($0.text) }), role < parts.count - 1, parts[(role + 1)...].contains(where: { !isRole($0.text) && !joining.contains($0.bare) }) {
            parts.removeFirst(role + 1)
        }
        // A rank goes before a name, so one after a first name or a word no
        // list calls ordinary is a surname: "Evan Ensign", "Germini Major".
        func surnamed(_ index: Int) -> Bool {
            guard index > 0, WrittenNames.ranks.contains(parts[index].bare) || WrittenNames.wordRanks.contains(parts[index].bare) else { return false }
            let before = parts[index - 1]
            return before.text.first?.isUppercase == true && !isRole(before.text) && !joining.contains(before.bare)
                && (NameLists.isFirst(before.bare) || !NameLists.isOrdinary(before.bare))
        }
        var trailingRole = false
        while let last = parts.last, isRole(last.text) && !surnamed(parts.count - 1) || joining.contains(last.bare) {
            trailingRole = trailingRole || isRole(last.text)
            parts.removeLast()
        }
        while let first = parts.first, isRole(first.text) || joining.contains(first.bare) || commands(first, in: text) || parts.count > 1 && opener(first) { parts.removeFirst() }
        // "at 4:12 PM Jasper Thornquist": the time's half of the day and its zone go with the time.
        while parts.count > 1, clock.contains(parts[0].bare), afterTime(parts[0].range.lowerBound, in: text) { parts.removeFirst() }
        // "Customer Tomasz O'Sullivan": the word for whose record it is goes; "Customer Service" was never anyone.
        if let first = parts.first, parties.contains(first.bare), first.text.first?.isUppercase == true {
            let rest = parts.dropFirst().filter { !joining.contains($0.bare) }
            guard rest.contains(where: { NameLists.isName($0.bare) || !NameLists.isOrdinary($0.bare) }) else { return nil }
            parts.removeFirst()
        }
        // "Assistant Secretary": the ordinary words before a role are part of the
        // role, not a name ("Sergeant Gamble" is someone).
        if trailingRole, parts.allSatisfy({ NameLists.isOrdinary($0.bare) && !NameLists.isName($0.bare) }) { return nil }
        // What is left must hold more than initials.
        guard parts.contains(where: { $0.bare.count >= 2 && !People.isTitle($0.text) }) else { return nil }
        if isDate(parts, in: text) { return nil }
        // A word's own full stop stays only on an initial or a title ("S.", "Dr.").
        var end = parts.last!.range.upperBound
        if let last = parts.last, last.text.hasSuffix("."), last.bare.count >= 2, !People.isTitle(last.text) { end -= 1 }
        let range = parts.first!.range.lowerBound..<end
        if range == span.range { return span }
        // Only cut, never grown.
        guard range.lowerBound >= span.range.lowerBound, range.upperBound <= span.range.upperBound, !range.isEmpty else { return nil }
        return Span(range: range, entity: span.entity, score: span.score)
    }

    /// The words a clock time writes after its digits: its half of the day and its zone.
    private static let clock: Set<String> = ["am", "pm", "utc", "gmt", "est", "edt", "cst", "cdt", "mst", "mdt", "pst", "pdt", "bst", "cet", "cest", "ist"]
    /// Whether `start` follows a clock time ("4:12", "16:05", "9"), across spaces and the clock's words before it.
    private static func afterTime(_ start: Int, in text: String) -> Bool {
        let before = (text as NSString).substring(to: start)
        return before.range(of: #"\d(?:[ \t]*(?i:a\.?m\.?|p\.?m\.?|utc|gmt|[a-z]{1,2}[sd]t|bst|cet|cest|ist))*[ \t]*$"#, options: .regularExpression) != nil
    }

    /// A month or weekday written as part of a date: "June 22", "22 June",
    /// "June. 8", "Tuesday, June 12", "in May and June". A person called June
    /// is followed by what she did.
    /// Whether `range` opens a sentence, a small word follows it, and the line it is on
    /// reads as written in a language other than English.
    static func opensForeignSentence(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        var before = range.lowerBound
        while before > 0, ns.character(at: before - 1) == 32 || ns.character(at: before - 1) == 9 { before -= 1 }
        guard before == 0 || [10, 13, 46, 33, 63, 58].contains(ns.character(at: before - 1)) else { return false }
        let after = ns.substring(with: NSRange(location: range.upperBound, length: min(8, ns.length - range.upperBound)))
        guard after.first == " ", after.dropFirst().first?.isLowercase == true else { return false }
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: range.lowerBound, length: 0)))
        guard line.split(separator: " ").count >= 3 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(line.prefix(400)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return false }
        return language != .english && confidence >= 0.6
    }
    private static func isDate(_ parts: [Word], in text: String) -> Bool {
        guard parts.allSatisfy({ months.contains($0.bare) || weekdays.contains($0.bare) || $0.bare == "and" }) else { return false }
        let ns = text as NSString
        let after = ns.substring(with: NSRange(location: parts.last!.range.upperBound, length: min(16, ns.length - parts.last!.range.upperBound)))
        let beforeStart = max(0, parts.first!.range.lowerBound - 16)
        let before = ns.substring(with: NSRange(location: beforeStart, length: parts.first!.range.lowerBound - beforeStart))
        if after.range(of: #"^[.,]?[ \t]*\d"#, options: .regularExpression) != nil { return true }
        if before.range(of: #"\d(?:st|nd|rd|th)?[ \t]+$"#, options: .regularExpression) != nil { return true }
        if before.range(of: #"(?i)\b(?:in|during|since|until|till|by|through|from|early|late|mid|last|next|this|of|every|each|on)[ \t]+$"#, options: .regularExpression) != nil { return true }
        if before.range(of: #"(?i)\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|may|june|july|august|september|october|november|december)[ \t]*(?:,|and|or|to|-|–)[ \t]*$"#, options: .regularExpression) != nil { return true }
        return after.range(of: #"(?i)^[ \t]*(?:,|and|or|to|-|–)[ \t]*(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|may|june|july|august|september|october|november|december)\b"#, options: .regularExpression) != nil
    }

    /// A guess of the name model's made of ordinary words only ("Gas Day",
    /// "Total Life", "Article", "art. 47", "Advisers"), none of them a name
    /// that is no word, and with nothing around it that marks a name. The
    /// model reads shape and context, not vocabulary, so a capitalised word
    /// before a number or at a line's start looks to it like a name.
    static func ordinaryGuess(_ span: Span, in text: String) -> Bool {
        guard span.entity == "PERSON" else { return false }
        let parts = words(span.range, in: text)
        // A word opening a sentence in another language ("Zorg ervoor dat u …", "Hierzu zählen …") is
        // that language's word: only the lists, or a cue, make it someone there.
        if parts.count == 1, !NameLists.isFirst(parts[0].bare), !NameLists.isSurname(parts[0].bare), !NameCues.strong(span.range, in: text),
           opensForeignSentence(span.range, in: text) { return true }
        guard !parts.isEmpty, parts.allSatisfy({ NameLists.isOrdinary($0.bare) || joining.contains($0.bare) || isRole($0.text) }),
              !parts.contains(where: { NameLists.isName($0.bare) }) else { return false }
        if NameCues.strong(span.range, in: text) { return false }
        // "Commissioner Wood", "Sergeant Gamble": a rank names the one after it.
        if parts.count > 1, isRole(parts[0].text), !parts.dropFirst().contains(where: { isRole($0.text) }) { return false }
        guard parts.count == 1 else { return true }
        // "Faith confirmed", "for Ken.", "Ken's office": a first name written as a name is someone;
        // so is a surname listed before a first name ("; Hunter, Larry").
        return !(NameLists.isFirst(parts[0].bare) && NameCues.position(span.range, in: text) || NameCues.listedLastFirst(span.range, in: text))
    }
}

/// Where a word stands as a name: after a title or "named", in a greeting
/// or above a sign-off, or before "said" or "wrote".
enum NameCues {
    private static let before: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "dame", "named", "called", "dear", "hi", "hello", "hey", "thanks", "cheers", "regards", "love", "cc", "attn", "attention"]
    private static let letters = TextPattern(#"[A-Za-z]+"#)
    private static let initialBefore = TextPattern(#"(?<![\p{L}.])\p{Lu}\.[ \t]+$"#)
    private static let reporting: Set<String> = ["said", "says", "asked", "asks", "wrote", "writes", "emailed", "phoned", "called", "replied", "told", "thinks", "thought", "mentioned", "added"]
    private static let closing = TextPattern(#"(?i)^[ \t>]*(?:thanks|thank you|many thanks|thanks again|thx|cheers|regards|best regards|kind regards|warm regards|best|best wishes|all the best|sincerely|yours|yours truly|yours sincerely|love|take care|talk soon|see you|ciao)[ \t]*[,.!]*[ \t]*$"#)
    private static let greeting = TextPattern(#"(?i)^[ \t>]*(?:hi|hello|hey|dear|morning|good morning|good afternoon|good evening|greetings|thanks|thank you|hiya|yo)[ \t]+$"#)
    private static let afterGreeting = TextPattern(#"^[ \t]*(?:[,:!—–-]|$|\r)"#)

    private static let irregular: Set<String> = ["said", "says", "left", "told", "sent", "wrote", "took", "gave", "made", "came", "went", "got", "paid", "spoke", "knew", "thought",
                                                 "found", "rang", "brought", "bought", "met", "felt", "kept", "heard", "saw", "ran", "won", "lost", "wants", "needs", "thinks",
                                                 "asks", "writes", "calls", "agrees", "agreed", "is", "was", "has", "had", "will", "would", "can", "could", "should", "might"]
    /// Verbs that tell what someone did, not who: "SAID", "WROTE" in capitals name no one.
    static let verbs = reporting.union(irregular)
    /// The word after is a verb, so the one before is its subject: "Faith
    /// confirmed", "Will asked". "Gas Day January", "Article 47" are no clause.
    static func acts(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        guard range.upperBound < ns.length, ns.character(at: range.upperBound) == 32 else { return false }
        guard let next = Context.words(after: range.upperBound, in: text, limit: 1, pattern: letters).first, next.first?.isLowercase == true else { return false }
        return irregular.contains(next) || next.count > 4 && next.hasSuffix("ed") && NameLists.isOrdinary(next)
    }

    /// Written as a name: with a cue, as a clause's subject, before "'s", or
    /// capitalised inside a sentence beside a lowercase word ("told Hunt that",
    /// "the Long family"). Opening a sentence or a heading proves nothing.
    static func position(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        guard !range.isEmpty, let first = Unicode.Scalar(ns.character(at: range.lowerBound)), CharacterSet.uppercaseLetters.contains(first) else { return false }
        if strong(range, in: text) || acts(range, in: text) { return true }
        if range.upperBound + 1 < ns.length, [39, 0x2019].contains(ns.character(at: range.upperBound)), ns.character(at: range.upperBound + 1) == 115 { return true }
        var at = range.lowerBound
        while at > 0, ns.character(at: at - 1) == 32 || ns.character(at: at - 1) == 9 { at -= 1 }
        if paired(range, ns) { return true }
        guard at > 0, let mark = Unicode.Scalar(ns.character(at: at - 1)), !".!?:;\"“(\n\r-–—•*>".unicodeScalars.contains(mark) else { return false }
        let previous = Context.words(before: range.lowerBound, in: text, limit: 1, pattern: letters).first
        let next = Context.words(after: range.upperBound, in: text, limit: 1, pattern: letters).first
        // A name learned elsewhere must not turn "a Rod" or "an Amber" into that person.
        if previous.map({ ["a", "an"].contains($0.lowercased()) }) == true { return false }
        return previous?.first?.isLowercase == true || next?.first?.isLowercase == true
    }

    /// Whether the word opens a sentence, a line or a heading, where any word has a capital.
    static func opens(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        var at = range.lowerBound
        while at > 0, ns.character(at: at - 1) == 32 || ns.character(at: at - 1) == 9 { at -= 1 }
        guard at > 0, let mark = Unicode.Scalar(ns.character(at: at - 1)) else { return true }
        return ".!?:;\"“(\n\r-–—•*>".unicodeScalars.contains(mark)
    }
    /// Written as a name, for a word a dictionary holds and no list of names
    /// does ("Refund"): opening a sentence, only a title, a greeting or a
    /// sign-off says so; "Refund approved" is a word before its verb.
    static func namedWord(_ range: Range<Int>, in text: String) -> Bool {
        position(range, in: text) && (!opens(range, in: text) || strong(range, in: text))
    }

    private static let pairedAfter = TextPattern(#"^[ \t]*(?:&|and)[ \t]+(\p{Lu}\p{Ll}+)"#)
    private static let pairedBefore = TextPattern(#"(\p{Lu}\p{Ll}+)[ \t]+(?:&|and)[ \t]*$"#)
    /// Two first names joined: "Wade & Heidi", "Holly and Grace".
    private static func paired(_ range: Range<Int>, _ ns: NSString) -> Bool {
        let after = ns.substring(with: NSRange(location: range.upperBound, length: min(24, ns.length - range.upperBound)))
        let start = max(0, range.lowerBound - 24)
        let before = ns.substring(with: NSRange(location: start, length: range.lowerBound - start))
        for (pattern, piece) in [(pairedAfter, after), (pairedBefore, before)] {
            if let match = TextRanges.matches(pattern, in: piece).first, NameLists.isFirst((piece as NSString).substring(with: match.range(at: 1))) { return true }
        }
        return false
    }

    private static let firstAfterComma = TextPattern(#"^,[ \t]*(\p{Lu}\p{Ll}+)\b"#)
    /// "Hunter, Larry" in a list of people: the line or a semicolon before, a first name after.
    static func listedLastFirst(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        let after = ns.substring(with: NSRange(location: range.upperBound, length: min(32, ns.length - range.upperBound)))
        guard let match = TextRanges.matches(firstAfterComma, in: after).first, NameLists.isFirst((after as NSString).substring(with: match.range(at: 1))) else { return false }
        var at = range.lowerBound
        while at > 0, ns.character(at: at - 1) == 32 || ns.character(at: at - 1) == 9 { at -= 1 }
        return at == 0 || [10, 13, 59, 58].contains(ns.character(at: at - 1))
    }

    static func strong(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        let words = Context.before(range, in: text, limit: 1)
        // A title or a rank before the word: "Ms Rose", "Sergeant Gamble".
        if !words.isDisjoint(with: before) || words.contains(where: { NameShape.isRole($0) && $0 != "agent" }) { return true }
        // An initial before the word: "J. Green".
        let start = max(0, range.lowerBound - 4)
        if TextRanges.matches(initialBefore, in: ns.substring(with: NSRange(location: start, length: range.lowerBound - start))).count > 0 { return true }
        if let next = Context.words(after: range.upperBound, in: text, limit: 1, pattern: letters).first?.lowercased(), reporting.contains(next) { return true }
        return greeted(range, ns) || signs(range, ns)
    }

    /// "Hi Ama," or "Ama," opening a line, or "Dear Ama Okafor:".
    static func greeted(_ range: Range<Int>, _ ns: NSString) -> Bool {
        let line = ns.lineRange(for: NSRange(location: range.lowerBound, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: range.lowerBound - line.location))
        let tailEnd = NSMaxRange(line)
        let tail = ns.substring(with: NSRange(location: range.upperBound, length: max(0, tailEnd - range.upperBound)))
        guard !TextRanges.matches(afterGreeting, in: tail).isEmpty else { return false }
        if head.trimmingCharacters(in: CharacterSet(charactersIn: " \t>")).isEmpty { return tail.trimmingCharacters(in: .whitespacesAndNewlines).first.map { ",:!".contains($0) } == true }
        return !TextRanges.matches(greeting, in: head).isEmpty
    }

    /// A name alone on its line under "Thanks," or "Regards,".
    static func signs(_ range: Range<Int>, _ ns: NSString) -> Bool {
        let line = ns.lineRange(for: NSRange(location: range.lowerBound, length: 0))
        let own = ns.substring(with: line).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n-–—~>*"))
        guard own == ns.substring(with: NSRange(location: range.lowerBound, length: range.count)).trimmingCharacters(in: .whitespaces) else { return false }
        var at = line.location
        while at > 0 {
            let previous = ns.lineRange(for: NSRange(location: at - 1, length: 0))
            let content = ns.substring(with: previous)
            at = previous.location
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return !TextRanges.matches(closing, in: content.trimmingCharacters(in: .newlines)).isEmpty
        }
        return false
    }
}
