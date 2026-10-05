import Foundation

struct SensitiveOriginal {
    let original: String
    let entity: String
}

struct Replacement {
    let original: String
    let fake: String
    let entity: String
}

enum Correction {
    static func run(_ initial: String, marks: [Mark], job: Job) throws -> (String, [Mark], [Mark]) {
        var gate = LeakGate()
        gate.add(marks, in: initial)
        return try run(initial, marks: marks, job: job, matcher: OriginalMatcher(job), gazetteer: GazetteerMatcher(job.gazetteer, nameParts: job.nameParts, cuedParts: job.cuedParts), gate: gate)
    }
    /// Replaces what is left of the originals in `initial`, up to `passes`
    /// times, until a pass finds nothing. What is still there after the last
    /// pass, and what the leak gate only suspects, comes back as unresolved:
    /// marks over text left as written, with the original and a confidence
    /// below `Finding.reviewBelow`, so review asks about each one.
    static func run(_ initial: String, marks initialMarks: [Mark], job: Job, matcher: OriginalMatcher, gazetteer: GazetteerMatcher, gate: LeakGate, passes: Int = 3, base: [Span]? = nil) throws -> (String, [Mark], [Mark]) {
        var held: [Mark] = []
        return try run(initial, marks: initialMarks, job: job, matcher: matcher, gazetteer: gazetteer, gate: gate, passes: passes, base: base, held: &held)
    }
    /// `held` marks places left as written (people the detectors doubted);
    /// they come back where they stand in the output, without any a replacement covers.
    static func run(_ initial: String, marks initialMarks: [Mark], job: Job, matcher: OriginalMatcher, gazetteer: GazetteerMatcher, gate: LeakGate, passes: Int = 3, base: [Span]? = nil, held: inout [Mark]) throws -> (String, [Mark], [Mark]) {
        var output = initial
        var marks = initialMarks
        for pass in 0..<passes {
            try Scrubber.checkCancellation()
            let found = visibleLeftovers(in: output, marks: marks, job: job, matcher: matcher, gazetteer: gazetteer, gate: gate, base: pass == 0 ? base : nil)
            let spans = Detector.resolve(found.spans)
            if spans.isEmpty { return (output, marks, unresolved(found.suspects, in: output)) }
            var fakes = Array(repeating: "", count: spans.count)
            var sources = [String?](repeating: nil, count: spans.count)
            var unclear: Set<Int> = []
            // Numbers, birth dates and what is read off them note where they sit (see `Spots`).
            let spots = spans.contains { StandIns.anchored($0.entity) } ? job.spots(output) : nil
            for (count, index) in spans.indices.reversed().enumerated() {
                if count.isMultiple(of: 64) { try Scrubber.checkCancellation() }
                let span = spans[index], original = TextRanges.substring(output, span.range)
                // A variant of a replaced value takes the stand-in its original got, written the same way.
                // What it reads as: a link's part decoded, hidden characters and in-word markup gone (see `Visible`).
                let shown = Visible.plain(span.url.map { URLs.decode(original, $0) } ?? original)
                func written(_ fake: String) -> String { span.url.map { URLs.encode(fake, like: original, $0) } ?? Visible.rewrite(original, with: fake) }
                if let leak = found.leaks[span.range], leak.entity == span.entity {
                    sources[index] = leak.source
                    if let fake = leak.fake {
                        fakes[index] = written(job.variant(shown, fake: fake, entity: leak.entity, source: leak.source))
                        continue
                    }
                }
                let local = StandIns.anchored(span.entity) ? spots?.scopes(at: span.range.lowerBound) ?? [] : []
                fakes[index] = written(job.replacement(for: span.entity, original: shown, persona: nil, local: local))
                if job.lastUnclear { unclear.insert(index) }
            }
            // An age with no birth date to follow stays as it was, unmarked, as in `Job.apply`.
            let changes = spans.indices.filter { index in
                !(fakes[index] == TextRanges.substring(output, spans[index].range) && (StandIns.derived.contains(spans[index].entity) || spans[index].entity == "TIME_ZONE"))
            }
            if changes.isEmpty { return (output, marks, unresolved(found.suspects, in: output)) }
            let edits = changes.map { (range: spans[$0].range, value: fakes[$0]) }
            let (edited, placed) = TextRanges.apply(edits, to: output)
            if !held.isEmpty { held = TextRanges.shift(held, by: edits) }
            marks = TextRanges.shift(marks, by: edits) + zip(placed, changes).map { range, index in
                let span = spans[index], original = TextRanges.substring(output, span.range)
                // As sure as the value it varies: a name only a model read stays one to ask about.
                let confidence = sources[index].flatMap { job.confidence(of: $0) } ?? job.here(span, original)
                let entity = sources[index] == nil ? job.kind(of: original, read: span.entity) : span.entity
                return unclear.contains(index) ? Mark(range: range, entity: entity, original: original, confidence: min(confidence, Doubt.unclearOwner.confidence), doubt: .unclearOwner)
                    : Mark(range: range, entity: entity, original: original, confidence: min(confidence, 1))
            }
            marks.sort { $0.range.lowerBound < $1.range.lowerBound }
            output = edited
        }
        let found = visibleLeftovers(in: output, marks: marks, job: job, matcher: matcher, gazetteer: gazetteer, gate: gate)
        // Still there after the last pass: left as written, and asked about.
        let left = Detector.resolve(found.spans).map { Span(range: $0.range, entity: $0.entity, score: LeakGate.suspectConfidence) }
        return (output, marks, unresolved(left + found.suspects, in: output))
    }

