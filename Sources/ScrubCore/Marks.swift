import Foundation

/// Values a person marked by hand in a finished scrub: each replaced wherever
/// it is written, with its variants, on top of the scrub as made and without
/// running the detectors again (see `ScrubResult.applying(_:marks:)`). They
/// live with the result only; nothing about them is written anywhere.
public struct Marks: Sendable, Equatable {
    /// One value marked, and the kind to replace it as.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: Int
        public let text: String
        public let entity: String
    }

    public private(set) var entries: [Entry] = []
    /// Ids are never reused, so a place's choice never passes to another mark.
    private var next = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Marks `text` as `entity`. The same value marked again as another kind
    /// keeps its place among the marks, with a new stand-in, and its choices
    /// made place by place start over.
    @discardableResult
    public mutating func add(_ text: String, as entity: String) -> Entry {
        let entry = Entry(id: next, text: text, entity: entity)
        next += 1
        if let known = entries.firstIndex(where: { Review.matchKey($0.text, entity: $0.entity) == Review.matchKey(text, entity: $0.entity) }) {
            if entries[known].entity == entity { return entries[known] }
            entries[known] = entry
        } else {
            entries.append(entry)
        }
        return entry
    }

    public mutating func remove(_ id: Entry.ID) { entries.removeAll { $0.id == id } }

    /// The kinds a person can mark a value as, in the order a menu lists them.
    public static let kinds = ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "ADDRESS", "LOCATION", "USERNAME", "EMPLOYER", "ID_NUMBER", "SECRET"]

    /// Kinds that draw a stand-in of their own from the value alone. A part
    /// of a name is marked as a name; what is read off another value (an age,
    /// last digits) or only placed beside one (a region, a postcode) as an ID, which keeps its shape.
    private static let drawn: Set<String> = Set(kinds).union(["CREDIT_CARD", "US_SSN", "IBAN_CODE", "IP_ADDRESS", "DATE_OF_BIRTH", "US_BANK_NUMBER", "US_PASSPORT", "US_DRIVER_LICENSE", "US_ITIN", "MEDICAL_LICENSE", "RECORD_ID", "CRYPTO"])
    private static func markable(_ entity: String) -> String {
        if drawn.contains(entity) { return entity }
        return ["FIRST_NAME", "LAST_NAME", "INITIALS"].contains(entity) ? "PERSON" : "ID_NUMBER"
    }

    /// What a value most likely is: what a pattern reads it as, what the
    /// field it sits under says (a CSV column), or what its shape suggests.
    public static func guess(_ text: String, key: String? = nil) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = (value as NSString).length
        guard length > 0 else { return "PERSON" }
        // A pattern that reads the whole value is surest: an email, a phone, a card, a key.
        let read = Patterns.find(value, isCancelled: { false }).filter { $0.range.count * 10 >= length * 9 }
        if let best = read.max(by: { $0.score < $1.score }) { return markable(best.entity) }
        if let hint = KeyHints.hint(key) { return markable(hint) }
        let words = value.split(whereSeparator: \.isWhitespace)
        let digits = value.filter(\.isNumber).count, letters = value.filter(\.isLetter).count
        if value.contains("@"), !value.contains(" ") { return value.hasPrefix("@") ? "USERNAME" : "EMAIL_ADDRESS" }
        if letters == 0 { return digits >= 7 && value.allSatisfy({ $0.isNumber || " +-().".contains($0) }) && value.contains(where: { " -().".contains($0) }) ? "PHONE_NUMBER" : "ID_NUMBER" }
        // "14 Larkspur Row", "Flat 3": a number before words.
        if words.count >= 2, digits > 0, letters > digits, words.first?.first?.isNumber == true || words.contains(where: { ["flat", "apt", "unit", "suite"].contains($0.lowercased()) }) { return "ADDRESS" }
        if words.count == 1, digits > 0 || value.contains(where: { "_.".contains($0) }) {
            return value == value.lowercased() && letters > digits ? "USERNAME" : "ID_NUMBER"
        }
        // A name is written with a capital; one word all in lowercase is a handle.
        if words.count == 1, value == value.lowercased() { return "USERNAME" }
        if ["inc", "inc.", "ltd", "llc", "gmbh", "co.", "corp", "plc"].contains(words.last?.lowercased() ?? "") { return "EMPLOYER" }
        return "PERSON"
    }
}

