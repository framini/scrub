import Foundation
import NaturalLanguage
import Synchronization

/// What makes a person only a reader guessed (a model, the system tagger, a
/// capital or a shape) sure enough to replace where English is not what the
/// text is written in, or on a log's technical line. Without it the guess is
/// left as written and asked about: a word of the text's own language that a
/// reader took for a name ("Adresse", "Wij", "Buenos") changes what the text says.
///
/// Evidence is a title or a phrase that introduces a name ("Herr", "Sra.",
/// "me llamo", "ik ben"), a label for one ("Nombre:"), a sign-off above it,
/// an email or handle in the text built from it, or a known given name that is
/// no word of the text's language followed by a surname. A name found surely
/// elsewhere in the document is found again wherever it is written (see `GazetteerMatcher`).
enum NameEvidence {
    // MARK: The text's language

    /// The language a piece of text is written in, when the recogniser is sure of it.
    static func language(of text: String) -> NLLanguage? {
        // Words of letters only: a label, a date or an ID says nothing of the language ("DOB: 1981-11-13, ID: QX-…").
        let words = text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 }
        guard words.count >= 5 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        // A short line's guess must be surer: a few labels read as any language.
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= (words.count < 8 ? 0.85 : 0.6) else { return nil }
        return language
    }
    /// The language at `range`: its line's, else the whole text's, else the document's. The name itself is
    /// left out, so a Dutch-looking surname never makes an English line Dutch ("per Achterberg, waive the fee").
    static func language(around range: Range<Int>, in text: String, document: NLLanguage?) -> NLLanguage? {
        let ns = text as NSString
        let masked = ns.replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: " ") as NSString
        let line = masked.substring(with: masked.lineRange(for: NSRange(location: range.lowerBound, length: 0)))
        if let found = language(of: line) { return found }
        if masked.length > (line as NSString).length, let found = language(of: masked as String) { return found }
        return document
    }

    // MARK: The language's own words

    /// The dictionaries macOS checks spelling with, read on this Mac alone. One check at a
    /// time: the checker answers wrongly now and then when several threads ask at once.
    private static let checked = Mutex<[String: Bool]>([:])
    private static let dictionaries: [NLLanguage: [String]] = [
        .german: ["de"], .spanish: ["es"], .portuguese: ["pt_PT", "pt_BR"], .french: ["fr"], .italian: ["it"], .dutch: ["nl"],
        .polish: ["pl"], .swedish: ["sv"], .turkish: ["tr"], .vietnamese: ["vi"], .danish: ["da"], .norwegian: ["nb"], .finnish: ["fi"],
        .czech: ["cs"], .romanian: ["ro"], .hungarian: ["hu"], .indonesian: ["id"],
    ]
    /// Whether Scrub can tell this language's words from names.
    static func readable(_ language: NLLanguage) -> Bool { dictionaries[language] != nil }
    /// The system's spell checker, reached through the runtime: importing its framework
    /// here would make the whole module slower to compile. Nil where it can't be loaded; only used under `checked`'s lock.
    private typealias Check = @convention(c) (AnyObject, Selector, NSString, Int, NSString?, Bool, Int, UnsafeMutablePointer<Int>?) -> NSRange
    nonisolated(unsafe) private static let checker: (object: AnyObject, check: Check)? = {
        guard Bundle(path: "/System/Library/Frameworks/AppKit.framework")?.load() == true,
              let type = NSClassFromString("NSSpellChecker") as? NSObject.Type, let shared = type.value(forKey: "sharedSpellChecker") as? NSObject else { return nil }
        let selector = NSSelectorFromString("checkSpellingOfString:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:")
        guard shared.responds(to: selector) else { return nil }
        return (shared, unsafeBitCast(shared.method(for: selector), to: Check.self))
    }()
    private static func inDictionary(_ word: String, _ language: NLLanguage) -> Bool {
        guard let codes = dictionaries[language], !word.isEmpty else { return false }
        let key = language.rawValue + "\u{0}" + word
        return checked.withLock { known in
            if let found = known[key] { return found }
            guard let checker else { return false }
            let selector = NSSelectorFromString("checkSpellingOfString:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:")
            let found = codes.contains { code in checker.check(checker.object, selector, word as NSString, 0, code as NSString, false, 0, nil).location == NSNotFound }
            known[key] = found
            return found
        }
    }
    /// A word the language's dictionary holds: written in small letters ("ernst", "jong"),
    /// or only with its capital where no list holds it as a name (a German noun, "Adresse").
    /// Dictionaries hold common names with their capital too ("Ernesto"), never in small letters.
    static func isOrdinary(_ word: String, in language: NLLanguage) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 2, lower.allSatisfy(\.isLetter) else { return false }
        if language == .english || !readable(language) { return NameLists.isOrdinary(lower) || NameLists.isWordlike(lower) }
        if inDictionary(lower, language) { return true }
        let capital = lower.prefix(1).uppercased() + lower.dropFirst()
        return !NameLists.isFirst(lower) && !NameLists.isSurname(lower) && inDictionary(capital, language)
    }

    /// A word the language writes in small letters ("rose", "jong"): a known person's given name that is one is unsure alone.
    static func isLowercaseWord(_ word: String, in language: NLLanguage) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 2, lower.allSatisfy(\.isLetter) else { return false }
        return language == .english || !readable(language) ? NameLists.isOrdinary(lower) || NameLists.isWordlike(lower) : inDictionary(lower, language)
    }

    // MARK: Evidence

    /// Titles and forms of address written before a name, in the languages Scrub reads.
    static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "dame", "herr", "herrn", "frau", "fräulein", "sr", "sra", "srta",
                                              "don", "doña", "dona", "señor", "señora", "señorita", "senhor", "senhora", "m", "mme", "mlle", "monsieur", "madame",
                                              "mademoiselle", "dhr", "mevr", "mevrouw", "meneer", "heer", "sig", "signor", "signora", "signorina", "dott", "dottor",
                                              "dottoressa", "pan", "pani", "fru", "bay", "bayan", "ông", "bà", "anh", "chị", "dra", "ing", "mag",
                                              "maître", "maitre", "me", "avv", "avvocato", "arch", "geom", "rag", "dipl", "drs", "ir", "lic"]
    /// Turkish writes the title after the name: "Barış Bey", "Gülsüm Hanım".
    private static let titlesAfter: Set<String> = ["bey", "hanım", "hanim", "beyefendi", "hanımefendi"]
    /// What introduces a name, ending right before it: "mein Name ist", "me llamo", "ik ben", "nazywam się".
    private static let introduced = TextPattern(#"(?i)(?:\b(?:my name is|i am|this is|named|called|name is|mein name ist|ich bin|ich heiße|hier ist|hier spricht|spricht|me llamo|mi nombre es|soy|je m'appelle|je m’appelle|je suis|je soussignée?|mi chiamo|il mio nome è|sono|meu nome é|me chamo|chamo-me|sou(?: [oa])?|aqui é(?: [oa])?|ik ben|mijn naam is|spreekt met|met|jag heter|jag är|mitt namn är|pratar med|nazywam się|jestem|mam na imię|benim adım|adım|ben|tôi là|tên tôi là|em là)|\b(?:name|full name|nombre|nombre completo|nome|nome completo|nom|nom complet|naam|namn|navn|isim|ad soyad|imię i nazwisko|họ và tên|họ tên)[ \t]*:)[ \t]*$"#)
    /// How a letter or message is signed off, a line above the name alone.
    private static let closings = TextPattern(#"(?i)(?:regards|thanks|thank you|cheers|best|sincerely|grüßen|grüße|gruß|groet|groeten|saludos?|saludo cordial|atentamente|atenciosamente|cumprimentos|abraços|saluti|cordialement|distinguées|distingués|poważaniem|pozdrawiam|pozdrowienia|hälsningar|hälsning|saygılarımla|selamlar|trân trọng)[ \t]*[,.!]*[ \t]*$"#)
    private static let particles: Set<String> = ["de", "da", "das", "do", "dos", "del", "della", "di", "du", "des", "la", "le", "van", "von", "der", "den", "ten", "ter", "zu", "y", "e", "bin", "al", "el"]

    private static let titleBefore = TextPattern("(?i)(?<![\\p{L}\\p{N}])(?:" + titles.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")(?:\\.-?(?:" + People.titleParts.sorted { $0.count > $1.count }.joined(separator: "|") + "))*\\.?[ \\t]+$")
    /// A title or form of address right before the name, or a Turkish one right after it.
    /// Whether a form of address could open a name in `text`: a cheap check before reading them.
    static func mayHoldTitle(_ text: String) -> Bool {
        text.split { !$0.isLetter }.contains { $0.count <= 11 && $0.first?.isUppercase == true && titles.contains($0.lowercased()) }
    }
    static func titled(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        let start = max(0, range.lowerBound - 20)
        if !TextRanges.matches(titleBefore, in: ns.substring(with: NSRange(location: start, length: range.lowerBound - start))).isEmpty { return true }
        return Context.words(after: range.upperBound, in: text, limit: 1).first.map { titlesAfter.contains($0.lowercased()) } == true
    }
    /// A title, a phrase or a label that introduces a name, or a sign-off above it.
    static func cued(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        if titled(range, in: text) { return true }
        // A title written as the name's own first word ("M. Bertrand Lacombe", "Mme Géraldine"), or a Turkish one as its last ("Barış Bey").
        let words = NameShape.words(range, in: text).map { $0.text.lowercased() }
        if words.count >= 2, titles.contains(words[0]) || titlesAfter.contains(words[words.count - 1]) { return true }
        // An English cue, only where it stands on the name's own line with nothing but spaces after it: a letter's
        // "Geachte heer of mevrouw," on the line above greets no one by name.
        var lead = range.lowerBound
        while lead > 0, ns.character(at: lead - 1) == 32 || ns.character(at: lead - 1) == 9 { lead -= 1 }
        if lead > 0, let mark = Unicode.Scalar(ns.character(at: lead - 1)), CharacterSet.letters.contains(mark) || mark == ".", NameCues.strong(range, in: text, opening: false) { return true }
        let line = ns.lineRange(for: NSRange(location: range.lowerBound, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: range.lowerBound - line.location))
        if !TextRanges.matches(introduced, in: String(head.suffix(48))).isEmpty { return true }
        // Alone on its line under a sign-off.
        let own = ns.substring(with: line).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n-–—~>*,."))
        guard own == ns.substring(with: NSRange(location: range.lowerBound, length: range.count)), line.location > 0 else { return false }
        var at = line.location
        while at > 0 {
            let previous = ns.lineRange(for: NSRange(location: at - 1, length: 0))
            let content = ns.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
            at = previous.location
            if content.isEmpty { continue }
            return !TextRanges.matches(closings, in: content).isEmpty
        }
        return false
    }
    /// A known given name that is no word of the language, then a surname: each word after it a
    /// known name or no word of the language, with a surname's particles between ("Pieter de Jong").
    static func paired(_ range: Range<Int>, in text: String, language: NLLanguage) -> Bool {
        let words = NameShape.words(range, in: text).filter { !particles.contains($0.text.lowercased()) || $0.text.first?.isUppercase == true }
        guard words.count >= 2, words.allSatisfy({ $0.text.first?.isUppercase == true }) else { return false }
        let first = words[0].text.trimmingCharacters(in: CharacterSet(charactersIn: ".'’"))
        // A given name the lists know, or one the language's dictionary holds only as a proper name ("Maarten").
        // German writes every noun with a capital, so there only the lists say.
        let given = NameLists.isFirst(first) || language != .german && readable(language) && inDictionary(first.prefix(1).uppercased() + first.dropFirst().lowercased(), language)
        guard first.count >= 2, given, !isOrdinary(first, in: language) else { return false }
        return words.dropFirst().allSatisfy { word in
            let bare = word.text.trimmingCharacters(in: CharacterSet(charactersIn: ".'’"))
            if bare.count == 1 { return true }
            if bare.contains("-") { return bare.split(separator: "-").allSatisfy { NameLists.isSurname(String($0)) || !isOrdinary(String($0), in: language) } }
            return NameLists.isSurname(bare) || NameLists.isFirst(bare) || !isOrdinary(bare, in: language)
        }
    }
    private static let mailbox = TextPattern(#"[\p{L}\p{N}._%+-]+@[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+|(?<![\p{L}\p{N}])@[\p{L}\p{N}._-]{3,}"#)
    /// An email or handle in the text built from a word of the name ("barış.k@…" beside "Barış").
    static func handled(_ range: Range<Int>, in text: String) -> Bool {
        func folded(_ word: String) -> String { word.lowercased().folding(options: .diacriticInsensitive, locale: nil) }
        let names = Set(NameShape.words(range, in: text).map { folded($0.text) }.filter { $0.count >= 3 })
        guard !names.isEmpty else { return false }
        return TextRanges.matches(mailbox, in: text).contains { match in
            let local = (text as NSString).substring(with: match.range).split(separator: "@").first.map(String.init) ?? ""
            return !names.isDisjoint(with: local.split(whereSeparator: { ".-_+0123456789".contains($0) }).map { folded(String($0)) })
        }
    }

    // MARK: Lines and spans that hold no one

    private static let technical = TextPattern(#"(?im)^[ \t]*(?:[*<>$][ \t]|\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}|\[?\d{2}:\d{2}:\d{2}[\] ]|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[ \t]+\d{1,2}[ \t]+\d{2}:\d{2}:\d{2}[ \t]|\[?(?:INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL|NOTICE)\b)|\bHTTP/\d|\b(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /|\b(?:TLS|SSL)v?\d?\b"#)
    /// A log's or a tool's line: a timestamp (a system log's "Oct  9 03:12:44" too) or level opening it, a command's or a transfer's marks, an HTTP request.
    static func technicalLine(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: range.lowerBound, length: 0)))
        return !TextRanges.matches(technical, in: line).isEmpty
    }
    /// The forms a company's name ends with: "Lda.", "Cía. Ltda.", "y Cía.", "e Hijos", "& Co.", "S.A.C.", "S. de R.L.", "EIRL", "S.A.", "GmbH", "B.V.", "S.r.l.", "Ltd", "Co., Ltd.", "Sdn Bhd", "K.K.", "A.Ş.", "d.o.o.", "Sp. z o.o.", "ООО".
    static let companyForm = #"(?:C[íi]a\.?\s?Ltda|y\s?C[íi]a|C[íi]a|e\s?Hijos|&\s?Co|S\.?\s?de\s?R\.?\s?L|S\.?A\.?C|S\.?R\.?L|EIRL|S\.?A\.?\s?de\s?C\.?V|GmbH\s?&\s?Co\.?\s?KG|\(Pty\)\s?Ltd|Co\.?,?\s?Ltd|Pte\.?\s?Ltd|Pvt\.?\s?Ltd|Sdn\.?\s?Bhd|Bhd|Berhad|K\.K|G\.?K|Lda|Ltda|S\.?A\.?S?|S\.?L\.?U?|S\.?r\.?l|S\.?p\.?A|S\.?A\.?R\.?L|SARL|GmbH|AG|KG|OHG|e\.?V|B\.?V|N\.?V|V\.?O\.?F|Ltd|Limited|LLC|LLP|L\.?P|Inc|Corp|Co|PLC|AB|ASA|AS|A/S|ApS|Oy|Oyj|A\.?Ş|Ltd\.?\s?Şti|[sS]p\.?\s?z\s?o\.?\s?o|[dD]\.?\s?o\.?\s?o|[sS]\.?\s?r\.?\s?o|S\.?C|SpA|Srl|SAS|SE|S\.?C\.?A|Unipessoal|EIRELI|ME|EPP|Pty|BVBA|SRL|OÜ|SIA|UAB|Kft|Zrt|Nyrt|Bt|Α\.?Ε|Ε\.?Π\.?Ε|ΙΚΕ|ЕООД|ООД|ЕАД|ООО|ОАО|ЗАО|ТОВ|ПАО)\.?"#
    private static let formAround = TextPattern(#"(?:^|[ \t,])"# + companyForm + #"(?![\p{L}\p{N}])"#)
    private static let formOnly = TextPattern(#"^"# + companyForm + #"$"#)
    private static let formAfter = TextPattern(#"^,?[ \t]+"# + companyForm + #"(?![\p{L}\p{N}])"#)
    private static let formAhead = TextPattern(#"^(?:[ \t]+\p{Lu}[\p{L}\p{M}'’&-]*){1,3},?[ \t]+"# + companyForm + #"(?![\p{L}\p{N}])"#)
    private static let formEnding = TextPattern(#"^\p{L}[\p{L}\p{M}\p{N}'’&.\- ]*?,?[ \t]+("# + companyForm + #")$"#)
    private static let formBefore = TextPattern(#"(?:^|[ \t,])"# + companyForm + #",?[ \t]+$"#)
    /// A place written right after a company's form is the company's seat ("Primer Trgovina d.o.o. Beograd",
    /// "Example GmbH, Köln"): it names where the company is, not where anyone lives.
    static func seat(_ span: Span, in text: String) -> Bool {
        guard span.entity == "LOCATION", span.range.lowerBound > 0 else { return false }
        let ns = text as NSString, start = max(0, span.range.lowerBound - 32)
        return !TextRanges.matches(formBefore, in: ns.substring(with: NSRange(location: start, length: span.range.lowerBound - start))).isEmpty
    }
    /// Whether a whole value is a company's name: words, then the form it ends with ("Example Distribuidora S.A.").
    static func companyName(_ value: String) -> Bool { companyNameForm(value) != nil }
    /// The form a company's whole name ends with ("Unipessoal Lda." of "… Unipessoal Lda." reads "Lda."), nil for no company's name.
    static func companyNameForm(_ value: String) -> String? {
        TextRanges.matches(formEnding, in: value).first.map { (value as NSString).substring(with: $0.range(at: 1)) }
    }
    /// A name ending in a company's form, or followed by one, is an organisation's ("Example Lisboa Consultoria, Lda."),
    /// as is one a reader ended inside its form ("Example Arredamenti S" of "S.r.l.") or that opens one, and the
    /// form alone names no one. A company's name is no place either.
    static func company(_ span: Span, in text: String) -> Bool {
        let ns = text as NSString
        let value = ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
        if !TextRanges.matches(formOnly, in: value).isEmpty { return true }
        let after = ns.substring(with: NSRange(location: span.range.upperBound, length: min(48, ns.length - span.range.upperBound)))
        // "Haugen" of "Haugen Eiendom AS": the start of a company's name, its form a few words on.
        if !TextRanges.matches(formAfter, in: after).isEmpty || !TextRanges.matches(formAhead, in: after).isEmpty { return true }
        let joined = (value + after) as NSString, end = (value as NSString).length
        return TextRanges.matches(formAround, in: joined as String).contains { match in
            match.range.location <= end && NSMaxRange(match.range) >= end && match.range.location > 0 || match.range.location == 0 && NSMaxRange(match.range) >= end
        }
    }

    /// "Ik ben Lotte", "dla Jana Nowaka", "geboren Schulz": a word of the text's language written in small letters,
    /// with only a name's capitalised words after it, is no part of the name, nor is any word before it. A surname's
    /// particles ("van", "de") are, and a name written all in small letters is left as it was found. Only where the
    /// language is one Scrub has the words of: in English a first name is written in small letters too often ("rose Martinez").
    static func withoutLeadingWords(_ spans: [Span], in text: String, document: NLLanguage?) -> [Span] {
        spans.map { span in
            guard ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(span.entity), span.url == nil else { return span }
            let words = NameShape.words(span.range, in: text)
            guard words.count >= 2, let cut = words.indices.dropLast().last(where: { index in
                let word = words[index].text
                return word == word.lowercased() && word.allSatisfy(\.isLetter) && !particles.contains(word)
            }), words[(cut + 1)...].allSatisfy({ $0.text.first?.isUppercase == true }) else { return span }
            guard let language = language(around: span.range, in: text, document: document), language != .english, readable(language),
                  isLowercaseWord(words[cut].text, in: language) else { return span }
            return Span(range: words[cut + 1].range.lowerBound..<span.range.upperBound, entity: span.entity, score: span.score)
        }
    }

    /// "Ik ben", "dla": short words of the text's language, two or more or one in small letters, are no one to ask about.
    /// One alone with its capital ("Ben") may still be someone.
    static func smallWords(_ span: Span, in text: String, document: NLLanguage?) -> Bool {
        guard ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(span.entity) else { return false }
        let words = NameShape.words(span.range, in: text)
        guard !words.isEmpty, words.count >= 2 || words[0].text == words[0].text.lowercased(),
              let language = language(around: span.range, in: text, document: document), language != .english, readable(language) else { return false }
        return words.allSatisfy { $0.text.count <= 3 && isLowercaseWord($0.text, in: language) }
    }

    // MARK: Places

    private static let postcodeBefore = TextPattern(#"(?<![\p{L}\p{N}])(?:[A-Z]{1,2}-)?\d{4,5}(?:[ \t]?[A-Z]{2})?[ \t]+$"#)
    private static let postcodeAfter = TextPattern(#"^,?[ \t]+(?:[A-Z]{1,2}-)?\d{4,5}(?![\p{L}\p{N}])"#)
    /// Whether a place has more to it than a reader's guess: a place Scrub knows ("Leipzig"), a postcode beside it
    /// ("34117 Kassel"), an address it touches or that names it, or a key that names a place.
    static func placed(_ span: Span, among spans: [Span], key: String?, in text: String) -> Bool {
        if let hint = KeyHints.hint(key), hint == "LOCATION" || hint == "ADDRESS" { return true }
        let ns = text as NSString
        if AddressBlock.knownPlace(ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))) { return true }
        let start = max(0, span.range.lowerBound - 16), end = min(ns.length, span.range.upperBound + 16)
        if !TextRanges.matches(postcodeBefore, in: ns.substring(with: NSRange(location: start, length: span.range.lowerBound - start))).isEmpty
            || !TextRanges.matches(postcodeAfter, in: ns.substring(with: NSRange(location: span.range.upperBound, length: end - span.range.upperBound))).isEmpty { return true }
        // An address it touches, or one elsewhere in the text that ends in it ("geboren in Kassel" beside "Lindenstraße 14, 34117 Kassel").
        let place = ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
        return spans.contains { other in
            other.entity == "ADDRESS" && (other.range.lowerBound <= span.range.upperBound + 3 && span.range.lowerBound <= other.range.upperBound + 3
                || TextRanges.substring(text, other.range).split(whereSeparator: { !$0.isLetter }).suffix(3).joined(separator: " ").hasSuffix(place.split(whereSeparator: { !$0.isLetter }).joined(separator: " ")))
        }
    }
    /// German's prepositions of place, which take a town's name with no article ("in Kassel", "nach Kassel") and a noun with one ("in der Stadt").
    private static let placePrepositions: Set<String> = ["in", "nach", "aus", "bei", "von", "ab", "über", "nahe"]
    /// Whether every word of the span is one of the language's own: in small letters, or, in German, which writes
    /// its nouns with a capital, as written ("Strom"). In German a preposition of place right before it makes it a town ("in Essen").
    /// A place's own name the dictionary holds only with its capital is no plain word.
    static func plainWords(_ range: Range<Int>, in text: String, language: NLLanguage) -> Bool {
        let words = TextRanges.substring(text, range).split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return false }
        if language == .german, Context.words(before: range.lowerBound, in: text, limit: 1).first.map({ placePrepositions.contains($0.lowercased()) }) == true { return false }
        return words.allSatisfy { word in
            let lower = word.lowercased()
            if language == .english || !readable(language) { return NameLists.isOrdinary(lower) }
            return inDictionary(lower, language) || language == .german && inDictionary(lower.prefix(1).uppercased() + lower.dropFirst(), language)
        }
    }

    // MARK: The gate

    /// Greetings and words of thanks a message opens with, in languages Scrub has no dictionary of: "Dumela", "Sawubona",
    /// "Habari", "Jambo", "Asante", "Salamat", "Sige", "Po", "Terima kasih", "Selamat pagi".
    private static let greetings: [[String]] = [
        ["dumela"], ["dumelang"], ["sawubona"], ["sanibonani"], ["habari"], ["jambo"], ["asante", "sana"], ["asante"], ["karibu"], ["salamat", "po"], ["salamat"],
        ["sige", "po"], ["sige"], ["po"], ["opo"], ["mabuhay"], ["kumusta"], ["terima", "kasih"], ["selamat", "pagi"], ["selamat", "siang"], ["selamat", "sore"],
        ["selamat", "malam"], ["selamat", "datang"], ["selamat"], ["siyabonga"], ["ngiyabonga"], ["ke", "a", "leboga"], ["re", "a", "leboga"],
    ]
    /// How many of `words`, from the first, a greeting is: 0 where none opens them.
    static func greetingLength(_ words: [String]) -> Int {
        var at = 0
        while let phrase = greetings.first(where: { phrase in at + phrase.count <= words.count && Array(words[at..<(at + phrase.count)]) == phrase }) { at += phrase.count }
        return at
    }
    /// A name only guessed where the text's language is not English and is none Scrub has the words of, or is too
    /// short to tell: a capitalised word opening a sentence with a comma after it ("Sige, …"), a name written all
    /// in small letters ("tumepokea hati zako"), or words a likely language's dictionary holds ("Hendes pas er udløbet")
    /// are no name unless a name list holds them.
    private static func unread(_ span: Span, in text: String, around language: NLLanguage?) -> Bool {
        guard language != .english else { return false }
        let words = NameShape.words(span.range, in: text)
        guard !words.isEmpty, !words.allSatisfy({ NameLists.isFirst($0.text) || NameLists.isSurname($0.text) }) else { return false }
        let ns = text as NSString
        let lines = ns.lineRange(for: NSRange(location: span.range.lowerBound, length: 0))
        // The line without the name: a name says nothing of the language around it.
        let line = ns.substring(with: NSRange(location: lines.location, length: span.range.lowerBound - lines.location)) + " "
            + ns.substring(with: NSRange(location: span.range.upperBound, length: max(0, NSMaxRange(lines) - span.range.upperBound)))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(line)
        let likely = recognizer.languageHypotheses(withMaximum: 2).filter { $0.value >= 0.2 }.map(\.key)
        guard likely.first != .english else { return false }
        if words.allSatisfy({ $0.text == $0.text.lowercased() }) { return true }
        if likely.contains(where: readable), let read = likely.first(where: readable), words.allSatisfy({ isOrdinary($0.text, in: read) }) { return true }
        guard words.count == 1, !(language.map(readable) ?? false) else { return false }
        let before = ns.substring(with: NSRange(location: lines.location, length: span.range.lowerBound - lines.location)).trimmingCharacters(in: .whitespaces)
        let opens = before.isEmpty || before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?") || before.hasSuffix("\"")
        return opens && span.range.upperBound < ns.length && ns.character(at: span.range.upperBound) == 0x2C
    }

    private static let names: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME"]
    /// People only guessed, where the text is in a language Scrub can read the words of or on a technical
    /// line, kept only with evidence; the rest become doubts. Organisations are no one, and an address that
    /// runs over a date written out is no address. `evidenced`: what rules that read a cue found.
    /// Keys that say their value is a person, in the languages Scrub reads ("cliente", "titular", "Kunde"): evidence for every name in it.
    private static let personKeys: Set<String> = ["cliente", "client", "clients", "customer", "kunde", "kundin", "klant", "titular", "titolare", "musteri", "kund", "klient",
                                                  "nome", "nombre", "nom", "naam", "name", "namn", "isim", "imie", "holder", "applicant", "solicitante", "beneficiario", "contact", "contacto", "contato"]
    static func namesPerson(_ key: String?) -> Bool {
        KeyHints.words(key).contains { personKeys.contains($0.folding(options: .diacriticInsensitive, locale: nil)) }
    }
    /// "Bonjour M. Laurent Dubreuil": a name a reader ran back over a title and the word before it starts after the title,
    /// which stays as written.
    private static let namePartTitles: Set<String> = ["anh", "bà", "ông", "chị", "don", "dona", "doña", "pan", "pani", "bay", "bayan", "me", "m", "sig", "ing",
                                                      "mag", "dra", "fru", "heer", "sr", "sra", "ir", "lic", "rag", "arch"]
    /// A title opening the name in another language ("Sra. Maribel Ocampo", "Bà Lương Thị Hạnh") stays too, where two
    /// names or more follow it; one written as a name is kept ("Mr", "Herr"), so a stand-in fits it.
    static func afterTitle(_ span: Span, in text: String, document: NLLanguage? = nil) -> Span {
        let words = NameShape.words(span.range, in: text)
        // One that is also a given name ("Don", "Doña", "Anh") opens a name as a title only in another language's text.
        func titleOfLanguage(_ index: Int) -> Bool {
            guard NameLists.isFirst(words[index].bare) else { return true }
            return language(around: span.range, in: text, document: document).map { $0 != .english } ?? false
        }
        // A title that is also a name's part or a word ("Anh", "Don", "Pan", "Me") counts only with its full stop,
        // or opening the name where it is no given name Scrub knows ("Doña", "Chị").
        guard words.count >= 3, let index = words.indices.dropLast().last(where: { index in
            guard titles.contains(words[index].bare) else { return false }
            if index == 0 {
                return !People.isTitle(words[0].text) && words[1...].allSatisfy { $0.text.first?.isUppercase == true }
                    && (words[0].text.hasSuffix(".") || !namePartTitles.contains(words[0].bare) || titleOfLanguage(0))
            }
            return words[index].text.hasSuffix(".") || !namePartTitles.contains(words[index].bare)
                || People.leadingTitle(words[index...].map(\.text))
                || words.count - index >= 3 && words[(index + 1)...].allSatisfy { $0.text.first?.isUppercase == true } && titleOfLanguage(index)
        }) else { return span }
        return Span(range: words[index + 1].range.lowerBound..<span.range.upperBound, entity: span.entity, score: span.score, url: span.url)
    }
    private static let joinedTitle = TextPattern(#"(?<![\p{L}\p{N}.-])\p{L}{1,6}\.(?:-?\p{L}{1,6}\.?)+(?![\p{L}\p{N}])"#)
    /// "Univ.-Prof.", "Dipl.-Ing.", "Dr.-Ing.", "Mag.a": a title joined of several is one title, and no piece of it is anyone's
    /// name. A name a reader ran into one starts after it; one inside it is dropped.
    static func withoutJoinedTitles(_ spans: [Span], in text: String) -> [Span] {
        // "Estimada Doña Carmen Ruiz": a name a reader ran back over a title starts after it, however sure the reader.
        let spans = spans.map { names.contains($0.entity) ? afterTitle($0, in: text) : $0 }
        guard text.contains(".") else { return spans }
        let titles = TextRanges.matches(joinedTitle, in: text).filter { People.isTitle((text as NSString).substring(with: $0.range)) }
            .map { $0.range.location..<NSMaxRange($0.range) }
        guard !titles.isEmpty else { return spans }
        return spans.compactMap { span in
            guard names.contains(span.entity), let title = titles.last(where: { $0.overlaps(span.range) }) else { return span }
            guard let next = NameShape.words(span.range, in: text).first(where: { $0.range.lowerBound >= title.upperBound }) else { return nil }
            return Span(range: next.range.lowerBound..<span.range.upperBound, entity: span.entity, score: span.score, url: span.url)
        }
    }
    /// "Sig. Direttore Generale", "Sr. Director General": after a title, words the language's dictionary holds in small
    /// letters, and no list holds as a name, name no one. Dictionaries hold towns and given names with their capital
    /// ("Hoogeveen", "Pieter"), so those count.
    static func ordinaryAfterTitle(_ range: Range<Int>, in text: String, language: NLLanguage) -> Bool {
        guard language != .vietnamese else { return false }
        var words = NameShape.words(range, in: text)
        if let first = words.first, words.count >= 2, titles.contains(first.bare) { words.removeFirst() }
        else if !titled(range, in: text) { return false }
        // A name that is also a word ("Chiara Bassi") is a name still.
        return !words.isEmpty && words.allSatisfy { word in
            isLowercaseWord(word.text, in: language) && !NameLists.isFirst(word.bare) && !NameLists.isSurname(word.bare)
        }
    }
    /// Places only guessed, in the same text, kept only as a place Scrub knows, beside a postcode or an address, or under a place's key
    /// ("Wohnort"); one made of the language's own words ("Kopie Ihres", "Strom") is asked about and left as written.
    static func gate(_ spans: [Span], doubts: [Span], evidenced: [Range<Int>], in text: String, document: NLLanguage?, key: String? = nil) -> (spans: [Span], doubts: [Span]) {
        var kept: [Span] = [], doubted = doubts
        var taken = IndexSet()
        for doubt in doubts where !doubt.range.isEmpty { taken.insert(integersIn: doubt.range) }
        func doubt(_ span: Span) {
            guard !taken.intersects(integersIn: span.range) else { return }
            taken.insert(integersIn: span.range)
            doubted.append(Span(range: span.range, entity: span.entity == "LOCATION" ? "LOCATION" : "PERSON", score: min(span.score, Doubt.unconfirmed.confidence)))
        }
        for found in spans {
            let span = names.contains(found.entity) ? afterTitle(found, in: text, document: document) : found
            let person = names.contains(span.entity)
            if span.entity == "ADDRESS", WrittenDates.holds(TextRanges.substring(text, span.range)) || WrittenDates.yearAlone(TextRanges.substring(text, span.range)) { continue }
            // "Dumela Lerato", "Terima kasih, Budi": a greeting or a word of thanks opens a message, never a name; the name starts after it.
            if person || span.entity == "LOCATION", span.url == nil, case let words = NameShape.words(span.range, in: text), case let greeted = greetingLength(words.map { $0.bare }), greeted > 0 {
                guard greeted < words.count, person else { continue }
                let rest = Span(range: words[greeted].range.lowerBound..<span.range.upperBound, entity: span.entity, score: span.score, url: span.url)
                // A listed name is kept; one no list holds is asked about, never left unseen.
                if words[greeted...].contains(where: { NameLists.isFirst($0.text) || NameLists.isSurname($0.text) }) { kept.append(rest) } else { doubt(rest) }
                continue
            }
            guard (person || span.entity == "LOCATION") && span.url == nil && span.score < 1 && !span.range.isEmpty else { kept.append(span); continue }
            if person || span.entity == "LOCATION", company(span, in: text) { continue }
            if evidenced.contains(where: { $0.overlaps(span.range) }) { kept.append(span); continue }
            let technical = technicalLine(span.range, in: text)
            let language = language(around: span.range, in: text, document: document)
            let foreign = language.map { $0 != .english && readable($0) } ?? false
            if span.entity == "LOCATION" {
                if technical && span.score < 0.9 || (foreign || technical) && !placed(span, among: spans, key: key, in: text)
                    && plainWords(span.range, in: text, language: foreign ? language ?? .english : .english) {
                    doubt(span)
                } else {
                    kept.append(span)
                }
                continue
            }
            if !foreign, !technical, unread(span, in: text, around: language) { doubt(span); continue }
            guard foreign || technical else { kept.append(span); continue }
            if ordinaryAfterTitle(span.range, in: text, language: language ?? .english) { doubt(span); continue }
            if cued(span.range, in: text) || handled(span.range, in: text) || paired(span.range, in: text, language: foreign ? language ?? .english : .english) {
                kept.append(span)
            } else if let rest = NameShape.words(span.range, in: text).dropFirst().first(where: { word in
                cued(word.range.lowerBound..<span.range.upperBound, in: text)
            }) {
                // A reader that took in the words introducing the name ("Ik ben Joris Achterberg") keeps the name alone.
                kept.append(Span(range: rest.range.lowerBound..<span.range.upperBound, entity: span.entity, score: span.score))
            } else {
                doubt(span)
            }
        }
        // A company's name, its form and all ("Penang Rimba Sdn Bhd"), is no one to ask about either.
        doubted.removeAll { smallWords($0, in: text, document: document) || company($0, in: text) }
        doubted.sort { $0.range.lowerBound < $1.range.lowerBound }
        return (kept, doubted)
    }
}

/// Dates written out in words, in the languages Scrub reads: "3 de marzo de 1975", "3. März 1975",
/// "3 mars 1975", "12 maja 1966 r.". One unit: never a house number, a postcode and a street.
enum WrittenDates {
    private static let locales = ["en_US_POSIX", "de", "es", "pt", "fr", "it", "nl", "pl", "sv", "tr", "da", "nb", "fi", "cs", "ro", "hu", "id", "vi", "sk", "hr", "sl", "el"]
    /// Each month's names, in full and short, as a date writes them and as they stand alone, lowercased: month number by name.
    static let months: [String: Int] = {
        var found: [String: Int] = [:]
        for identifier in locales {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            for symbols in [formatter.monthSymbols, formatter.standaloneMonthSymbols, formatter.shortMonthSymbols, formatter.shortStandaloneMonthSymbols] {
                for (index, name) in (symbols ?? []).enumerated() {
                    let word = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    guard word.count >= 3, word.allSatisfy(\.isLetter), found[word] == nil else { continue }
                    found[word] = index + 1
                }
            }
        }
        return found
    }()
    private static let formatters: [String: DateFormatter] = Dictionary(uniqueKeysWithValues: locales.map { identifier in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: identifier)
        return (identifier, formatter)
    })
    /// The locales whose month names write `word`, and whether in full, in the order Scrub reads them.
    static func locales(of word: String) -> [(identifier: String, full: Bool)] {
        let word = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return locales.compactMap { identifier in
            let formatter = formatters[identifier]!
            if (formatter.monthSymbols + formatter.standaloneMonthSymbols).contains(where: { $0.lowercased() == word }) { return (identifier, true) }
            if (formatter.shortMonthSymbols + formatter.shortStandaloneMonthSymbols).contains(where: { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == word }) { return (identifier, false) }
            return nil
        }
    }
    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth",
                                   "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth", "twenty-first", "twenty-second",
                                   "twenty-third", "twenty-fourth", "twenty-fifth", "twenty-sixth", "twenty-seventh", "twenty-eighth", "twenty-ninth", "thirtieth", "thirty-first"]
    private static let firsts: Set<String> = ["premier", "première", "primero", "primeiro", "primo", "întâi"]
    /// Each locale's days of a month spelled out, 1 to 31, lowercased.
    private static let spelled: [(identifier: String, days: [String])] = locales.map { identifier in
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: identifier == "en_US_POSIX" ? "en" : identifier)
        formatter.numberStyle = .spellOut
        return (identifier, (1...31).map { formatter.string(from: NSNumber(value: $0))?.lowercased().replacingOccurrences(of: "\u{AD}", with: "") ?? "" })
    }
    /// A day of the month spelled out in a date ("doce", "twelfth", "huszonegyedikén"): the day, and its stand-in
    /// `day` written the same way where Scrub can write it so, else in digits. Nil for a word that is no day.
    static func spelledDay(_ word: String, as day: Int) -> String? {
        let lower = word.lowercased()
        guard lower.count >= 3, (1...31).contains(day) else { return nil }
        func cased(_ made: String) -> String { word.first?.isUppercase == true ? made.prefix(1).uppercased() + made.dropFirst() : made }
        if ordinals.contains(lower) { return cased(ordinals[day - 1]) }
        // "premier mai", "primero de mayo": a first of the month no other day is written as, so another takes its digits.
        if firsts.contains(lower) { return day == 1 ? word : String(day) }
        for (identifier, days) in spelled where days.contains(lower) { return cased(days[day - 1]) }
        // An ordinal or a case ending on the day's stem ("huszonegyedikén", "dvanáctého"): its digits, as that language writes them.
        for (identifier, days) in spelled where identifier != "en_US_POSIX" {
            if days.contains(where: { $0.count >= 3 && lower.hasPrefix($0) && lower.count - $0.count <= 7 }) || days.contains(where: { $0.count >= 5 && lower.hasPrefix($0.dropLast(1)) && lower.count - $0.count <= 7 }) {
                return String(day) + (["hu", "de", "cs", "sk", "fi", "hr", "sl", "da", "nb", "pl"].contains(identifier) ? "." : "")
            }
        }
        return nil
    }
    /// A weekday's name in a date ("jueves", "Thursday"), written again as `date`'s weekday in its language and case.
    static func weekday(_ word: String, of date: (year: Int, month: Int, day: Int)) -> String? {
        let lower = word.lowercased()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let made = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) else { return nil }
        let index = calendar.component(.weekday, from: made) - 1
        for identifier in locales {
            let formatter = formatters[identifier]!
            for symbols in [formatter.weekdaySymbols, formatter.standaloneWeekdaySymbols] where symbols?.contains(where: { $0.lowercased() == lower }) == true {
                let name = symbols![index]
                if word == word.uppercased() { return name.uppercased() }
                return word.first?.isUppercase == true ? name.prefix(1).uppercased() + name.dropFirst() : name.lowercased()
            }
        }
        return nil
    }
    /// Every weekday's name the locales write, lowercased.
    static let weekdays: Set<String> = Set(locales.flatMap { identifier in
        let formatter = formatters[identifier]!
        return ((formatter.weekdaySymbols ?? []) + (formatter.standaloneWeekdaySymbols ?? [])).map { $0.lowercased() }
    })
    /// How many of the languages that write `word` write month `month` as its stand-in name does.
    static func readers(_ month: Int, like word: String) -> Int {
        let found = locales(of: word)
        let names = found.compactMap { name(month, like: word, in: $0)?.lowercased() }
        return names.map { name in names.filter { $0 == name }.count }.max() ?? 0
    }
    /// The locale Scrub writes months in for text in `language`, nil for one it doesn't.
    static func locale(of language: NLLanguage) -> String? {
        let identifier = language == .english ? "en_US_POSIX" : language == .norwegian ? "nb" : language.rawValue
        return locales.contains(identifier) ? identifier : nil
    }
    /// Month `month`'s name in the language and form `word` is written in, in its case. A word several
    /// languages write ("juli" is Dutch, German and Swedish) takes the name of `language`, the text's,
    /// when it is one of them, else the name most of them write.
    static func name(_ month: Int, like word: String, language: String? = nil) -> String? {
        let found = locales(of: word)
        if let language, let own = found.first(where: { $0.identifier == language }) { return name(month, like: word, in: own) }
        let names = found.compactMap { name(month, like: word, in: $0) }
        return names.max { a, b in names.filter { $0.lowercased() == a.lowercased() }.count < names.filter { $0.lowercased() == b.lowercased() }.count }
    }
    private static func name(_ month: Int, like word: String, in found: (identifier: String, full: Bool)) -> String? {
        let (identifier, full) = found
        guard let formatter = formatters[identifier] else { return nil }
        let lower = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // A month written as a date writes it ("maja") or as it stands alone ("maj"): the stand-in follows.
        let standalone = !(full ? formatter.monthSymbols : formatter.shortMonthSymbols).contains { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == lower }
        let symbols = full ? (standalone ? formatter.standaloneMonthSymbols : formatter.monthSymbols) : (standalone ? formatter.shortStandaloneMonthSymbols : formatter.shortMonthSymbols)
        guard let symbols, (1...12).contains(month) else { return nil }
        var made = symbols[month - 1]
        if !word.hasSuffix(".") { made = made.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let letters = word.filter(\.isLetter)
        if letters == letters.uppercased() { return made.uppercased() }
        if letters.first?.isUppercase == true { return made.prefix(1).uppercased() + made.dropFirst() }
        return made.lowercased()
    }
    private static let pattern = TextPattern(#"(?i)(?<![\p{L}\p{N}])(\d{1,2})\.?[ \t]+(?:(?:de|del|of)[ \t]+)?(\p{L}{3,})\.?,?[ \t]+(?:(?:de|del|of)[ \t]+)?(\d{4})(?![\p{L}\p{N}])"#)
    /// Whether a supposed address's only number of any length is a year, beside at most a day's
    /// ("el veintiuno de agosto de 1988", "le 1er mars 1985", "August 21st, 1988"), with no word that
    /// names a kind of street: a date, or a life's event, and no address. An address has a street or a postcode.
    private static let boxes: Set<String> = ["box", "postfach", "postbus", "postboks", "apartado", "casella", "caixa", "bag"]
    static func yearAlone(_ text: String) -> Bool {
        let numbers = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard numbers.contains(where: { $0.count == 4 && (1800...2099).contains(Int($0) ?? 0) }),
              numbers.allSatisfy({ $0.count <= 2 || $0.count == 4 && (1800...2099).contains(Int($0) ?? 0) }) else { return false }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "/" }).map(String.init)
        return !words.contains { word in
            AddressBlock.streetKinds.contains(word) || AddressBlock.englishKinds.contains(word) || AddressBlock.placeWords.contains(word) || boxes.contains(word)
                || AddressBlock.streetSuffixes.contains { word.hasSuffix($0) && word.count > $0.count + 2 }
        }
    }
    /// Whether the text holds a whole date written with its month's name: day, month and year.
    static func holds(_ text: String) -> Bool {
        TextRanges.matches(pattern, in: text).contains { match in
            months[(text as NSString).substring(with: match.range(at: 2)).lowercased()] != nil
        }
    }
}
