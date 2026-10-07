import Foundation

/// One person written in pieces that readers found apart: a given name and a
/// surname with an initial between them ("Dirk M Sinkel"), a nickname in
/// quotes ("Matt 'the doctor' Smith", "Robert \"Bobby\" Tables"), a surname's
/// particles ("Pieter van der Berg", "Rania El-Sayed"), a name joined by a
/// hyphen ("Mary-Kate O'Neil"), or a surname before a suffix ("Martin Luther
/// King Jr."). Replaced in pieces, a part no reader took stays, and the
/// surname takes a given name's stand-in; joined, the person is replaced
/// whole, and a doubted piece is as sure as the name it is part of.
enum JoinedNames {
    /// What may stand between two pieces of one name on one line: a space, initials, a
    /// nickname in quotes, a surname's particles, or a hyphen.
    private static let bridge = TextPattern(#"^(?: | (?:\p{Lu}\.? ){1,2}| ["“'‘][^"“”'‘’\n]{1,24}["”'’] | (?:(?i:van|von|der|den|de|del|della|di|da|du|dos|das|la|le|ten|ter|bin|ibn|binti|al|el|abu|ben) ){1,3}| (?i:al|el)[-‐]|[-‐])$"#)
    /// A nickname in quotes after a name, then the surname it is written before.
    private static let nicknameAfter = TextPattern(#"^[ \t]+["“'‘][^"“”'‘’\n]{1,24}["”'’][ \t]+(\p{Lu}[\p{L}'’-]*\p{L})"#)
    /// A given name, a nickname in quotes and a surname, all capitalised.
    private static let nicknameBetween = TextPattern(#"^\p{Lu}[\p{L}'’-]* ["“'‘][^"“”'‘’\n]{1,24}["”'’] \p{Lu}[\p{L}'’-]*$"#)
    /// A given name, then a nickname in quotes, before a name.
    private static let nicknameBefore = TextPattern(#"(?<![\p{L}\p{N}'’.@/_-])(\p{Lu}[\p{L}'’-]*\p{L})[ \t]+["“'‘][^"“”'‘’\n]{1,24}["”'’][ \t]+$"#)
    /// A given name and initials before a surname: "Dirk M ", "Kwame A. ".
    private static let initialsBefore = TextPattern(#"(?<![\p{L}\p{N}'’.@/_-])(\p{Lu}\p{Ll}+)[ \t]+(?:\p{Lu}\.?[ \t]+){1,2}$"#)
    /// A given name before a surname that opens with its particle: "Pieter " before "van der Berg".
    private static let givenBefore = TextPattern(#"(?<![\p{L}\p{N}'’.@/_-])(\p{Lu}\p{Ll}+)[ \t]+$"#)
    /// Capitalised words between a name and its suffix: " King" of "Martin Luther King Jr.".
    private static let beforeSuffix = TextPattern(#"^((?:[ \t]+\p{Lu}\p{Ll}+){1,2})(?=,?[ \t]+(?:Jr|Sr|II|III|IV)\b)"#)
    /// A lowercase given name before a lowercase surname: "diego " before "maradona".
    private static let lowerBefore = TextPattern(#"(?<![\p{L}\p{N}'’.@/_-])(\p{Ll}+)[ \t]+$"#)
    static let particles: Set<String> = ["van", "von", "der", "den", "de", "del", "della", "di", "da", "du", "dos", "das", "la", "le", "ten", "ter", "bin", "ibn", "binti", "al", "el", "abu", "ben"]

    private struct Piece {
        var range: Range<Int>
        var sure: Bool
        var score: Double
        /// A place the tagger read that is also a given name ("Rania"): one only beside another piece.
        var place: Bool
        let span: Span
    }

    /// `kept` and `doubts` with the pieces of each person joined; a doubted
    /// piece joined to a found one is found.
    static func joined(_ kept: [Span], _ doubts: [Span], in text: String) -> (kept: [Span], doubts: [Span]) {
        let ns = text as NSString
        func word(_ range: Range<Int>) -> String { ns.substring(with: NSRange(location: range.lowerBound, length: range.count)) }
        var pieces: [Piece] = []
        var others: [Span] = [], otherDoubts: [Span] = []
        for span in kept {
            if span.entity == "PERSON", span.url == nil { pieces.append(Piece(range: span.range, sure: true, score: span.score, place: false, span: span)) }
            else if span.entity == "LOCATION", case let value = word(span.range), !value.contains(" "), NameLists.isFirst(value), !NameLists.isOrdinary(value) {
                pieces.append(Piece(range: span.range, sure: true, score: span.score, place: true, span: span))
                others.append(span)
            } else { others.append(span) }
        }
        for doubt in doubts {
            if doubt.entity == "PERSON" { pieces.append(Piece(range: doubt.range, sure: false, score: doubt.score, place: false, span: doubt)) } else { otherDoubts.append(doubt) }
        }
        guard !pieces.isEmpty else { return (kept, doubts) }
        pieces.sort { $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound > $1.range.upperBound }
        // Pieces side by side on one line, with what may stand inside a name between them.
        // Pieces that overlap are left as they were read, for the findings' own order to settle.
        var groups: [[Piece]] = [], tangled: Set<Int> = []
        for piece in pieces {
            if var last = groups.last, let end = last.map(\.range.upperBound).max() {
                if piece.range.lowerBound < end {
                    last.append(piece); groups[groups.count - 1] = last; tangled.insert(groups.count - 1); continue
                }
                let gap = word(end..<piece.range.lowerBound)
                if !TextRanges.matches(bridge, in: gap).isEmpty {
                    last.append(piece); groups[groups.count - 1] = last; continue
                }
            }
            groups.append([piece])
        }
        var people: [Span] = [], doubted: [Span] = []
        var joinedPlaces: [Range<Int>] = []
        for (index, group) in groups.enumerated() {
            if tangled.contains(index) {
                for piece in group where !piece.place {
                    let span = Span(range: unsuffixed(piece.range, in: text), entity: piece.span.entity, score: piece.span.score)
                    if piece.sure { people.append(span) } else { doubted.append(span) }
                }
                continue
            }
            // A place alone stays a place.
            if group.allSatisfy(\.place) { continue }
            if group.count > 1 { joinedPlaces += group.filter(\.place).map(\.range) }
            let joined = group.map(\.range.lowerBound).min()!..<group.map(\.range.upperBound).max()!
            let (range, nicknamed) = grown(joined, in: text)
            // A nickname in quotes between a given name and a surname writes a person, whatever any model doubts.
            let sure = group.contains(where: \.sure) || nicknamed || TextRanges.matches(nicknameBetween, in: word(joined)).count > 0
            let score = group.filter { $0.sure == sure }.map(\.score).max() ?? 0
            if sure { people.append(Span(range: range, entity: "PERSON", score: score)) } else { doubted.append(Span(range: range, entity: "PERSON", score: score)) }
        }
        others.removeAll { span in span.entity == "LOCATION" && joinedPlaces.contains(span.range) }
        // A finding of another kind inside a joined person ("Mary" read as a place) gives way to it.
        others.removeAll { span in span.entity == "LOCATION" && people.contains { $0.range.lowerBound <= span.range.lowerBound && span.range.upperBound <= $0.range.upperBound && $0.range != span.range } }
        let all = (others + people).sorted { $0.range.lowerBound < $1.range.lowerBound }
        return (all, (otherDoubts + doubted).sorted { $0.range.lowerBound < $1.range.lowerBound })
    }

    /// A person's range taking in the words of their name no reader took:
    /// the surname after a nickname, the given name before one or before
    /// initials, the given name before a surname that opens with its
    /// particle, the surname before a suffix, and a lowercase given name
    /// before a lowercase surname.
    /// `nicknamed`: it took in a nickname in quotes.
    static func grown(_ range: Range<Int>, in text: String) -> (range: Range<Int>, nicknamed: Bool) {
        let ns = text as NSString
        var lower = range.lowerBound, upper = range.upperBound, nicknamed = false
        let value = ns.substring(with: NSRange(location: lower, length: upper - lower))
        let head = max(0, lower - 48)
        let before = ns.substring(with: NSRange(location: head, length: lower - head))
        let after = ns.substring(with: NSRange(location: upper, length: min(48, ns.length - upper)))
        func given(_ word: String) -> Bool {
            let bare = word.lowercased()
            return !People.isTitle(word) && !NameShape.isRole(word) && !NameShape.joining.contains(bare) && !NameShape.parties.contains(bare)
                && !NameShape.commands.contains(bare) && !People.isSuffix(word) && !NameShape.months.contains(bare) && !NameShape.weekdays.contains(bare)
        }
        // The surname after a nickname: "Robert \"Bobby\" Tables".
        if let match = TextRanges.matches(nicknameAfter, in: after).first, case let surname = (after as NSString).substring(with: match.range(at: 1)),
           given(surname), !NameCues.verbs.contains(surname.lowercased()) {
            upper += NSMaxRange(match.range)
            nicknamed = true
        } else if let match = TextRanges.matches(beforeSuffix, in: after).first,
                  (after as NSString).substring(with: match.range(at: 1)).split(separator: " ").allSatisfy({ given(String($0)) }) {
            upper += NSMaxRange(match.range(at: 1))
        }
        let firstWord = value.prefix { !$0.isWhitespace && $0 != "-" }
        if let match = TextRanges.matches(nicknameBefore, in: before).first, given((before as NSString).substring(with: match.range(at: 1))) {
            lower = head + match.range.location
            nicknamed = true
        } else if firstWord.first?.isUppercase == true, let match = TextRanges.matches(initialsBefore, in: before).first,
                  given((before as NSString).substring(with: match.range(at: 1))), !NameCues.opens(head + match.range.location..<lower, in: text) || NameLists.isFirst((before as NSString).substring(with: match.range(at: 1))) {
            lower = head + match.range.location
        } else if particles.contains(firstWord.lowercased()), firstWord.first?.isLowercase == true, let match = TextRanges.matches(givenBefore, in: before).first,
                  case let word = (before as NSString).substring(with: match.range(at: 1)), given(word), NameLists.isName(word) || !NameLists.isWord(word) {
            lower = head + match.range.location
        } else if value == value.lowercased(), !value.contains(where: { !$0.isLetter && $0 != " " }), let match = TextRanges.matches(lowerBefore, in: before).first,
                  case let word = (before as NSString).substring(with: match.range(at: 1)), given(word), NameLists.isFirst(word), !NameLists.isWordlike(word), !NameLists.isOrdinary(word) {
            lower = head + match.range.location
        }
        return (unsuffixed(lower..<upper, in: text), nicknamed)
    }
    /// A suffix says which of a family it is, not who: it stays as written after the stand-in ("… Jr.").
    private static func unsuffixed(_ range: Range<Int>, in text: String) -> Range<Int> {
        guard let match = TextRanges.matches(suffix, in: TextRanges.substring(text, range)).first, match.range.location > 0 else { return range }
        return range.lowerBound..<(range.lowerBound + match.range.location)
    }
    /// A suffix ending a name, with the comma or space before it.
    private static let suffix = TextPattern(#"(?<=\p{L}\p{L}),? (?:Jr|Sr|II|III|IV)\.?$"#)
}
