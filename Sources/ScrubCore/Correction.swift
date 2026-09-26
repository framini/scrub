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
        try run(initial, marks: marks, job: job, matcher: OriginalMatcher(job), gazetteer: GazetteerMatcher(job.gazetteer))
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
        let ours = { (range: Range<Int>, entity: String) in
            marks.contains { mark in
                (mark.range.lowerBound <= range.lowerBound && range.upperBound <= mark.range.upperBound)
                    || (["PERSON", "LOCATION"].contains(entity) && mark.range.overlaps(range))
            } || job.isEmitted(TextRanges.substring(output, range))
        }
        var found: [Span] = []
        found.append(contentsOf: matcher.spans(in: output).filter { !ours($0.range, "") })
        let detected = base.map { job.detector.combined($0, text: output, matcher: gazetteer) }
            ?? job.detector.find(output, matcher: gazetteer)
        found.append(contentsOf: detected.filter { !ours($0.range, $0.entity) })
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
    mutating func add(_ replacements: ArraySlice<Replacement>) {
        let originals = replacements.filter { !$0.original.isEmpty }
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
            guard !candidate.original.isEmpty else { return }
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
        // An original matched inside a longer word ("Ann" in "annual") is not
        // that person; the edge only needs a boundary where the original has a
        // letter or digit.
        func wordy(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = Unicode.Scalar(ns.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return matches(in: text, accepting: { range in
            !(wordy(range.lowerBound) && wordy(range.lowerBound - 1)) && !(wordy(range.upperBound - 1) && wordy(range.upperBound))
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
