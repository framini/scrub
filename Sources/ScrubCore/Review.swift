import Foundation

/// One value Scrub replaced, and every place it did: the places where the
/// same original stood, read as the same kind of value, given the same
/// stand-in and doubted for the same reason. One original that two people
/// own ("1234" ending two SSNs) has two stand-ins, so two findings.
public struct Finding: Sendable, Identifiable, Equatable {
    /// Findings less sure than this are worth a person's look: people only a
    /// model read that the person scorer is least sure of, other values only
    /// a model read, and places only the system tagger guessed. A rule, a
    /// title, a key or a list in context is surer.
    public static let reviewBelow = 0.65

    public let id: Int
    public let entity: String
    public let original: String
    public let standIn: String
    /// How sure Scrub was of its least sure place, from 0 to 1: 1 for a
    /// field's key or a pattern that checks itself (an email, a card number),
    /// about 0.9 for a rule that reads its context, 0.85 for the system tagger's
    /// people, 0.6 for its places, and 0.5 for the context model. A person only
    /// a model read carries the person scorer's probability, from 0.5 to 0.85
    /// (0.55 for the name model's where the context model read nothing). A
    /// name found again elsewhere is as sure as the finding it was learned from.
    public let confidence: Double
    /// Every place it stands, each with its own evidence.
    public let places: [Occurrence]
    public var occurrences: Int { places.count }
    /// A few of the places it was replaced, as the output reads there.
    public let excerpts: [Excerpt]
    /// Found by the final check (see `LeakGate`), or a name not confirmed
    /// enough to replace (`Doubt.unconfirmed`), and left as written: replaced
    /// only when a person chooses, with `standIn`; its excerpts read as the
    /// output would then.
    public let suspected: Bool
    /// Why to look, beyond how sure the detector was; nil when only the confidence says so.
    public let doubt: Doubt?
    public var needsReview: Bool { confidence < Self.reviewBelow }
}

/// One place a finding stands.
public struct Occurrence: Sendable, Identifiable, Equatable {
    public let id: Int
    /// The record it sits in (a CSV row, a JSON object, an XML element), or
    /// nil in prose, so a choice can cover one record.
    public let record: Int?
    /// How sure Scrub was here.
    public let confidence: Double
    /// The output's line around it, kept for the findings worth a look.
    public let excerpt: Excerpt?
}

/// Why a finding is worth a person's look, beyond how sure its detector was.
public enum Doubt: String, Sendable {
    /// An age, last digits or a masked number that more than one value near
    /// it could be read off: it follows the first, and a person should check.
    case unclearOwner
    /// A name only a model read that nothing else in the text agrees with.
    /// Not sure enough to replace, too likely to ignore: left as written
    /// until a person chooses.
    case unconfirmed

    /// The confidence a place with this doubt carries, below `Finding.reviewBelow`.
    var confidence: Double { 0.5 }
}

/// The stand-in with the text around it on its line.
public struct Excerpt: Sendable, Equatable {
    public let before: String
    public let standIn: String
    public let after: String
}

/// What a person chose: which findings stay as written, everywhere or place
/// by place. A place's own choice wins over its finding's.
public struct Choices: Sendable, Equatable {
    /// Findings left as written wherever they stand.
    public var left: Set<Finding.ID>
    /// Places decided on their own: true leaves the original there, false writes the stand-in.
    public var places: [Occurrence.ID: Bool]

    public init(left: Set<Finding.ID> = [], places: [Occurrence.ID: Bool] = [:]) {
        self.left = left
        self.places = places
    }

    public func leaves(_ place: Occurrence, of finding: Finding) -> Bool { places[place.id] ?? left.contains(finding.id) }

    /// Leaves, or replaces, a finding everywhere, dropping the choices made place by place.
    public mutating func set(_ finding: Finding, leave: Bool) {
        if leave { left.insert(finding.id) } else { left.remove(finding.id) }
        for place in finding.places { places[place.id] = nil }
    }

    /// Leaves, or replaces, a finding in one record only.
    public mutating func set(_ finding: Finding, leave: Bool, inRecord record: Int) {
        for place in finding.places where place.record == record { places[place.id] = leave }
    }

    /// Leaves, or replaces, one place only.
    public mutating func set(_ place: Occurrence, leave: Bool) { places[place.id] = leave }

    /// How many places of `findings` stay as written.
    public func leftCount(of findings: [Finding]) -> Int {
        findings.reduce(0) { total, finding in total + finding.places.filter { leaves($0, of: finding) }.count }
    }
}