/// What a selection in the preview stands on: values written as they were,
/// to mark, or stand-ins, whose originals can be kept.
public struct Pick: Sendable, Equatable {
    /// Values written as they were in the input, found in the file's values.
    public var missed: [String] = []
    /// What Scrub replaced there: every finding of the same original.
    public var replaced: [Finding] = []
    /// What a person marked there.
    public var marked: [Marks.Entry] = []
    public var isEmpty: Bool { missed.isEmpty && replaced.isEmpty && marked.isEmpty }
    public init() {}
}

extension ScrubResult {
    /// The marks this result was written with.
    public var marks: Marks { marked ?? Marks() }
    /// The values marked by hand, each as a finding whose places can be left
    /// one by one with `Choices`, like any other. Their ids are negative.
    public var byHand: [Finding] { review?.marked(marks, edits: edits) ?? [] }

    /// This result written with `choices` and `marks`, and the edits it was
    /// written with, always from the scrub as first made: the same scrub,
    /// choices and marks write the same bytes.
    public func applying(_ choices: Choices, marks: Marks) throws -> ScrubResult {
        try applying(choices, marks: marks, edits: edits)
    }

    /// This result written with `choices`, `marks` and `edits`, always from
    /// the scrub as first made: the same scrub, choices, marks and edits
    /// write the same bytes.
    public func applying(_ choices: Choices, marks: Marks, edits: Edits) throws -> ScrubResult {
        guard let review, choices != self.choices || marks != self.marks || edits != self.edits else { return self }
        var revised = try review.applying(choices, marks: marks, edits: edits)
        revised.coverage = coverage
        return revised
    }

    /// What `range` of a preview stands on. `text` is the preview as shown (the
    /// output, or one table cell) and `marks` its stand-ins. A selection is
    /// widened to whole words; what it holds outside the stand-ins is what to
    /// mark, and one wholly on stand-ins (or a click on one) picks them.
    public func pick(in text: String, marks: [Mark], range: Range<Int>) -> Pick {
        guard let review else { return Pick() }
        let ns = text as NSString
        let range = max(0, min(range.lowerBound, ns.length))..<max(0, min(range.upperBound, ns.length))
        var picked = Pick()
        let marks = marks.filter { $0.range.upperBound <= ns.length }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let snapped = range.isEmpty ? range : Self.snapped(ns, range)
        let covered = range.isEmpty ? marks.filter { $0.range.contains(range.lowerBound) } : marks.filter { $0.range.overlaps(snapped) }
        // A click picks the stand-in under it, and nothing elsewhere.
        if range.isEmpty && covered.isEmpty { return picked }
        // The words the selection holds between stand-ins ("Ysolde" in "Ysolde Ruth").
        var pieces: [Range<Int>] = []
        var cursor = snapped.lowerBound
        for mark in covered + [Mark(range: snapped.upperBound..<snapped.upperBound, entity: "")] {
            let limit = min(mark.range.lowerBound, snapped.upperBound)
            if limit > cursor {
                let widened = Self.snapped(ns, cursor..<limit)
                let piece = max(cursor, widened.lowerBound)..<max(cursor, min(limit, widened.upperBound))
                if ns.substring(with: NSRange(location: piece.lowerBound, length: piece.count)).contains(where: { $0.isLetter || $0.isNumber }) { pieces.append(piece) }
            }
            cursor = max(cursor, mark.range.upperBound)
        }
        if !pieces.isEmpty {
            for piece in pieces {
                // Each as the value it reads: "%51uillmere" in a link is Quillmere.
                for candidate in review.candidates(ns.substring(with: NSRange(location: piece.lowerBound, length: piece.count))).map(review.identity) where !picked.missed.contains(candidate) { picked.missed.append(candidate) }
            }
            return picked
        }
        for mark in covered {
            let owners = review.owners(ofStandIn: ns.substring(with: NSRange(location: mark.range.lowerBound, length: mark.range.count)), marks: self.marks, edits: edits)
            for finding in owners.findings where !picked.replaced.contains(where: { $0.id == finding.id }) { picked.replaced.append(finding) }
            for entry in owners.entries where !picked.marked.contains(entry) { picked.marked.append(entry) }
        }
        return picked
    }

