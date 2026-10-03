import Foundation

/// The text as a reader sees it. Characters no one sees (a zero-width space
/// or joiner, a soft hyphen, a byte-order mark) and markup that splits a word
/// ("Odal**ys", "Odal</b>ys") hide a value from detectors that read
/// characters, though not from a person or an AI tool that reads the text.
/// Detection reads the visible text; replacement maps each finding back onto
/// the text as written, drops the hidden characters inside it, and keeps the
/// markup, so "<b>Odal</b>ys" becomes "<b>Maren</b>" and stays valid.
struct Visible {
    let clean: String
    /// For each UTF-16 unit of `clean`, its offset in the text as written.
    private let toRaw: [Int]
    /// For each UTF-16 unit of the text as written, its offset in `clean` (a hidden one: the next visible unit's).
    private let toClean: [Int]
    private let rawLength: Int

    /// Unseen characters: zero-width space, non-joiner and joiner, word joiner, byte-order mark, soft hyphen.
    static let hidden: Set<UInt16> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD]
    private static let nbsp: UInt16 = 0x00A0
    /// Formatting against a word: emphasis asterisks and strike-through
    /// touching a letter ("*Odalys*", "Odal**ys"), never a digit ("****1234"
    /// is a mask), and inline tags touching one ("<b>Odal</b>ys").
    private static let markup = TextPattern(
        #"(?<=[\p{L}])(?:\*{1,3}|~~)(?![\p{N}*~])|(?<![\p{N}*~])(?:\*{1,3}|~~)(?=[\p{L}])"#
        + #"|(?<=[\p{L}])</?(?:b|i|u|s|em|strong|mark|span|small|sup|sub|del|ins|font|code)(?:\s[^<>]{0,80})?>|</?(?:b|i|u|s|em|strong|mark|span|small|sup|sub|del|ins|font|code)(?:\s[^<>]{0,80})?>(?=[\p{L}])"#,
        options: [.caseInsensitive])

    /// The visible text of `text`, or nil when it is all visible already.
    init?(_ text: String) {
        // Most text has nothing hidden and no markup against a word: one pass, no copy.
        var hasHidden = false, hasMarkup = false
        var previous: UInt16 = 32
        for unit in text.utf16 {
            if unit == 0x00A0 || unit == 0x200B || unit == 0x200C || unit == 0x200D || unit == 0x2060 || unit == 0xFEFF || unit == 0x00AD { hasHidden = true }
            // Markup that may touch a word: a mark or a tag after a letter, or before one (checked below).
            if (unit == 42 || unit == 126 || unit == 60) && !hasMarkup { hasMarkup = true }
            if (previous == 42 || previous == 126 || previous == 62) && Self.isLetter(unit) { hasMarkup = true }
            previous = unit
        }
        guard hasHidden || hasMarkup else { return nil }
        let units = Array(text.utf16)
        var removed = [Bool](repeating: false, count: units.count)
        for (index, unit) in units.enumerated() where Self.hidden.contains(unit) { removed[index] = true }
        if hasMarkup {
            for match in Self.markupMatches(text, units) {
                for index in match.location..<NSMaxRange(match) { removed[index] = true }
            }
        }
        guard removed.contains(true) || units.contains(Self.nbsp) else { return nil }
        var cleanUnits: [UInt16] = [], toRaw: [Int] = [], toClean: [Int] = []
        cleanUnits.reserveCapacity(units.count)
        for (index, unit) in units.enumerated() {
            toClean.append(cleanUnits.count)
            guard !removed[index] else { continue }
            // A no-break space reads as a space.
            cleanUnits.append(unit == Self.nbsp ? 32 : unit)
            toRaw.append(index)
        }
        toClean.append(cleanUnits.count)
        clean = String(decoding: cleanUnits, as: UTF16.self)
        self.toRaw = toRaw
        self.toClean = toClean
        rawLength = units.count
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit > 127 && Unicode.Scalar(unit).map(CharacterSet.letters.contains) == true
    }

    /// The pattern's matches, the same as a scan of the whole text finds,
    /// read only around marks and tags that touch a letter: the pattern's
    /// matches start at a mark or a tag and run at most 90 units, and the
    /// look-behind runs against the text around each window.
    private static func markupMatches(_ text: String, _ units: [UInt16]) -> [NSRange] {
        guard let regex = markup.regex else { return [] }
        var windows: [NSRange] = []
        for (index, unit) in units.enumerated() where unit == 42 || unit == 126 || unit == 60 {
            // A mark or tag touching a letter: before it, or after the run of marks or the tag's end.
            var end = index
            while end < units.count, units[end] == unit, unit != 60 { end += 1 }
            if unit == 60 { end = units[index..<min(units.count, index + 96)].firstIndex(of: 62).map { $0 + 1 } ?? index + 1 }
            let touches = index > 0 && isLetter(units[index - 1]) || end < units.count && isLetter(units[end])
            guard touches else { continue }
            let window = NSRange(location: index, length: min(units.count, index + 100) - index)
            if let last = windows.last, NSMaxRange(last) >= window.location { windows[windows.count - 1] = NSUnionRange(last, window) } else { windows.append(window) }
        }
        var found: [NSRange] = []
        for window in windows {
            for match in regex.matches(in: text, options: [.withTransparentBounds], range: window) where found.last.map({ NSMaxRange($0) <= match.range.location }) ?? true {
                found.append(match.range)
            }
        }
        return found
    }

    /// A range of `clean` in the text as written, spanning what is hidden inside it.
    func raw(_ range: Range<Int>) -> Range<Int> {
        guard !range.isEmpty, range.upperBound <= toRaw.count else {
            let at = range.lowerBound < toRaw.count ? toRaw[range.lowerBound] : rawLength
            return at..<at
        }
        return toRaw[range.lowerBound]..<(toRaw[range.upperBound - 1] + 1)
    }

    /// A range of the text as written in `clean`.
    func clean(_ range: Range<Int>) -> Range<Int> {
        let lower = toClean[min(range.lowerBound, rawLength)], upper = toClean[min(range.upperBound, rawLength)]
        return lower..<max(lower, upper)
    }

    func raw(_ span: Span) -> Span { Span(range: raw(span.range), entity: span.entity, score: span.score, url: span.url) }
    func clean(_ mark: Mark) -> Mark { mark.moved(to: clean(mark.range)) }

    /// What a piece of text reads as: its hidden characters and in-word markup gone, a no-break space a space.
    static func plain(_ text: String) -> String { Visible(text)?.clean ?? text }

    /// `standIn` written where `raw` stood: the hidden characters dropped and
    /// the markup kept around the words it marked. Word for word where both
    /// have as many ("*Ingvar* **Peltomaa**" → "*Maren* **Holt**"); otherwise
    /// the markup inside after it, so "Odal</b>ys" becomes "Maren</b>".
    static func rewrite(_ raw: String, with standIn: String) -> String {
        guard raw.utf16.contains(where: { hidden.contains($0) || $0 == nbsp || $0 == 42 || $0 == 126 || $0 == 60 }) else { return standIn }
        let rawWords = raw.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).map(String.init)
        let fakeWords = standIn.split(separator: " ").map(String.init)
        if rawWords.count > 1, rawWords.count == fakeWords.count {
            return zip(rawWords, fakeWords).map { piece($0, with: $1) }.joined(separator: " ")
        }
        return piece(raw, with: standIn)
    }

    /// One word's stand-in with the word's markup: what opens it before, the rest after.
    private static func piece(_ raw: String, with standIn: String) -> String {
        let ns = raw as NSString
        var first = 0
        while first < ns.length, let scalar = Unicode.Scalar(ns.character(at: first)), !CharacterSet.alphanumerics.contains(scalar) { first += 1 }
        var lead = "", trail = ""
        for match in TextRanges.matches(markup, in: raw) {
            let text = ns.substring(with: match.range)
            if match.range.location < first { lead += text } else { trail += text }
        }
        return lead + standIn + trail
    }
}
