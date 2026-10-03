import Foundation

/// One value Scrub replaced, wherever it did: every place the same original
/// stood, read as the same kind of value, is one finding with one stand-in.
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
    /// How sure the surest detector that found it was, from 0 to 1: 1 for a
    /// field's key or a pattern that checks itself (an email, a card number),
    /// about 0.9 for a rule that reads its context, 0.85 for the system tagger's
    /// people, 0.6 for its places, and 0.5 for the context model. A person only
    /// a model read carries the person scorer's probability, from 0.5 to 0.85
    /// (0.55 for the name model's where the context model read nothing).
    public let confidence: Double
    public let occurrences: Int
    /// A few of the places it was replaced, as the output reads there.
    public let excerpts: [Excerpt]
    /// Found by the final check (see `LeakGate`) and left as written: a value
    /// written like one already replaced but not surely it, a number that
    /// checks itself, or one still there when the check stopped. It is
    /// replaced only when a person chooses, with `standIn`; its excerpts read
    /// as the output would then.
    public let suspected: Bool
    public var needsReview: Bool { confidence < Self.reviewBelow }
}

/// The stand-in with the text around it on its line.
public struct Excerpt: Sendable, Equatable {
    public let before: String
    public let standIn: String
    public let after: String
}

/// What a scrub kept so a person can take back some of its findings: the
/// values as replaced, and how to write the file from them. Taking a finding
/// back writes its original wherever its stand-in stood, so a value is left
/// as written everywhere or replaced everywhere, and every other stand-in
/// stays as it was.
final class Review: @unchecked Sendable {
    private let values: [DocumentValue]
    private let counts: [String: Int]
    private let render: ([DocumentValue], [String: Int]) throws -> ScrubResult
    let findings: [Finding]
    /// For each finding, the value and mark of every place it was replaced,
    /// or for a suspect, the value and place it was left as written.
    private let places: [[(value: Int, mark: Int)]]
    private let lock = NSLock()

    init(values: [DocumentValue], counts: [String: Int], render: @escaping ([DocumentValue], [String: Int]) throws -> ScrubResult) {
        self.values = values
        self.counts = counts
        self.render = render
        var index: [String: Int] = [:]
        var places: [[(value: Int, mark: Int)]] = []
        var found: [(entity: String, original: String, standIn: String, confidence: Double, excerpts: [Excerpt], suspected: Bool)] = []
        func add(_ key: String, _ entity: String, _ original: String, _ standIn: String, _ confidence: Double, _ place: (value: Int, mark: Int), _ excerpt: @autoclosure () -> Excerpt, suspected: Bool) {
            let id: Int
            if let known = index[key] { id = known } else {
                id = found.count
                index[key] = id
                found.append((entity, original, standIn, 0, [], suspected))
                places.append([])
            }
            places[id].append(place)
            found[id].confidence = max(found[id].confidence, confidence)
            if found[id].excerpts.count < 3 {
                let excerpt = excerpt()
                if !found[id].excerpts.contains(excerpt) { found[id].excerpts.append(excerpt) }
            }
        }
        for (valueIndex, value) in values.enumerated() {
            let ns = value.text as NSString
            for (markIndex, mark) in value.marks.enumerated() {
                guard let original = mark.original, !original.isEmpty, mark.range.upperBound <= ns.length else { continue }
                let standIn = ns.substring(with: NSRange(location: mark.range.lowerBound, length: mark.range.count))
                add(mark.entity + "\u{0}" + original.lowercased(), mark.entity, original, standIn, mark.confidence ?? 1, (valueIndex, markIndex), Self.excerpt(ns, mark.range), suspected: false)
            }
            // Left as written: one finding per value however often it is suspected.
            for (place, mark) in value.unresolved.enumerated() where place < value.proposals.count {
                guard let original = mark.original, !original.isEmpty, mark.range.upperBound <= ns.length else { continue }
                let proposal = value.proposals[place]
                add("?\u{0}" + mark.entity + "\u{0}" + original.lowercased(), mark.entity, original, proposal, min(mark.confidence ?? LeakGate.suspectConfidence, LeakGate.suspectConfidence),
                    (valueIndex, place), Self.excerpt(ns, mark.range, standIn: proposal), suspected: true)
            }
        }
        self.places = places
        findings = found.enumerated().map { id, item in
            Finding(id: id, entity: item.entity, original: item.original, standIn: item.standIn, confidence: item.confidence, occurrences: places[id].count, excerpts: item.excerpts, suspected: item.suspected)
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

    /// The findings left as written in the scrub as made: the suspects.
    var leftAsWritten: Set<Int> { Set(findings.filter(\.suspected).map(\.id)) }

    /// The file with the findings in `skipped` left as written, every other
    /// suspect replaced with its stand-in, and every other stand-in as it was.
    func skipping(_ skipped: Set<Int>) throws -> ScrubResult {
        lock.lock()
        defer { lock.unlock() }
        var revised = values
        var changed: [String: Int] = [:]
        var reverts: [Int: Set<Int>] = [:], applies: [Int: Set<Int>] = [:]
        for finding in findings where finding.suspected != skipped.contains(finding.id) {
            for place in places[finding.id] {
                if finding.suspected { applies[place.value, default: []].insert(place.mark) } else { reverts[place.value, default: []].insert(place.mark) }
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
                kept.append(Mark(range: range, entity: suspect.entity, original: suspect.original, confidence: suspect.confidence))
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
        result.left = skipped
        return result
    }
}

extension ScrubResult {
    /// Every value replaced, once each, in the order first met, and every
    /// suspect the final check left as written.
    public var findings: [Finding] { review?.findings ?? [] }
    /// The findings worth a person's look before the file is saved: every suspect among them.
    public var uncertain: [Finding] { findings.filter(\.needsReview) }
    /// The findings this result leaves as written: the suspects, until a person chooses otherwise.
    public var leftAsWritten: Set<Finding.ID> { left ?? review?.leftAsWritten ?? [] }
    /// This result with the findings in `skipped` left as written everywhere,
    /// every suspect not in it replaced with its stand-in, and every other
    /// stand-in unchanged. Always applied to the scrub as first made, so
    /// choices can be changed and applied again.
    public func skipping(_ skipped: Set<Finding.ID>) throws -> ScrubResult {
        guard let review, skipped != leftAsWritten else { return self }
        return try review.skipping(skipped)
    }
}
