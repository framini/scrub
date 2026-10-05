import Foundation

/// The last check before a scrub finishes. Detecting again on the output finds
/// nothing the detectors missed the first time, so this check reads with what
/// they did not have: the values already replaced. It looks for those values
/// written another way and still in the output:
///
/// - a name's part split by a soft hyphen or a hyphen at a line's end
///   ("Fer-⏎riter"), or alone where only the full name was found;
/// - a name inside a handle or a login: "odalys.f", "@odalysf", "oferriter",
///   "ferriterodalys", "ferriter99";
/// - a number's digits with other separators or none ("4158672290" for
///   "(415) 867-2290"), and its last four digits after a label ("ending in 2290");
/// - an email's local part on its own ("user quillpen77");
/// - any of these in a link's part written percent-encoded ("?q=%4Cisk"),
///   read decoded and without hidden characters, as a reader reads it.
///
/// Each is replaced by the stand-in its original got, written the same way.
/// A part is used only when it is at least four letters and no ordinary or
/// dictionary word, and a joined form only when it is no word either, so a
/// name that is also a word ("Will", "Rose") is never hunted this way.
///
/// It also flags numbers that check themselves and are still as written
/// anywhere: a card number that passes its check digit and starts as a card
/// network's do, an IBAN, a Social Security number in its own layout. Nothing
/// replaced those, so a detector or rule chose to keep them; unless they are
/// filed under an order, an invoice or a ticket, they go to review as
/// suspects, left as written until a person chooses.
struct LeakGate {
    /// How sure a suspect is: low enough that review always asks about it.
    static let suspectConfidence = 0.5

    /// A variant of a replaced value: its range in the text, what it is, and
    /// its stand-in, or nil to draw one as any other value of `entity`.
    struct Leak {
        let range: Range<Int>
        let entity: String
        let fake: String?
        /// The replaced original it is a variant of.
        let source: String
    }
    struct Found {
        var leaks: [Leak] = []
        var suspects: [Span] = []
    }

    private struct Piece { let length: Int; let fake: String }
    private var parts: [String: (fake: String, source: String)] = [:]
    /// A name's parts joined: "odalysferriter", "oferriter", "odalysf", each piece with its stand-in.
    private var combos: [String: (pieces: [Piece], source: String)] = [:]
    private var numbers: [String: (entity: String, fake: String, source: String)] = [:]
    /// The last four digits of each number replaced, with what the numbers were.
    private var endings: [String: Set<String>] = [:]
    private var locals: [String: (fake: String, source: String)] = [:]
    /// The lengths of the words above, to skip every other word at once.
    private var lengths: Set<Int> = []
    /// The fewest UTF-16 units a token needs to hold any of them.
    private var shortest = Int.max
    private var seen: Set<String> = []

    var isEmpty: Bool { parts.isEmpty && combos.isEmpty && numbers.isEmpty && locals.isEmpty }

