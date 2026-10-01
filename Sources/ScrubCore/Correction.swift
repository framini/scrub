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
        try run(initial, marks: marks, job: job, matcher: OriginalMatcher(job), gazetteer: GazetteerMatcher(job.gazetteer, nameParts: job.nameParts))
    }
    static func run(_ initial: String, marks initialMarks: [Mark], job: Job, matcher: OriginalMatcher, gazetteer: GazetteerMatcher, passes: Int = 3, base: [Span]? = nil) throws -> (String, [Mark], [Mark]) {
        var output = initial
        var marks = initialMarks
        for pass in 0..<passes {
            try Scrubber.checkCancellation()
            let spans = Detector.resolve(leftovers(in: output, marks: marks, job: job, matcher: matcher, gazetteer: gazetteer, base: pass == 0 ? base : nil))
            if spans.isEmpty { return (output, marks, []) }
            var fakes = Array(repeating: "", count: spans.count)
            for (count, index) in spans.indices.reversed().enumerated() {
                if count.isMultiple(of: 64) { try Scrubber.checkCancellation() }
                fakes[index] = job.replacement(for: spans[index].entity, original: TextRanges.substring(output, spans[index].range))
            }
            let edits = zip(spans, fakes).map { (range: $0.range, value: $1) }
            let (edited, placed) = TextRanges.apply(edits, to: output)
            marks = TextRanges.shift(marks, by: edits) + zip(placed, spans).map { Mark(range: $0, entity: $1.entity) }
            marks.sort { $0.range.lowerBound < $1.range.lowerBound }
            output = edited
        }
        var unresolved = leftovers(in: output, marks: marks, job: job, matcher: matcher, gazetteer: gazetteer).map { Mark(range: $0.range, entity: $0.entity) }
        var seen: Set<String> = []
        unresolved = unresolved.filter { seen.insert("\($0.range.lowerBound):\($0.range.upperBound):\($0.entity)").inserted }
        return (output, marks, unresolved)
    }

    private static func leftovers(in output: String, marks: [Mark], job: Job, matcher: OriginalMatcher, gazetteer: GazetteerMatcher, base: [Span]? = nil) -> [Span] {
        if marks.contains(where: { $0.range == 0..<(output as NSString).length }) { return [] }
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
                    || (["PERSON", "LOCATION"].contains(entity) && mark.overlaps(range)) { return true }
                index += 1
            }
            return job.isEmitted(TextRanges.substring(output, range))
        }
        var found: [Span] = []
        found.append(contentsOf: matcher.spans(in: output).filter { !ours($0.range, "") })
        let detected = base.map { job.detector.combined($0, text: output, matcher: gazetteer) }
            ?? job.detector.find(output, matcher: gazetteer)
        // Places the first pass found are originals, and the matcher above finds
        // them. A place detected only now was read from the stand-ins' context
        // ("Later, Larry Alvarado" makes "Later" a city) and names nothing real.
        found.append(contentsOf: detected.filter { $0.entity != "LOCATION" && !ours($0.range, $0.entity) })
        return found
    }
}

struct OriginalMatcher {
    let matcher: Matcher
    let entities: [String]
    private var supplements: [(Matcher, [String])] = []

    init(_ job: Job) {
        let (literals, labels) = Self.entries(job)
        matcher = Matcher(literals)
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
        supplements.append((Matcher(literals), labels))
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
        return result
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
