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
    private let records: [Int?]
    /// Values written as bare numbers (a JSON number), which only a number may replace.
    private let numeric: Set<Int>
    /// Mixed into every stand-in drawn for a mark: the scrub's seed when it
    /// had one, so the same scrub and marks write the same bytes.
    var salt: UInt64 = 0
    /// What marking reads, built once on first use (see `Marking`).
    private var marking: Marking?

    /// Secrets, keys and IDs are told apart by case; names, places and emails are not.
    private static let caseSensitive: Set<String> = ["SECRET", "ID_NUMBER", "CRYPTO", "US_DRIVER_LICENSE", "US_PASSPORT", "MEDICAL_LICENSE", "IBAN_CODE"]
    static func matchKey(_ text: String, entity: String) -> String { caseSensitive.contains(entity) ? text : text.lowercased() }

    /// `records` holds the record each value sits in, when the file has records.
    init(values: [DocumentValue], counts: [String: Int], records: [Int?] = [], numeric: Set<Int> = [], render: @escaping ([DocumentValue], [String: Int]) throws -> ScrubResult) {
        self.values = values
        self.counts = counts
        self.render = render
        self.records = records
        self.numeric = numeric
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
    /// each value in `marks` replaced where it stands unless a choice leaves
    /// it, and every other stand-in as it was.
    func applying(_ choices: Choices, marks: Marks = Marks()) throws -> ScrubResult {
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
        // Marked by hand: each place a choice does not leave.
        var added: [Int: [(range: Range<Int>, value: String, entity: String, original: String)]] = [:]
        for (entry, places) in try placements(marks) {
            let finding = Self.findingID(entry)
            for (index, place) in places where !(choices.places[Self.placeID(entry, index)] ?? choices.left.contains(finding)) {
                let original = (values[place.value].text as NSString).substring(with: NSRange(location: place.range.lowerBound, length: place.range.count))
                added[place.value, default: []].append((place.range, place.written, place.entity, original))
            }
        }
        for valueIndex in Set(reverts.keys).union(applies.keys).union(added.keys).sorted() {
            try Scrubber.checkCancellation()
            let value = values[valueIndex]
            let marks = value.marks, reverted = reverts[valueIndex] ?? [], applied = applies[valueIndex] ?? [], manual = added[valueIndex] ?? []
            // Each edit, in order: a stand-in taken back to its original, a suspect given its stand-in, or a value marked by hand.
            var edits: [(range: Range<Int>, value: String, made: Mark?)] = reverted.map { (marks[$0].range, marks[$0].original ?? "", nil) }
            edits += applied.map { index in
                let suspect = value.unresolved[index]
                return (suspect.range, value.proposals[index], Mark(range: suspect.range, entity: suspect.entity, original: suspect.original, confidence: suspect.confidence, doubt: suspect.doubt))
            }
            edits += manual.map { ($0.range, $0.value, Mark(range: $0.range, entity: $0.entity, original: $0.original, confidence: 1)) }
            edits.sort { $0.range.lowerBound < $1.range.lowerBound }
            for index in reverted { changed[marks[index].entity, default: 0] -= 1 }
            for index in applied { changed[value.unresolved[index].entity, default: 0] += 1 }
            for place in manual { changed[place.entity, default: 0] += 1 }
            let plain = edits.map { (range: $0.range, value: $0.value) }
            let (text, placed) = TextRanges.apply(plain, to: value.text)
            var kept = TextRanges.shift(marks.indices.filter { !reverted.contains($0) }.map { marks[$0] }, by: plain)
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
        var located: [Marks.Entry: Located] = [:]
        /// The findings' values and parts, read as the leak gate reads them.
        var known: LeakGate?
        /// The last marks shown as findings, which every redraw of the result asks for.
        var shown: (marks: Marks, findings: [Finding])?
    }
    typealias Place = (value: Int, range: Range<Int>, written: String, entity: String)
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
    private func prepared() throws -> Marking {
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
    private func value(at offset: Int, in marking: Marking) -> Int {
        var low = 0, high = marking.starts.count
        while low < high {
            let middle = (low + high) / 2
            if marking.starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
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
    func candidates(_ text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let marking = try? prepared() else { return [] }
        func held(_ candidate: String) -> Bool {
            !candidate.isEmpty && (marking.originals.contains(candidate.lowercased()) || marking.joined.range(of: candidate).location != NSNotFound)
        }
        if held(text) { return [text] }
        var found: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var piece = String(line).replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            if let key = piece.range(of: #"^\s*"?[^"]*"\s*:\s*"#, options: .regularExpression) { piece.removeSubrange(key) }
            let ns = piece as NSString
            let snapped = ScrubResult.snapped(ns, 0..<ns.length)
            let candidate = ns.substring(with: NSRange(location: snapped.lowerBound, length: snapped.count))
            if held(candidate), !found.contains(candidate) { found.append(candidate) }
        }
        return found
    }

    /// The findings and marks whose stand-in is `standIn`, as written anywhere:
    /// for a finding, every finding of the same original.
    func owners(ofStandIn standIn: String, marks: Marks) -> (findings: [Finding], entries: [Marks.Entry]) {
        lock.lock()
        defer { lock.unlock() }
        guard let marking = try? prepared() else { return ([], []) }
        var owned: [Finding] = []
        for index in marking.byStandIn[standIn.lowercased()] ?? [] {
            let finding = findings[index]
            guard Self.matchKey(finding.standIn, entity: finding.entity) == Self.matchKey(standIn, entity: finding.entity) else { continue }
            let key = Self.matchKey(finding.original, entity: finding.entity)
            for same in findings where !owned.contains(where: { $0.id == same.id }) && Self.matchKey(same.original, entity: same.entity) == key { owned.append(same) }
        }
        let entries = marks.entries.filter { entry in (try? locate(entry))?.written.contains(standIn.lowercased()) == true }
        return (owned, entries)
    }

    /// Each marked value as a finding, with the places it takes.
    func marked(_ marks: Marks) -> [Finding] {
        lock.lock()
        defer { lock.unlock() }
        if let shown = marking?.shown, shown.marks == marks { return shown.findings }
        guard let placed = try? placements(marks) else { return [] }
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
            let standIn = (try? locate(entry))?.standIn ?? ""
            return Finding(id: Self.findingID(entry), entity: entry.entity, original: entry.text, standIn: standIn, confidence: 1, places: occurrences, excerpts: excerpts, suspected: false, doubt: nil)
        }
        marking?.shown = (marks, made)
        return made
    }

    /// Each mark's places with their index among all it found, without those
    /// an earlier mark took: marks apply in the order made, so the same marks
    /// place the same way whatever choices are made.
    private func placements(_ marks: Marks) throws -> [(Marks.Entry, [(Int, Place)])] {
        guard !marks.isEmpty else { return [] }
        var claimed: [Int: [Range<Int>]] = [:]
        var result: [(Marks.Entry, [(Int, Place)])] = []
        for entry in marks.entries {
            let located = try locate(entry)
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
    /// a stand-in or a suspect, which their own choices decide.
    private func locate(_ entry: Marks.Entry) throws -> Located {
        let marking = try prepared()
        if let known = marking.located[entry] { return known }
        let standIn = try self.standIn(for: entry.text, entity: entry.entity)
        let joined = marking.joined
        let caseless = !Self.caseSensitive.contains(entry.entity)
        var found: [(range: Range<Int>, written: String, entity: String)] = []
        for (literal, fake) in Self.forms(entry.text, entity: entry.entity, standIn: standIn) {
            var start = 0
            var count = 0
            while start < joined.length {
                count += 1
                if count.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
                let match = joined.range(of: literal, options: caseless ? [.caseInsensitive] : [], range: NSRange(location: start, length: joined.length - start))
                if match.location == NSNotFound { break }
                start = NSMaxRange(match)
                let range = match.location..<NSMaxRange(match)
                // "Ann" inside "annual" is no one.
                guard !TextRanges.joinsWord(joined, at: range.lowerBound, underscore: false), !TextRanges.joinsWord(joined, at: range.upperBound, underscore: false) else { continue }
                let written = joined.substring(with: match)
                found.append((range, written == literal || !caseless ? fake : LeakGate.cased(fake, like: written), entry.entity))
            }
        }
        var gate = LeakGate()
        gate.add([Replacement(original: entry.text, fake: standIn, entity: entry.entity)])
        if !gate.isEmpty {
            for leak in gate.scan(joined as String, suspects: false).leaks {
                if let fake = leak.fake { found.append((leak.range, fake, leak.entity)) }
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
            if numeric.contains(value), !(item.written + joined.substring(with: NSRange(location: item.range.lowerBound, length: item.range.count))).allSatisfy({ $0.isASCII && $0.isNumber }) { continue }
            places.append((value, local, item.written, item.entity))
            end = item.range.upperBound
        }
        let located = Located(standIn: standIn, places: places, written: Set([standIn.lowercased()] + places.map { $0.written.lowercased() }))
        self.marking?.located[entry] = located
        return located
    }

    private static let names: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME"]

    /// A marked value and the ways a person's name is also written, each with
    /// its stand-in written the same way. The leak gate hunts a name's handles
    /// only when no part is a word; a person who marked the name has said it
    /// is one, so its handles are looked for here too, each as a whole word.
    private static func forms(_ text: String, entity: String, standIn: String) -> [(String, String)] {
        var forms = [(text, standIn)]
        guard names.contains(entity) else { return forms }
        let real = text.split(whereSeparator: \.isWhitespace).map(String.init), made = standIn.split(whereSeparator: \.isWhitespace).map(String.init)
        guard real.count >= 2, real.count == made.count, let first = real.first, let last = real.last, let fakeFirst = made.first, let fakeLast = made.last,
              first.allSatisfy(\.isLetter), last.count >= 2 else { return forms }
        let initial = String(first.prefix(1)), fakeInitial = String(fakeFirst.prefix(1))
        forms += [(initial + ". " + last, fakeInitial + ". " + fakeLast), (last + ", " + first, fakeLast + ", " + fakeFirst), (last + ", " + initial + ".", fakeLast + ", " + fakeInitial + ".")]
        // "A Long" without its full stop is how "a long time" begins.
        if LeakGate.usable(last) { forms.append((initial + " " + last, fakeInitial + " " + fakeLast)) }
        let (f, l, ff, fl) = (first.lowercased(), last.lowercased().filter(\.isLetter), fakeFirst.lowercased().filter(\.isLetter), fakeLast.lowercased().filter(\.isLetter))
        for separator in [".", "_", ""] { forms.append((f + separator + l, ff + separator + fl)) }
        forms += [(initial.lowercased() + l, String(ff.prefix(1)) + fl), (l + initial.lowercased(), fl + String(ff.prefix(1))), (l + f, fl + ff)]
        return forms
    }

    /// The stand-in a marked value takes. One Scrub already gave it, or a
    /// value it is part of, is kept, so a marked surname matches the full
    /// name's stand-in. Otherwise one is drawn as any other, from the scrub's
    /// salt and the value alone, so marks made in any order draw the same.
    private func standIn(for text: String, entity: String) throws -> String {
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
        if let leak = marking?.known?.scan(text, suspects: false).leaks.first(where: { $0.range == 0..<length }), let fake = leak.fake { return fake }
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
