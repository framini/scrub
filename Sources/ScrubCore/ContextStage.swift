import Foundation
import Synchronization

/// Runs the context model over a document's free text: every value of three
/// words or more, or with letters outside the Latin script. Its windows are
/// spread over every core, report progress as `.reading`, and stop between
/// windows once cancelled. Above `gateLimit` UTF-16 units of free text, a
/// window is read only if a sentence in it has something the model could find
/// (see `ContextGate`); below it the model reads everything.
enum ContextStage {
    /// Its findings score below every other detector's, the name model's included.
    static let score = 0.5
    /// The gate misses a few findings reading everything catches, so it waits
    /// for documents where reading everything costs minutes: the model adds
    /// about 20 seconds a megabyte of prose on an M1 Max, the rest of a scrub
    /// several times that. Tests may move it, in debug builds only.
    #if DEBUG
    static let gateFrom = Atomic<Int>(10_000_000)
    static var gateLimit: Int { gateFrom.load(ordering: .relaxed) }
    #else
    static var gateLimit: Int { 10_000_000 }
    #endif
    /// The most a non-Latin name's pieces may lean to no label, set per build
    /// of the model from its held-out generated set (`ContextWeights`).
    static let nonLatinDoubt = ContextWeights.shipped.nonLatinDoubt
    /// Off only in tests that measure Scrub without the model; release builds have no switch.
    #if DEBUG
    static let enabled = Atomic(true)
    static var isEnabled: Bool { enabled.load(ordering: .relaxed) }
    #else
    static var isEnabled: Bool { true }
    #endif

    /// What the model read in one text: its findings as Scrub names them,
    /// and the people it read in Latin script, which count only where
    /// something else agrees. `whole` is false where the gate left windows unread.
    struct Reading: Sendable {
        var spans: [Span] = []
        var people: [Person] = []
        var whole = true
    }
    struct Person: Sendable, Equatable {
        let range: Range<Int>
        /// The most any of its pieces leaned to no label at all.
        let doubt: Float
    }

    /// The model's findings for each text, nil where it read nothing.
    static func find(_ texts: [String?], progress: (Stage, Int, Int) -> Void, cancelled: CancellationFlag) throws -> [Reading?] {
        guard isEnabled, !Coverage.withheld.contains(.contextModel), let model = ContextModel.shared else { return texts.map { _ in nil } }
        let readable = texts.indices.filter { texts[$0].map(isFreeText) == true }
        guard !readable.isEmpty else { return texts.map { _ in nil } }
        let gated = readable.reduce(0) { $0 + (texts[$1]! as NSString).length } >= gateLimit

        // Pieces, in chunks so a long text is cut on every core.
        let chunks = readable.flatMap { leaf in Self.chunks(texts[leaf]!).map { (leaf, $0) } }
        let pieces = Mutex([Int: [(Range<Int>, [PieceTokenizer.Piece])]]())
        try parallel(chunks.count, cancelled: cancelled) { index in
            let (leaf, range) = chunks[index]
            let text = texts[leaf]!
            let part = TextRanges.substring(text, range)
            let found = model.tokenizer.pieces(part, isCancelled: { cancelled.isSet }).map { PieceTokenizer.Piece(id: $0.id, range: ($0.range.lowerBound + range.lowerBound)..<($0.range.upperBound + range.lowerBound)) }
            pieces.withLock { $0[leaf, default: []].append((range, found)) }
        }
        var leaves: [(leaf: Int, pieces: [PieceTokenizer.Piece], windows: [(first: Int, ids: [Int32])], read: [Bool])] = []
        for leaf in readable {
            let ordered = pieces.withLock { $0[leaf] ?? [] }.sorted { $0.0.lowerBound < $1.0.lowerBound }.flatMap(\.1)
            guard !ordered.isEmpty else { continue }
            let windows = model.windows(ordered)
            let read: [Bool]
            if gated {
                let picked = ContextGate.picks(texts[leaf]!, model: model)
                read = windows.map { window in
                    let last = min(ordered.count, window.first + window.ids.count - 2) - 1
                    let span = ordered[window.first].range.lowerBound..<ordered[last].range.upperBound
                    return picked.contains { $0.overlaps(span) }
                }
            } else {
                read = windows.map { _ in true }
            }
            leaves.append((leaf, ordered, windows, read))
        }

        // A window's labels follow from its pieces alone, so windows with the
        // same pieces (a table's repeated notes) are read once.
        var distinct: [[Int32]] = [], reading: [[Int32]: Int] = [:]
        var readAs = leaves.map { [Int?](repeating: nil, count: $0.windows.count) }
        for item in leaves.indices {
            for window in leaves[item].windows.indices where leaves[item].read[window] {
                let ids = leaves[item].windows[window].ids
                if let known = reading[ids] { readAs[item][window] = known; continue }
                reading[ids] = distinct.count
                readAs[item][window] = distinct.count
                distinct.append(ids)
            }
        }
        // Longest first so the last ones to finish are short.
        let toRead = distinct
        let jobs = toRead.indices.sorted { toRead[$0].count > toRead[$1].count }
        let decided = Mutex([[ContextModel.Decision]?](repeating: nil, count: toRead.count))
        let done = Atomic(0)
        try parallel(jobs.count, cancelled: cancelled, progress: { progress(.reading, done.load(ordering: .relaxed), jobs.count) }) { index in
            let labels = model.decide(model.logits(toRead[jobs[index]]))
            decided.withLock { $0[jobs[index]] = labels }
            done.add(1, ordering: .relaxed)
        }
        progress(.reading, jobs.count, jobs.count)
        let labelsRead = decided.withLock { $0 }
        let predictions = readAs.map { windows in windows.map { $0.flatMap { labelsRead[$0] } } }

        var result = texts.map { _ -> Reading? in nil }
        for (item, leaf) in leaves.enumerated() {
            let text = texts[leaf.leaf]!
            let labels = model.labelled(leaf.pieces, windows: leaf.windows, predictions: predictions[item])
            let links = links(in: text)
            let found = model.spans(leaf.pieces, labels: labels, in: text)
            result[leaf.leaf] = Reading(spans: found.compactMap { span($0, in: text, links: links) },
                                        people: found.compactMap { person($0, in: text, links: links) },
                                        whole: !leaf.read.contains(false))
        }
        return result
    }

