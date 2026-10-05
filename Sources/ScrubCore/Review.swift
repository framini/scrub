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
    let values: [DocumentValue]
    private let counts: [String: Int]
    private let render: ([DocumentValue], [String: Int]) throws -> ScrubResult
    let findings: [Finding]
    /// For each place, by its id: the value and mark it is, or for a place
    /// left as written, the value and its index among the unresolved.
    let spots: [(value: Int, mark: Int, suspected: Bool)]
    let lock = NSLock()
    private let records: [Int?]
    /// Values written as bare numbers (a JSON number), which only a number may replace.
    let numeric: Set<Int>
    /// Values written as an XML name, which keeps only some of a value's
    /// characters (see `squeezed(_:)`): what is written there is read so too.
    let squeezed: Set<Int>
    /// The people the scrub drew names for, and for each finding of a name,
    /// or of an email, username or initials built from one, whose it is.
    let people: PersonLinks
    let personOf: [Finding.ID: Int]
    /// Mixed into every stand-in drawn for a mark: the scrub's seed when it
    /// had one, so the same scrub and marks write the same bytes.
    var salt: UInt64 = 0
    /// What marking reads, built once on first use (see `Marking`).
    var marking: Marking?

    /// Secrets, keys and IDs are told apart by case; names, places and emails are not.
    private static let caseSensitive: Set<String> = ["SECRET", "ID_NUMBER", "CRYPTO", "US_DRIVER_LICENSE", "US_PASSPORT", "MEDICAL_LICENSE", "IBAN_CODE"]
    static func matchKey(_ text: String, entity: String) -> String { caseSensitive.contains(entity) ? text : text.lowercased() }

    /// `records` holds the record each value sits in, when the file has records.
    init(values: [DocumentValue], counts: [String: Int], records: [Int?] = [], people: PersonLinks = PersonLinks(), numeric: Set<Int> = [], squeezed: Set<Int> = [], render: @escaping ([DocumentValue], [String: Int]) throws -> ScrubResult) {
        self.values = values
        self.counts = counts
        self.render = render
        self.records = records
        self.numeric = numeric
        self.squeezed = squeezed
        self.people = people
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
        var owners: [Finding.ID: Int] = [:]
        for (id, group) in groups.enumerated() where !people.isEmpty {
            if let person = people.person(original: group.original, standIn: group.standIn) { owners[id] = person }
        }
        personOf = owners
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
    /// each value in `marks` replaced where it stands unless a choice leaves
    /// it, each finding `edits` revise written with its new stand-in and kind,
    /// and every other stand-in as it was.
    func applying(_ choices: Choices, marks: Marks = Marks(), edits: Edits = Edits()) throws -> ScrubResult {
        lock.lock()
        defer { lock.unlock() }
        var revised = values
        var changed: [String: Int] = [:]
        var reverts: [Int: Set<Int>] = [:], applies: [Int: Set<Int>] = [:]
        let revisions = try self.revisions(edits)
        // Each place of a revised finding that stays replaced, by value and the
        // index of its stand-in (or of its suspect, where one is replaced).
        var rewrites: [Int: [Int: Revision]] = [:], appliedAs: [Int: [Int: Revision]] = [:]
        for finding in findings {
            let revision = revisions[finding.id]
            for place in finding.places {
                let spot = spots[place.id], leaves = choices.leaves(place, of: finding)
                if leaves != finding.suspected {
                    if spot.suspected { applies[spot.value, default: []].insert(spot.mark) } else { reverts[spot.value, default: []].insert(spot.mark) }
                }
                guard let revision, !leaves else { continue }
                if spot.suspected { appliedAs[spot.value, default: [:]][spot.mark] = revision } else { rewrites[spot.value, default: [:]][spot.mark] = revision }
            }
        }
        // Marked by hand: each place a choice does not leave.
        var added: [Int: [(range: Range<Int>, value: String, entity: String, original: String)]] = [:]
        for (entry, places) in try placements(marks, edits: edits) {
            let finding = Self.findingID(entry)
            for (index, place) in places where !(choices.places[Self.placeID(entry, index)] ?? choices.left.contains(finding)) {
                let original = (values[place.value].text as NSString).substring(with: NSRange(location: place.range.lowerBound, length: place.range.count))
                added[place.value, default: []].append((place.range, place.written, place.entity, original))
            }
        }
        for valueIndex in Set(reverts.keys).union(applies.keys).union(added.keys).union(rewrites.keys).sorted() {
            try Scrubber.checkCancellation()
            let value = values[valueIndex]
            let marks = value.marks, reverted = reverts[valueIndex] ?? [], applied = applies[valueIndex] ?? [], manual = added[valueIndex] ?? []
            // A revised stand-in, written as its place writes one; none where it cannot be (a word for a JSON number).
            var redrawn: [Int: (written: String, revision: Revision)] = [:], suspects: [Int: (written: String, revision: Revision)] = [:]
            for (index, revision) in rewrites[valueIndex] ?? [:] {
                if let written = written(revision, over: TextRanges.substring(value.text, marks[index].range), value: valueIndex, range: marks[index].range) { redrawn[index] = (written, revision) }
            }
            for (index, revision) in appliedAs[valueIndex] ?? [:] where applied.contains(index) {
                let range = value.unresolved[index].range
                if let written = written(revision, over: TextRanges.substring(value.text, range), value: valueIndex, range: range) { suspects[index] = (written, revision) }
            }
            // Each edit, in order: a stand-in taken back to its original, a suspect given its stand-in,
            // a stand-in written again as a person revised it, or a value marked by hand.
            var edits: [(range: Range<Int>, value: String, made: Mark?)] = reverted.map { (marks[$0].range, marks[$0].original ?? "", nil) }
            edits += applied.map { index in
                let suspect = value.unresolved[index], revised = suspects[index]
                return (suspect.range, revised?.written ?? value.proposals[index], Mark(range: suspect.range, entity: revised?.revision.entity ?? suspect.entity, original: suspect.original, confidence: suspect.confidence, doubt: suspect.doubt))
            }
            edits += redrawn.map { index, made in
                let old = marks[index]
                return (old.range, made.written, Mark(range: old.range, entity: made.revision.entity, original: old.original, confidence: old.confidence, doubt: old.doubt))
            }
            edits += manual.map { ($0.range, $0.value, Mark(range: $0.range, entity: $0.entity, original: $0.original, confidence: 1, byHand: true)) }
            edits.sort { $0.range.lowerBound < $1.range.lowerBound }
            for index in reverted { changed[marks[index].entity, default: 0] -= 1 }
            for index in applied { changed[suspects[index]?.revision.entity ?? value.unresolved[index].entity, default: 0] += 1 }
            for (index, made) in redrawn where made.revision.entity != marks[index].entity {
                changed[marks[index].entity, default: 0] -= 1
                changed[made.revision.entity, default: 0] += 1
            }
            for place in manual { changed[place.entity, default: 0] += 1 }
            let plain = edits.map { (range: $0.range, value: $0.value) }
            let (text, placed) = TextRanges.apply(plain, to: value.text)
            var kept = TextRanges.shift(marks.indices.filter { !reverted.contains($0) && redrawn[$0] == nil }.map { marks[$0] }, by: plain)
            for (range, edit) in zip(placed, edits) {
                if let made = edit.made { kept.append(made.moved(to: range)) }
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
        result.marked = marks.isEmpty ? nil : marks
        result.edited = edits.isEmpty ? nil : edits
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
    /// applied to the scrub as first made, so choices can be changed and
    /// applied again. Values marked by hand stay marked.
    public func applying(_ choices: Choices) throws -> ScrubResult {
        try applying(choices, marks: marks)
    }
    /// This result with the findings in `skipped` left as written everywhere,
    /// every other value left as written replaced with its stand-in, and
    /// every other stand-in unchanged.
    public func skipping(_ skipped: Set<Finding.ID>) throws -> ScrubResult {
        try applying(Choices(left: skipped))
    }
}

// MARK: Marked by hand

extension Review {
    /// What marking reads: every value's text joined once, so a marked value
    /// is found in a 40,000-row file with one search rather than one a value.
    struct Marking {
        let joined: NSString
        /// Where each value starts in `joined`; values are joined with a NUL, which no search crosses.
        let starts: [Int]
        /// The findings by their stand-in, in lowercase.
        let byStandIn: [String: [Int]]
        /// The findings' originals, in lowercase: written back where a person kept them.
        let originals: Set<String>
        /// The stand-ins and suspects of each value, in order, which a mark never overlaps.
        var taken: [Int: [Range<Int>]] = [:]
        /// Where each mark stands, by the mark and the replacement typed for it, if any.
        var located: [Locating: Located] = [:]
        /// The findings' values and parts, read as the leak gate reads them.
        var known: LeakGate?
        /// The last marks shown as findings, which every redraw of the result asks for.
        var shown: (marks: Marks, edits: Edits, findings: [Finding])?
        /// The last edits read as revisions, which every redraw and pick asks for, and
        /// the findings whose revision cannot be written (see `revisions`).
        var revised: (edits: Edits, revisions: [Finding.ID: Revision], byStandIn: [String: [Finding.ID]], blocked: Set<Finding.ID>)?
        /// The findings of each value as it reads (see `sameValues`).
        var sameValues: [String: [Finding.ID]]?
        /// Every original found as it reads, for checking what an edit writes (see `held`).
        var readable: Readable?
        /// The values as they read where that differs from how they are written, built on first use.
        var readings: Readings?
        /// Each value's link parts, read once a mark stands in the value.
        var links: [Int: [URLs.Component]] = [:]
    }
    /// The values' texts as a reader reads them where that differs from how
    /// they are written, joined as `Marking.joined` is: a mark is found there
    /// too, so "Quill<em>mere</em>", "?depot=%51uillmere" and
    /// "?depot=%51uill%E2%80%8Bmere" are Quillmere.
    struct Readings {
        let joined: NSString
        let starts: [Int]
        let readings: [Reading]
    }
    /// One value's text as it reads: without hidden characters, in-word
    /// markup and the joints between an XML element's pieces (see `Visible`),
    /// or one part of a link percent-decoded and without hidden characters (see `URLs.reading`).
    struct Reading {
        let value: Int
        /// For each UTF-16 unit of the reading, the range of the value's text it is read from.
        let sources: [Range<Int>]
        /// The part of a link it is, which says how a stand-in is written there; nil for the visible text.
        let part: URLPart?
    }
    typealias Place = (value: Int, range: Range<Int>, written: String, entity: String)
    /// A mark, and the replacement typed for it, if any: what a mark's places are found by.
    struct Locating: Hashable {
        let entry: Marks.Entry
        let typed: String?
    }
    /// Where one marked value stands, and the stand-in it takes.
    struct Located {
        let standIn: String
        /// Each place, in the order met: the value, the range in its text as
        /// first made, the stand-in written as the place is, and its kind.
        let places: [Place]
        /// Every way its stand-in is written, in lowercase.
        let written: Set<String>
    }

    /// A marked value is a finding with a negative id, and its places too, so none meets a finding's.
    static func findingID(_ entry: Marks.Entry) -> Finding.ID { -(entry.id + 1) }
    static func placeID(_ entry: Marks.Entry, _ index: Int) -> Occurrence.ID { -(((entry.id + 1) << 32) + index) }

    func prepare() {
        lock.lock()
        defer { lock.unlock() }
        _ = try? prepared()
    }

    /// The marking state, built on first use. Every caller holds the lock.
    func prepared() throws -> Marking {
        if let marking { return marking }
        let joined = NSMutableString()
        var starts: [Int] = []
        starts.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 4096) { try Scrubber.checkCancellation() }
            starts.append(joined.length)
            joined.append(value.text)
            joined.append("\u{0}")
        }
        var byStandIn: [String: [Int]] = [:]
        for (index, finding) in findings.enumerated() { byStandIn[finding.standIn.lowercased(), default: []].append(index) }
        let made = Marking(joined: joined.copy() as? NSString ?? joined, starts: starts, byStandIn: byStandIn, originals: Set(findings.map { $0.original.lowercased() }))
        marking = made
        return made
    }

    /// The value `offset` in the joined text falls in.
    private func value(at offset: Int, in marking: Marking) -> Int { Self.piece(at: offset, starts: marking.starts) }

    /// The piece of a joined text, by where each starts, that `offset` falls in.
    private static func piece(at offset: Int, starts: [Int]) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    /// The parts of the links in a value, read once. Every caller holds the lock.
    func links(_ value: Int) -> [URLs.Component] {
        if let known = marking?.links[value] { return known }
        let found = URLs.components(in: values[value].text)
        marking?.links[value] = found
        return found
    }

    /// The readings of every value that reads otherwise than it is written,
    /// built on first use. Every caller holds the lock.
    private func readings() throws -> Readings {
        if let known = marking?.readings { return known }
        let joined = NSMutableString()
        var starts: [Int] = [], readings: [Reading] = []
        func add(_ text: String, value: Int, sources: [Range<Int>], part: URLPart?) {
            starts.append(joined.length)
            joined.append(text)
            joined.append("\u{0}")
            readings.append(Reading(value: value, sources: sources, part: part))
        }
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 4096) { try Scrubber.checkCancellation() }
            if let view = Visible(value.text) {
                add(view.clean, value: index, sources: (0..<(view.clean as NSString).length).map { view.raw($0..<($0 + 1)) }, part: nil)
            }
            // Only a percent sign or a plus reads otherwise in a link.
            guard value.text.contains("%") || value.text.contains("+") else { continue }
            for component in URLs.components(in: value.text) {
                guard let read = URLs.reading(TextRanges.substring(value.text, component.range), component.part) else { continue }
                let offset = component.range.lowerBound
                add(read.text, value: index, sources: read.sources.map { ($0.lowerBound + offset)..<($0.upperBound + offset) }, part: component.part)
            }
        }
        let made = Readings(joined: joined.copy() as? NSString ?? joined, starts: starts, readings: readings)
        marking?.readings = made
        return made
    }

    private func taken(_ value: Int) -> [Range<Int>] {
        if let known = marking?.taken[value] { return known }
        let ranges = (values[value].marks.map(\.range) + values[value].unresolved.map(\.range)).sorted { $0.lowerBound < $1.lowerBound }
        marking?.taken[value] = ranges
        return ranges
    }

    /// The text a selection stands on, as the values hold it: whole when a
    /// value holds it (or it is an original a person kept), or else line by
    /// line, each without the markup around it (a JSON key, an XML tag, the
    /// quotes and commas between them).
    /// A key and its string value, either end's quote possibly cut by the selection.
    private static let stringValue = TextPattern(#""?[^",{}\[\]]*"\s*:\s*"((?:[^"\\]|\\.)*)(?:"|$)"#)
    func candidates(_ text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let marking = try? prepared() else { return [] }
        func held(_ candidate: String) -> Bool {
            !candidate.isEmpty && (marking.originals.contains(candidate.lowercased()) || marking.joined.range(of: candidate).location != NSNotFound)
        }
        if held(text) { return [text] }
        // A value written with JSON's escapes ("Qz\\u0061x") is the value it decodes to.
        func decoded(_ written: String) -> String? {
            guard written.contains("\\"), let value = try? JSONSerialization.jsonObject(with: Data(("\"" + written + "\"").utf8), options: [.fragmentsAllowed]) as? String else { return nil }
            return value
        }
        if let plain = decoded(text), held(plain) { return [plain] }
        var found: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            // JSON written on one line holds several values: each string a key holds is one.
            if line.contains("\":") {
                for match in TextRanges.matches(Self.stringValue, in: String(line)) where match.numberOfRanges > 1 {
                    let written = ((String(line) as NSString).substring(with: match.range(at: 1)) as String).trimmingCharacters(in: .whitespaces)
                    let candidate = decoded(written) ?? written
                    if held(candidate), !found.contains(candidate) { found.append(candidate) }
                }
            }
            var piece = String(line).replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            if let key = piece.range(of: #"^\s*"?[^"]*"\s*:\s*"#, options: .regularExpression) { piece.removeSubrange(key) }
            let ns = piece as NSString
            let snapped = ScrubResult.snapped(ns, 0..<ns.length)
            let candidate = ns.substring(with: NSRange(location: snapped.lowerBound, length: snapped.count))
            if held(candidate), !found.contains(candidate) { found.append(candidate) }
        }
        return found
    }

    /// Where a selection of `text` stands in the values: the first place it
    /// is written in a link's `part`, or with `part` nil, the first place it
    /// is written outside any link. Nil where it stands nowhere so.
    func place(of text: String, in part: URLPart?) -> (value: Int, range: Range<Int>)? {
        guard !text.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let length = (text as NSString).length
        for (index, value) in values.enumerated() where value.text.contains(text) {
            let ns = value.text as NSString
            var start = 0
            while start < ns.length {
                let found = ns.range(of: text, range: NSRange(location: start, length: ns.length - start))
                if found.location == NSNotFound { break }
                let range = found.location..<(found.location + length)
                if links(index).first(where: { $0.range.lowerBound <= range.lowerBound && range.upperBound <= $0.range.upperBound })?.part == part { return (index, range) }
                start = found.location + 1
            }
        }
        return nil
    }

    /// The value a selection is, as a reader reads it: "%51uillmere" or
    /// "Quill%6Dere" in a link is Quillmere, "Odalys+Ferriter" in a query is
    /// Odalys Ferriter, and "Quill\u{200B}mere" or "Quill<em>mere</em>" is
    /// Quillmere. A mark is made of it, so it reaches the value in every form
    /// (see `locate`). Decoded as the link readers decode (see
    /// `URLs.reading`), and only where the place selected, `location` (a
    /// value and a range in its text), sits in a link's part: "C++" or "50%"
    /// in prose is written as it reads, and so is "KX+4471" selected in prose
    /// though a link writes it too. Without a place, nothing is decoded.
    func identity(_ text: String, at location: (value: Int, range: Range<Int>)? = nil) -> String {
        var read = text
        if let location, text.contains("%") || text.contains("+") {
            lock.lock()
            defer { lock.unlock() }
            if values.indices.contains(location.value),
               let component = links(location.value).first(where: { $0.range.lowerBound <= location.range.lowerBound && location.range.upperBound <= $0.range.upperBound }),
               let decoded = URLs.reading(text, component.part) {
                read = decoded.text
            }
        }
        let plain = Visible.plain(read).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? text : plain
    }

    /// The findings and marks whose stand-in is `standIn`, as written anywhere
    /// once `edits` revise them: for a finding, every finding of the same original.
    func owners(ofStandIn standIn: String, marks: Marks, edits: Edits = Edits()) -> (findings: [Finding], entries: [Marks.Entry]) {
        lock.lock()
        defer { lock.unlock() }
        guard let marking = try? prepared(), let revisions = try? revisions(edits) else { return ([], []) }
        var owned: [Finding] = []
        let lowered = standIn.lowercased()
        // A revised finding is no longer written with its stand-in as made.
        let made = (marking.byStandIn[lowered] ?? []).filter { revisions[$0] == nil }
        var written = made + (self.marking?.revised?.byStandIn[lowered] ?? [])
        // An XML name writes a stand-in squeezed ("Jane Roe" as <JaneRoe>): there it is still its finding's.
        func squeezedTo(_ index: Int) -> Bool { Self.squeezed(revisions[index]?.standIn ?? findings[index].standIn).lowercased() == lowered }
        if !squeezed.isEmpty, Self.squeezed(standIn) == standIn {
            let known = Set(written)
            written += findings.indices.filter { !known.contains($0) && squeezedTo($0) }
        }
        for index in written {
            let finding = findings[index]
            let current = revisions[index]?.standIn ?? finding.standIn
            guard Self.matchKey(current, entity: finding.entity) == Self.matchKey(standIn, entity: finding.entity) || !squeezed.isEmpty && squeezedTo(index) else { continue }
            // The same value as it reads, plainly or inside a link, whatever kind it was read as,
            // and the same person's: another person's "Odalys" is kept or edited on her own.
            let read = Self.read(finding.original), key = Self.matchKey(read, entity: finding.entity)
            let groups = sameValues()
            var same: [Finding.ID] = []
            for entity in Set(findings.map(\.entity)).sorted() {
                for id in groups[Self.matchKey(read, entity: entity)] ?? [] where findings[id].entity == entity && Self.matchKey(Self.read(findings[id].original), entity: entity) == key { same.append(id) }
            }
            for id in same.sorted() where !owned.contains(where: { $0.id == id }) && sharesValue(index, id, among: same) { owned.append(findings[id]) }
        }
        let entries = marks.entries.filter { entry in (try? locate(entry, as: edits.replacements[Self.findingID(entry)]))?.written.contains(lowered) == true }
        return (owned, entries)
    }

    /// Each marked value as a finding, with the places it takes and the
    /// stand-in `edits` give it.
    func marked(_ marks: Marks, edits: Edits = Edits()) -> [Finding] {
        lock.lock()
        defer { lock.unlock() }
        if let shown = marking?.shown, shown.marks == marks, shown.edits == edits { return shown.findings }
        guard let placed = try? placements(marks, edits: edits) else { return [] }
        var bridged: [Int: NSString] = [:]
        let made = placed.map { entry, places in
            var excerpts: [Excerpt] = []
            let occurrences = places.map { index, place -> Occurrence in
                let ns = bridged[place.value] ?? values[place.value].text as NSString
                bridged[place.value] = ns
                let excerpt = Self.excerpt(ns, place.range, standIn: place.written)
                if excerpts.count < 3, !excerpts.contains(excerpt) { excerpts.append(excerpt) }
                return Occurrence(id: Self.placeID(entry, index), record: records.indices.contains(place.value) ? records[place.value] : nil, confidence: 1, excerpt: excerpt)
            }
            let standIn = (try? locate(entry, as: edits.replacements[Self.findingID(entry)]))?.standIn ?? ""
            return Finding(id: Self.findingID(entry), entity: entry.entity, original: entry.text, standIn: standIn, confidence: 1, places: occurrences, excerpts: excerpts, suspected: false, doubt: nil)
        }
        marking?.shown = (marks, edits, made)
        return made
    }

    /// Each mark's places with their index among all it found, without those
    /// an earlier mark took: marks apply in the order made, so the same marks
    /// place the same way whatever choices are made. A mark `edits` give a
    /// typed replacement is written with it.
    private func placements(_ marks: Marks, edits: Edits = Edits()) throws -> [(Marks.Entry, [(Int, Place)])] {
        guard !marks.isEmpty else { return [] }
        var claimed: [Int: [Range<Int>]] = [:]
        var result: [(Marks.Entry, [(Int, Place)])] = []
        for entry in marks.entries {
            let located = try locate(entry, as: edits.replacements[Self.findingID(entry)])
            let kept = located.places.enumerated().filter { _, place in !(claimed[place.value] ?? []).contains { $0.overlaps(place.range) } }
            for (_, place) in kept { claimed[place.value, default: []].append(place.range) }
            result.append((entry, kept.map { ($0.offset, $0.element) }))
        }
        return result
    }

    /// Every place a marked value stands, and its variants: the value in any
    /// case, a name with its initial or last name first, and what the leak
    /// gate reads as written from it (a name's part alone or inside a handle,
    /// an email's local part, a number with other separators). None overlaps
    /// a stand-in or a suspect, which their own choices decide. A replacement
    /// typed for the mark is its stand-in, and its variants follow it.
    func locate(_ entry: Marks.Entry, as typed: String? = nil) throws -> Located {
        let marking = try prepared()
        let key = Locating(entry: entry, typed: typed)
        if let known = marking.located[key] { return known }
        let standIn = try typed ?? self.standIn(for: entry.text, entity: entry.entity)
        let joined = marking.joined
        let caseless = !Self.caseSensitive.contains(entry.entity)
        var found: [(range: Range<Int>, written: String, entity: String, encoded: Bool)] = []
        // Found as the value was first marked (its `variants` kind, with that kind's own stand-in), so a
        // replacement typed for it or a kind changed reaches every place the mark did. Each variant is
        // written with this stand-in where it takes one of that shape, and otherwise with the whole of it.
        let reshaped = typed != nil || entry.variants != entry.entity
        let forms = Self.forms(entry.text, entity: entry.variants, standIn: standIn, whole: !Self.names.contains(entry.entity))
        var gate = LeakGate(), writer = LeakGate()
        gate.add([Replacement(original: entry.text, fake: reshaped ? try self.standIn(for: entry.text, entity: entry.variants) : standIn, entity: entry.variants)])
        if reshaped { writer.add([Replacement(original: entry.text, fake: standIn, entity: entry.entity)]) }
        func reshape(_ leak: LeakGate.Leak, in text: NSString, written: [Range<Int>: LeakGate.Leak]) -> (fake: String, entity: String) {
            if let made = written[leak.range], let fake = made.fake { return (fake, made.entity) }
            let read = text.substring(with: NSRange(location: leak.range.lowerBound, length: leak.range.count))
            let entity = Self.names.contains(entry.entity) ? leak.entity : entry.entity
            let fake = leak.entity == "USERNAME" ? Self.handle(standIn) : standIn
            return (caseless ? LeakGate.cased(fake, like: read) : fake, entity)
        }
        /// Each place in `text` the value reads, in any of its forms or as the
        /// leak gate reads a variant of it (a name's part alone or in a handle),
        /// with its stand-in cased as the place reads.
        func matches(in text: NSString) throws -> [(range: Range<Int>, fake: String, entity: String)] {
            var hits: [(range: Range<Int>, fake: String, entity: String)] = []
            var count = 0
            for (literal, fake) in forms {
                var start = 0
                while start < text.length {
                    count += 1
                    if count.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
                    let match = text.range(of: literal, options: caseless ? [.caseInsensitive] : [], range: NSRange(location: start, length: text.length - start))
                    if match.location == NSNotFound { break }
                    start = NSMaxRange(match)
                    // "Ann" inside "annual" is no one.
                    guard !TextRanges.joinsWord(text, at: match.location, underscore: false), !TextRanges.joinsWord(text, at: NSMaxRange(match), underscore: false) else { continue }
                    let read = text.substring(with: match)
                    hits.append((match.location..<NSMaxRange(match), read == literal || !caseless ? fake : LeakGate.cased(fake, like: read), entry.entity))
                }
            }
            if !gate.isEmpty {
                let leaks = gate.scan(text as String, suspects: false).leaks
                guard reshaped else {
                    for leak in leaks { if let fake = leak.fake { hits.append((leak.range, fake, leak.entity)) } }
                    return hits
                }
                var written: [Range<Int>: LeakGate.Leak] = [:]
                if !writer.isEmpty, !leaks.isEmpty { for leak in writer.scan(text as String, suspects: false).leaks { written[leak.range] = leak } }
                for leak in leaks where leak.fake != nil {
                    let made = reshape(leak, in: text, written: written)
                    hits.append((leak.range, made.fake, made.entity))
                }
            }
            return hits
        }
        for hit in try matches(in: joined) { found.append((hit.range, hit.fake, hit.entity, false)) }
        // Where it is written otherwise than it reads, split by markup or a hidden
        // character, or encoded in a link: found as plain text is, every form and
        // variant, and its stand-in written as the place is, with the markup kept
        // or encoded as the link needs.
        let readings = try self.readings()
        if readings.joined.length > 0 {
            for hit in try matches(in: readings.joined) {
                let index = Self.piece(at: hit.range.lowerBound, starts: readings.starts)
                let reading = readings.readings[index], offset = readings.starts[index]
                guard hit.range.upperBound - offset <= reading.sources.count else { continue }
                let source = reading.sources[hit.range.lowerBound - offset].lowerBound..<reading.sources[hit.range.upperBound - offset - 1].upperBound
                let written = (values[reading.value].text as NSString).substring(with: NSRange(location: source.lowerBound, length: source.count))
                // Written as it reads, the search above found it.
                guard written != readings.joined.substring(with: NSRange(location: hit.range.lowerBound, length: hit.range.count)) else { continue }
                let rewritten = reading.part.map { URLs.encode(hit.fake, like: written, $0) } ?? Visible.rewrite(written, with: hit.fake)
                let at = marking.starts[reading.value]
                found.append(((source.lowerBound + at)..<(source.upperBound + at), rewritten, hit.entity, reading.part != nil))
            }
        }
        try Scrubber.checkCancellation()
        // The longest reading of a place wins; the same place read twice is one.
        found.sort { $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.count > $1.range.count }
        var places: [Place] = []
        var end = 0
        for item in found where item.range.lowerBound >= end {
            let value = self.value(at: item.range.lowerBound, in: marking)
            let local = (item.range.lowerBound - marking.starts[value])..<(item.range.upperBound - marking.starts[value])
            guard local.upperBound <= (values[value].text as NSString).length, !taken(value).contains(where: { $0.overlaps(local) }) else { continue }
            // A JSON number stays a number.
            if numeric.contains(value), !Self.isJSONNumber(TextRanges.replace(values[value].text, local, with: item.written)) { continue }
            // Inside a link's part, written as the link writes it ("near=Quillmere+North" keeps a valid link).
            var written = item.written
            if !item.encoded, let component = links(value).first(where: { $0.range.lowerBound <= local.lowerBound && local.upperBound <= $0.range.upperBound }) {
                written = URLs.encode(written, like: joined.substring(with: NSRange(location: item.range.lowerBound, length: item.range.count)), component.part)
            }
            places.append((value, local, written, item.entity))
            end = item.range.upperBound
        }
        let located = Located(standIn: standIn, places: places, written: Set([standIn.lowercased()] + places.map { $0.written.lowercased() }))
        self.marking?.located[key] = located
        return located
    }

    static let names: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME"]

    /// A marked value and the ways a person's name is also written, each with
    /// its stand-in written the same way. The leak gate hunts a name's handles
    /// only when no part is a word; a person who marked the name has said it
    /// is one, so its handles are looked for here too, each as a whole word.
    /// A stand-in of two words or more is written in each form by its first
    /// and last words ("J. Roe", "jroe"). One of a single word (a first name
    /// typed for a full name), or `whole`, for a value now read as another
    /// kind, is written whole in each: "h. lisk" and "Lisk, Harrowgate" read
    /// "Jane", and the handles "harrowgate.lisk" and "hlisk" read "jane".
    static func forms(_ text: String, entity: String, standIn: String, whole: Bool = false) -> [(String, String)] {
        var forms = [(text, standIn)]
        guard names.contains(entity) else { return forms }
        let real = text.split(whereSeparator: \.isWhitespace).map(String.init), made = standIn.split(whereSeparator: \.isWhitespace).map(String.init)
        guard real.count >= 2, let first = real.first, let last = real.last, first.allSatisfy(\.isLetter), last.count >= 2 else { return forms }
        let initial = String(first.prefix(1))
        // "A Long" without its full stop is how "a long time" begins.
        let spaced = [initial + ". " + last, last + ", " + first, last + ", " + initial + "."] + (LeakGate.usable(last) ? [initial + " " + last] : [])
        let (f, l) = (first.lowercased(), last.lowercased().filter(\.isLetter))
        let joined = [f + "." + l, f + "_" + l, f + l, initial.lowercased() + l, l + initial.lowercased(), l + f]
        guard !whole, made.count >= 2, let fakeFirst = made.first, let fakeLast = made.last else {
            return forms + spaced.map { ($0, standIn) } + joined.map { ($0, handle(standIn)) }
        }
        let fakeInitial = String(fakeFirst.prefix(1))
        forms += zip(spaced, [fakeInitial + ". " + fakeLast, fakeLast + ", " + fakeFirst, fakeLast + ", " + fakeInitial + ".", fakeInitial + " " + fakeLast]).map { ($0, $1) }
        let (ff, fl) = (fakeFirst.lowercased().filter(\.isLetter), fakeLast.lowercased().filter(\.isLetter))
        forms += zip(joined, [ff + "." + fl, ff + "_" + fl, ff + fl, String(ff.prefix(1)) + fl, fl + String(ff.prefix(1)), fl + ff]).map { ($0, $1) }
        return forms
    }

    /// A stand-in written as a handle is: an email's local part, or the
    /// letters and digits of a name or a word, in lowercase ("Corvane
    /// Holdings" is "corvaneholdings").
    static func handle(_ standIn: String) -> String {
        var value = standIn
        if let at = value.firstIndex(of: "@"), at != value.startIndex { value = String(value[..<at]) }
        let made = fold(value).filter { $0.isLetter || $0.isNumber || "._-".contains($0) }.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return made.isEmpty ? standIn : made
    }

    /// The stand-in a marked value takes. One Scrub already gave it, or a
    /// value it is part of, is kept, so a marked surname matches the full
    /// name's stand-in. Otherwise one is drawn as any other, from the scrub's
    /// salt and the value alone, so marks made in any order draw the same.
    /// `fresh` for a value changed to a new kind: its own stand-in as the old
    /// kind is no part of it, and it draws one of the new kind.
    func standIn(for text: String, entity: String, fresh: Bool = false) throws -> String {
        let key = Self.matchKey(text, entity: entity)
        func kin(_ other: String) -> Bool { other == entity || Self.names.contains(other) && Self.names.contains(entity) }
        if let same = findings.first(where: { kin($0.entity) && Self.matchKey($0.original, entity: $0.entity) == key && $0.standIn != $0.original }) {
            return text == same.original || Self.caseSensitive.contains(entity) ? same.standIn : LeakGate.cased(same.standIn, like: text)
        }
        if marking?.known == nil {
            var gate = LeakGate()
            gate.add(findings.filter { !$0.suspected }.map { Replacement(original: $0.original, fake: $0.standIn, entity: $0.entity) })
            marking?.known = gate
        }
        let length = (text as NSString).length
        if let leak = marking?.known?.scan(text, suspects: false).leaks.first(where: { $0.range == 0..<length && !(fresh && Self.matchKey($0.source, entity: entity) == key) }), let fake = leak.fake { return fake }
        // A part of a name too short or too common for the gate ("Rose"): the same part of the name's stand-in.
        if Self.names.contains(entity), !text.contains(where: \.isWhitespace) {
            for finding in findings where Self.names.contains(finding.entity) && !finding.suspected {
                let real = finding.original.split(whereSeparator: \.isWhitespace), made = finding.standIn.split(whereSeparator: \.isWhitespace)
                guard real.count >= 2, real.count == made.count, let index = real.firstIndex(where: { $0.lowercased() == key }) else { continue }
                return LeakGate.cased(String(made[index]), like: text)
            }
        }
        let drawn = StandIns(rng: SeededGenerator(seed: salt ^ Self.hash(entity + "\u{0}" + key)))
        for (index, finding) in findings.enumerated() {
            if index.isMultiple(of: 4096) { try Scrubber.checkCancellation() }
            drawn.avoid(finding.original)
        }
        let used = Set(findings.map { $0.standIn.lowercased() })
        var fake = text
        for _ in 0..<8 {
            fake = drawn.replace(entity, text)
            if fake.lowercased() != text.lowercased() && !used.contains(fake.lowercased()) { break }
        }
        // A kind that keeps the value as written here still never leaves it: it changes as an ID does, character by character.
        if fake.lowercased() == text.lowercased() { fake = drawn.replace("ID_NUMBER", text) }
        // A part Scrub already replaced on its own keeps its stand-in: "Ysolde Varrick"
        // beside "Varrick" → "Ruth" is someone Ruth.
        let real = text.split(whereSeparator: \.isWhitespace), made = fake.split(whereSeparator: \.isWhitespace)
        if Self.names.contains(entity), real.count >= 2, real.count == made.count {
            let parts = made.indices.map { index in
                findings.first { Self.names.contains($0.entity) && !$0.suspected && $0.original.lowercased() == real[index].lowercased() && !$0.standIn.contains(where: \.isWhitespace) }
                    .map { LeakGate.cased($0.standIn, like: String(real[index])) } ?? String(made[index])
            }
            fake = parts.joined(separator: " ")
        }
        return fake
    }

    /// FNV-1a over the value's UTF-8: the same on every run, unlike `Hasher`.
    private static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }
}