    init() {}
    /// Stops early once the task is cancelled; the caller checks before using it.
    init(_ values: [DocumentValue]) {
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return }
            add(value.marks, in: value.text)
        }
    }

    mutating func add(_ marks: [Mark], in text: String) {
        for mark in marks {
            guard let original = mark.original, !original.isEmpty else { continue }
            add(mark.entity, original: original, fake: { TextRanges.substring(text, mark.range) })
        }
    }
    mutating func add<S: Sequence>(_ replacements: S) where S.Element == Replacement {
        for replacement in replacements { add(replacement.entity, original: replacement.original, fake: { replacement.fake }) }
    }

    private static let numbered: Set<String> = ["PHONE_NUMBER", "US_SSN", "CREDIT_CARD", "US_BANK_NUMBER", "ID_NUMBER", "US_ITIN", "US_PASSPORT", "US_DRIVER_LICENSE", "MEDICAL_LICENSE", "IBAN_CODE"]

    private mutating func add(_ entity: String, original: String, fake made: () -> String) {
        let isName = ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(entity)
        guard isName || entity == "EMAIL_ADDRESS" || Self.numbered.contains(entity) else { return }
        guard seen.insert(entity + "\u{0}" + original).inserted else { return }
        let fake = made()
        guard !fake.isEmpty, fake != original else { return }
        if isName { addName(original, fake) }
        else if entity == "EMAIL_ADDRESS" { addEmail(original, fake) }
        else { addNumber(entity, original, fake) }
    }

    /// The words of a name, first name first, without titles or suffixes; empty
    /// when any word is more than letters, an apostrophe or a hyphen.
    private static func nameWords(_ value: String) -> [String] {
        let words = (People.naturalOrder(value) ?? value).split { $0.isWhitespace || $0 == "," }.map(String.init)
            .drop { People.isTitle($0) }.filter { !People.isSuffix($0) }
        guard words.allSatisfy({ word in word.allSatisfy { $0.isLetter || "'’-.".contains($0) } }) else { return [] }
        return words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    }
    /// A name's part worth looking for wherever it is written: four letters or
    /// more, and no word any list holds ("Will", "Rose", "Refund").
    static func usable(_ part: String) -> Bool {
        part.count >= 4 && part.allSatisfy(\.isLetter) && !Names.ambiguousFirst.contains(part.lowercased()) && !NameLists.isWord(part)
    }
    private static func letters(_ value: String) -> String { value.lowercased().filter(\.isLetter) }

    private mutating func addName(_ original: String, _ fake: String) {
        let real = Self.nameWords(original), made = Self.nameWords(fake)
        guard !real.isEmpty, real.count == made.count, real.count <= 4 else { return }
        for (part, stand) in zip(real, made) where Self.usable(part) {
            let key = part.lowercased()
            if parts[key] == nil { parts[key] = (stand, original); lengths.insert(part.count); shortest = min(shortest, part.utf16.count) }
        }
        guard real.count >= 2, let first = real.first, let last = real.last, let fakeFirst = made.first, let fakeLast = made.last else { return }
        let f = Self.letters(first), l = Self.letters(last), ff = Self.letters(fakeFirst), fl = Self.letters(fakeLast)
        guard f.count >= 2, l.count >= 2, !ff.isEmpty, !fl.isEmpty else { return }
        // Each form as the real pieces and their stand-ins: "odalysferriter", "ferriterodalys",
        // "oferriter" and "ferritero" (with a surname worth hunting), "odalysf" (with such a first name).
        let initial = String(f.prefix(1)), fakeInitial = String(ff.prefix(1))
        // Two parts that are both words ("Will Rose") are no handle worth hunting.
        guard Self.usable(first) || Self.usable(last) else { return }
        var forms: [[(String, String)]] = [[(f, ff), (l, fl)], [(l, fl), (f, ff)]]
        if Self.usable(last) { forms += [[(initial, fakeInitial), (l, fl)], [(l, fl), (initial, fakeInitial)]] }
        if Self.usable(first) { forms.append([(f, ff), (String(l.prefix(1)), String(fl.prefix(1)))]) }
        for form in forms {
            let key = form.map(\.0).joined()
            guard key.count >= 6, !NameLists.isWord(key), combos[key] == nil else { continue }
            combos[key] = (form.map { Piece(length: $0.0.count, fake: $0.1) }, original)
            lengths.insert(key.count)
            shortest = min(shortest, key.utf16.count)
        }
    }

    /// Mailboxes everyone has: "info", "support", "billing".
    private static let mailboxes: Set<String> = ["info", "admin", "support", "sales", "contact", "hello", "office", "billing", "noreply", "no-reply", "team", "help",
                                                 "mail", "accounts", "account", "service", "careers", "jobs", "press", "media", "webmaster", "postmaster", "security", "privacy"]
    private mutating func addEmail(_ original: String, _ fake: String) {
        let real = original.split(separator: "@", maxSplits: 1), made = fake.split(separator: "@", maxSplits: 1)
        guard real.count == 2, made.count == 2 else { return }
        let local = String(real[0]), key = local.lowercased()
        guard local.filter({ $0.isLetter || $0.isNumber }).count >= 4, local.contains(where: \.isLetter), !Self.mailboxes.contains(key), !People.isRoleMailbox(original), !NameLists.isWord(local) else { return }
        if locals[key] == nil { locals[key] = (String(made[0]), original); shortest = min(shortest, local.utf16.count) }
    }

    private static func digits(_ value: String) -> String { value.filter { $0.isASCII && $0.isNumber } }
    private mutating func addNumber(_ entity: String, _ original: String, _ fake: String) {
        guard !StandIns.isMasked(original) else { return }
        var real = Self.digits(original), made = Self.digits(fake)
        guard real.count >= 7, real.count == made.count, real != made else { return }
        if entity == "PHONE_NUMBER", real.count == 11, real.first == "1" { real.removeFirst(); made.removeFirst() }
        if numbers[real] == nil { numbers[real] = (entity, made, original) }
        endings[String(real.suffix(4)), default: []].insert(entity)
    }

    // MARK: Reading

    /// Whether `text` holds any variant this gate knows, for a value no check has read since.
    func hits(_ text: String) -> Bool { !scan(text, suspects: false).leaks.isEmpty }

    /// The variants and suspects in `text`. Past `budget` variants, the rest
    /// are suspects too: a pass fixes a bounded amount, and nothing is dropped.
    func scan(_ text: String, budget: Int = .max, suspects: Bool = true, isCancelled: () -> Bool = { Task.isCancelled }) -> Found {
        let units = Array(text.utf16)
        var found = Found()
        guard !units.isEmpty else { return found }
        if !isEmpty {
            if !parts.isEmpty || !combos.isEmpty || !locals.isEmpty { words(units, text, into: &found, isCancelled: isCancelled) }
            if !isCancelled() { numbers(units, text, into: &found, isCancelled: isCancelled) }
            if !isCancelled(), text.contains("%") { encoded(text, into: &found, isCancelled: isCancelled) }
        }
        if suspects, !isCancelled() { checked(units, text, into: &found, isCancelled: isCancelled) }
        if found.leaks.count > budget {
            found.suspects += found.leaks[budget...].map { Span(range: $0.range, entity: $0.entity, score: Self.suspectConfidence) }
            found.leaks.removeSubrange(budget...)
        }
        return found
    }

    /// Variants in the parts of links written percent-encoded, read as the
    /// parts read (see `URLs.reading`) and placed back over them as written:
    /// "?q=%4Cisk" holds "Lisk", and "%51uill%E2%80%8Bmere" "Quillmere".
    private func encoded(_ text: String, into found: inout Found, isCancelled: () -> Bool) {
        for component in URLs.components(in: text) {
            if isCancelled() { return }
            let raw = TextRanges.substring(text, component.range)
            guard raw.contains("%"), let read = URLs.reading(raw, component.part) else { continue }
            let units = Array(read.text.utf16)
            var inner = Found()
            words(units, read.text, into: &inner, isCancelled: isCancelled)
            numbers(units, read.text, into: &inner, isCancelled: isCancelled)
            for leak in inner.leaks where leak.range.upperBound <= read.sources.count {
                let offset = component.range.lowerBound
                let range = (read.sources[leak.range.lowerBound].lowerBound + offset)..<(read.sources[leak.range.upperBound - 1].upperBound + offset)
                guard !found.leaks.contains(where: { $0.range.overlaps(range) }) else { continue }
                found.leaks.append(Leak(range: range, entity: leak.entity, fake: leak.fake, source: leak.source))
            }
        }
    }

    private static let softHyphen: UInt16 = 0xAD
    private static func isLetter(_ unit: UInt16) -> Bool {
        if unit < 128 { return (65...90).contains(unit) || (97...122).contains(unit) }
        if unit == softHyphen { return false }
        if (0xD800...0xDFFF).contains(unit) { return true }
        return Unicode.Scalar(unit).map(CharacterSet.letters.contains) ?? false
    }
    private static func isDigit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
    /// Joins a word to the next inside a token: "odalys.f", "odalys_ferriter", "@odalysf", "o'brien".
    private static func isJoiner(_ unit: UInt16) -> Bool { [46, 95, 45, 64, 43, 39, 0x2019].contains(unit) || unit == softHyphen }

    private struct Segment {
        var range: Range<Int>
        var letters: String
    }

    /// Names and email local parts written into words and handles.
    private func words(_ units: [UInt16], _ text: String, into found: inout Found, isCancelled: () -> Bool) {
        let ns = text as NSString
        var index = 0
        var tokens = 0
        while index < units.count {
            guard Self.isLetter(units[index]) || Self.isDigit(units[index]) || Self.isJoiner(units[index]) else { index += 1; continue }
            tokens += 1
            if tokens.isMultiple(of: 4096) && isCancelled() { return }
            let start = index
            while index < units.count, Self.isLetter(units[index]) || Self.isDigit(units[index]) || Self.isJoiner(units[index]) { index += 1 }
            // Too short to hold anything looked for, unless a hyphen ends it at a line's end.
            if index - start < shortest && !(units[index - 1] == 45 && index < units.count && [10, 13, 32, 9].contains(units[index])) { continue }
            token(start..<index, units, ns, into: &found)
        }
    }

    private func token(_ range: Range<Int>, _ units: [UInt16], _ ns: NSString, into found: inout Found) {
        // Trailing punctuation ends a sentence, not a handle: "odalys.f." or "Ferriter's".
        var end = range.upperBound
        while end > range.lowerBound, [46, 45, 39, 0x2019, Self.softHyphen].contains(units[end - 1]) { end -= 1 }
        var start = range.lowerBound
        while start < end, [46, 45, 39, 0x2019, 64, 43, 95].contains(units[start]) { start += 1 }
        guard start < end else { return }
        // A hyphen at a line's end splits one word over two lines: "Fer-⏎riter".
        if end < range.upperBound, units[end] == 45, let joined = split(end, units, ns) {
            let head = lastSegment(start..<end, units, ns)
            if let head, let part = parts[(head.letters + joined.letters).lowercased()] {
                found.leaks.append(Leak(range: head.range.lowerBound..<joined.range.upperBound, entity: "PERSON", fake: Self.cased(part.fake, like: head.letters), source: part.source))
                return
            }
        }
        let whole = ns.substring(with: NSRange(location: start, length: end - start))
        // An email's local part on its own.
        if !locals.isEmpty, let local = locals[whole.lowercased()] {
            found.leaks.append(Leak(range: start..<end, entity: "USERNAME", fake: local.fake, source: local.source))
            return
        }
        // An email itself was read by the detectors, and a stand-in is in the marks.
        if whole.contains("@") { return }
        let segments = self.segments(start..<end, units, ns)
        // A word with only apostrophes or hyphens in it ("Ferriter's", "Ferriter-Lind") is a name; one with a dot, an underscore, an at sign or a digit is a handle.
        let plain = !units[start..<end].contains { [46, 95, 64, 43].contains($0) || Self.isDigit($0) }
        var index = 0
        while index < segments.count {
            let segment = segments[index]
            // Two words joined by one separator: "odalys.f", "o_ferriter".
            if index + 1 < segments.count, segment.range.upperBound + 1 == segments[index + 1].range.lowerBound,
               [46, 95, 45].contains(units[segment.range.upperBound]) {
                let next = segments[index + 1]
                let key = (segment.letters + next.letters).lowercased()
                if lengths.contains(key.count), let combo = combos[key], combo.pieces.count == 2,
                   combo.pieces[0].length == segment.letters.count, combo.pieces[1].length == next.letters.count {
                    let separator = ns.substring(with: NSRange(location: segment.range.upperBound, length: 1))
                    let fake = Self.cased(combo.pieces[0].fake, like: segment.letters) + separator + Self.cased(combo.pieces[1].fake, like: next.letters)
                    found.leaks.append(Leak(range: segment.range.lowerBound..<next.range.upperBound, entity: "USERNAME", fake: fake, source: combo.source))
                    index += 2
                    continue
                }
            }
            let key = segment.letters.lowercased()
            if lengths.contains(key.count) {
                if let part = parts[key] {
                    // Alone it is a name; inside a handle it is the handle's.
                    found.leaks.append(Leak(range: segment.range, entity: plain ? "PERSON" : "USERNAME", fake: Self.cased(part.fake, like: segment.letters), source: part.source))
                } else if let combo = combos[key] {
                    let fake = combo.pieces.map(\.fake).joined()
                    found.leaks.append(Leak(range: segment.range, entity: "USERNAME", fake: Self.cased(fake, like: segment.letters), source: combo.source))
                }
            }
            index += 1
        }
    }

    /// The runs of letters in a token, each read without its soft hyphens ("Fer\u{AD}riter").
    private func segments(_ range: Range<Int>, _ units: [UInt16], _ ns: NSString) -> [Segment] {
        var result: [Segment] = []
        var index = range.lowerBound
        while index < range.upperBound {
            guard Self.isLetter(units[index]) else { index += 1; continue }
            let start = index
            var letters: [UInt16] = []
            while index < range.upperBound, Self.isLetter(units[index]) || units[index] == Self.softHyphen && index + 1 < range.upperBound && Self.isLetter(units[index + 1]) {
                if units[index] != Self.softHyphen { letters.append(units[index]) }
                index += 1
            }
            // A camelCase join starts a new word ("odalysFerriter"), which the detectors already read.
            result.append(Segment(range: start..<index, letters: String(utf16CodeUnits: letters, count: letters.count)))
        }
        return result
    }
    private func lastSegment(_ range: Range<Int>, _ units: [UInt16], _ ns: NSString) -> Segment? {
        guard let last = segments(range, units, ns).last, last.range.upperBound == range.upperBound else { return nil }
        return last
    }
    /// The word that goes on after a hyphen at `at` and a line break.
    private func split(_ at: Int, _ units: [UInt16], _ ns: NSString) -> Segment? {
        var index = at + 1
        while index < units.count, units[index] == 32 || units[index] == 9 { index += 1 }
        if index < units.count, units[index] == 13 { index += 1 }
        guard index < units.count, units[index] == 10 else { return nil }
        index += 1
        while index < units.count, units[index] == 32 || units[index] == 9 { index += 1 }
        guard index < units.count, Self.isLetter(units[index]) else { return nil }
        var end = index
        while end < units.count, Self.isLetter(units[end]) { end += 1 }
        return Segment(range: index..<end, letters: ns.substring(with: NSRange(location: index, length: end - index)))
    }

    /// A stand-in written as the variant is: in capitals, in lowercase, or capitalised.
    static func cased(_ fake: String, like variant: String) -> String {
        let letters = variant.filter(\.isLetter)
        if letters.count >= 2, letters == letters.uppercased(), letters != letters.lowercased() { return fake.uppercased() }
        if letters == letters.lowercased() { return fake.lowercased() }
        if letters.first?.isUppercase == true { return fake.prefix(1).uppercased() + fake.dropFirst().lowercased() }
        return fake
    }

    // MARK: Numbers

    private struct Chunk { let range: Range<Int>; let digits: String }

    /// Runs of digits, grouped where one or two separators join them: "(415) 867-2290", "536 21 7784".
    private static func groups(_ units: [UInt16], isCancelled: () -> Bool) -> [[Chunk]] {
        var groups: [[Chunk]] = []
        var current: [Chunk] = []
        var index = 0
        var runs = 0
        while index < units.count {
            guard isDigit(units[index]) else { index += 1; continue }
            runs += 1
            if runs.isMultiple(of: 4096) && isCancelled() { return groups }
            let start = index
            while index < units.count, isDigit(units[index]) { index += 1 }
            let chunk = Chunk(range: start..<index, digits: String(utf16CodeUnits: Array(units[start..<index]), count: index - start))
            if let last = current.last {
                let between = units[last.range.upperBound..<start]
                if between.count <= 2, between.allSatisfy({ [32, 45, 46, 47, 40, 41].contains($0) }) { current.append(chunk) }
                else { groups.append(current); current = [chunk] }
            } else { current = [chunk] }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Before last four digits: "ending in", "ends with", "last four", "last 4 digits of her card:", or a mask.
    private static let endingLabel = TextPattern(#"(?i)(?:\bending(?:[ \t]+(?:in|with))?|\bends?[ \t]+(?:in|with)|\blast[ \t-]*(?:4|four)(?:[ \t]+[\p{L}'’]+){0,4}|\blast4|[x*•#]{2,}[ \t-]*)[ \t]*[:#=]?[ \t]*$"#)

    private func numbers(_ units: [UInt16], _ text: String, into found: inout Found, isCancelled: () -> Bool) {
        guard !numbers.isEmpty else { return }
        let ns = text as NSString
        for group in Self.groups(units, isCancelled: isCancelled) {
            for first in group.indices {
                var digits = ""
                for last in first..<group.count {
                    digits += group[last].digits
                    guard digits.count <= 19 else { break }
                    let national = digits.count == 11 && digits.first == "1" ? String(digits.dropFirst()) : nil
                    guard let known = numbers[digits] ?? national.flatMap({ numbers[$0] }).flatMap({ $0.entity == "PHONE_NUMBER" ? $0 : nil }) else { continue }
                    let range = group[first].range.lowerBound..<group[last].range.upperBound
                    let written = ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
                    let source = digits.count == known.fake.count + 1 ? "1" + known.fake : known.fake
                    var iterator = source.makeIterator()
                    let fake = String(written.map { $0.isASCII && $0.isNumber ? iterator.next() ?? $0 : $0 })
                    found.leaks.append(Leak(range: range, entity: known.entity, fake: fake, source: known.source))
                }
            }
            // The last four digits of a number replaced elsewhere, after a label.
            if group.count == 1, let chunk = group.first, chunk.digits.count == 4, let kinds = endings[chunk.digits] {
                let start = max(0, chunk.range.lowerBound - 48)
                let before = ns.substring(with: NSRange(location: start, length: chunk.range.lowerBound - start))
                if !TextRanges.matches(Self.endingLabel, in: before).isEmpty, Self.names(before, kinds), !found.leaks.contains(where: { $0.range.overlaps(chunk.range) }) {
                    found.leaks.append(Leak(range: chunk.range, entity: "LAST_DIGITS", fake: nil, source: chunk.digits))
                }
            }
        }
    }

    /// Words that say what kind of number the last digits end, and the kinds they fit.
    private static let endingKinds: [(words: Set<String>, kinds: Set<String>)] = [
        (["card", "visa", "mastercard", "amex", "credit", "debit"], ["CREDIT_CARD"]),
        (["phone", "mobile", "cell", "tel", "telephone", "landline", "fax"], ["PHONE_NUMBER", "ID_NUMBER"]),
        (["ssn", "social", "itin", "tin", "taxpayer"], ["US_SSN", "US_ITIN", "ID_NUMBER"]),
        (["account", "acct", "iban", "bank", "routing", "checking", "savings"], ["US_BANK_NUMBER", "IBAN_CODE", "ID_NUMBER"]),
        (["passport"], ["US_PASSPORT", "ID_NUMBER"]),
        (["license", "licence"], ["US_DRIVER_LICENSE", "MEDICAL_LICENSE", "ID_NUMBER"]),
    ]
    /// Whether the label before last digits could be about a number of one of
    /// `kinds`: "card ending 1001" is no phone's ending, whatever phone ends so.
    private static func names(_ label: String, _ kinds: Set<String>) -> Bool {
        let words = Set(label.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let said = endingKinds.filter { !$0.words.isDisjoint(with: words) }
        return said.isEmpty || said.contains { !$0.kinds.isDisjoint(with: kinds) }
    }

    // MARK: Numbers that check themselves

    private static let ibanStart = TextPattern(#"(?<![A-Za-z0-9])[A-Z]{2}[0-9]{2}(?:[ -]?[A-Z0-9]){11,32}"#)

    private func checked(_ units: [UInt16], _ text: String, into found: inout Found, isCancelled: () -> Bool) {
        let ns = text as NSString
        var digitCount = 0
        for unit in units where Self.isDigit(unit) { digitCount += 1; if digitCount >= 9 { break } }
        guard digitCount >= 9 else { return }
        for group in Self.groups(units, isCancelled: isCancelled) {
            let digits = group.map(\.digits).joined()
            let range = group[0].range.lowerBound..<group[group.count - 1].range.upperBound
            let separators = Set(group.dropFirst().indices.flatMap { units[group[$0 - 1].range.upperBound..<group[$0].range.lowerBound] })
            guard !Detector.filed(range.lowerBound, in: ns), !Self.versioned(range, units, ns) else { continue }
            if (13...19).contains(digits.count), separators.isSubset(of: [32, 45]), Self.cardLike(digits), Patterns.luhn(digits.compactMap(\.wholeNumberValue)) {
                found.suspects.append(Span(range: range, entity: "CREDIT_CARD", score: Self.suspectConfidence))
            } else if group.count == 3, group.map(\.digits.count) == [3, 2, 4], separators.count == 1, separators.isSubset(of: [32, 45]), Self.socialSecurity(digits) {
                found.suspects.append(Span(range: range, entity: "US_SSN", score: Self.suspectConfidence))
            }
        }
        guard !isCancelled(), text.contains(where: { $0.isASCII && $0.isUppercase }) else { return }
        for match in TextRanges.matches(Self.ibanStart, in: text, isCancelled: isCancelled) {
            let candidate = ns.substring(with: match.range)
            // The longest IBAN the run starts with: "DE89 3704 0044 0532 0130 00 thanks" is one.
            for length in stride(from: candidate.utf16.count, through: 15, by: -1) {
                let prefix = (candidate as NSString).substring(to: length)
                guard prefix.last != " ", prefix.last != "-" else { continue }
                if Patterns.iban(prefix) {
                    found.suspects.append(Span(range: match.range.location..<(match.range.location + length), entity: "IBAN_CODE", score: Self.suspectConfidence))
                    break
                }
            }
        }
    }

    /// Starts as a card network's numbers do: 4, 51–55, 2221–2720, 34 or 37, 35, 36 or 38, 6011, 62, 644–649 or 65.
    static func cardLike(_ digits: String) -> Bool {
        guard let two = Int(digits.prefix(2)), let four = Int(digits.prefix(4)) else { return false }
        switch digits.first {
        case "4": return [13, 16, 19].contains(digits.count)
        case "5": return (51...55).contains(two) && digits.count == 16
        case "2": return (2221...2720).contains(four) && digits.count == 16
        case "3": return ([34, 37].contains(two) && digits.count == 15) || (two == 35 && digits.count == 16) || ([36, 38].contains(two) && digits.count == 14)
        case "6": return (four == 6011 || two == 62 || two == 65 || (644...649).contains(four / 10)) && (16...19).contains(digits.count)
        default: return false
        }
    }
    /// A Social Security number's ranges: no area 000, 666 or 900–999, no group 00, no serial 0000.
    static func socialSecurity(_ digits: String) -> Bool {
        guard digits.count == 9, let area = Int(digits.prefix(3)), let group = Int(digits.dropFirst(3).prefix(2)), let serial = Int(digits.suffix(4)) else { return false }
        return area != 0 && area != 666 && area < 900 && group != 0 && serial != 0 && Set(digits).count > 1
    }
    /// A version ("v4.5.3914", "version 4111 1111…") or a number glued to a word: no card or ID of anyone's.
    private static func versioned(_ range: Range<Int>, _ units: [UInt16], _ ns: NSString) -> Bool {
        if range.lowerBound > 0, isLetter(units[range.lowerBound - 1]) || units[range.lowerBound - 1] == 46 { return true }
        if range.upperBound < units.count, isLetter(units[range.upperBound]) || units[range.upperBound] == 46 && range.upperBound + 1 < units.count && isDigit(units[range.upperBound + 1]) { return true }
        let start = max(0, range.lowerBound - 12)
        let before = ns.substring(with: NSRange(location: start, length: range.lowerBound - start)).lowercased()
        return before.hasSuffix("version ") || before.hasSuffix("build ") || before.hasSuffix("v")
    }
}
