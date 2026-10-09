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

    private static let titleBefore = TextPattern("(?i)(?<![\\p{L}\\p{N}])(?:" + titles.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\.?[ \\t]+$")
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

    private static let technical = TextPattern(#"(?im)^[ \t]*(?:[*<>$][ \t]|\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}|\[?\d{2}:\d{2}:\d{2}[\] ]|\[?(?:INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL|NOTICE)\b)|\bHTTP/\d|\b(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /|\b(?:TLS|SSL)v?\d?\b"#)
    /// A log's or a tool's line: a timestamp or level opening it, a command's or a transfer's marks, an HTTP request.
    static func technicalLine(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: range.lowerBound, length: 0)))
        return !TextRanges.matches(technical, in: line).isEmpty
    }
    /// The forms a company's name ends with: "Lda.", "S.A.", "GmbH", "B.V.", "S.r.l.", "Ltd", "A.Ş.", "d.o.o.", "Sp. z o.o.", "ООО".
    static let companyForm = #"(?:S\.?A\.?\s?de\s?C\.?V|GmbH\s?&\s?Co\.?\s?KG|\(Pty\)\s?Ltd|Pte\.?\s?Ltd|Lda|Ltda|S\.?A\.?S?|S\.?L\.?U?|S\.?r\.?l|S\.?p\.?A|S\.?A\.?R\.?L|SARL|GmbH|AG|KG|OHG|e\.?V|B\.?V|N\.?V|V\.?O\.?F|Ltd|Limited|LLC|LLP|L\.?P|Inc|Corp|Co|PLC|AB|ASA|AS|A/S|ApS|Oy|Oyj|A\.?Ş|Ltd\.?\s?Şti|[sS]p\.?\s?z\s?o\.?\s?o|[dD]\.?\s?o\.?\s?o|[sS]\.?\s?r\.?\s?o|S\.?C|SpA|Srl|SAS|SE|S\.?C\.?A|Unipessoal|EIRELI|ME|EPP|Pty|BVBA|SRL|OÜ|SIA|UAB|Kft|Zrt|Nyrt|Bt|Α\.?Ε|Ε\.?Π\.?Ε|ΙΚΕ|ЕООД|ООД|ЕАД|ООО|ОАО|ЗАО|ТОВ|ПАО)\.?"#
    private static let formAround = TextPattern(#"(?:^|[ \t,])"# + companyForm + #"(?![\p{L}\p{N}])"#)
    private static let formOnly = TextPattern(#"^"# + companyForm + #"$"#)
    private static let formAfter = TextPattern(#"^,?[ \t]+"# + companyForm + #"(?![\p{L}\p{N}])"#)
    private static let formAhead = TextPattern(#"^(?:[ \t]+\p{Lu}[\p{L}\p{M}'’&-]*){1,3},?[ \t]+"# + companyForm + #"(?![\p{L}\p{N}])"#)
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
    static func afterTitle(_ span: Span, in text: String) -> Span {
        let words = NameShape.words(span.range, in: text)
        // A title that is also a name's part or a word ("Anh", "Don", "Pan", "Me") counts only with its full stop.
        guard words.count >= 3, let index = words.indices.dropLast().last(where: { index in
            index > 0 && titles.contains(words[index].bare) && (words[index].text.hasSuffix(".") || !namePartTitles.contains(words[index].bare))
        }) else { return span }
        return Span(range: words[index + 1].range.lowerBound..<span.range.upperBound, entity: span.entity, score: span.score, url: span.url)
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
            let span = names.contains(found.entity) ? afterTitle(found, in: text) : found
            let person = names.contains(span.entity)
            if span.entity == "ADDRESS", WrittenDates.holds(TextRanges.substring(text, span.range)) || WrittenDates.yearAlone(TextRanges.substring(text, span.range)) { continue }
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
            guard foreign || technical else { kept.append(span); continue }
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
        doubted.removeAll { smallWords($0, in: text, document: document) }
        doubted.sort { $0.range.lowerBound < $1.range.lowerBound }
        return (kept, doubted)
    }
}

/// Dates written out in words, in the languages Scrub reads: "3 de marzo de 1975", "3. März 1975",
/// "3 mars 1975", "12 maja 1966 r.". One unit: never a house number, a postcode and a street.
enum WrittenDates {
    private static let locales = ["en_US_POSIX", "de", "es", "pt", "fr", "it", "nl", "pl", "sv", "tr", "da", "nb", "fi", "cs", "ro", "hu", "id", "vi"]
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
    /// How many of the languages that write `word` write month `month` as its stand-in name does.
    static func readers(_ month: Int, like word: String) -> Int {
        let found = locales(of: word)
        let names = found.compactMap { name(month, like: word, in: $0)?.lowercased() }
        return names.map { name in names.filter { $0 == name }.count }.max() ?? 0
    }
    /// Month `month`'s name in the language and form `word` is written in, in its case. A word several
    /// languages write ("juli" is Dutch, German and Swedish) takes the name most of them write.
    static func name(_ month: Int, like word: String) -> String? {
        let found = locales(of: word)
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