    /// Suspects as marks over the text left as written, once each, in order.
    private static func unresolved(_ suspects: [Span], in output: String) -> [Mark] {
        var seen: Set<String> = []
        return suspects.sorted { $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound < $1.range.upperBound }
            .filter { seen.insert("\($0.range.lowerBound):\($0.range.upperBound):\($0.entity)").inserted }
            .map { Mark(range: $0.range, entity: $0.entity, original: TextRanges.substring(output, $0.range), confidence: min($0.score, LeakGate.suspectConfidence)) }
    }

    /// `leftovers` read in the text as a reader sees it, mapped back onto the text as written.
    private static func visibleLeftovers(in output: String, marks: [Mark], job: Job, matcher: OriginalMatcher, gazetteer: GazetteerMatcher, gate: LeakGate, base: [Span]? = nil) -> Leftovers {
        guard let view = Visible(output) else { return leftovers(in: output, marks: marks, job: job, matcher: matcher, gazetteer: gazetteer, gate: gate, base: base) }
        let seen = leftovers(in: view.clean, marks: marks.map(view.clean), job: job, matcher: matcher, gazetteer: gazetteer, gate: gate, base: base.map { _ in [] })
        var found = Leftovers()
        found.spans = seen.spans.map(view.raw)
        found.suspects = seen.suspects.map(view.raw)
        for (range, leak) in seen.leaks { found.leaks[view.raw(range)] = LeakGate.Leak(range: view.raw(range), entity: leak.entity, fake: leak.fake, source: leak.source) }
        return found
    }

    private struct Leftovers {
        var spans: [Span] = []
        /// The variants the leak gate found, by range, with the stand-in each takes.
        var leaks: [Range<Int>: LeakGate.Leak] = [:]
        var suspects: [Span] = []
    }