    /// A finding as Scrub names it, or nil for one the stage leaves to others:
    /// a person in Latin script counts only where something else agrees (`person`),
    /// and a handle needs a digit, dot or underscore to be told from a word.
    private static let qualifiedName = TextPattern(#"^(?:[a-z][a-z0-9_]*\.){2,}[A-Z][A-Za-z0-9_$]*$"#)
    static func span(_ found: ContextModel.Found, in text: String, links: [Range<Int>] = []) -> Span? {
        let ns = text as NSString
        guard let range = cleaned(found.range, in: text, links: links) else { return nil }
        let value = TextRanges.substring(text, range)
        let digits = value.filter(\.isNumber).count
        // A secret, ID or handle is a whole token: the model reading the first
        // letters of "Qz7nwsgydtlekmwf&<\"'\\" would leave the rest behind.
        if ["SECRET", "ID", "USERNAME"].contains(found.kind), !wholeToken(ns, range) { return nil }
        // An object's ID ("cus_4TUvJhQkMeNW3tprfQ6G", "pm_9mzWb…") is a reference, not a secret,
        // unless the sentence calls it a key or token.
        if ["SECRET", "ID"].contains(found.kind), !TextRanges.matches(objectID, in: value).isEmpty,
           TextRanges.matches(secretWord, in: sentence(around: range, in: text).text).isEmpty { return nil }
        // So is one under a key an API calls its "token" ("entity_token": "P-MSBW…", see `KeyHints.fits`).
        if found.kind == "SECRET", let key = Patterns.keyBefore(ns, range.lowerBound), KeyHints.hint(key) == "SECRET", !KeyHints.fits(key, value) { return nil }
        let entity: String
        switch found.kind {
        case "PERSON":
            // Names it is sure of: a word in another script ("Καλημέρα" in a
            // caption) leans a little more to being no name than any held-out name did.
            guard value.unicodeScalars.contains(where: isNonLatinNameScript), found.doubt < nonLatinDoubt, mostlyLatin(around: range, in: text) else { return nil }
            entity = "PERSON"
        case "USERNAME":
            let inner = value.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
            // Initials ("P.K.") are no handle: a handle has a lowercase letter or a digit.
            guard inner.count >= 3, inner.contains(where: { $0.isNumber || $0 == "." || $0 == "_" }), !inner.allSatisfy(\.isNumber), !inner.contains(where: \.isWhitespace),
                  inner.contains(where: { $0.isLowercase || $0.isNumber }),
                  // A file name is no handle: "AHMED.mpg".
                  !fileExtensions.contains(inner.split(separator: ".").last.map { $0.lowercased() } ?? "") || !inner.contains(".") else { return nil }
            // Nor is a logger's or a class's qualified name ("c.e.infra.Health", "com.example.kyc.Retry").
            if !TextRanges.matches(qualifiedName, in: inner).isEmpty, let last = inner.split(separator: ".").last.map({ $0.lowercased() }),
               !NameLists.isFirst(last), !NameLists.isSurname(last) { return nil }
            entity = "USERNAME"
        case "LOCATION":
            // A country, a continent or a nationality ("a Danish citizen", "the
            // United Kingdom") is shared by millions: no one's place.
            guard named(value), !isNation(value), !holidays.contains(normalPlace(value)) else { return nil }
            entity = "LOCATION"
        case "ORG":
            guard named(value), employment(around: range, in: text) else { return nil }
            entity = "EMPLOYER"
        case "ID":
            // An amount, a count or a short reference ("deal #268093", "Law no. 3713",
            // "GBP 2,092,569") is no one's ID.
            // Numbers in cells a tab or a run of spaces apart are a table's row ("2093	655	3547"), not one ID.
            guard digits >= 4, !amount(range, in: text), TextRanges.matches(decimal, in: value).isEmpty, !value.contains("\t"), !value.contains("  ") else { return nil }
            // A calendar date ("Last backup 2022-11-28") is a date, not an ID; a birth date is DOB's.
            guard TextRanges.matches(calendarDate, in: value).isEmpty else { return nil }
            // Nor is a reading, a code or a reference no one is filed under (see `notFiledUnder`).
            // Unless its own words call it a person's ("license plate FYT-9375", "MRN-65881").
            guard !notFiledUnder(value) || namedPersonal(range, in: text) else { return nil }
            // A bare run of digits is someone's only where the sentence ties it to
            // someone: a deal, notice or ticket number in a business email is not.
            if value.allSatisfy(\.isNumber) {
                guard digits >= 7, !TextRanges.matches(owner, in: sentence(around: range, in: text).text).isEmpty else { return nil }
            }
            entity = "ID_NUMBER"
        case "SECRET":
            // A secret has a digit, or is a long run in both cases ("UHcYVBCTKacnq"); "Marie-Tooth" is a word.
            guard value.count >= 6, !value.contains(where: \.isWhitespace),
                  digits > 0 || value.count >= 12 && value.contains(where: \.isUppercase) && value.contains(where: \.isLowercase) else { return nil }
            entity = "SECRET"
        case "DOB":
            // A birth date the model reads alone has its year and a day or month
            // ("born 12 May 1984"); a year alone or a month alone is ProseLabels' to judge.
            // A date is a birth date only where the sentence speaks of birth or age: most dates in a document are not.
            guard TextRanges.matches(year, in: value).count == 1, value.contains(where: \.isLetter) || digits > 4,
                  !TextRanges.matches(birth, in: sentence(around: range, in: text).text).isEmpty else { return nil }
            entity = "DATE_OF_BIRTH"
        default: return nil
        }
        return Span(range: range, entity: entity, score: score)
    }

    /// The range without the sentence's punctuation at its ends, or nil for
    /// a guess rather than a finding: inside a link or a hashtag, a piece of a
    /// word ("Down" of "Downtown"), or a run over a line break.
    private static func cleaned(_ found: Range<Int>, in text: String, links: [Range<Int>]) -> Range<Int>? {
        let ns = text as NSString
        // Punctuation at either end belongs to the sentence ("(1-800…", "ICYMI-").
        var range = found
        while range.count > 0, edges.contains(Character(Unicode.Scalar(ns.character(at: range.lowerBound)) ?? " ")) { range = (range.lowerBound + 1)..<range.upperBound }
        while range.count > 0, edges.contains(Character(Unicode.Scalar(ns.character(at: range.upperBound - 1)) ?? " ")) { range = range.lowerBound..<(range.upperBound - 1) }
        guard !range.isEmpty else { return nil }
        // A link's path and a hashtag are written for everyone to read: "t.co/8X9QR2r7zz" is no ID.
        if links.contains(where: { $0.overlaps(range) }) { return nil }
        let value = TextRanges.substring(text, range)
        if value.contains(where: \.isNewline) || TextRanges.joinsWord(ns, at: range.lowerBound, underscore: true) && joined(ns, range.lowerBound)
            || TextRanges.joinsWord(ns, at: range.upperBound, underscore: true) && joined(ns, range.upperBound - 1)
            || hyphened(ns, before: range.lowerBound) || hyphened(ns, after: range.upperBound) { return nil }
        return range
    }

    /// A person the model read in Latin script, which it reads well beside
    /// words that mark a name and too often elsewhere ("Mark" opening a line,
    /// a product): it counts only where something else agrees (`PersonScorer`).
    static func person(_ found: ContextModel.Found, in text: String, links: [Range<Int>] = []) -> Person? {
        guard found.kind == "PERSON", let cleaned = cleaned(found.range, in: text, links: links), !inToken(cleaned, in: text as NSString),
              TextRanges.matches(handleJoint, in: TextRanges.substring(text, cleaned)).isEmpty else { return nil }
        let range = chatterTrimmed(cleaned, in: text)
        let value = TextRanges.substring(text, range)
        guard value.contains(where: \.isLetter), !value.unicodeScalars.contains(where: isNonLatinNameScript) else { return nil }
        return Person(range: range, doubt: found.doubt)
    }

    /// A dot, underscore, at sign or slash between a lowercase letter or digit and another letter or digit, as in a handle ("priya.r"), not between initials ("J.R.").
    private static let handleJoint = TextPattern(#"[\p{Ll}\d][._@/][\p{L}\d]|[\p{L}\d][._@/][\p{Ll}\d]"#)

    /// Whether the range is part of a handle, an address or a path: a dot,
    /// underscore, at sign or slash joins it to a letter or digit ("priya" of "priya.r").
    private static func inToken(_ range: Range<Int>, in ns: NSString) -> Bool {
        let joiners: Set<unichar> = [46, 95, 64, 47]
        let before = range.lowerBound >= 2 && joiners.contains(ns.character(at: range.lowerBound - 1)) && joined(ns, range.lowerBound - 2)
        let after = range.upperBound + 1 < ns.length && joiners.contains(ns.character(at: range.upperBound)) && joined(ns, range.upperBound + 1)
        // "linnea_" of "linnea_a": the joiner inside the range, the rest of the token outside it.
        let opens = joiners.contains(ns.character(at: range.lowerBound)) && joined(ns, range.lowerBound - 1)
        let closes = joiners.contains(ns.character(at: range.upperBound - 1)) && joined(ns, range.upperBound)
        return before || after || opens || closes
    }

    /// The guess without a lowercase word at either end that is no listed
    /// name but an ordinary or a short word, where a listed name is left:
    /// "fyi sven okafor" is Sven Okafor, "w lucia" is Lucia.
    static func chatterTrimmed(_ range: Range<Int>, in text: String) -> Range<Int> {
        let words = NameShape.words(range, in: text)
        func listed(_ word: NameShape.Word) -> Bool { PersonScorer.listedFirst(word.bare) || NameLists.isSurname(word.bare) }
        guard words.count >= 2, words.contains(where: listed) else { return range }
        func chatter(_ word: NameShape.Word) -> Bool {
            word.text == word.text.lowercased() && !listed(word) && (word.bare.count <= 3 || NameLists.isOrdinary(word.bare))
        }
        var low = 0, high = words.count - 1
        while low < high, chatter(words[low]) { low += 1 }
        while high > low, chatter(words[high]) { high -= 1 }
        guard words[low...high].contains(where: listed) else { return range }
        return words[low].range.lowerBound..<words[high].range.upperBound
    }

    private static let objectID = TextPattern(#"^[a-z]{2,8}_[A-Za-z0-9]{8,}$"#)
    private static let secretWord = TextPattern(#"(?i)(?:pass(?:word|wd|code|phrase)?|pwd|secret|token|key|credential|auth|bearer)"#)
    /// An amount ("12.50") or a measure or score ("0.874", "3.14159"): one
    /// point, at most three digits before it.
    /// A value no person is filed under, however much it looks like an ID: a
    /// reading ("BP 156/62"), a diagnosis code ("R07.89"), a reference its prefix
    /// names as an application's, a request's, an order's or a ticket's
    /// ("APP-95146469", "ref-55af36d14d"), or a tracker's key, a project's
    /// capitals and a short number ("PAY-1693"). A prefix that names an
    /// account, a customer or a member ("ACC-0610949") still marks an ID.
    static func notFiledUnder(_ value: String) -> Bool {
        if !TextRanges.matches(reading, in: value).isEmpty || !TextRanges.matches(diagnosis, in: value).isEmpty { return true }
        guard let match = TextRanges.matches(referenced, in: value).first else { return false }
        let ns = value as NSString
        let prefix = ns.substring(with: match.range(at: 1)), number = ns.substring(with: match.range(at: 2))
        if RecordIDs.personPrefixes.contains(prefix.lowercased()) { return false }
        return referencePrefixes.contains(prefix.lowercased())
            || prefix == prefix.uppercased() && (1...5).contains(number.count) && number.allSatisfy(\.isNumber)
    }
    /// Whether an ID is a person's by its own words, though shaped like a reference: its prefix is a
    /// medical record's or a customer's code ("MRN-65881", "CID-92281"), or the words before it in its
    /// sentence name a person's record, licence, plate or biometric ID with no request, order or ticket
    /// after them ("The license plate for the vehicle is VXP-3921", "| Employee ID: | MKT-3928").
    static func namedPersonal(_ range: Range<Int>, in text: String) -> Bool {
        let value = TextRanges.substring(text, range)
        if let match = TextRanges.matches(referenced, in: value).first,
           personCodes.contains((value as NSString).substring(with: match.range(at: 1)).lowercased()) { return true }
        let around = sentence(around: range, in: text)
        let before = (text as NSString).substring(with: NSRange(location: around.range.lowerBound, length: range.lowerBound - around.range.lowerBound))
        guard let cue = TextRanges.matches(personsID, in: before).last else { return false }
        return TextRanges.matches(referenceWord, in: (before as NSString).substring(from: NSMaxRange(cue.range))).isEmpty
    }
    private static let personCodes: Set<String> = ["mrn", "cid"]
    private static let personsID = TextPattern(#"(?i)\b(?:medical[ \t]+records?|mrn|patient|customer|client|member|employee|biometric|licen[cs]e|plates?)\b"#)
    private static let referenceWord = TextPattern(#"(?i)\b(?:order|ticket|request|invoice|application|case|transaction|incident|quote)s?\b"#)
    /// A value whose prefix names a request's, an order's or a ticket's reference ("ref-55af36d14d", "REQ-20417").
    static func referencePrefixed(_ value: String) -> Bool {
        guard let match = TextRanges.matches(referenced, in: value).first else { return false }
        // "app_" opens an applicant's ID as often as an application's reference.
        let prefix = (value as NSString).substring(with: match.range(at: 1)).lowercased()
        return referencePrefixes.contains(prefix) && !["app", "application"].contains(prefix)
    }
    private static let reading = TextPattern(#"^(?:[A-Za-z][A-Za-z0-9]{0,4}[ \t:]+)?\d{2,3}/\d{2,3}$"#)
    private static let diagnosis = TextPattern(#"^[A-Z]\d{2}\.[0-9A-Z]{1,4}$"#)
    private static let referenced = TextPattern(#"^([A-Za-z]{2,10})[-_]([A-Za-z0-9]+)$"#)
    private static let referencePrefixes: Set<String> = ["app", "application", "ref", "reference", "req", "request", "rq", "ticket", "tkt", "case", "order", "ord", "inv", "invoice",
                                                         "txn", "trx", "tx", "quote", "rma", "inc", "chg", "task", "bug", "issue", "job", "run", "batch", "build", "msg", "evt", "event", "trace", "corr"]
    private static let decimal = TextPattern(#"^[-+]?(?:\d+[.,]\d{1,2}|\d{1,3}\.\d+)$"#)
    private static let calendarDate = TextPattern(#"^(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{4})$"#)
    /// Days of the year read as places: "visit at Easter".
    static let holidays: Set<String> = ["easter", "christmas", "xmas", "thanksgiving", "halloween", "new year", "new year's", "hanukkah", "passover",
                                        "ramadan", "eid", "diwali", "lent", "advent", "pentecost", "whitsun", "midsummer"]
    private static let opening: Set<unichar> = Set("([{\"'“‘:=@".utf16)
    private static let closing: Set<unichar> = Set(")]}\"'”’.,;:!?".utf16)

    /// Nothing but space, the text's ends or punctuation that wraps a value on either side.
    private static func wholeToken(_ ns: NSString, _ range: Range<Int>) -> Bool {
        func space(_ index: Int) -> Bool { Unicode.Scalar(ns.character(at: index)).map(\.properties.isWhitespace) ?? false }
        let before = range.lowerBound == 0 || space(range.lowerBound - 1) || opening.contains(ns.character(at: range.lowerBound - 1))
        let after = range.upperBound == ns.length || space(range.upperBound) || closing.contains(ns.character(at: range.upperBound))
            && (range.upperBound + 1 == ns.length || space(range.upperBound + 1) || closing.contains(ns.character(at: range.upperBound + 1)))
        return before && after
    }

    private static let edges: Set<Character> = [".", ",", ";", ":", "!", "?", "(", ")", "[", "]", "{", "}", "\"", "'", "“", "”", "‘", "’", "-", "–", "—", " ", "\t"]
    private static let birth = TextPattern(#"(?i)\b(?:born|birth\w*|dob|d\.o\.b|b\.|aged?|years? old)(?![\w])"#)

    /// The span is part of a hyphenated or dotted word: "Marie-Tooth" of "Charcot-Marie-Tooth".
    private static func hyphened(_ ns: NSString, before index: Int) -> Bool {
        index >= 2 && [45, 46].contains(ns.character(at: index - 1)) && joined(ns, index - 2)
    }
    private static func hyphened(_ ns: NSString, after index: Int) -> Bool {
        index + 1 < ns.length && [45].contains(ns.character(at: index)) && joined(ns, index + 1)
    }

    /// The letter or digit at `index` is part of the word the span cut.
    private static func joined(_ ns: NSString, _ index: Int) -> Bool {
        guard index >= 0, index < ns.length, let scalar = Unicode.Scalar(ns.character(at: index)) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// A place or company is named: some word in it is capitalised (or in
    /// another script) and not one of the commonest words ("the", "aviation", "twerk").
    /// A place as `nations` lists it: lowercase, without "the", an article elided before it ("l'Algérie", "dell'Italia") or a possessive.
    static func normalPlace(_ value: String) -> String {
        var words = value.lowercased().replacingOccurrences(of: "’", with: "'").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.first == "the" { words.removeFirst() }
        if let first = words.first, let elided = first.range(of: #"^(?:l|d|dell|nell|all|dall|sull)'(?=\p{L})"#, options: .regularExpression) {
            words[0] = String(first[elided.upperBound...])
        }
        if let last = words.last, last.hasSuffix("'s") { words[words.count - 1] = String(last.dropLast(2)) }
        return words.joined(separator: " ")
    }

    /// Countries, continents and the words for their people, in English.
    static let nations: Set<String> = Set("""
        afghanistan afghan albania albanian algeria algerian andorra angola angolan argentina argentine argentinian armenia armenian australia australian \
        austria austrian azerbaijan azerbaijani bahamas bahrain bangladesh bangladeshi barbados belarus belarusian belgium belgian belize benin bhutan \
        bolivia bolivian bosnia bosnian botswana brazil brazilian britain british brunei bulgaria bulgarian burkina burundi cambodia cambodian cameroon \
        canada canadian chad chile chilean china chinese colombia colombian congo congolese croatia croatian cuba cuban cyprus cypriot czechia czech \
        denmark danish djibouti dominica ecuador egypt egyptian eritrea estonia estonian eswatini ethiopia ethiopian fiji finland finnish france french \
        gabon gambia georgia georgian germany german ghana ghanaian greece greek grenada guatemala guinea guyana haiti haitian honduras hungary hungarian \
        iceland icelandic india indian indonesia indonesian iran iranian iraq iraqi ireland irish israel israeli italy italian jamaica jamaican japan \
        japanese jordan jordanian kazakhstan kazakh kenya kenyan kiribati korea korean kosovo kuwait kuwaiti kyrgyzstan laos latvia latvian lebanon \
        lebanese lesotho liberia libya libyan liechtenstein lithuania lithuanian luxembourg madagascar malawi malaysia malaysian maldives mali malta \
        maltese mauritania mauritius mexico mexican micronesia moldova moldovan monaco mongolia mongolian montenegro morocco moroccan mozambique myanmar \
        namibia nauru nepal nepalese netherlands dutch nicaragua niger nigeria nigerian norway norwegian oman pakistan pakistani palau palestine \
        palestinian panama paraguay peru peruvian philippines filipino poland polish portugal portuguese qatar romania romanian russia russian rwanda \
        samoa senegal serbia serbian seychelles singapore slovakia slovak slovenia slovenian somalia somali spain spanish sudan suriname sweden swedish \
        switzerland swiss syria syrian taiwan taiwanese tajikistan tanzania thailand thai togo tonga tunisia tunisian turkey turkish turkmenistan tuvalu \
        uganda ugandan ukraine ukrainian uruguay uzbekistan vanuatu venezuela venezuelan vietnam vietnamese yemen zambia zimbabwe english scottish welsh \
        kurdish kurd arab arabic european asian african american latin \
        africa asia europe antarctica oceania america
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init)).union([
        "united kingdom", "united states", "united states of america", "usa", "uk", "us", "new zealand", "south africa", "south korea", "north korea",
        "saudi arabia", "sri lanka", "costa rica", "el salvador", "sierra leone", "ivory coast", "czech republic", "dominican republic",
        "united arab emirates", "great britain", "northern ireland", "north america", "south america", "latin america", "central america",
        "middle east", "south african", "new zealander", "sri lankan", "saudi", "british isles", "soviet union", "ussr", "eu", "european union",
        "republic of turkey", "russian federation", "people's republic of china", "republic of ireland", "republic of poland",
    ])

    /// Whether a place is a country, a continent or the word for a people: in English, or a country in a language Scrub reads ("Algérie", "Alemania", "Litauen").
    static func isNation(_ value: String) -> Bool {
        let place = normalPlace(value)
        return nations.contains(place) || countriesAbroad.contains(place.folding(options: .diacriticInsensitive, locale: nil))
    }
    /// Every country's name in the languages Scrub reads, lowercase and without accents.
    private static let countriesAbroad: Set<String> = {
        let languages = ["fr", "es", "pt", "it", "de", "nl", "pl", "sv", "da", "nb", "fi", "cs", "sk", "ro", "hu", "tr", "id", "vi", "lt", "lv", "et", "hr", "sl", "sr-Latn", "sq", "ca", "el", "ru", "uk", "bg"]
        let codes = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        var names: Set<String> = []
        for language in languages {
            let locale = Locale(identifier: language)
            for code in codes {
                guard let name = locale.localizedString(forRegionCode: code) else { continue }
                names.insert(name.lowercased().folding(options: .diacriticInsensitive, locale: nil))
            }
        }
        return names
    }()

    private static func named(_ value: String) -> Bool {
        let common = ContextModel.shared?.common ?? []
        return value.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).contains { word in
            (word.first?.isUppercase == true || word.unicodeScalars.contains(where: ContextGate.isNonLatinLetter)) && !common.contains(word.lowercased())
        }
    }

    /// The sentence holding `range`: from the last full stop, line break or the like before it to the next after it.
    static func sentence(around range: Range<Int>, in text: String) -> (text: String, range: Range<Int>) {
        let ns = text as NSString
        var start = range.lowerBound, end = range.upperBound
        func boundary(_ unit: unichar) -> Bool { unit == 10 || unit == 13 || unit == 46 || unit == 33 || unit == 63 || unit == 59 }
        while start > 0, !boundary(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, !boundary(ns.character(at: end)) { end += 1 }
        return (ns.substring(with: NSRange(location: start, length: end - start)), start..<end)
    }

    /// Names in another script are read inside English text: the sentence
    /// around one is mostly Latin letters, not a whole sentence in that script.
    private static func mostlyLatin(around range: Range<Int>, in text: String) -> Bool {
        let around = sentence(around: range, in: text)
        let ns = text as NSString
        let before = ns.substring(with: NSRange(location: around.range.lowerBound, length: range.lowerBound - around.range.lowerBound))
        let after = ns.substring(with: NSRange(location: range.upperBound, length: around.range.upperBound - range.upperBound))
        let letters = (before + " " + after).unicodeScalars.filter(\.properties.isAlphabetic)
        let latin = letters.filter { $0.isASCII || !ContextGate.isNonLatinLetter($0) }.count
        return latin * 2 >= letters.count && latin > 0
    }

    private static let year = TextPattern(#"(?<!\d)(?:19|20)\d{2}(?!\d)"#)
    private static let link = TextPattern(#"(?i)\b[a-z][a-z0-9+.\-]*://[^\s<>"]+|\bwww\.[^\s<>"]+|(?<![\w&])#\w+"#)
    private static let money = TextPattern(#"(?i)(?:[$£€¥]|\b(?:usd|gbp|gpb|eur|pln|try|chf|cad|aud|inr|jpy)\b)\s?[\d.,]+[kmb]?\b|\b\d[\d.,]*\s?(?:k|m|bn|billion|million|thousand)\b|\b\d{1,3}(?:,\s?\d{3})+(?:\.\d+)?\b"#)
    static let fileExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "csv", "txt", "log", "json", "xml", "zip", "gz", "png", "jpg", "jpeg", "gif", "heic", "mov",
                                                      "mp4", "mpg", "mp3", "wav", "avi", "ppt", "pptx", "md", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "sh", "yml", "yaml", "toml", "css", "html", "exe", "dmg"]
    /// Links and hashtags in `text`, where the stage finds nothing.
    static func links(in text: String) -> [Range<Int>] {
        guard text.contains("://") || text.contains("www.") || text.contains("#") else { return [] }
        return TextRanges.matches(link, in: text).map { $0.range.location..<NSMaxRange($0.range) }
    }

    private static func amount(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        let start = max(0, range.lowerBound - 8), end = min(ns.length, range.upperBound + 12)
        let window = ns.substring(with: NSRange(location: start, length: end - start))
        return TextRanges.matches(money, in: window).contains { match in
            let found = (match.range.location + start)..<(NSMaxRange(match.range) + start)
            return found.overlaps(range)
        }
    }

    private static let owner = TextPattern(#"(?i)\b(?:record|member|patient|customer|client|account|acct|passport|licen[cs]e|ssn|sin|nhs|mrn|policy|tax|employee|staff|student|national|insurance|social security|benefits?|pension|voter|citizen|resident|applicant|claim(?:ant)?|caller|person|people|anonymi[sz]e|my|his|her|their)\b"#)
    private static let work = TextPattern(#"(?i)\b(?:work(?:s|ed|ing)?\s+(?:at|for)|job|employ\w*|manager|boss|colleague|payroll|redundan\w*|quit|shifts?|hired|intern\w*|trained|volunteer\w*|contract(?:ed|or)|ceo|cfo|cto|founder|director|officer|editor|staff|been with|started at|on the payroll|as an? [a-z]+)\b"#)
    /// An employer is personal only through its employee: the sentence it is in
    /// speaks of someone's work ("works at", "my manager at", "has been with",
    /// "Employer:"). "Tallowmere Holdings was formed out of a merger" is about the company alone.
    static func employment(around range: Range<Int>, in text: String) -> Bool {
        let around = sentence(around: range, in: text)
        let inside = (range.lowerBound - around.range.lowerBound)..<(range.upperBound - around.range.lowerBound)
        return TextRanges.matches(work, in: around.text).contains { !($0.range.location..<NSMaxRange($0.range)).overlaps(inside) }
    }

    /// Greek, Cyrillic, Hebrew, Arabic, Devanagari, Thai, kana, CJK and Hangul: the scripts it was trained to read names in.
    private static func isNonLatinNameScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0370...0x03FF, 0x0400...0x04FF, 0x0590...0x05FF, 0x0600...0x06FF, 0x0900...0x097F, 0x0E00...0x0E7F, 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF: true
        default: false
        }
    }

    /// Three words with letters, or a letter outside the Latin script.
    static func isFreeText(_ text: String) -> Bool {
        var words = 0, inWord = false, lettered = false
        for scalar in text.unicodeScalars {
            if ContextGate.isNonLatinLetter(scalar) { return true }
            if scalar.properties.isWhitespace {
                if inWord, lettered { words += 1; if words >= 3 { return true } }
                (inWord, lettered) = (false, false)
            } else {
                inWord = true
                if scalar.properties.isAlphabetic { lettered = true }
            }
        }
        return words + (inWord && lettered ? 1 : 0) >= 3
    }

    /// Cuts a long text into parts that tokenize as they would whole: after a
    /// line break, before a letter or digit, so no word, marker or quirk of
    /// the normaliser spans a cut.
    static func chunks(_ text: String, size: Int = 32_768) -> [Range<Int>] {
        let ns = text as NSString
        guard ns.length > size * 2 else { return [0..<ns.length] }
        var result: [Range<Int>] = [], start = 0, index = size
        while index < ns.length {
            let unit = ns.character(at: index)
            if ns.character(at: index - 1) == 10, unit < 128, (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) {
                result.append(start..<index)
                start = index
                index += size
            } else {
                index += 1
            }
        }
        result.append(start..<ns.length)
        return result
    }

    /// `body` for each index on every core, while the calling thread reports
    /// progress and watches for cancellation; throws once cancelled.
    static func parallel(_ count: Int, cancelled: CancellationFlag, progress: () -> Void = {}, _ body: @escaping @Sendable (Int) -> Void) throws {
        guard count > 0 else { return }
        let finished = DispatchGroup()
        finished.enter()
        Work.queue.async {
            DispatchQueue.concurrentPerform(iterations: count) { index in
                if !cancelled.isSet { body(index) }
            }
            finished.leave()
        }
        while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if Task.isCancelled { cancelled.set() }
            progress()
        }
        if Task.isCancelled { cancelled.set() }
        try Scrubber.checkCancellation()
    }
}

/// Picks the sentences worth the model's time in a long document: those with
/// a letter outside the Latin script, a word about work, an ID-, secret- or
/// handle-shaped token, a capitalised word no dictionary has, or a cue for a
/// birth date, secret or handle. A sentence with none of these holds nothing
/// the model was trained to find.
enum ContextGate {
    static func picks(_ text: String, model: ContextModel) -> [Range<Int>] {
        let ns = text as NSString
        return sentences(text).filter { trigger(ns.substring(with: NSRange(location: $0.lowerBound, length: $0.count)), model: model) != nil }
    }

    private static let line = TextPattern(#"[^\n]+"#)
    private static let cut = TextPattern(#"(?<=[.!?])\s+(?=["'(\[]?[A-ZЀ-ӿ])"#)
    private static let abbreviation = TextPattern(#"(?:\b[A-Za-z]\.){2,}$|\b(?:Mr|Mrs|Ms|Dr|St|No|Inc|Ltd|Co|vs|etc|approx|dept|Jr|Sr)\.$"#)

    /// Lines, split again after a full stop, question or exclamation mark
    /// before a capital, but not after an abbreviation (D.O.B., P.O., Dr.).
    static func sentences(_ text: String) -> [Range<Int>] {
        let ns = text as NSString
        var result: [Range<Int>] = []
        for match in TextRanges.matches(line, in: text) {
            let lineText = ns.substring(with: match.range) as NSString
            var start = match.range.location
            for split in TextRanges.matches(cut, in: lineText as String) {
                let before = lineText.substring(to: split.range.location)
                if !TextRanges.matches(abbreviation, in: before).isEmpty { continue }
                if match.range.location + split.range.location > start { result.append(start..<(match.range.location + split.range.location)) }
                start = match.range.location + NSMaxRange(split.range)
            }
            if start < NSMaxRange(match.range) { result.append(start..<NSMaxRange(match.range)) }
        }
        return result.filter { !ns.substring(with: NSRange(location: $0.lowerBound, length: $0.count)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static let employer = TextPattern(#"\b(?:works?|worked|working|employed|teach(?:es|ing)?|taught|interns?|volunteers?|job|shifts?|nights|days|manager|boss|nurse|engineer|cashier|driver|joined|started|hired|placement|contract(?:ed|or)?)\s+(?:\w+\s+)?(?:at|for|by|with)\b|\bemployer\b|\bemployed\b"#, options: [.caseInsensitive])
    private static let handleCue = TextPattern(#"\b(?:user(?:name)?|handle|gamertag|ig|insta(?:gram)?|twitter|tiktok|discord|github|gitlab|slack|telegram|snap(?:chat)?|reddit|login|alias|nick(?:name)?|dm|ping|cc|ask|from|by|author|to|with)\b(?=(?:\s+(?:is|was|are))?\W{0,3}\s*([a-z][\w.-]*))"#, options: [.caseInsensitive])
    private static let secretCue = TextPattern(#"\b(?:pass(?:word|wd|code|phrase)?|pwd|pin|key|token|secret|code|combination)\b"#, options: [.caseInsensitive])
    private static let digitTail = TextPattern(#"^[A-Za-z][a-z]{1,15}\d{1,4}$"#)
    private static let secretShape = TextPattern(#"^(?=.*[A-Za-z])(?=.*\d)(?:(?=.*[!@#$%^&*+?~])|(?=.*[a-z])(?=.*[A-Z])).{6,}$"#)
    // Capitals and lowercase of any script: "Łódź" is as much a town as "Delft".
    private static let placeCue = TextPattern(#"\b(?:in|at|from|to|near|outside|into|around|of|for|the|via)\s+(?:the\s+)?(\p{Lu}[\p{Ll}'’]+)"#)
    private static let dobCue = TextPattern(#"\b(?:born|dob|d\.o\.b|birth(?:day|date)?)\b|\bb\.\s*\d{4}\b"#, options: [.caseInsensitive])
    private static let dateTime = TextPattern(#"^(?:\d{4}-\d\d-\d\d(?:[T ]\d\d:\d\d(?::\d\d(?:\.\d+)?)?Z?)?|\d\d?:\d\d(?::\d\d)?|\d{1,5}(?:\.\d+)?(?:ms|s|m|h|kb|mb|gb|KB|MB|GB|%)|v?\d+(?:\.\d+){1,3}|(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?)$"#)
    private static let grouped = TextPattern(#"(?<![\w.])\d{2,4}(?:[ .\-/]\d{2,4}){2,}(?![\w])"#)
    private static let capitalRun = TextPattern(#"\b\p{Lu}[\p{Ll}'’]+(?:[ \-](?:of |de |la |van |von )?\p{Lu}[\p{Ll}'’]+)+"#)
    private static let nameShape = TextPattern(#"^\p{Lu}[\p{Ll}'’]+(?:-\p{Lu}?[\p{Ll}'’]+)*$"#)
    private static let token = TextPattern(#"[^\s,;()\[\]{}<>"'`|=/]+(?:==?(?![\w]))?"#)
    private static let home = TextPattern(#"/(?:home|Users|users)/[^/\s]*[A-Za-z][^/\s]*"#)
    private static let port = TextPattern(#":\d{2,5}$"#)
    private static let hexOnly = TextPattern(#"^[0-9a-f]+$"#)
    private static let lettersJoined = TextPattern(#"[A-Za-z][._][A-Za-z]"#)
    private static let camel = TextPattern(#"[a-z][A-Z]"#)
    private static let parts = TextPattern(#"[A-Z]+[a-z]*|[a-z]+|\d+"#)
    private static let afterCue = TextPattern(#"^\s*(?:'s|’s|is|was|:|=|to)\s*\S"#)
    private static let digitSoon = TextPattern(#"^\W{0,3}\s*(?:\S+\s+){0,2}\S*\d"#)
    private static let nextWord = TextPattern(#"^\W{0,3}\s*([^\s.,;]+)"#)
    private static let extensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "csv", "txt", "log", "json", "xml", "zip", "gz", "tar", "png", "jpg", "jpeg", "heic", "mov",
                                                  "mp4", "app", "conf", "cfg", "plist", "md", "py", "js", "ts", "swift", "git", "com", "org", "net", "io", "test", "local", "internal"]

    private static func matches(_ pattern: TextPattern, _ text: String) -> Bool { !TextRanges.matches(pattern, in: text).isEmpty }

    static func isNonLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value > 127, scalar.properties.isAlphabetic, [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter].contains(scalar.properties.generalCategory) else { return false }
        return scalar.properties.name.map { !$0.hasPrefix("LATIN") } ?? false
    }

    /// Why the model should read `sentence`, or nil.
    static func trigger(_ sentence: String, model: ContextModel) -> String? {
        let ns = sentence as NSString
        if sentence.unicodeScalars.contains(where: isNonLatinLetter) { return "nonlatin" }
        if matches(employer, sentence) { return "employer" }
        if matches(home, sentence) { return "handle" }
        for match in TextRanges.matches(grouped, in: sentence) {
            let value = ns.substring(with: match.range)
            if value.filter(\.isNumber).count >= 6, !matches(dateTime, value) { return "id" }
        }
        for match in TextRanges.matches(placeCue, in: sentence) where !model.common.contains(ns.substring(with: match.range(at: 1)).lowercased()) { return "capital" }
        for match in TextRanges.matches(capitalRun, in: sentence) {
            let words = ns.substring(with: match.range).split(whereSeparator: { $0 == " " || $0 == "-" })
            if words.contains(where: { $0.first?.isUppercase == true && !model.common.contains($0.lowercased()) }) { return "capital" }
        }
        for match in TextRanges.matches(token, in: sentence) {
            let end = NSMaxRange(match.range)
            var word = ns.substring(with: match.range)
            while let last = word.last, ".,!?:".contains(last) { word.removeLast() }
            guard !word.isEmpty else { continue }
            // A key in key=value.
            if end < ns.length, ns.character(at: end) == 61, end + 1 < ns.length, ns.character(at: end + 1) != 61 { continue }
            if idShape(word) { return "id" }
            if matches(secretShape, word.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))) || randomLetters(word, model: model), !word.hasPrefix("-") { return "secret" }
            if matches(digitTail, word), let tail = word.range(of: #"\d+$"#, options: .regularExpression),
               word.distance(from: tail.lowerBound, to: tail.upperBound) >= 2 || !known(String(word[..<tail.lowerBound]), model: model) { return "handle" }
            if handleShape(word, model: model) { return "handle" }
            if unknownCapital(word, model: model) { return "capital" }
        }
        if matches(dobCue, sentence), sentence.contains(where: \.isNumber) { return "dob" }
        for match in TextRanges.matches(secretCue, in: sentence) {
            let end = NSMaxRange(match.range)
            let after = ns.substring(with: NSRange(location: end, length: min(40, ns.length - end)))
            if matches(afterCue, after) || matches(digitSoon, after) { return "secret" }
            if let next = TextRanges.matches(nextWord, in: after).first {
                let word = (after as NSString).substring(with: next.range(at: 1))
                if word.contains(where: \.isLetter), !known(word.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")), model: model) { return "secret" }
            }
        }
        // A cue word, then a lowercase word no dictionary has: "user tdlamini", "ping redwisil".
        for match in TextRanges.matches(handleCue, in: sentence) where match.range(at: 1).location != NSNotFound {
            let word = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            if word.count >= 4, !known(word, model: model), !word.allSatisfy(\.isNumber) { return "handlecue" }
        }
        return nil
    }

    private static let endings: [(String, String)] = [("s", ""), ("es", ""), ("ed", ""), ("ed", "e"), ("d", ""), ("ing", ""), ("ing", "e"), ("ies", "y"), ("ied", "y"),
                                                      ("er", ""), ("ers", ""), ("ly", ""), ("'s", ""), ("’s", "")]

    /// An ordinary word, inflected or not: escalated, prefers, renewals.
    static func known(_ word: String, model: ContextModel) -> Bool {
        let lower = word.lowercased()
        if model.dictionary.contains(lower) || model.common.contains(lower) { return true }
        for (end, add) in endings where lower.hasSuffix(end) && lower.count - end.count >= 3 {
            let stem = String(lower.dropLast(end.count)) + add
            if model.dictionary.contains(stem) || model.common.contains(stem) { return true }
        }
        return false
    }

    /// Digit-only IDs of seven digits or more; mixed ones with four digits, or
    /// long, or with a symbol. Not a date, time, duration, version, address or hash.
    static func idShape(_ word: String) -> Bool {
        var stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: ".-#*:"))
        if let match = TextRanges.matches(port, in: stripped).first { stripped = (stripped as NSString).substring(to: match.range.location) }
        guard !stripped.isEmpty, !word.hasPrefix("-"), !matches(dateTime, stripped) else { return false }
        let digits = stripped.filter(\.isNumber).count, letters = stripped.filter(\.isLetter).count
        if letters > 0, digits > 0, matches(hexOnly, stripped) { return false }
        guard letters > 0 else { return digits >= 7 }
        return digits >= 4 || digits >= 2 && stripped.count >= 12 || digits >= 2 && stripped.count >= 5 && stripped.contains(where: "!@#$%^&*+".contains)
    }

    /// Letters joined by a dot or underscore with a part no dictionary has
    /// (f.herrera, x_akosua_x), or @name; not code (user.isActive) or a config key (bind_address).
    static func handleShape(_ word: String, model: ContextModel) -> Bool {
        let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        if word.hasPrefix("@"), stripped.count > 3 { return true }
        let lettersCased = stripped.contains(where: { $0.isUppercase || $0.isLowercase })
        if ["e.g", "i.e", "etc", "vs"].contains(stripped.lowercased()) || lettersCased && !stripped.contains(where: \.isLowercase) { return false }
        guard matches(lettersJoined, stripped), stripped.contains(where: \.isLowercase), !matches(camel, stripped) else { return false }
        var pieces = stripped.split(whereSeparator: { "._-".contains($0) }).map(String.init).filter { !$0.allSatisfy(\.isNumber) }
        if let last = pieces.last, extensions.contains(last.lowercased()) { pieces.removeLast() }
        return pieces.contains { piece in
            let uncommon = !model.common.contains(piece.lowercased())
            return piece.count == 1 || uncommon && !known(piece, model: model) || uncommon && pieces.count == 2 && piece == piece.lowercased()
        }
    }

    /// A run of letters in both cases that splits into no words: UHcYVBCTKacnq.
    static func randomLetters(_ word: String, model: ContextModel) -> Bool {
        let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: "!?.,"))
        guard stripped.count >= 8, stripped.filter(\.isUppercase).count >= 3, stripped.contains(where: \.isLowercase) else { return false }
        let found = TextRanges.matches(parts, in: stripped).map { (stripped as NSString).substring(with: $0.range) }
        let unknown = found.filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) && !known($0, model: model) }.count
        let short = found.filter { $0.count <= 2 && $0.allSatisfy(\.isLetter) }.count
        return unknown + short >= 2
    }

    /// A name-shaped capitalised word no dictionary has.
    static func unknownCapital(_ word: String, model: ContextModel) -> Bool {
        var core = word.trimmingCharacters(in: CharacterSet(charactersIn: "'’."))
        if let quote = core.firstIndex(where: { $0 == "'" || $0 == "’" }) { core = String(core[..<quote]) }
        return core.count >= 3 && matches(nameShape, core) && !core.split(separator: "-").allSatisfy { known(String($0), model: model) }
    }
}

/// Where a scrub's parallel work starts. The calling thread waits for it, and
/// that thread may be one of Swift concurrency's, which share the global
/// concurrent queues' few threads (one per core): with as many scrubs at once
/// as cores, work sent there would never start. A serial queue of its own
/// gets a thread of its own, and `concurrentPerform` runs on it whatever else is busy.
enum Work {
    static var queue: DispatchQueue { DispatchQueue(label: "Scrub.work", qos: .userInitiated) }
}