/// What a scrub kept so a person can take back some of its findings: the
/// values as replaced, and how to write the file from them. Taking a finding
/// back writes its original wherever its stand-in stood (or only in the
/// places chosen), and every other stand-in stays as it was.
final class Review: @unchecked Sendable {
    private let values: [DocumentValue]
    private let counts: [String: Int]
    private let render: ([DocumentValue], [String: Int]) throws -> ScrubResult
    let findings: [Finding]
    /// For each place, by its id: the value and mark it is, or for a place
    /// left as written, the value and its index among the unresolved.
    private let spots: [(value: Int, mark: Int, suspected: Bool)]
    private let lock = NSLock()

    /// Secrets, keys and IDs are told apart by case; names, places and emails are not.
    private static let caseSensitive: Set<String> = ["SECRET", "ID_NUMBER", "CRYPTO", "US_DRIVER_LICENSE", "US_PASSPORT", "MEDICAL_LICENSE", "IBAN_CODE"]
    static func matchKey(_ text: String, entity: String) -> String { caseSensitive.contains(entity) ? text : text.lowercased() }

    /// `records` holds the record each value sits in, when the file has records.
    init(values: [DocumentValue], counts: [String: Int], records: [Int?] = [], render: @escaping ([DocumentValue], [String: Int]) throws -> ScrubResult) {
        self.values = values
        self.counts = counts
        self.render = render
        struct Group {
            let entity: String, original: String, standIn: String, suspected: Bool, doubt: Doubt?
            var places: [(spot: Int, record: Int?, confidence: Double, range: Range<Int>, value: Int, standIn: String?)] = []
            var confidence = Double.infinity
        }
        var index: [String: Int] = [:]
        var groups: [Group] = []
        var spots: [(value: Int, mark: Int, suspected: Bool)] = []
        func add(_ mark: Mark, standIn: String, value: Int, at place: Int, suspected: Bool) {
            guard let original = mark.original, !original.isEmpty else { return }
            let confidence = suspected ? min(mark.confidence ?? LeakGate.suspectConfidence, LeakGate.suspectConfidence) : mark.confidence ?? 1
            let key = [suspected ? "?" : "", mark.entity, Self.matchKey(original, entity: mark.entity), Self.matchKey(standIn, entity: mark.entity), mark.doubt?.rawValue ?? ""].joined(separator: "\u{0}")
            let id: Int
            if let known = index[key] { id = known } else {
                id = groups.count
                index[key] = id
                groups.append(Group(entity: mark.entity, original: original, standIn: standIn, suspected: suspected, doubt: mark.doubt))
            }
            groups[id].places.append((spots.count, records.indices.contains(value) ? records[value] : nil, confidence, mark.range, value, suspected ? standIn : nil))
            groups[id].confidence = min(groups[id].confidence, confidence)
            spots.append((value, place, suspected))
        }
        for (valueIndex, value) in values.enumerated() {
            let ns = value.text as NSString
            for (markIndex, mark) in value.marks.enumerated() where mark.range.upperBound <= ns.length {
                add(mark, standIn: ns.substring(with: NSRange(location: mark.range.lowerBound, length: mark.range.count)), value: valueIndex, at: markIndex, suspected: false)
            }
            // Left as written, each with the stand-in it would take.
            for (place, mark) in value.unresolved.enumerated() where place < value.proposals.count && mark.range.upperBound <= ns.length {
                add(mark, standIn: value.proposals[place], value: valueIndex, at: place, suspected: true)
            }
        }
        self.spots = spots
        // Each value's text bridged once, not once a place.
        var bridged: [Int: NSString] = [:]
        func text(_ value: Int) -> NSString {
            if let known = bridged[value] { return known }
            let ns = values[value].text as NSString
            bridged[value] = ns
            return ns
        }
        findings = groups.enumerated().map { id, group in
            let confidence = group.confidence.isFinite ? group.confidence : 1
            let looked = confidence < Finding.reviewBelow
            var excerpts: [Excerpt] = []
            let places = group.places.map { place -> Occurrence in
                // Every place's line for the findings a person sees; a few for the rest.
                var excerpt: Excerpt?
                if looked || excerpts.count < 3 {
                    let made = Self.excerpt(text(place.value), place.range, standIn: place.standIn)
                    if excerpts.count < 3, !excerpts.contains(made) { excerpts.append(made) }
                    if looked { excerpt = made }
                }
                return Occurrence(id: place.spot, record: place.record, confidence: place.confidence, excerpt: excerpt)
            }
            return Finding(id: id, entity: group.entity, original: group.original, standIn: group.standIn, confidence: confidence, places: places, excerpts: excerpts, suspected: group.suspected, doubt: group.doubt)
        }
    }

