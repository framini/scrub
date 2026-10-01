import Foundation
import Synchronization

/// Runs the context model over a document's free text: every value of three
/// words or more, or with letters outside the Latin script. Its windows are
/// spread over every core, report progress as `.reading`, and stop between
/// windows once cancelled. Above `gateFrom` UTF-16 units of free text, a
/// window is read only if a sentence in it has something the model could find
/// (see `ContextGate`); below it the model reads everything.
enum ContextStage {
    /// Its findings score below every other detector's, the name model's included.
    static let score = 0.5
    /// The gate misses a few findings reading everything catches, so it waits
    /// for documents where reading everything costs minutes: the model adds
    /// about 20 seconds a megabyte of prose on an M1 Max, the rest of a scrub
    /// several times that.
    static let gateFrom = Atomic<Int>(10_000_000)
    /// The most a non-Latin name's pieces may lean to no label. Every non-Latin
    /// name in the held-out generated set stays under 0.0026.
    static let nonLatinDoubt: Float = 0.004
    /// Off only in tests that measure Scrub without the model.
    static let enabled = Atomic(true)

    /// The model's findings for each text, nil where it read nothing.
    static func find(_ texts: [String?], progress: (Stage, Int, Int) -> Void, cancelled: CancellationFlag) throws -> [[Span]?] {
        guard enabled.load(ordering: .relaxed), let model = ContextModel.shared else { return texts.map { _ in nil } }
        let readable = texts.indices.filter { texts[$0].map(isFreeText) == true }
        guard !readable.isEmpty else { return texts.map { _ in nil } }
        let gated = readable.reduce(0) { $0 + (texts[$1]! as NSString).length } >= gateFrom.load(ordering: .relaxed)

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

        // Windows, longest first so the last ones to finish are short.
        let jobs = leaves.indices.flatMap { item in leaves[item].windows.indices.filter { leaves[item].read[$0] }.map { (item, $0) } }
            .sorted { leaves[$0.0].windows[$0.1].ids.count > leaves[$1.0].windows[$1.1].ids.count }
        let ids = leaves.map { $0.windows.map(\.ids) }
        let predictions = Mutex([[[ContextModel.Decision]?]](leaves.map { [[ContextModel.Decision]?](repeating: nil, count: $0.windows.count) }))
        let done = Atomic(0)
        try parallel(jobs.count, cancelled: cancelled, progress: { progress(.reading, done.load(ordering: .relaxed), jobs.count) }) { index in
            let (item, window) = jobs[index]
            let labels = model.decide(model.logits(ids[item][window]))
            predictions.withLock { $0[item][window] = labels }
            done.add(1, ordering: .relaxed)
        }
        progress(.reading, jobs.count, jobs.count)

        var result = texts.map { _ -> [Span]? in nil }
        let read = predictions.withLock { $0 }
        for (item, leaf) in leaves.enumerated() {
            let text = texts[leaf.leaf]!
            let labels = model.labelled(leaf.pieces, windows: leaf.windows, predictions: read[item])
            let links = links(in: text)
            result[leaf.leaf] = model.spans(leaf.pieces, labels: labels, in: text).compactMap { span($0, in: text, links: links) }
        }
        return result
    }

    /// A finding as Scrub names it, or nil for one the stage leaves to others:
    /// a person in Latin script is the name model's and the tagger's to find,
    /// and a handle needs a digit, dot or underscore to be told from a word.
    static func span(_ found: ContextModel.Found, in text: String, links: [Range<Int>] = []) -> Span? {
        let ns = text as NSString
        // Punctuation at either end belongs to the sentence ("(1-800…", "ICYMI-").
        var range = found.range
        while range.count > 0, edges.contains(Character(Unicode.Scalar(ns.character(at: range.lowerBound)) ?? " ")) { range = (range.lowerBound + 1)..<range.upperBound }
        while range.count > 0, edges.contains(Character(Unicode.Scalar(ns.character(at: range.upperBound - 1)) ?? " ")) { range = range.lowerBound..<(range.upperBound - 1) }
        guard !range.isEmpty else { return nil }
        let value = TextRanges.substring(text, range)
        // A link's path and a hashtag are written for everyone to read: "t.co/8X9QR2r7zz" is no ID.
        if links.contains(where: { $0.overlaps(range) }) { return nil }
        // A piece of a word ("Down" of "Downtown") or a run over a line break is a guess, not a finding.
        if value.contains(where: \.isNewline) || TextRanges.joinsWord(ns, at: range.lowerBound, underscore: true) && joined(ns, range.lowerBound)
            || TextRanges.joinsWord(ns, at: range.upperBound, underscore: true) && joined(ns, range.upperBound - 1)
            || hyphened(ns, before: range.lowerBound) || hyphened(ns, after: range.upperBound) { return nil }
        let digits = value.filter(\.isNumber).count
        // A secret, ID or handle is a whole token: the model reading the first
        // letters of "Qz7nwsgydtlekmwf&<\"'\\" would leave the rest behind.
        if ["SECRET", "ID", "USERNAME"].contains(found.kind), !wholeToken(ns, range) { return nil }
        // An object's ID ("cus_4TUvJhQkMeNW3tprfQ6G", "pm_9mzWb…") is a reference, not a secret,
        // unless the sentence calls it a key or token.
        if ["SECRET", "ID"].contains(found.kind), !TextRanges.matches(objectID, in: value).isEmpty,
           TextRanges.matches(secretWord, in: sentence(around: range, in: text).text).isEmpty { return nil }
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
            entity = "USERNAME"
        case "LOCATION":
            guard named(value) else { return nil }
            entity = "LOCATION"
        case "ORG":
            guard named(value), employment(around: range, in: text) else { return nil }
            entity = "EMPLOYER"
        case "ID":
            // An amount, a count or a short reference ("deal #268093", "Law no. 3713",
            // "GBP 2,092,569") is no one's ID.
            guard digits >= 4, !amount(range, in: text), TextRanges.matches(decimal, in: value).isEmpty else { return nil }
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

    private static let objectID = TextPattern(#"^[a-z]{2,8}_[A-Za-z0-9]{8,}$"#)
    private static let secretWord = TextPattern(#"(?i)(?:pass(?:word|wd|code|phrase)?|pwd|secret|token|key|credential|auth|bearer)"#)
    private static let decimal = TextPattern(#"^[-+]?\d+[.,]\d{1,2}$"#)
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
    private static let fileExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "csv", "txt", "log", "json", "xml", "zip", "gz", "png", "jpg", "jpeg", "gif", "heic", "mov",
                                                      "mp4", "mpg", "mp3", "wav", "avi", "ppt", "pptx", "md", "py", "js", "swift", "html", "exe", "dmg"]
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
        DispatchQueue.global(qos: .userInitiated).async {
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