    private static func leftovers(in output: String, marks: [Mark], job: Job, matcher: OriginalMatcher, gazetteer: GazetteerMatcher, gate: LeakGate, base: [Span]? = nil) -> Leftovers {
        if marks.contains(where: { $0.range == 0..<(output as NSString).length }) { return Leftovers() }
        // The name model joins words next to a stand-in into one name ("Scott
        // Hunt Called"); that adds no personal data. A pattern match running
        // past a stand-in can be the tail of a secret, so only exact containment
        // exempts it. Originals next to a stand-in are caught by the sweep below.
        // Scanning every mark per span is quadratic. With marks in start order,
        // a running maximum of their ends finds the first one that can reach
        // the span, and the scan stops at the first one starting after it.
        let ordered = zip(marks, marks.dropFirst()).allSatisfy({ $0.range.lowerBound <= $1.range.lowerBound }) ? marks : marks.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var reach: [Int] = []
        reach.reserveCapacity(ordered.count)
        for mark in ordered { reach.append(max(reach.last ?? 0, mark.range.upperBound)) }
        let ours = { (range: Range<Int>, entity: String) in
            var low = 0, high = ordered.count
            while low < high {
                let middle = (low + high) / 2
                if reach[middle] <= range.lowerBound { low = middle + 1 } else { high = middle }
            }
            var index = low
            while index < ordered.count, ordered[index].range.lowerBound < max(range.upperBound, range.lowerBound + 1) {
                let mark = ordered[index].range
                if (mark.lowerBound <= range.lowerBound && range.upperBound <= mark.upperBound)
                    || (["PERSON", "LOCATION"].contains(entity) && mark.overlaps(range))
                    // "retry 3 for Theresa Lane" ends in a stand-in surname that reads as a street.
                    || (entity == "ADDRESS" && mark.lowerBound < range.upperBound && range.upperBound <= mark.upperBound)
                    // "Estrada Quiet Weekly Summary 403" opens with a stand-in surname that reads as a road.
                    || (entity == "ADDRESS" && !StandIns.placed.contains(ordered[index].entity) && mark.lowerBound <= range.lowerBound && range.lowerBound < mark.upperBound) { return true }
                index += 1
            }
            return job.isEmitted(TextRanges.substring(output, range))
        }
        var found = Leftovers()
        found.spans.append(contentsOf: matcher.spans(in: output).filter { !ours($0.range, "") })
        let detected = base.map { job.detector.combined($0, text: output, matcher: gazetteer) }
            ?? job.detector.find(output, matcher: gazetteer, modelled: false)
        // Places the first pass found are originals, and the matcher above finds
        // them. A place detected only now was read from the stand-ins' context
        // ("Later, Larry Alvarado" makes "Later" a city) and names nothing real.
        // So is a person made of ordinary words that the tagger reads only now:
        // "Later" opening a sentence after a stand-in "Quinn Ramos" is no one,
        // and the first pass, reading the original, said so.
        found.spans.append(contentsOf: detected.filter { $0.entity != "LOCATION" && !ours($0.range, $0.entity) && !readOffStandIns($0, in: output) })
        found.spans = Links.outside(found.spans, in: output)
        // The leak gate: variants of values already replaced, which no detector
        // reads, and numbers that check themselves left as written. A pass fixes
        // a bounded number of variants, in proportion to the text; the rest are suspects.
        let gated = gate.scan(output, budget: max(256, (output as NSString).length / 8))
        let length = (output as NSString).length
        // A name that is a whole part of a link (a path segment, a query value,
        // its user) is replaced in place, encoded as the link writes it; one
        // inside a part (a host name, half a segment) is left to review rather than breaking the link.
        let linked = gated.leaks.isEmpty ? [] : Links.ranges(in: output)
        let parts = linked.isEmpty ? [] : URLs.components(in: output)
        for leak in gated.leaks where !ours(leak.range, "PERSON") {
            if Links.named.contains(leak.entity), linked.contains(where: { $0.overlaps(leak.range) }) {
                if let part = parts.first(where: { $0.range == leak.range }) {
                    found.spans.append(Span(range: leak.range, entity: leak.entity, score: 1.1, url: part.part))
                    found.leaks[leak.range] = leak
                } else {
                    found.suspects.append(Span(range: leak.range, entity: leak.entity, score: LeakGate.suspectConfidence))
                }
                continue
            }
            found.spans.append(Span(range: leak.range, entity: leak.entity, score: 1.1))
            found.leaks[leak.range] = leak
        }
        found.suspects += gated.suspects.filter { $0.range.upperBound <= length && !ours($0.range, "PERSON") }
        return found
    }

    /// A guess about a person, below the surety of a found original, made of
    /// ordinary words that are no one's first name or surname ("Later"). A
    /// name that is also a word ("Olive", "Randy") is still caught.
    static func readOffStandIns(_ span: Span, in text: String) -> Bool {
        guard span.entity == "PERSON", span.score < 0.9 else { return false }
        let words = NameShape.words(span.range, in: text)
        return !words.isEmpty && words.allSatisfy { NameLists.isOrdinary($0.bare) || NameShape.joining.contains($0.bare) }
            && !words.contains { NameLists.isFirst($0.bare) || NameLists.isSurname($0.bare) }
    }
}

struct OriginalMatcher {
    let matcher: Matcher
    let entities: [String]
    private var supplements: [(Matcher, [String])] = []