    private static func excerpt(_ ns: NSString, _ range: Range<Int>, standIn: String? = nil) -> Excerpt {
        let line = ns.lineRange(for: NSRange(location: range.lowerBound, length: 0))
        let start = max(line.location, range.lowerBound - 60), end = min(NSMaxRange(line), range.upperBound + 60)
        let before = ns.substring(with: NSRange(location: start, length: range.lowerBound - start))
        let after = ns.substring(with: NSRange(location: range.upperBound, length: max(0, end - range.upperBound)))
        let leading = before.drop { $0.isWhitespace }, trailing = String(after.reversed().drop { $0.isWhitespace || $0.isNewline }.reversed())
        return Excerpt(before: (start > line.location ? "…" : "") + leading,
                       standIn: standIn ?? ns.substring(with: NSRange(location: range.lowerBound, length: range.count)),
                       after: trailing + (end < NSMaxRange(line) && end < ns.length ? "…" : ""))
    }

    /// The choices of the scrub as made: what was left as written stays so.
    var asMade: Choices { Choices(left: Set(findings.filter(\.suspected).map(\.id))) }

    /// The file with each place left as written or replaced as `choices` say,
    /// and every other stand-in as it was.
    func applying(_ choices: Choices) throws -> ScrubResult {
        lock.lock()
        defer { lock.unlock() }
        var revised = values
        var changed: [String: Int] = [:]
        var reverts: [Int: Set<Int>] = [:], applies: [Int: Set<Int>] = [:]
        for finding in findings {
            for place in finding.places where choices.leaves(place, of: finding) != finding.suspected {
                let spot = spots[place.id]
                if spot.suspected { applies[spot.value, default: []].insert(spot.mark) } else { reverts[spot.value, default: []].insert(spot.mark) }
            }
        }
        for valueIndex in Set(reverts.keys).union(applies.keys).sorted() {
            try Scrubber.checkCancellation()
            let value = values[valueIndex]
            let marks = value.marks, reverted = reverts[valueIndex] ?? [], applied = applies[valueIndex] ?? []
            // Each edit, in order: a stand-in taken back to its original, or a suspect given its stand-in.
            var edits: [(range: Range<Int>, value: String, applied: Int?)] = reverted.map { (marks[$0].range, marks[$0].original ?? "", nil) }
            edits += applied.map { (value.unresolved[$0].range, value.proposals[$0], $0) }
            edits.sort { $0.range.lowerBound < $1.range.lowerBound }
            for index in reverted { changed[marks[index].entity, default: 0] -= 1 }
            for index in applied { changed[value.unresolved[index].entity, default: 0] += 1 }
            let plain = edits.map { (range: $0.range, value: $0.value) }
            let (text, placed) = TextRanges.apply(plain, to: value.text)
            var kept = TextRanges.shift(marks.indices.filter { !reverted.contains($0) }.map { marks[$0] }, by: plain)
            for (range, edit) in zip(placed, edits) {
                guard let place = edit.applied else { continue }
                let suspect = value.unresolved[place]
                kept.append(Mark(range: range, entity: suspect.entity, original: suspect.original, confidence: suspect.confidence, doubt: suspect.doubt))
            }
            kept.sort { $0.range.lowerBound < $1.range.lowerBound }
            let left = value.unresolved.indices.filter { !applied.contains($0) }
            revised[valueIndex] = DocumentValue(text: text, marks: kept, unresolved: TextRanges.shift(left.map { value.unresolved[$0] }, by: plain), proposals: left.map { value.proposals[$0] })
        }
        var counts = self.counts
        for (entity, change) in changed { counts[entity] = max(0, (counts[entity] ?? 0) + change) }
        counts = counts.filter { $0.value > 0 }
        var result = try render(revised, counts)
        try Scrubber.checkCancellation()
        result.review = self
        result.made = choices
        return result
    }
}

extension ScrubResult {
    /// Every value replaced, once each, in the order first met, and every
    /// value left as written for a person to decide.
    public var findings: [Finding] { review?.findings ?? [] }
    /// The findings worth a person's look before the file is saved: every one left as written among them.
    public var uncertain: [Finding] { findings.filter(\.needsReview) }
    /// The choices this result was written with: as made, what was left as written stays so.
    public var choices: Choices { made ?? review?.asMade ?? Choices() }
    /// The findings this result leaves as written everywhere.
    public var leftAsWritten: Set<Finding.ID> { choices.left }
    /// This result written with `choices`: each place left as written or
    /// replaced as they say, and every other stand-in unchanged. Always
    /// applied to the scrub as first made, so choices can be changed and applied again.
    public func applying(_ choices: Choices) throws -> ScrubResult {
        guard let review, choices != self.choices else { return self }
        var revised = try review.applying(choices)
        revised.coverage = coverage
        return revised
    }
    /// This result with the findings in `skipped` left as written everywhere,
    /// every other value left as written replaced with its stand-in, and
    /// every other stand-in unchanged.
    public func skipping(_ skipped: Set<Finding.ID>) throws -> ScrubResult {
        try applying(Choices(left: skipped))
    }
}