    /// The choices and marks that replace `texts` as `entity`: each marked as
    /// the value it reads (a selection encoded in a link, or split by markup
    /// or a hidden character, is the value decoded, which reaches every
    /// form), and any finding of the same value left as written replaced again.
    public func marking(_ texts: [String], as entity: String, choices: Choices, marks: Marks) -> (Choices, Marks) {
        var choices = choices, marks = marks
        for text in texts.map({ review?.identity($0) ?? $0 }) {
            for finding in findings where Review.matchKey(finding.original, entity: finding.entity) == Review.matchKey(text, entity: finding.entity)
                && finding.places.contains(where: { choices.leaves($0, of: finding) }) {
                choices.set(finding, leave: false)
            }
            marks.add(text, as: entity)
        }
        return (choices, marks)
    }

    /// The choices and marks that keep what `pick` stands on as written: its
    /// findings left everywhere, and its marks taken back.
    public func keeping(_ pick: Pick, choices: Choices, marks: Marks) -> (Choices, Marks) {
        var choices = choices, marks = marks
        for finding in pick.replaced { choices.set(finding, leave: true) }
        for entry in pick.marked { marks.remove(entry.id) }
        return (choices, marks)
    }

    /// Warms what marking reads, so the first selection in a large file answers at once.
    public func prepareMarking() { review?.prepare() }

    private static let joiners: Set<unichar> = [46, 95, 45, 43, 64, 39, 0x2019]
    private static let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’`,;:()[]{}<>=|.!?*"))
    /// `range` widened to the words it cuts into, and trimmed of the spaces
    /// and punctuation around it. A word cut in half is taken whole, with what
    /// joins it to its neighbours ("ria@kest" is "maria@kestrel.example"); a
    /// possessive's "'s" is no part of the name.
    static func snapped(_ ns: NSString, _ range: Range<Int>) -> Range<Int> {
        func word(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length else { return false }
            let unit = ns.character(at: index)
            if (0xD800...0xDFFF).contains(unit) { return true }
            return Unicode.Scalar(unit).map(CharacterSet.alphanumerics.contains) ?? false
        }
        func joins(_ index: Int) -> Bool { index >= 0 && index < ns.length && joiners.contains(ns.character(at: index)) && word(index - 1) && word(index + 1) }
        var start = range.lowerBound, end = range.upperBound
        if word(start) && word(start - 1) {
            while word(start - 1) || joins(start - 1) { start -= 1 }
        }
        if word(end - 1) && word(end) {
            while word(end) || joins(end) { end += 1 }
        }
        func edge(_ index: Int) -> Bool { Unicode.Scalar(ns.character(at: index)).map(edges.contains) ?? false }
        while start < end, edge(start) { start += 1 }
        while end > start, edge(end - 1) {
            // "M." keeps its full stop.
            if ns.character(at: end - 1) == 46, end - start >= 2, end - 2 >= start, let letter = Unicode.Scalar(ns.character(at: end - 2)), CharacterSet.uppercaseLetters.contains(letter), !word(end - 3) { break }
            end -= 1
        }
        if end - start > 2, ["'s", "’s"].contains(ns.substring(with: NSRange(location: end - 2, length: 2)).lowercased()) { end -= 2 }
        return start..<end
    }
}