    /// Stops building once the task is cancelled; every caller checks for
    /// cancellation before its first match, so a part-built matcher is never used.
    init(_ job: Job) {
        let (literals, labels) = Self.entries(job)
        matcher = Matcher(literals, isCancelled: { Task.isCancelled })
        entities = labels
    }
    /// Whether an original is long enough to hunt through the rest of the text.
    /// A one-character one ("a" as a password) only breaks prose, and a short
    /// number (a birth day of 18) turns up in every timestamp.
    static func spreads(_ original: String, entity: String = "") -> Bool {
        // A region code ("WA", "IN", "OR") is a word everywhere else, and
        // initials, ages, coordinates and time zones only mean something where they were found.
        if ["REGION", "INITIALS", "AGE", "LAST_DIGITS", "LATITUDE", "LONGITUDE", "COORDINATES", "TIME_ZONE"].contains(entity) { return false }
        let significant = original.filter { $0.isLetter || $0.isNumber }
        return significant.count >= (significant.allSatisfy(\.isNumber) ? 5 : 2)
    }
    mutating func add(_ replacements: ArraySlice<Replacement>) {
        let originals = replacements.filter { Self.spreads($0.original, entity: $0.entity) }
        guard !originals.isEmpty else { return }
        let literals = originals.map(\.original)
        let labels = originals.map(\.entity)
        supplements.append((Matcher(literals, isCancelled: { Task.isCancelled }), labels))
    }
    private static func entries(_ job: Job) -> ([String], [String]) {
        var literals: [String] = []
        var labels: [String] = []
        var seen: [FoldHash: Int] = [:]
        var collisions: [FoldHash: [Int]] = [:]
        func add(_ candidate: SensitiveOriginal) {
            guard spreads(candidate.original, entity: candidate.entity) else { return }
            let folded = Matcher.fold(candidate.original)
            let key = FoldHash(folded)
            if let first = seen[key] {
                if Matcher.fold(literals[first]) == folded || collisions[key]?.contains(where: { Matcher.fold(literals[$0]) == folded }) == true { return }
                collisions[key, default: []].append(literals.count)
            } else { seen[key] = literals.count }
            literals.append(candidate.original)
            labels.append(candidate.entity)
        }
        for candidate in job.sensitiveOriginals.reversed() { add(candidate) }
        for replacement in job.replacements {
            add(SensitiveOriginal(original: replacement.original, entity: replacement.entity))
        }
        return (literals, labels)
    }
    func spans(in text: String) -> [Span] {
        var result = matcher.matcherSpans(in: text, entities: entities)
        for (supplement, labels) in supplements {
            result.append(contentsOf: supplement.matcherSpans(in: text, entities: labels))
        }
        // A name that is also an ordinary word ("Rose", "Day") spreads only where
        // it is written as a name: "the rose", "pipeline day" and "Rose bushes"
        // opening a sentence are no one.
        let ns = text as NSString
        return result.filter { span in
            guard ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION"].contains(span.entity) else { return true }
            let word = ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
            guard GazetteerMatcher.ordinaryWord(word) else { return true }
            return NameLists.isUnlistedWord(word) ? NameCues.namedWord(span.range, in: text) : NameCues.position(span.range, in: text)
        }
    }
}

private extension Matcher {
    func matcherSpans(in text: String, entities: [String]) -> [Span] {
        let ns = text as NSString
        // An original matched inside a longer word ("Ann" in "annual") is not that person.
        return matches(in: text, accepting: { range in
            guard !TextRanges.joinsWord(ns, at: range.lowerBound, underscore: false) && !TextRanges.joinsWord(ns, at: range.upperBound, underscore: false) else { return false }
            // A short number tied to a word ("client-transaction-12345", "order_12345") is part of an identifier.
            if range.count < 7, range.lowerBound >= 2, let separator = Unicode.Scalar(ns.character(at: range.lowerBound - 1)), "-_".unicodeScalars.contains(separator),
               let before = Unicode.Scalar(ns.character(at: range.lowerBound - 2)), CharacterSet.letters.contains(before),
               ns.substring(with: NSRange(location: range.lowerBound, length: range.count)).allSatisfy(\.isNumber) { return false }
            return true
        }).map { Span(range: $0.range, entity: entities[$0.index], score: 1.1) }
    }
}

private struct FoldHash: Hashable {
    let first: UInt64
    let second: UInt64
    init(_ units: [UInt16]) {
        var a: UInt64 = 0xcbf29ce484222325
        var b: UInt64 = 0x84222325cbf29ce4
        for unit in units {
            a = (a ^ UInt64(unit)) &* 0x100000001b3
            b = (b ^ UInt64(unit)) &* 0x9e3779b185ebca87
        }
        first = a
        second = b
    }
}
