import Foundation
import NaturalLanguage

public final class Detector {
    private let systemDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.address.rawValue)
    // Creating a tagger loads its model; one per document, not one per value.
    private let tagger = NLTagger(tagSchemes: [.nameType])
    private let isCancelled: @Sendable () -> Bool
    /// Whether the address model reads text for this detector (see `AddressModel.active`).
    private let addresses: Bool
    /// Whether the learned scorer judges people only a model read (see `PersonScorer.learned`).
    private let learned: Bool
    /// The name model, unless this scrub runs without it (see `Coverage`).
    private let names: NameModel?
    /// When set, every person only a model read is written here with what is known about it.
    var personLog: PersonLog?
    /// The links `found` read in the text `base` judges, so `Links.outside` needn't read them again.
    private var foundLinks: [Range<Int>]?
    /// The people only a model read that the last `base` call did not keep
    /// but that are too likely to ignore (see `PersonScorer.reviewFrom`), and
    /// the streets or houses named alone (see `AddressModel.read`): left as
    /// written, and put to a person in review.
    private(set) var doubts: [Span] = []
    /// The language the document around the text is written in, when known (see `NameEvidence`).
    var language: NLLanguage?
    /// What the rules that read a cue found in the last `base` call: a label, a mail header, an email spelling the name.
    private var evidenced: [Range<Int>] = []
    public init() {
        isCancelled = { Task.isCancelled }
        addresses = AddressModel.active && !Coverage.withheld.contains(.addressModel)
        learned = PersonScorer.learned
        names = Coverage.withheld.contains(.nameModel) ? nil : NameModel.shared
    }
    init(isCancelled: @escaping @Sendable () -> Bool, addresses: Bool = AddressModel.active, learned: Bool = PersonScorer.learned, names: Bool = true) {
        self.isCancelled = isCancelled; self.addresses = addresses; self.learned = learned; self.names = names ? NameModel.shared : nil
    }
    public func find(_ text: String, key: String? = nil, gazetteer: [String: Set<String>] = [:], contextWords: Set<String> = []) -> [Span] {
        find(text, key: key, matcher: GazetteerMatcher(gazetteer), contextWords: contextWords)
    }
    func find(_ text: String, key: String? = nil, matcher: GazetteerMatcher, contextWords: Set<String> = [], modelled: Bool = true) -> [Span] {
        autoreleasepool { combined(base(text, key: key, contextWords: contextWords, modelled: modelled), text: text, matcher: matcher) }
    }
    /// `modelled: false` leaves out the name model, for a sweep over text that
    /// already holds stand-ins: the model reads the words around each one, so
    /// it would judge the stand-ins' context rather than the original's.
    /// `context` holds the context model's reading of the text, whose findings fill only what nothing else found.
    /// `naming`: the words that may name an identifier in `text`, where they are fewer than `contextWords` (see `DocumentLeaf.namingWords`).
    func base(_ text: String, key: String? = nil, contextWords: Set<String> = [], naming: Set<String>? = nil, modelled: Bool = true, context: ContextStage.Reading? = nil) -> [Span] {
        autoreleasepool {
            doubts = []
            evidenced = []
            foundLinks = nil
            // A person a reading detector found, cut to what a name can hold (see NameShape).
            // A rule's person keeps its words, but not the verb that opens its sentence ("Call Odalys").
            var spans = found(text, key: key, contextWords: contextWords, naming: naming, modelled: modelled, context: context).compactMap { span in
                span.entity != "PERSON" ? span : span.score < 0.95 ? NameShape.trimmed(span, in: text) : NameShape.withoutCommand(span, in: text)
            }
            // A literal of the code or JSON around a value ("livemode": false, None) is no one, whatever a model reads.
            // In quotes it is a string ("pin": "null"), which may be a secret.
            let units = text.utf16
            func quoted(_ range: Range<Int>) -> Bool {
                guard range.lowerBound > 0, range.upperBound < units.count else { return false }
                let before = units[units.index(units.startIndex, offsetBy: range.lowerBound - 1)], after = units[units.index(units.startIndex, offsetBy: range.upperBound)]
                return before == after && (before == 34 || before == 39)
            }
            spans.removeAll { Self.literals.contains(TextRanges.substring(text, $0.range)) && ($0.entity != "SECRET" || !quoted($0.range)) }
            // Whichever reader took them for a name, a sentence's own small words in another language are no one (see `NameShape.smallForeignWords`).
            spans.removeAll { $0.score < 0.95 && $0.url == nil && NameShape.smallForeignWords($0, in: text) }
            // An ID made of a name after the word for whose it is ("account Quillmere_Tavish"), where nothing else was read.
            spans += RecordIDs.labelled(in: text).filter { id in !spans.contains { $0.range.overlaps(id.range) } }
            // One made of a word and a number, with nothing labelling it ("close QUILLMERE-0042"):
            // a name's is replaced, an unknown word's is asked about.
            let worded = RecordIDs.worded(in: text)
            spans += worded.named.filter { id in !spans.contains { $0.range.overlaps(id.range) } }
            doubts += worded.unsure
            // One made of the name of a person found here and a number ("pat-1987" beside Pat Ferriter) is theirs.
            let named = Set(spans.filter { ["PERSON", "FIRST_NAME", "LAST_NAME"].contains($0.entity) }.flatMap { span in
                TextRanges.substring(text, span.range).split { !$0.isLetter }.map { $0.lowercased() }.filter { $0.count >= 3 && !People.isTitle($0) }
            })
            spans += RecordIDs.owned(in: text, by: named).filter { id in !spans.contains { $0.range.overlaps(id.range) } }
            // "RFC4716" names a standard, and "t.co/x" a link: neither is anyone's.
            // A secret under a query key ends with its parameter, whichever detector read it.
            let ns = text as NSString
            let cut = spans.map { span -> Span in
                guard span.entity == "SECRET", span.url == nil, let end = URLs.queryValueEnd(ns, span.range) else { return span }
                return Span(range: span.range.lowerBound..<end, entity: span.entity, score: span.score)
            }
            var kept = HomeFolders.over(Standards.outside(Links.outside(cut, in: text, links: foundLinks), in: text), in: text)
            kept.removeAll { Self.machineAccount($0, in: ns) }
            if !doubts.isEmpty { doubts = Self.doubted(doubts, besides: kept, in: text, links: foundLinks) }
            if !doubts.isEmpty { (kept, doubts) = Self.joined(doubts, onto: kept, in: text) }
            // A person written in pieces is one person (see `JoinedNames`).
            (kept, doubts) = JoinedNames.joined(kept, doubts, in: text)
            kept = Self.withNameEnds(kept, in: text)
            let called = Self.firstNamesOfLowercasePeople(kept, in: text)
            if !called.isEmpty {
                kept += called
                doubts.removeAll { doubt in called.contains { $0.range.overlaps(doubt.range) } }
            }
            // A person only guessed is replaced only with evidence where the text's language says what its words are.
            // A value under a key that names a person is evidence enough ("cliente": "Lucía").
            let whole = Self.wholeName(kept, in: text)
            if NameEvidence.namesPerson(key) { return whole }
            let gated = NameEvidence.gate(whole, doubts: doubts, evidenced: evidenced, in: text, document: language)
            doubts = gated.doubts
            return gated.spans
        }
    }
    /// "rose" alone in a chat that named "rose martinez": a person written all in small letters is
    /// called by their first name later, as a capitalised one is ("rose's ssn", "ping rose"), and
    /// that first name is theirs though it is also a word. Only where nothing else was found.
    static func firstNamesOfLowercasePeople(_ spans: [Span], in text: String) -> [Span] {
        var firsts: Set<String> = []
        for span in spans where span.entity == "PERSON" && span.url == nil {
            let words = NameShape.words(span.range, in: text)
            guard words.count >= 2, words.allSatisfy({ $0.text == $0.text.lowercased() }), NameLists.isFirst(words[0].bare), words[0].bare.count >= 3 else { continue }
            firsts.insert(words[0].text)
        }
        guard !firsts.isEmpty else { return [] }
        var taken = IndexSet()
        for span in spans where !span.range.isEmpty { taken.insert(integersIn: span.range) }
        var found: [Span] = []
        for first in firsts {
            let pattern = TextPattern("(?<![\\p{L}\\p{N}@._-])" + NSRegularExpression.escapedPattern(for: first) + "(?![\\p{L}\\p{N}@_-])(?!\\.[\\p{L}\\p{N}])")
            for match in TextRanges.matches(pattern, in: text) {
                let range = match.range.location..<NSMaxRange(match.range)
                guard !taken.intersects(integersIn: range) else { continue }
                found.append(Span(range: range, entity: "PERSON", score: 0.85))
            }
        }
        return found
    }
    /// The second half of a double-barrelled surname ("Müller-Lüdenscheidt") a reader stopped short of, and the
    /// initials written before a surname ("H.-J. Müller", "P. Okafor"): parts of the person, never left as written.
    private static let barrelAfter = TextPattern(#"^[-‐]\p{Lu}\p{Ll}[\p{L}'’]*(?![\p{L}\p{N}@_-])"#)
    private static let initialsBefore = TextPattern(#"(?<![\p{L}\p{N}.@_-])\p{Lu}\.(?:[ -]?\p{Lu}\.){0,2}[ \t]$"#)
    static func withNameEnds(_ spans: [Span], in text: String) -> [Span] {
        guard spans.contains(where: { $0.entity == "PERSON" }) else { return spans }
        let ns = text as NSString
        var taken = IndexSet()
        for span in spans where !span.range.isEmpty { taken.insert(integersIn: span.range) }
        return spans.map { span in
            guard span.entity == "PERSON", span.url == nil else { return span }
            var lower = span.range.lowerBound, upper = span.range.upperBound
            if upper < ns.length, let match = TextRanges.matches(barrelAfter, in: ns.substring(with: NSRange(location: upper, length: min(40, ns.length - upper)))).first,
               !taken.intersects(integersIn: upper..<(upper + match.range.length)) {
                upper += match.range.length
            }
            let head = max(0, lower - 12)
            if lower > 0, let match = TextRanges.matches(initialsBefore, in: ns.substring(with: NSRange(location: head, length: lower - head))).first,
               !taken.intersects(integersIn: (head + match.range.location)..<lower) {
                lower = head + match.range.location
            }
            return lower == span.range.lowerBound && upper == span.range.upperBound ? span : Span(range: lower..<upper, entity: span.entity, score: span.score)
        }
    }
    /// A value written whole as a name is one name when a reader took its
    /// every word for part of a person, or, with a surname's particle in it,
    /// any of them: "Odalys van der Berg" read in pieces is replaced as one,
    /// so no word of it stays and its stand-in is a name. So is one a reader took
    /// in part, where its other words are names or no word at all ("Priya" beside a
    /// surname found): half a name replaced must not leave the other half.
    static func wholeName(_ spans: [Span], in text: String) -> [Span] {
        guard !spans.isEmpty, spans.allSatisfy({ ["PERSON", "FIRST_NAME", "LAST_NAME"].contains($0.entity) && $0.url == nil }),
              let name = writtenName(text), spans.allSatisfy({ name.lowerBound <= $0.range.lowerBound && $0.range.upperBound <= name.upperBound }),
              spans.count > 1 || spans[0].range != name else { return spans }
        var covered = IndexSet()
        for span in spans where !span.range.isEmpty { covered.insert(integersIn: span.range) }
        let ns = text as NSString
        var start = name.lowerBound, particled = false, whole = true, named = true
        for end in name.lowerBound...name.upperBound where end == name.upperBound || ns.character(at: end) == 0x20 {
            if end > start, let first = Unicode.Scalar(ns.character(at: start)) {
                if CharacterSet.uppercaseLetters.contains(first) {
                    if !covered.contains(integersIn: start..<end) {
                        whole = false
                        let word = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: CharacterSet(charactersIn: ",."))
                        named = named && word.count >= 2 && word.allSatisfy { $0.isLetter || "'’-".contains($0) } && !People.isTitle(word) && (NameLists.isName(word) || !NameLists.isWord(word))
                    }
                }
                else { particled = true }
            }
            start = end + 1
        }
        guard whole || particled || named else { return spans }
        return [Span(range: name, entity: "PERSON", score: spans.map(\.score).max() ?? 1)]
    }
    private static let crashHeader = TextPattern(#"(?m)^(?:Process|Code Type|Exception Type|Crashed Thread|Report Version|Incident Identifier|Hardware Model|Parent Process|Responsible):[ \t]"#)
    private static let accountLabel = TextPattern(#"(?i)(?:^|[\s,;(])(?:user[ _]?id|uid)[ \t]*[:=][ \t]*$"#)
    /// A crash report's "User ID: 501": the account's number on that machine, which the first account
    /// on every one of them shares, so no one's. A report says it is one by three of its headers or more.
    private static func machineAccount(_ span: Span, in ns: NSString) -> Bool {
        guard span.entity == "RECORD_ID", (1...5).contains(span.range.count) else { return false }
        let value = ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(value), number <= 65_535 else { return false }
        let line = ns.lineRange(for: NSRange(location: span.range.lowerBound, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: span.range.lowerBound - line.location))
        guard !TextRanges.matches(accountLabel, in: before).isEmpty else { return false }
        let head = ns.substring(to: min(ns.length, 4096))
        return Set(TextRanges.matches(crashHeader, in: head).map { (head as NSString).substring(with: $0.range) }).count >= 3
    }
    /// What `base` finds, and the people it doubts.
    func read(_ text: String, key: String? = nil, contextWords: Set<String> = [], naming: Set<String>? = nil, context: ContextStage.Reading? = nil) -> (spans: [Span], doubts: [Span]) {
        let spans = Self.contactsOutOfAddresses(base(text, key: key, contextWords: contextWords, naming: naming, context: context), in: text).filter { !Self.served($0, in: text) }
        return (spans, doubts)
    }
    /// A number an access log writes after the request it answers: its status and sizes, whatever
    /// reading took them for a phone, an ID or an SSN (see `servedLead`).
    static func served(_ span: Span, in text: String) -> Bool {
        guard ["PHONE_NUMBER", "ID_NUMBER", "US_SSN"].contains(span.entity), span.range.lowerBound > 0, span.range.count <= 40 else { return false }
        let ns = text as NSString
        let value = ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
        guard value.range(of: #"^\d+(?:[ \t]+\d+){0,3}$"#, options: .regularExpression) != nil else { return false }
        let start = max(0, span.range.lowerBound - 160)
        return ns.substring(with: NSRange(location: start, length: span.range.lowerBound - start)).range(of: servedLead, options: .regularExpression) != nil
    }
    private static let contactKinds: Set<String> = ["EMAIL_ADDRESS", "PHONE_NUMBER", "URL"]
    /// An address read on into the phone number, the email or the link beside it ("…, 44000 Nantes.
    /// Tél. 02 40 55 01 27 — h.g@example.fr") ends before them and their label, and one read from inside
    /// one starts after it: each is then replaced as what it is. A number the address reads as its own
    /// part (a house number and a postcode a phone's pattern took) stays in it: a phone counts only after
    /// its label or with nothing but contacts after it.
    static func contactsOutOfAddresses(_ spans: [Span], in text: String) -> [Span] {
        let contacts = spans.filter { contactKinds.contains($0.entity) }
        guard !contacts.isEmpty, spans.contains(where: { $0.entity == "ADDRESS" }) else { return spans }
        let ns = text as NSString
        func labelled(_ index: Int, from lower: Int) -> Int? {
            // The word before `index`, its punctuation dropped, if it names a phone or an email ("Tél.", "E-Mail:").
            var end = index
            while end > lower, let scalar = Unicode.Scalar(ns.character(at: end - 1)), !CharacterSet.alphanumerics.contains(scalar) { end -= 1 }
            var start = end
            while start > lower, let scalar = Unicode.Scalar(ns.character(at: start - 1)), CharacterSet.alphanumerics.contains(scalar) || scalar == "-" { start -= 1 }
            guard start < end, let kind = KeyHints.hint(ns.substring(with: NSRange(location: start, length: end - start))), ["PHONE_NUMBER", "EMAIL_ADDRESS"].contains(kind) else { return nil }
            return start
        }
        return spans.compactMap { span in
            guard span.entity == "ADDRESS" else { return span }
            var lower = span.range.lowerBound, upper = span.range.upperBound
            for contact in contacts where contact.range.lowerBound <= lower && lower < contact.range.upperBound { lower = contact.range.upperBound }
            let inside = contacts.filter { lower < $0.range.lowerBound && $0.range.lowerBound < upper }.sorted { $0.range.lowerBound < $1.range.lowerBound }
            for (index, contact) in inside.enumerated() {
                let label = labelled(contact.range.lowerBound, from: lower)
                // What follows it to the address's end, the contacts after it left out: only their labels, if anything.
                var rest = "", at = contact.range.upperBound
                for later in inside[(index + 1)...] where later.range.lowerBound >= at {
                    rest += ns.substring(with: NSRange(location: at, length: min(later.range.lowerBound, upper) - at)) + " "
                    at = later.range.upperBound
                }
                if at < upper { rest += ns.substring(with: NSRange(location: at, length: upper - at)) }
                let onlyContacts = rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).allSatisfy { word in
                    KeyHints.hint(String(word)).map { ["PHONE_NUMBER", "EMAIL_ADDRESS"].contains($0) } == true
                }
                guard contact.entity != "PHONE_NUMBER" || label != nil || onlyContacts else { continue }
                upper = label ?? contact.range.lowerBound
                break
            }
            guard lower != span.range.lowerBound || upper != span.range.upperBound else { return span }
            guard let kept = trimmed(lower..<upper, in: ns) else { return nil }
            return Span(range: kept, entity: "ADDRESS", score: span.score)
        }
    }
    /// Doubted people cut to what a name holds, outside every finding and
    /// link, once each: where two models doubt one name, the likelier guess.
    private static func doubted(_ doubts: [Span], besides kept: [Span], in text: String, links: [Range<Int>]?) -> [Span] {
        var taken = IndexSet()
        for range in kept.map(\.range) + (links ?? Links.ranges(in: text)) where !range.isEmpty { taken.insert(integersIn: range) }
        var result: [Span] = []
        for doubt in doubts.compactMap({ NameShape.trimmed($0, in: text) }).sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.range.lowerBound < $1.range.lowerBound }) {
            guard !doubt.range.isEmpty, !taken.intersects(integersIn: doubt.range) else { continue }
            taken.insert(integersIn: doubt.range)
            result.append(doubt)
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
    /// A doubted word written right beside a person found surely, with one
    /// space between, is the rest of that name ("Tomasz O'Sullivan", where the
    /// tagger stops at the apostrophe): the person takes it in, so the whole
    /// name is replaced as one. A doubt of more than one word stays a doubt.
    private static func joined(_ doubts: [Span], onto kept: [Span], in text: String) -> (kept: [Span], doubts: [Span]) {
        let ns = text as NSString
        var kept = kept, left: [Span] = []
        for doubt in doubts {
            let word = ns.substring(with: NSRange(location: doubt.range.lowerBound, length: doubt.range.count))
            guard doubt.entity == "PERSON", !word.contains(where: \.isWhitespace), word.first?.isUppercase == true,
                  let index = kept.firstIndex(where: { person in
                      guard person.entity == "PERSON", person.score > NameModel.score, person.url == nil else { return false }
                      let gap = person.range.upperBound <= doubt.range.lowerBound ? person.range.upperBound..<doubt.range.lowerBound
                          : doubt.range.upperBound <= person.range.lowerBound ? doubt.range.upperBound..<person.range.lowerBound : nil
                      guard let gap else { return false }
                      return gap.count == 1 && ns.character(at: gap.lowerBound) == 0x20
                  }) else { left.append(doubt); continue }
            let person = kept[index]
            kept[index] = Span(range: min(person.range.lowerBound, doubt.range.lowerBound)..<max(person.range.upperBound, doubt.range.upperBound), entity: "PERSON", score: person.score)
        }
        return (kept, left)
    }
    /// What a value is when its key says so: the kind the key names, the whole value. An identifier its
    /// key names is that identifier, though the key names another kind elsewhere ("pan": a card's
    /// number, or India's tax number). Nil when the key names nothing.
    static func keyed(_ text: String, key: String?) -> [Span]? {
        // A cookie header's pairs keep their names and settings (see `KeyedValues.cookies`).
        if KeyedValues.cookieKey(key), let pairs = KeyedValues.cookies(text) { return pairs }
        guard let entity = KeyHints.hint(key), !text.isEmpty else { return nil }
        // The value before a note written after it is the field's; the note is read as any text is (see `KeyHints.noteStart`).
        if case let head = KeyHints.judged(key, text), head.utf16.count < text.utf16.count { return keyed(head, key: key) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Someone's value hashed: a stand-in digest of its shape, never an email or a name in its place.
        if KeyHints.digestKinds.contains(entity), KeyHints.isDigest(trimmed), let found = text.range(of: trimmed) {
            let start = NSRange(found, in: text).location
            return [Span(range: start..<(start + (trimmed as NSString).length), entity: "RECORD_ID", score: 1)]
        }
        // An account's number written as an IBAN ("AccountNumber": "LU28 0019 …") is one: its stand-in keeps its country and its check.
        if entity == "ID_NUMBER", trimmed.prefix(2).allSatisfy(\.isLetter), Patterns.iban(trimmed), let found = text.range(of: trimmed) {
            let start = NSRange(found, in: text).location
            return [Span(range: start..<(start + (trimmed as NSString).length), entity: "IBAN_CODE", score: 1)]
        }
        if trimmed.utf16.count <= 96, trimmed.contains(where: \.isNumber), let named = Recognizers.named(trimmed, by: Set(KeyHints.words(key))), named != entity,
           let found = text.range(of: trimmed) {
            let start = NSRange(found, in: text).location
            return [Span(range: start..<(start + (trimmed as NSString).length), entity: named, score: 1)]
        }
        return [Span(range: 0..<(text as NSString).length, entity: entity, score: 1)]
    }
    private func found(_ text: String, key: String?, contextWords: Set<String>, naming: Set<String>?, modelled: Bool, context: ContextStage.Reading?) -> [Span] {
        do {
            if let keyed = Self.keyed(text, key: key) { return keyed }
            if KeyHints.isRole(key), let name = Self.writtenName(text) { return [Span(range: name, entity: "PERSON", score: 1)] }
            // So is a handle there ("author": "maria.gonzalez", "jdoe42"): the role's person, by another name;
            // and under a client's key ("user": "jdoe.js"), whatever it ends in. An ID a type's prefix opens
            // ("customer": "cus_4TUvJh") is no handle: its stand-in keeps that shape.
            let bare = text.trimmingCharacters(in: .whitespaces)
            if KeyHints.isRole(key) || Self.clientKey(key), !RecordIDs.prefixed(bare), Self.isHandle(bare, client: Self.clientKey(key)), let found = text.range(of: bare) {
                let start = NSRange(found, in: text).location
                return [Span(range: start..<(start + (bare as NSString).length), entity: "USERNAME", score: 1)]
            }
            // A time zone ("America/New_York") names a region, not where someone lives.
            if text.contains("/"), text.count < 64, !TextRanges.matches(Self.timeZone, in: text).isEmpty { return [] }
            let plainWord = text.allSatisfy { $0.isASCII && $0.isLowercase }
                && !Names.firstFolded.contains(text) && !Names.lastFolded.contains(text)
            guard !plainWord else { return [] }
            let keyWords = Set(KeyHints.words(key))
            var spans = Patterns.find(text, contextWords: keyWords.union(contextWords), naming: naming.map(keyWords.union), isCancelled: isCancelled).compactMap { span in
                span.entity == "ADDRESS" ? Self.addressRange(span.range, in: text as NSString).map { Span(range: $0, entity: span.entity, score: span.score) } : span
            }
            let spelled = Self.spelledByEmail(spans, in: text, isCancelled: isCancelled)
            evidenced += spelled.map(\.range)
            spans.append(contentsOf: spelled)
            if text.contains(".") { spans.append(contentsOf: Self.namedFiles(in: text)) }
            spans.append(contentsOf: RecordIDs.spans(in: text))
            spans.append(contentsOf: ConnectionStrings.scan(text))
            spans.append(contentsOf: system(text))
            var organisations: [Range<Int>] = []
            spans.append(contentsOf: NameTagger.find(text, using: tagger, organisations: &organisations, isCancelled: isCancelled))
            let nameModel = modelled ? names : nil
            let reading = nameModel?.read(text, isCancelled: isCancelled)
            let named = nameModel.flatMap { model in reading.map { model.find(text, reading: $0) } } ?? []
            let (located, unsure) = modelled && addresses ? AddressModel.read(text, isCancelled: isCancelled) : ([], [])
            // A street or a house named alone is asked about, never replaced on a guess.
            doubts += unsure
            spans = Self.addressed(spans, in: text)
            // A country left unreplaced after a word of place is still a place: no model guess makes it
            // someone ("Shipping to Jordan"), though "Jordan is waiting" may be.
            let nations = spans.filter { span in
                span.entity == "LOCATION" && ContextStage.nations.contains(ContextStage.normalPlace(TextRanges.substring(text, span.range)))
                    && Context.words(before: span.range.lowerBound, in: text, limit: 1).first.map { Self.placeWords.contains($0.lowercased()) } == true
            }.map(\.range)
            // A postcode after a country kept as written is still someone's ("Switzerland 82590", "Netherlands 1012 AB").
            for span in spans where span.entity == "LOCATION" && ContextStage.nations.contains(ContextStage.normalPlace(TextRanges.substring(text, span.range))) {
                let ns = text as NSString, rest = ns.substring(with: NSRange(location: span.range.upperBound, length: min(16, ns.length - span.range.upperBound)))
                // Only as an address writes it: the country opening its line or after a comma, not "sold in Norway 2024".
                let lead = ns.substring(to: span.range.lowerBound).reversed().first { $0 != " " && $0 != "\t" }
                guard lead == nil || lead == "\n" || lead == "," else { continue }
                guard let match = TextRanges.matches(Self.countryPostcode, in: rest).first else { continue }
                let code = match.range(at: 1)
                spans.append(Span(range: (span.range.upperBound + code.location)..<(span.range.upperBound + NSMaxRange(code)), entity: "POSTAL_CODE", score: 0.85))
            }
            spans.removeAll { Self.namesNoOne($0, in: text) }
            // A place right after a title or a rank is the person it names: "Private Ellery", "Ms Paris".
            spans = spans.map { span in span.entity == "LOCATION" && Self.titled(span.range, in: text) ? Span(range: span.range, entity: "PERSON", score: span.score) : span }
            // The personal parts of links: a query value under a personal key, a
            // token, a person's segment of a path, a link's user name.
            // Only a link with a path or a query has parts that can name someone.
            if text.contains("://") || text.contains("www.") || text.contains(".") && (text.contains("/") || text.contains("?")) { foundLinks = Links.ranges(in: text) }
            let linked = foundLinks.map { URLs.scan(text, links: $0) } ?? []
            if !linked.isEmpty { spans.append(contentsOf: linked) }
            // A timestamp, ID or setting is read as written: its date is no birth
            // date, its digits no phone number, its region no place.
            if KeyHints.isStructural(key) { return spans.filter(Self.certain) }
            let keyed = KeyedValues.scan(text, isCancelled: isCancelled)
            var quiet = keyed.structural
            if text.contains("/") { quiet += TextRanges.matches(Self.zoneAnywhere, in: text).map { $0.range.location..<NSMaxRange($0.range) } }
            // No word inside a UUID is a name ("4ae18f24-cabe-…").
            if text.contains("-") { quiet += TextRanges.matches(Self.uuid, in: text).map { $0.range.location..<NSMaxRange($0.range) } }
            if !quiet.isEmpty {
                spans = spans.filter { span in Self.certain(span) || !quiet.contains { $0.overlaps(span.range) } }
            }
            spans.append(contentsOf: keyed.spans)
            // The words that name a value ("born", "d.o.b.", "passport number") are no one's name.
            let labelled = ProseLabels.scan(text, isCancelled: isCancelled)
            spans = spans.filter { span in Self.certain(span) || !labelled.labels.contains { $0.overlaps(span.range) } }
            spans.append(contentsOf: labelled.spans)
            evidenced += labelled.spans.map(\.range)
            // Names a mail header, an office path or a title holds; the path and a header's date hold none.
            let written = WrittenNames.scan(text, isCancelled: isCancelled)
            if !written.quiet.isEmpty {
                spans = spans.filter { span in Self.certain(span) || !written.quiet.contains { $0.overlaps(span.range) } }
            }
            spans.append(contentsOf: written.spans)
            evidenced += written.spans.map(\.range)
            // People a greeting, a signature or a known first name and surname hold, where nothing says otherwise.
            // The tagger calls a lone word on a line an organisation as often as not ("Best,⏎Rafael"),
            // so only a known pair defers to it.
            let unsaid = quiet + written.quiet + labelled.labels
            spans.append(contentsOf: ListedNames.scan(text, isCancelled: isCancelled).filter { span in
                !unsaid.contains { $0.overlaps(span.range) } && (span.score != ListedNames.pairScore || !organisations.contains { $0.overlaps(span.range) })
            })
            // Who speaks a chat line ("sarah: on it"); a name that is also a word there, or after
            // what names a person in chat ("spoke to will"), is asked about.
            let spoken = ListedNames.spoken(in: text, isCancelled: isCancelled)
            spans.append(contentsOf: spoken.sure)
            if !spoken.unsure.isEmpty {
                var taken = IndexSet()
                for span in spans { taken.insert(integersIn: span.range) }
                doubts += spoken.unsure.filter { !taken.intersects(integersIn: $0.range) }
            }
            // A given name before a hyphenated surname the tagger read in pieces ("Brisa Smith-Jones").
            spans.append(contentsOf: ListedNames.hyphenated(in: text, people: spans.filter { $0.entity == "PERSON" }.map(\.range), organisations: organisations, isCancelled: isCancelled).filter { span in
                !unsaid.contains { $0.overlaps(span.range) }
            })
            // A given name and a surname with its particles that no reader found ("Caio dos Santos").
            // It only fills a gap: a person found over any of it is read as found.
            let particled = JoinedNames.particled(in: text, places: spans.filter { $0.entity == "LOCATION" }.map(\.range), isCancelled: isCancelled)
            if !particled.isEmpty {
                var found = IndexSet()
                for span in spans where ["PERSON", "ADDRESS"].contains(span.entity) { found.insert(integersIn: span.range) }
                spans.append(contentsOf: particled.filter { span in !unsaid.contains { $0.overlaps(span.range) } && !found.intersects(integersIn: span.range) })
            }
            // Names in capitals beside a first name or a title ("Julie BEET", "Ms BEET").
            spans.append(contentsOf: CapitalNames.scan(text, isCancelled: isCancelled).filter { span in !unsaid.contains { $0.overlaps(span.range) } })
            // A field's whole value written as a name in capitals ("headline": "ODILON TAVARES").
            if key != nil, unsaid.isEmpty, let whole = CapitalNames.whole(text), !spans.contains(where: { $0.range.overlaps(whole.range) }) { spans.append(whole) }
            // The name model only fills gaps: where anything else found something, that finding stands.
            var covered = IndexSet()
            for range in spans.map(\.range) + nations + quiet + written.quiet + organisations + labelled.labels where !range.isEmpty { covered.insert(integersIn: range) }
            // A person only a model read is judged by what else agrees (see PersonScorer): by
            // the learned scorer where the context model read the whole text, else by hand rules.
            let people = context?.people ?? []
            let scoring = learned && context?.whole == true
            var sure: [Range<Int>: Double] = [:]
            personLog?.others += spans.filter { ["PERSON", "FIRST_NAME", "LAST_NAME", "USERNAME"].contains($0.entity) }.map(\.range)
            for (index, span) in named.enumerated() where !covered.intersects(integersIn: span.range) && !Self.namesNoOne(span, in: text) {
                if index.isMultiple(of: 64) && isCancelled() { return spans }
                guard span.entity == "PERSON" else { spans.append(span); continue }
                let hand = !NameShape.ordinaryGuess(span, in: text)
                guard scoring || personLog != nil else { if hand { spans.append(span) }; continue }
                let signals = PersonScorer.signals(span.range, in: text, reading: reading, people: people)
                let probability = PersonScorer.probability(signals)
                personLog?.candidates.append(.init(range: span.range, source: "name", signals: signals, probability: probability, hand: hand, free: true, ordinary: !hand))
                if scoring ? hand && probability >= PersonScorer.keepFrom : hand {
                    spans.append(span)
                    if scoring { sure[span.range] = PersonScorer.confidence(probability) }
                } else if scoring, hand, PersonScorer.doubtful(signals, probability) {
                    doubts.append(Span(range: span.range, entity: "PERSON", score: probability))
                }
            }
            // A kept guess carries the scorer's confidence; until then it keeps its model's score, so the address model and the context model's longer reading can still take it in.
            func scored(_ spans: [Span]) -> [Span] {
                sure.isEmpty ? spans : spans.map { span in
                    guard span.entity == "PERSON", span.score <= NameModel.score, let confidence = sure[span.range] else { return span }
                    return Span(range: span.range, entity: span.entity, score: confidence)
                }
            }
            // The address model reads each address whole, taking in the parts others found.
            spans = Self.placed(located, into: spans, quiet: quiet + written.quiet + labelled.labels + keyed.spans.map(\.range), fields: keyed.fields.map(\.range), in: text)
            guard let context, !context.spans.isEmpty || !context.people.isEmpty else { return scored(spans) }
            // The context model fills what is left after the name model. An
            // employer is the organisation the tagger saw; anything else in one is no one's.
            var taken = IndexSet(), organised = IndexSet()
            for range in spans.map(\.range) + quiet + written.quiet + labelled.labels where !range.isEmpty { taken.insert(integersIn: range) }
            for range in organisations where !range.isEmpty { organised.insert(integersIn: range) }
            // Whether a person read here would fill a gap: nothing else found there but
            // the name model's guesses inside it, and the tagger read no organisation.
            let weak = spans.filter { $0.entity == "PERSON" && $0.score <= NameModel.score }.map(\.range)
            var strong = IndexSet()
            for span in spans where !(span.entity == "PERSON" && span.score <= NameModel.score) && !span.range.isEmpty { strong.insert(integersIn: span.range) }
            for range in quiet + written.quiet + labelled.labels where !range.isEmpty { strong.insert(integersIn: range) }
            func open(_ range: Range<Int>) -> Bool {
                guard !organised.intersects(integersIn: range) || person(range), !strong.intersects(integersIn: range) else { return false }
                return !weak.contains { $0.overlaps(range) && !(range.lowerBound <= $0.lowerBound && $0.upperBound <= range.upperBound) }
            }
            // A listed first name and a surname or more, with no word of an organisation's around them, is a person's
            // name though the tagger read an organisation there ("Marta Nogueira Pinto"); the scorer still decides.
            func person(_ range: Range<Int>) -> Bool {
                let words = NameShape.words(range, in: text)
                guard words.count >= 2, let first = words.first, NameLists.isFirst(first.bare), !NameLists.isOrdinary(first.bare), !NameLists.isWordlike(first.bare),
                      words.allSatisfy({ $0.text.first?.isUppercase == true }) else { return false }
                return !NameTagger.partOfOrganisation(range, in: text)
            }
            // A street or a house the model reads as a place ("on Mill Lane") gets no town's
            // stand-in: like the address model's single pieces, it is asked about instead.
            var guesses: [Span] = []
            for span in context.spans {
                if span.entity == "LOCATION", !taken.intersects(integersIn: span.range), AddressModel.streetAlone(TextRanges.substring(text, span.range)) {
                    doubts.append(Span(range: span.range, entity: "ADDRESS", score: AddressModel.doubtScore))
                } else {
                    guesses.append(span)
                }
            }
            for (index, person) in context.people.enumerated() {
                if index.isMultiple(of: 64) && isCancelled() { return scored(spans) }
                let guess = Span(range: person.range, entity: "PERSON", score: ContextStage.score)
                guard !Self.namesNoOne(guess, in: text) else { continue }
                let free = open(person.range)
                guard free || personLog != nil else { continue }
                let signals = PersonScorer.signals(person.range, in: text, reading: reading, people: people)
                let probability = PersonScorer.probability(signals), hand = PersonScorer.agrees(signals), ordinary = NameShape.ordinaryGuess(guess, in: text)
                personLog?.candidates.append(.init(range: person.range, source: "context", signals: signals, probability: probability, hand: hand, free: free, ordinary: ordinary))
                guard free, hand, !ordinary, !scoring || probability >= PersonScorer.keepFrom else {
                    // Nothing else agrees, or the scorer doubts it: not sure enough to replace, too likely to ignore.
                    if scoring, free, !ordinary, PersonScorer.doubtful(signals, probability) { doubts.append(Span(range: person.range, entity: "PERSON", score: probability)) }
                    continue
                }
                guesses.append(guess)
                if scoring { sure[person.range] = PersonScorer.confidence(probability) }
            }
            guesses.sort { $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound < $1.range.upperBound }
            for (index, span) in guesses.enumerated() where !Self.namesNoOne(span, in: text) {
                // Each finding is checked against every other, so a long text checks often.
                if index.isMultiple(of: 64) && isCancelled() { return scored(spans) }
                // A guess inside the finding gives way to it: part of a non-Latin
                // name the name model read, or a company's first word the tagger
                // read as a person ("Orrinvale" of "Orrinvale Freight").
                let yields = { (other: Span) in
                    span.range.lowerBound <= other.range.lowerBound && other.range.upperBound <= span.range.upperBound
                        && (span.entity == "EMPLOYER" ? ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION"].contains(other.entity) && other.score <= 0.85
                                                      : span.entity == "PERSON" && other.score <= NameModel.score)
                }
                var blocked = taken
                for other in spans where yields(other) { blocked.remove(integersIn: other.range) }
                guard !blocked.intersects(integersIn: span.range) else { continue }
                guard span.entity == "EMPLOYER" || !organised.intersects(integersIn: span.range) || person(span.range) else { continue }
                spans.removeAll(where: yields)
                spans.append(span)
                taken.insert(integersIn: span.range)
            }
            return scored(spans)
        }
    }
    /// A name written beside the email it spells, in any case: "BRISA
    /// VANTONGEREN wrote from brisa.vantongeren@…". The local part's words,
    /// in order, written as words; one of them must be a name or no ordinary
    /// word, so "support.team" spells no one.
    private static let letters = CharacterSet.letters
    /// `handles`: read a username's whole value as a local part ("/Users/genevieve.oduya/…").
    static func spelledByEmail(_ spans: [Span], in text: String, handles: Bool = false, isCancelled: () -> Bool = { false }) -> [Span] {
        let emails = spans.filter { $0.entity == (handles ? "USERNAME" : "EMAIL_ADDRESS") }
        guard !emails.isEmpty else { return [] }
        var spelled: [[String]] = []
        var seen: Set<String> = []
        for email in emails {
            let local = TextRanges.substring(text, email.range).prefix { $0 != "@" }.lowercased()
            let parts = local.split(whereSeparator: { ".-_".contains($0) }).map(String.init)
            guard (2...3).contains(parts.count), parts.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }), seen.insert(local).inserted,
                  parts.contains(where: { NameLists.isName($0) || !NameLists.isOrdinary($0) }) else { continue }
            spelled.append(parts)
        }
        guard !spelled.isEmpty else { return [] }
        // Every word's place once; only a word as long as some email's first word is read: each
        // email's first word is looked up, not searched for.
        let ns = text as NSString
        var inEmail = IndexSet()
        for email in emails { inEmail.insert(integersIn: email.range) }
        let lengths = Set(spelled.map { ($0[0] as NSString).length })
        var words: [Range<Int>] = []
        var at: [String: [Int]] = [:]
        var start = -1
        for index in 0...ns.length {
            if index.isMultiple(of: 4096) && isCancelled() { return [] }
            let letter = index < ns.length && Unicode.Scalar(ns.character(at: index)).map(Self.letters.contains) == true
            if letter, start < 0 { start = index }
            if !letter, start >= 0 {
                if lengths.contains(index - start) { at[ns.substring(with: NSRange(location: start, length: index - start)).lowercased(), default: []].append(words.count) }
                words.append(start..<index)
                start = -1
            }
        }
        func word(_ range: Range<Int>) -> String { ns.substring(with: NSRange(location: range.lowerBound, length: range.count)).lowercased() }
        // Each run of words some email spells is read once where its first word is written, whichever emails spell it.
        let spellings = Set(spelled.map { $0.joined(separator: " ") })
        var written: [String: [Span]] = [:]
        for (opening, sizes) in Dictionary(grouping: spelled, by: { $0[0] }).mapValues({ Set($0.map(\.count)).sorted() }) {
            for first in at[opening] ?? [] {
                for size in sizes where first + size <= words.count {
                    let run = words[first..<(first + size)].map { (word: word($0), range: $0) }
                    let spelling = run.map(\.word).joined(separator: " ")
                    guard spellings.contains(spelling) else { continue }
                    // Written as words: only spaces between them, and not inside an email or handle.
                    let between = zip(run, run.dropFirst()).allSatisfy { a, b in ns.substring(with: NSRange(location: a.range.upperBound, length: b.range.lowerBound - a.range.upperBound)).allSatisfy { $0 == " " || $0 == "\t" } }
                    let range = run.first!.range.lowerBound..<run.last!.range.upperBound
                    let edge = { (index: Int) in index >= 0 && index < ns.length && "@._".utf16.contains(ns.character(at: index)) }
                    // A file's name is the name and its extension: "2025 return - Genevieve Oduya.ledger".
                    let extended = range.upperBound < ns.length && ns.character(at: range.upperBound) == 46
                        && ns.substring(with: NSRange(location: range.upperBound, length: min(32, ns.length - range.upperBound))).range(of: #"^\.[A-Za-z0-9]{1,8}(?![\p{L}\p{N}@._-])"#, options: .regularExpression) != nil
                    guard between, !edge(range.lowerBound - 1), !edge(range.upperBound) || extended, !inEmail.intersects(integersIn: range) else { continue }
                    written[spelling, default: []].append(Span(range: range, entity: "PERSON", score: 0.9))
                }
            }
        }
        return spelled.flatMap { written[$0.joined(separator: " ")] ?? [] }
    }
    /// A person's full name closing a file's name before its extension ("2025 return - Genevieve
    /// Oduya.ledger", "Lease_Odalys_Ferriter.pdf"), which no reader takes for a name with the
    /// extension stuck to it: a known first name opening it, and no ordinary word in it.
    private static let namedFile = TextPattern(#"(?<![\p{L}\p{N}'’.-])(\p{Lu}[\p{L}'’-]+(?:[ _]\p{Lu}[\p{L}'’-]+){1,3})\.[A-Za-z][A-Za-z0-9]{1,5}(?![\p{L}\p{N}])"#)
    static func namedFiles(in text: String) -> [Span] {
        TextRanges.matches(namedFile, in: text).compactMap { match in
            let stem = TextRanges.substring(text, match.range(at: 1).location..<NSMaxRange(match.range(at: 1)))
            var words = stem.split(whereSeparator: { $0 == " " || $0 == "_" })
            // What the file is opens its name before whose it is ("Lease_Odalys_Ferriter").
            while words.count > 2, !NameLists.isFirst(String(words[0])) { words.removeFirst() }
            guard words.count >= 2, let first = words.first.map(String.init), NameLists.isFirst(first), !NameLists.isWord(first),
                  words.dropFirst().allSatisfy({ NameLists.isName(String($0)) || !NameLists.isWord(String($0)) }) else { return nil }
            let start = match.range(at: 1).location + (String(stem[..<words[0].startIndex]) as NSString).length
            return Span(range: start..<NSMaxRange(match.range(at: 1)), entity: "PERSON", score: 0.85)
        }
    }
    /// Found by what the value is, whatever it sits under: an email, a card that
    /// passes its check digit, an IBAN, an IP address, a key with a known prefix.
    private static func certain(_ span: Span) -> Bool {
        ["EMAIL_ADDRESS", "CREDIT_CARD", "IBAN_CODE", "IP_ADDRESS", "SECRET"].contains(span.entity) || span.entity == "US_SSN" && span.score >= 0.85
            // An identifier passing its own check, in a form chance seldom writes or named so (see `Recognizers`).
            || Recognizers.drawn.contains(span.entity) && span.score >= 0.85
            // A link's part read by its key or its collection, and a person's ID by its prefix ("cus_…").
            || span.url != nil || span.entity == "RECORD_ID"
    }
    private static let countryPostcode = TextPattern(#"^,? {1,2}(\d{4,6}|\d{4} ?[A-Z]{2}|[A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2})(?=\s*$|\s*\n|[.;)])"#)
    private static let placeWords: Set<String> = ["to", "in", "from", "into", "across", "via", "of", "throughout", "within", "outside"]
    private static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "madam"]
    /// A title alone ("Mr.", "Ms") or before a role ("Madam Chair", "Mr Justice") names no one,
    /// and a rank alone ("Constable", "Private") is neither someone nor a place.
    /// Whether the range is inside a request header's name a command sets ("-H 'Idempotency-Key: …'"), which names nothing.
    static func inHeaderName(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        let start = max(0, range.lowerBound - 48), end = min(ns.length, range.upperBound + 48)
        let before = ns.substring(with: NSRange(location: start, length: range.lowerBound - start))
        let after = ns.substring(with: NSRange(location: range.upperBound, length: end - range.upperBound))
        return before.range(of: #"(?:^|\s)(?:-H|--header)[ \t]+['"]?[A-Za-z0-9-]*$"#, options: .regularExpression) != nil
            && after.range(of: #"^[A-Za-z0-9-]*:"#, options: .regularExpression) != nil
    }
    /// Ladies and gentlemen, as a letter in German, Dutch, French, Spanish or Italian greets them.
    private static let everyone = TextPattern(#"\b(?:Damen und Herren|Dames en Heren|Mesdames(?:,)? Messieurs|Mesdames et Messieurs|Señoras y Señores|Signore e Signori)\b"#)
    private static func namesNoOne(_ span: Span, in text: String) -> Bool {
        guard span.entity == "PERSON" || span.entity == "LOCATION" else { return false }
        if inHeaderName(span.range, in: text) { return true }
        let words = TextRanges.substring(text, span.range).split(separator: " ")
        if span.entity == "LOCATION" {
            // A country, a continent or a nationality ("of Norway", "Danish", "Finnish Export Controls") is shared by millions: no one's place.
            if ContextStage.nations.contains(ContextStage.normalPlace(TextRanges.substring(text, span.range))) { return true }
            return words.allSatisfy { NameShape.isRole(String($0)) && (WrittenNames.ranks.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))) || WrittenNames.wordRanks.contains($0.lowercased())) }
        }
        // An identifier's scheme named as its label ("Her Aadhaar is 2345…") is no one, though no list knows the word.
        if words.count == 1, let kind = KeyHints.hint(String(words[0])), ["ID_NUMBER", "US_SSN"].contains(kind),
           !NameLists.isFirst(String(words[0])), !NameLists.isSurname(String(words[0])) { return true }
        // A letter's "Sehr geehrte Damen und Herren" greets whoever reads it.
        if text.contains(" ") {
            let ns = text as NSString, from = max(0, span.range.lowerBound - 24)
            let around = ns.substring(with: NSRange(location: from, length: min(ns.length, span.range.upperBound + 24) - from))
            for match in TextRanges.matches(Self.everyone, in: around) where match.range.location + from <= span.range.lowerBound && span.range.upperBound <= NSMaxRange(match.range) + from { return true }
        }
        return words.allSatisfy { word in
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return titles.contains(bare) || WrittenNames.isRole(bare) || WrittenNames.wordRanks.contains(bare) && word.first?.isUppercase == true
        }
    }
    /// Whether a title or a rank, written with its capital, stands right before the range.
    private static func titled(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        guard range.lowerBound > 1, [32, 9].contains(ns.character(at: range.lowerBound - 1)) else { return false }
        guard let before = Context.words(before: range.lowerBound, in: text, limit: 1).first, before.first?.isUppercase == true else { return false }
        let start = range.lowerBound - 1 - (before as NSString).length
        let lead = start >= 0 ? ns.substring(with: NSRange(location: start, length: (before as NSString).length)) : ""
        let dotted = start >= 1 ? ns.substring(with: NSRange(location: start - 1, length: (before as NSString).length + 1)) : ""
        guard lead == before || dotted == before + "." else { return false }
        let bare = before.lowercased()
        return People.isTitle(before) || WrittenNames.ranks.contains(bare) || WrittenNames.wordRanks.contains(bare)
    }
    private static let uuid = TextPattern(#"(?i)(?<![0-9a-f-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f-])"#)
    private static let zoneAnywhere = TextPattern(#"(?<![A-Za-z])(?:Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific|Etc)/[A-Za-z_+-]+(?:/[A-Za-z_+-]+)?"#)
    func combined(_ base: [Span], text: String, matcher: GazetteerMatcher) -> [Span] {
        autoreleasepool {
            if let first = base.first, first.score == 1, first.range == 0..<(text as NSString).length,
               base.count == 1 { return base }
            var spans = base
            let ns = text as NSString
            func capital(_ index: Int) -> Bool {
                index < ns.length && Unicode.Scalar(ns.character(at: index)).map(CharacterSet.uppercaseLetters.contains) == true
            }
            // A lowercase name part counts only as the head of a camelCase word ("mariaGonzalez").
            // Inside a pasted object's key, a name counts only as the whole key: "ledgerlyFees" beside a
            // "Ledgerly" read as someone is still the field's name, and renaming it breaks the object.
            var keys: [Range<Int>]?
            for match in matcher.matcher.matches(in: text, accepting: { wholeWord($0, in: text) })
            where !matcher.capitalOnly[match.index] || capital(match.range.lowerBound) || capital(match.range.upperBound) {
                if keys == nil { keys = text.contains(":") || text.contains("=") ? KeyedValues.scan(text).keys : [] }
                if keys!.contains(where: { $0.overlaps(match.range) && $0 != match.range }) { continue }
                if matcher.cuedOnly[match.index] && !NameCues.position(match.range, in: text) { continue }
                if matcher.unlisted[match.index] && !NameCues.namedWord(match.range, in: text) { continue }
                // "Okafor, Ama" is one person unless it is two names' ends in a list: "Ama Okafor, Ama Lind".
                if matcher.lastFirst[match.index] && Self.withinList(match.range, ns) { continue }
                spans.append(Span(range: match.range, entity: matcher.entities[match.index], score: GazetteerMatcher.score))
            }
            // A name found elsewhere may be half of this one ("Karol" before a surname already known).
            return Self.wholeName(Self.resolve(Links.outside(spans, in: text)), in: text)
        }
    }
    private static let placeTail = TextPattern(#"^,[ \t]*([A-Z]{2}\b|[A-Z][a-z]+(?: [A-Z][a-z]+){0,3})(?:[ \t,]+(\d{5}(?:-\d{4})?|[A-Za-z]\d[A-Za-z] ?\d[A-Za-z]\d)\b)?"#)
    private static let cityLine = TextPattern(#"(?<![\p{L}-])(\p{Lu}[\p{Ll}'’.-]+(?: \p{Lu}[\p{Ll}'’.-]+){0,2}), ([A-Z]{2,3}) (\d{5}(?:-\d{4})?|[A-Z]\d[A-Z] ?\d[A-Z]\d|\d{4})(?![\w-])"#)
    private static let stacked = TextPattern(#"(?m)^[ \t]*(\d{1,6}[A-Za-z]?[ \t]+\p{Lu}[^\r\n]{1,60}?)[ \t]*\r?\n(?:[ \t]*([^\r\n,]{1,30}?)[ \t]*\r?\n)?[ \t]*(\p{Lu}[\p{L}.'’-]+(?:[ \t]+\p{Lu}[\p{L}.'’-]+){0,2}),[ \t]*(\p{Lu}\p{L}+(?:[ \t]+\p{Lu}\p{L}+){0,2}|[A-Z]{2,3})\.?[ \t]+(\d{5}(?:-\d{4})?|[A-Za-z]\d[A-Za-z][ \t]?\d[A-Za-z]\d)[ \t]*$"#)
    private static let addressee = TextPattern(#"(\p{Lu}[\p{L}'’.-]*(?:[ \t]+\p{Lu}[\p{L}'’.-]*){1,4})[ \t]*(?:,|\r?\n)[ \t]*$"#)
    private static let labelWords: Set<String> = ["ship", "to", "bill", "attn", "attention", "deliver", "send", "mail", "address", "customer", "name", "dear", "from", "care", "of", "c/o", "recipient", "sold", "remit"]
    /// Written addresses carry more than the parts found on their own. A place
    /// takes the region and postcode after it ("Boise, ID 83702"), and the
    /// capitalised words before a street address ("Oluwaseun Brightwater,
    /// 4821 Juniper Hollow Rd") are the person it is for.
    static func addressed(_ spans: [Span], in text: String) -> [Span] {
        var result = spans
        let ns = text as NSString
        for (index, span) in spans.enumerated() where span.entity == "LOCATION" {
            let rest = ns.substring(with: NSRange(location: span.range.upperBound, length: min(48, ns.length - span.range.upperBound)))
            guard let match = TextRanges.matches(placeTail, in: rest).first else { continue }
            let region = (rest as NSString).substring(with: match.range(at: 1))
            guard Places.region(region) != nil else { continue }
            result[index] = Span(range: span.range.lowerBound..<(span.range.upperBound + NSMaxRange(match.range)), entity: "LOCATION", score: max(span.score, 0.8))
        }
        // "Boise, ID 83702" and "Laval, QC H7N 5H9" are a place however the sentence around them reads.
        if text.contains(",") {
            for match in TextRanges.matches(cityLine, in: text) {
                let region = ns.substring(with: match.range(at: 2)), postal = ns.substring(with: match.range(at: 3))
                guard let known = Places.region(region), Places.country(postal: postal) == known.country else { continue }
                result.append(Span(range: match.range.location..<NSMaxRange(match.range), entity: "LOCATION", score: 0.85))
            }
        }
        // A signature stacks its address: a street, maybe a unit, then "City, ST ZIP".
        if text.contains("\n") {
            for match in TextRanges.matches(stacked, in: text) {
                let unit = match.range(at: 2), region = ns.substring(with: match.range(at: 4)), postal = ns.substring(with: match.range(at: 5))
                guard let known = Places.region(region), Places.country(postal: postal) == known.country,
                      unit.location == NSNotFound || ns.substring(with: unit).contains(where: \.isNumber) && ns.substring(with: unit).split(separator: " ").count <= 3 else { continue }
                let from = match.range(at: 1).location
                result.append(Span(range: from..<NSMaxRange(match.range(at: 5)), entity: "ADDRESS", score: 0.9))
            }
        }
        for span in spans where span.entity == "ADDRESS" && span.range.lowerBound > 0 {
            let start = max(0, span.range.lowerBound - 96)
            let before = ns.substring(with: NSRange(location: start, length: span.range.lowerBound - start))
            guard let match = TextRanges.matches(addressee, in: before).first else { continue }
            let window = before as NSString
            var words = window.substring(with: match.range(at: 1)).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var from = match.range(at: 1).location
            while let first = words.first, labelWords.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":."))) {
                from = NSMaxRange(window.range(of: words.removeFirst(), range: NSRange(location: from, length: window.length - from)))
            }
            let name = words.joined(separator: " ")
            guard words.count >= 2, !NameTagger.namesOrganisation(name), !Names.citiesFolded.contains(name.lowercased()), Self.readsAsAddressee(words) else { continue }
            let found = window.range(of: words[0], range: NSRange(location: from, length: window.length - from)).location
            guard found != NSNotFound else { continue }
            let end = start + NSMaxRange(match.range(at: 1))
            result.append(Span(range: (start + found)..<end, entity: "PERSON", score: 0.9))
        }
        return result
    }
    /// Words that make the line over an address a job title, a department or
    /// a business rather than the person it is for: "Senior Paralegal",
    /// "Kestrelwood Studio", "Accounts Payable".
    private static let notAddressee: Set<String> = [
        "senior", "junior", "lead", "head", "principal", "associate", "assistant", "executive", "paralegal", "partner", "founder", "cofounder",
        "owner", "coordinator", "specialist", "analyst", "engineer", "consultant", "administrator", "accountant", "receptionist", "clerk",
        "nurse", "technician", "designer", "developer", "intern", "supervisor", "editor", "producer", "curator", "librarian", "pharmacist",
        "studio", "studios", "gallery", "bakery", "cafe", "café", "clinic", "salon", "shop", "store", "restaurant", "legal", "law", "firm",
        "architects", "architecture", "photography", "media", "press", "design", "designs", "works", "workshop", "dental", "pharmacy",
        "surgery", "practice", "chambers", "offices", "hall", "building", "tower", "school", "college", "academy", "church", "hotel",
        "inn", "farm", "garage", "motors", "logistics", "freight", "trading", "traders", "co", "brewery", "kitchen", "estates", "properties",
        "realty", "insurance", "accounting", "recruitment", "reception", "accounts", "payable", "receivable", "division", "suite", "floor"]
    /// Whether the capitalised words over an address read as the person it is
    /// for: no role, job, department or business word, and a last word that
    /// is a name or no ordinary word ("Brightwater"), as a person's surname is.
    static func readsAsAddressee(_ words: [String]) -> Bool {
        let bare = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,:;'’")) }
        if bare.contains(where: { NameShape.isRole($0) || notAddressee.contains($0) }) { return false }
        guard let last = bare.last else { return false }
        return NameLists.isFirst(last) || NameLists.isSurname(last) || !NameLists.isOrdinary(last)
    }
    /// Kinds of finding that can be part of an address: the address model's
    /// finding takes them in, so the address is replaced as one unit.
    private static let addressParts: Set<String> = ["ADDRESS", "LOCATION", "POSTAL_CODE", "REGION", "ID_NUMBER", "US_BANK_NUMBER", "US_DRIVER_LICENSE", "US_PASSPORT", "US_ITIN", "US_SSN"]
    /// Read as a name, but inside an address it is a street or a building's
    /// ("rue Victor Hugo", "Corrib House") unless a rule was sure of it.
    private static let looseNames: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMPLOYER", "LOCATION"]

    /// The address model's findings, each one address however much of it the
    /// other detectors read. A number filed under an order or a case starts
    /// none, a greeting's line ends one, and none sits in a link, a quiet
    /// range (a label, a header's date, a structural value) or across a
    /// finding that is surely something else: such a finding at either end
    /// is cut off, and one in the middle leaves the rest as it was.
    static func placed(_ addresses: [Span], into spans: [Span], quiet: [Range<Int>], fields: [Range<Int>] = [], in text: String) -> [Span] {
        guard !addresses.isEmpty else { return spans }
        let ns = text as NSString
        let links = Links.ranges(in: text)
        var result = spans
        for found in addresses {
            // In pasted JSON, YAML or a log line, an address is inside one field's value; one
            // its key names ("postal_code", "city") is read by the key, with the fields beside it.
            guard !fields.contains(where: { $0.overlaps(found.range) && !($0.lowerBound <= found.range.lowerBound && found.range.upperBound <= $0.upperBound) }),
                  var range = addressRange(found.range, in: ns), !(quiet + links).contains(where: { $0.overlaps(range) }) else { continue }
            var blocked = false
            for other in result where other.range.overlaps(range) && !(addressParts.contains(other.entity) && !certain(other)) {
                let inside = range.lowerBound <= other.range.lowerBound && other.range.upperBound <= range.upperBound
                let lead = ns.substring(with: NSRange(location: range.lowerBound, length: max(0, other.range.lowerBound - range.lowerBound)))
                let tail = ns.substring(with: NSRange(location: other.range.upperBound, length: max(0, range.upperBound - other.range.upperBound)))
                let atEdge = !lead.contains(where: { $0.isLetter || $0.isNumber }) || !tail.contains(where: { $0.isLetter || $0.isNumber })
                // A name a reading detector guessed inside the address is a street's or a
                // building's ("rue Victor Hugo", "Corrib House", "Bâtiment C"); at its edge only
                // when it reads as a place, or only the name model guessed it ("Moinhos de Vento"
                // over a city), since an addressee's name may sit there.
                if inside, looseNames.contains(other.entity), other.score < 0.95,
                   other.score < 0.9 && !atEdge || other.score <= NameModel.score
                    || AddressBlock.readsAsPlace(ns.substring(with: NSRange(location: other.range.lowerBound, length: other.range.count)))
                    || Self.withinPiece(other.range, of: range, in: ns) { continue }
                if !lead.contains(where: { $0.isLetter || $0.isNumber }) || other.range.lowerBound <= range.lowerBound {
                    range = min(range.upperBound, other.range.upperBound)..<range.upperBound
                } else if !tail.contains(where: { $0.isLetter || $0.isNumber }) || other.range.upperBound >= range.upperBound {
                    range = range.lowerBound..<max(range.lowerBound, other.range.lowerBound)
                } else {
                    blocked = true
                }
            }
            guard !blocked, let found = trimmed(range, in: ns), !onlyFiledNumbers(found, in: ns), AddressBlock.hasCue(ns.substring(with: NSRange(location: found.lowerBound, length: found.count))) else { continue }
            // "(Burgos" closes its bracket.
            var kept = found
            let value = ns.substring(with: NSRange(location: kept.lowerBound, length: kept.count))
            if value.filter({ $0 == "(" }).count > value.filter({ $0 == ")" }).count, kept.upperBound < ns.length, ns.character(at: kept.upperBound) == 41 { kept = kept.lowerBound..<(kept.upperBound + 1) }
            // The parts it overlaps give way; one that runs past it (the system detector's longer reading) widens it.
            let parts = result.filter { $0.range.overlaps(kept) }
            let lower = parts.filter { $0.entity == "ADDRESS" }.map(\.range.lowerBound).reduce(kept.lowerBound, min)
            let upper = parts.filter { $0.entity == "ADDRESS" }.map(\.range.upperBound).reduce(kept.upperBound, max)
            let merged = lower..<upper
            let score = max(AddressModel.score, parts.filter { $0.entity == "ADDRESS" }.map(\.score).max() ?? 0)
            result.removeAll { $0.range.overlaps(merged) }
            result.append(Span(range: merged, entity: "ADDRESS", score: score))
        }
        return result
    }

    /// Whether every number in the range is filed under an order, a reference
    /// or a case ("ONLINE TRANSFER REF 88213"): then it holds no house number or postcode.
    private static func onlyFiledNumbers(_ range: Range<Int>, in ns: NSString) -> Bool {
        var index = range.lowerBound, numbers = 0
        while index < range.upperBound {
            guard let scalar = Unicode.Scalar(ns.character(at: index)), CharacterSet.decimalDigits.contains(scalar) else { index += 1; continue }
            if index == range.lowerBound || !(Unicode.Scalar(ns.character(at: index - 1)).map { CharacterSet.alphanumerics.contains($0) } ?? false) {
                numbers += 1
                if !filed(index, in: ns) { return false }
            }
            while index < range.upperBound, let next = Unicode.Scalar(ns.character(at: index)), CharacterSet.decimalDigits.contains(next) { index += 1 }
        }
        return numbers > 0
    }

    /// Whether a name inside an address shares its piece with the address's
    /// numbers: a street's name before a house number ("Contrada della Nazionale n. 73")
    /// or a city's after a postcode ("96011 Augusta"). An addressee's name is a piece of its own.
    private static func withinPiece(_ name: Range<Int>, of address: Range<Int>, in ns: NSString) -> Bool {
        let breaks = CharacterSet(charactersIn: ",;\n|")
        var start = name.lowerBound, end = name.upperBound
        while start > address.lowerBound, let scalar = Unicode.Scalar(ns.character(at: start - 1)), !breaks.contains(scalar) { start -= 1 }
        while end < address.upperBound, let scalar = Unicode.Scalar(ns.character(at: end)), !breaks.contains(scalar) { end += 1 }
        let lead = ns.substring(with: NSRange(location: start, length: name.lowerBound - start)), tail = ns.substring(with: NSRange(location: name.upperBound, length: end - name.upperBound))
        return lead.contains(where: \.isNumber) || tail.contains(where: \.isNumber)
    }

    /// The range without punctuation or spaces at its ends, if it still holds
    /// an address: two words, and a digit or two pieces ("Hauptstraße, Berlin-Mitte").
    private static func trimmed(_ range: Range<Int>, in ns: NSString) -> Range<Int>? {
        var lower = range.lowerBound, upper = range.upperBound
        let edge = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "#)"))
        while lower < upper, let scalar = Unicode.Scalar(ns.character(at: lower)), edge.contains(scalar) { lower += 1 }
        while upper > lower, let scalar = Unicode.Scalar(ns.character(at: upper - 1)), edge.contains(scalar) || scalar == ")" && !ns.substring(with: NSRange(location: lower, length: upper - lower)).contains("(") { upper -= 1 }
        guard lower < upper else { return nil }
        let value = ns.substring(with: NSRange(location: lower, length: upper - lower))
        let words = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.contains(where: \.isLetter) }
        return words.count >= 2 && (value.contains(where: \.isNumber) || AddressBlock.pieces(value).count >= 2) ? lower..<upper : nil
    }
    private static let timeZone = TextPattern(#"^\s*(?i:africa|america|antarctica|arctic|asia|atlantic|australia|europe|indian|pacific|etc)/[A-Za-z_+-]+(?:/[A-Za-z_+-]+)?\s*$"#)
    private static let decimal = TextPattern(#"^[-+]?\d+\.\d+$"#)
    /// A value written as a name (see `writtenName`), a surname's particles in lowercase between its words ("Odalys van der Berg").
    private static let nameShape = TextPattern(#"^\s*(\p{Lu}[\p{L}'’.-]*(?:\s+(?:(?:van|von|der|den|de|del|della|di|da|du|dos|das|la|le|ten|ter|bin|ibn|al|el|y)\s+){0,2}\p{Lu}[\p{L}'’.-]*){1,3}|\p{Lu}[\p{L}'’.-]*,\s*\p{Lu}[\p{L}'’.-]*(?:\s+\p{Lu}[\p{L}'’.-]*)?)\s*(?:\([^()]*\))?\s*$"#)
    private static let loneFirst = TextPattern(#"^\s*(\p{Lu}\p{Ll}+)\s*$"#)
    /// The range of a value written as a name: two to four capitalised words, with a
    /// surname's particles between them, "Last, First",
    /// either with a trailing note like "(Support)", or a known first name alone.
    /// One token a person signs in with: letters with a dot, an underscore or digits ("maria.gonzalez",
    /// "jdoe42"), never a file's name, a version, a link or an email.
    /// `client`: whether the key names the person the record serves ("patient", "customer"), whose
    /// handle a file's name may be ("jdoe.js"); under a worker's ("agent", "reviewer") it is a file.
    static func isHandle(_ text: String, client: Bool = false) -> Bool {
        guard (3...40).contains(text.count), text.first?.isLetter == true, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              text.contains(where: { $0 == "." || $0 == "_" || $0.isNumber }), text.last.map({ $0.isLetter || $0.isNumber }) == true else { return false }
        // A version ("curl8.0"), a release's tag ("release_2026"), a standard's name ("RFC4716") or a code in capitals ("SKU4410").
        guard !RecordIDs.versioned(text), TextRanges.matches(capitalCode, in: text).isEmpty else { return false }
        // A file's name, but where the key names a client: there its stem is the handle ("jdoe.js").
        if RecordIDs.isFileName(text) { return client && text[..<text.lastIndex(of: ".")!].filter(\.isLetter).count >= 3 }
        return text.filter(\.isLetter).count >= 3
    }
    private static let capitalCode = TextPattern(#"^[A-Z]{2,}[-_]?\d+$"#)
    /// The people a record serves, under whose key a handle is theirs whatever it ends in.
    static let clients: Set<String> = ["patient", "customer", "client", "user", "member", "student", "applicant", "candidate", "passenger", "traveler", "traveller",
                                               "tenant", "borrower", "guest", "insured", "policyholder", "cardholder", "accountholder", "beneficiary", "visitor", "employee"]
    static func clientKey(_ key: String?) -> Bool {
        KeyHints.words(key).last.map(clients.contains) == true
    }
    static func writtenName(_ text: String) -> Range<Int>? {
        let match = TextRanges.matches(nameShape, in: text).first
            ?? TextRanges.matches(loneFirst, in: text).first.flatMap { match in
                Names.unambiguousFirst.contains(TextRanges.substring(text, match.range(at: 1).location..<NSMaxRange(match.range(at: 1))).lowercased()) ? match : nil
            }
        guard let match else { return nil }
        let range = match.range(at: 1).location..<NSMaxRange(match.range(at: 1))
        return NameTagger.namesOrganisation(TextRanges.substring(text, range)) ? nil : range
    }
    private func system(_ text: String) -> [Span] {
        guard let detector = systemDetector else { return [] }
        var matches: [NSTextCheckingResult] = []
        // Reports progress between matches as well, so a long text stops partway once cancelled.
        detector.enumerateMatches(in: text, options: .reportProgress, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            if isCancelled() { stop.pointee = true; return }
            if let match { matches.append(match) }
        }
        return matches.compactMap { match in
            let entity: String
            let score: Double
            switch match.resultType {
            case .phoneNumber:
                let value = TextRanges.substring(text, match.range.location..<NSMaxRange(match.range))
                // A coordinate like "-122.4443" is no phone number.
                guard TextRanges.matches(Self.decimal, in: value).isEmpty else { return nil }
                // Four dotted groups of up to three digits are an address or a version ("256.256.256.256"), never a phone.
                if value.range(of: #"^\d{1,3}(?:\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return nil }
                // A day written year first ("input=1984-03-07", "2026/09/14") is a date, never a phone.
                if value.range(of: #"^(?:19|20)\d\d([-/.])(?:0?[1-9]|1[0-2])\1(?:0?[1-9]|[12]\d|3[01])$"#, options: .regularExpression) != nil { return nil }
                // Ten digits from 1 are a Unix time (2001 to 2033), never a North
                // American number, whose area code starts from 2.
                if value.count == 10 || value.count == 13, value.first == "1", value.allSatisfy({ $0.isASCII && $0.isNumber }) { return nil }
                // A log's technical numbers: a connection's port ("from 10.0.0.5 port 52144"), and an access log's
                // status and size after the request it answers ("GET /x HTTP/1.1" 200 1877).
                let before = (text as NSString).substring(to: match.range.location)
                if before.range(of: #"(?i)\bport[ \t]*[:=]?[ \t]*$"#, options: .regularExpression) != nil, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                   Int(value).map({ $0 <= 65_535 }) == true { return nil }
                if before.range(of: Self.servedLead, options: .regularExpression) != nil, value.range(of: #"^\d+(?:[ \t]+\d+){0,3}$"#, options: .regularExpression) != nil { return nil }
                // A bare run of digits may as well be an account, SSN or ID, so its
                // stand-in keeps the digits instead of becoming "+1 555-…".
                entity = value.allSatisfy(\.isNumber) ? "ID_NUMBER" : "PHONE_NUMBER"; score = 0.75
            case .address:
                // A postcode and nothing but a "state" written like a word ("77120 Hi"): a greeting, not Hawaii.
                let parts = match.addressComponents ?? [:]
                // One piece with no space is a reference's code ("SA-00012": a state's code and a number), never an address.
                guard TextRanges.substring(text, match.range.location..<NSMaxRange(match.range)).contains(where: { $0.isWhitespace || $0 == "," }) else { return nil }
                if parts[.street] == nil, parts[.city] == nil, let state = parts[.state], state.count == 2, state != state.uppercased() { return nil }
                guard let range = Self.addressRange(match.range.location..<NSMaxRange(match.range), in: text as NSString, street: parts[.street] != nil) else { return nil }
                return Span(range: range, entity: "ADDRESS", score: 0.6)
            default: return nil
            }
            return Span(range: match.range.location..<NSMaxRange(match.range), entity: entity, score: score)
        }
    }
    /// What an access log writes before a response's status and sizes: the request it answers
    /// ("GET /x HTTP/1.1" 200 1877), a proxy's timers (0/0/1/42/43 200 1532), a load balancer's
    /// timings in seconds (0.000 0.001 0.000 200 200 34 366), with any statuses or "-" between.
    private static let servedLead = #"(?:HTTP/\d(?:\.\d)?"|(?<![\w/])(?:-?\d+/){2,}\+?-?\d+|(?<![\w.])(?:(?:-?\d+\.\d{3,}|-1)[ \t]+){2}(?:-?\d+\.\d{3,}|-1))(?:[ \t]+(?:\d+|-))*[ \t]+$"#
    /// A line that opens a message or closes one: "Hi Saoirse,", "Dear Ms Lind", "Thanks, Bram".
    private static let greetingLine = TextPattern(#"(?i)^[ \t>]*(?:hi|hello|hey|hiya|dear|greetings|good (?:morning|afternoon|evening)|thanks|thank you|many thanks|cheers|regards|kind regards|best regards|warm regards|sincerely|yours sincerely|yours truly)(?![\p{L}\p{N}])"#)
    /// A number something is filed under ("order 77120", "Invoice #4412", "case no. 88"), which no house or postcode is.
    private static let referenceBefore = TextPattern(#"(?i)(?<![\p{L}\p{N}])(?:order|invoice|ticket|case|ref|reference|booking|confirmation|tracking|claim|policy|receipt|transaction)[ \t]*(?:#|no\.?|nr\.?|number|num\.?|:)?[ \t]*#?[ \t]*$"#)
    /// A number at `location` filed under an order or a case ("order 77120").
    static func filed(_ location: Int, in ns: NSString) -> Bool {
        guard location < ns.length, let first = Unicode.Scalar(ns.character(at: location)), CharacterSet.decimalDigits.contains(first) else { return false }
        let start = max(0, location - 32)
        return !TextRanges.matches(referenceBefore, in: ns.substring(with: NSRange(location: start, length: location - start))).isEmpty
    }
    /// An address as read, cut to what one can hold: a number filed under an
    /// order or a case starts none ("re: order 77120 The Elm Dr Apartments"),
    /// and it ends before a line that greets or signs off ("77120⏎Hi Saoirse"
    /// is no ZIP and state, "77120⏎Dear Mr Lane" no street). Nil when nothing of an address is
    /// left: no words beside its numbers, or, where `street` says the reading
    /// had none, no street at all ("Code 77120⏎Hi" is a word and a number).
    static func addressRange(_ found: Range<Int>, in ns: NSString, street: Bool = true) -> Range<Int>? {
        var range = NSRange(location: found.lowerBound, length: found.count)
        guard range.length > 0 else { return found }
        if filed(range.location, in: ns) { return nil }
        var at = range.location
        while at < NSMaxRange(range) {
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: at, length: 0)))
            guard next < NSMaxRange(range), next > at else { break }
            let rest = ns.substring(with: NSRange(location: next, length: NSMaxRange(range) - next))
            if !TextRanges.matches(greetingLine, in: rest).isEmpty {
                range.length = next - range.location
                // What is left must still be a street or a place: words beside its number.
                let kept = ns.substring(with: range).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
                guard street, kept.contains(where: \.isLetter), kept.contains(where: \.isNumber) else { return nil }
                return range.location..<(range.location + (kept as NSString).length)
            }
            at = next
        }
        // A sentence after the postcode ("…, NY 11215. Done in admin", "…, NY 70544 failed ID-SYN-3") is no part of the address.
        // So is one after the town that follows it ("…, 72194 Regensburg failed WL_FUZZY_HIT").
        let written = ns.substring(with: range)
        // In an address written with capitals, a word in small letters after its postcode or its town is the sentence's;
        // the postcode comes after a comma, never as the house number that opens the address ("4250 North Fairfax Dr. suite 1410").
        let cased = written.contains(where: \.isUppercase)
        let afterComma = { (match: NSTextCheckingResult) in (written as NSString).substring(to: match.range.location).contains(",") }
        if let stop = TextRanges.matches(sentenceAfterPostcode, in: written).first
            ?? (cased ? (TextRanges.matches(wordAfterPostcode, in: written) + TextRanges.matches(sentenceAfterTown, in: written)).filter(afterComma).min(by: { $0.range.location < $1.range.location }) : nil) {
            range.length = stop.range.location
        }
        return range.location..<NSMaxRange(range)
    }
    private static let sentenceAfterTown = TextPattern(#"(?<=(?:\d{4,5}|\d[A-Z]{2})(?:[ \t]{1,3}\p{Lu}[\p{L}'’.-]{0,30}){1,3})(?=[ \t]+(?!(?:upon|unter|sous|over)\b)\p{Ll}{4,}\b)"#)
    private static let sentenceAfterPostcode = TextPattern(#"(?<=\d{4}|\d[A-Z]{2})\.(?=[ \t]+(?!(?:Apt|Apartment|Suite|Ste|Unit|Flat|Floor|St|Ave|Rd|Box)\b)\p{Lu}\p{Ll})"#)
    private static let wordAfterPostcode = TextPattern(#"(?<=\d{4}|\d[A-Z]{2})(?=[ \t]+(?!(?:upon|unter|sous|over)\b)\p{Ll}{4,}\b)"#)
    private static let nameBefore = TextPattern(#"\p{Lu}[\p{L}'’.-]*[ \t]+$"#)
    private static let nameAfter = TextPattern(#"^[ \t]+\p{Lu}"#)
    private static func withinList(_ range: Range<Int>, _ ns: NSString) -> Bool {
        let start = max(0, range.lowerBound - 32)
        let before = ns.substring(with: NSRange(location: start, length: range.lowerBound - start))
        let after = ns.substring(with: NSRange(location: range.upperBound, length: min(8, ns.length - range.upperBound)))
        return !TextRanges.matches(nameBefore, in: before).isEmpty || !TextRanges.matches(nameAfter, in: after).isEmpty
    }
    private func wholeWord(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        return !TextRanges.joinsWord(ns, at: range.lowerBound, underscore: true) && !TextRanges.joinsWord(ns, at: range.upperBound, underscore: true)
    }
    static let literals: Set<String> = ["true", "false", "null", "True", "False", "None", "nil", "undefined", "NaN", "TRUE", "FALSE", "NULL"]
    static func resolve(_ spans: [Span]) -> [Span] {
        let ordered = spans.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.range.count != b.range.count { return a.range.count > b.range.count }
            return a.range.lowerBound < b.range.lowerBound
        }
        var kept: [Span] = []
        for (index, span) in ordered.enumerated() {
            if index.isMultiple(of: 64) && Task.isCancelled { return kept }
            var low = 0, high = kept.count
            while low < high {
                let middle = (low + high) / 2
                if kept[middle].range.lowerBound < span.range.lowerBound { low = middle + 1 }
                else { high = middle }
            }
            let insertion = low
            var first = insertion
            if first > 0 && kept[first - 1].range.overlaps(span.range) { first -= 1 }
            var end = first
            while end < kept.count && kept[end].range.overlaps(span.range) { end += 1 }
            if first == end {
                kept.insert(span, at: insertion)
            } else if kept[first..<end].allSatisfy({
                span.range.lowerBound <= $0.range.lowerBound && span.range.upperBound >= $0.range.upperBound
                    && span.range != $0.range && span.entity != $0.entity
            }) {
                kept.replaceSubrange(first..<end, with: [span])
            }
        }
        return kept
    }
}

struct GazetteerMatcher {
    static let supportedEntities = ["FIRST_NAME", "LAST_NAME", "PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER"]
    /// What a value found again by its name carries until it takes the confidence of where it was learned (`Job.here`).
    static let score = 0.95
    let matcher: Matcher
    let entities: [String]
    let capitalOnly: [Bool]
    /// Found only where written as a name (`NameCues.position`).
    let cuedOnly: [Bool]
    /// "Okafor, Ama": found only where no other name runs into it.
    let lastFirst: [Bool]
    /// A word a dictionary holds and no list of names does ("Refund"): never found opening a sentence on its own.
    let unlisted: [Bool]

    init(_ gazetteer: [String: Set<String>], nameParts: Set<String> = [], cuedParts: Set<String> = [], isCancelled: () -> Bool = { false }) {
        let (literals, labels) = Self.entries(gazetteer, isCancelled: isCancelled)
        matcher = Matcher(literals, isCancelled: isCancelled)
        entities = labels
        // A name that is also an ordinary word ("Rose", "Hunt", "Will") is
        // that person only where it is written with a capital.
        cuedOnly = zip(literals, labels).map { literal, label in
            label == "PERSON" && cuedParts.contains(literal) || ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(label) && Self.ordinaryWord(literal)
        }
        capitalOnly = zip(zip(literals, labels), cuedOnly).map { pair, cued in cued || pair.1 == "PERSON" && nameParts.contains(pair.0) }
        lastFirst = zip(literals, labels).map { $1 == "PERSON" && $0.contains(",") }
        unlisted = zip(literals, labels).map { literal, label in ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(label) && NameLists.isUnlistedWord(literal) }
    }

    static func ordinaryWord(_ literal: String) -> Bool {
        literal.allSatisfy(\.isLetter) && (NameLists.isWordlike(literal) || NameLists.isOrdinary(literal) || NameLists.isUnlistedWord(literal))
    }
    private static func entries(_ gazetteer: [String: Set<String>], isCancelled: () -> Bool) -> ([String], [String]) {
        var literals: [String] = []
        var labels: [String] = []
        var seen: Set<[UInt16]> = []
        for entity in supportedEntities {
            for (index, entry) in (gazetteer[entity] ?? []).sorted().enumerated() where !entry.isEmpty {
                if index.isMultiple(of: 4096) && isCancelled() { return (literals, labels) }
                if seen.insert(Matcher.fold(entry)).inserted {
                    literals.append(entry)
                    labels.append(entity)
                }
            }
        }
        return (literals, labels)
    }
}
