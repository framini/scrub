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
    static func run(_ initial: String, marks initialMarks: [Mark], job: Job) throws -> (String, [Mark], [Mark]) {
        var output = initial
        var marks = initialMarks
        for _ in 0..<3 {
            try Scrubber.checkCancellation()
            let spans = Detector.resolve(leftovers(in: output, marks: marks, job: job))
            if spans.isEmpty { break }
            for (index, span) in spans.reversed().enumerated() {
                if index.isMultiple(of: 64) { try Scrubber.checkCancellation() }
                let original = TextRanges.substring(output, span.range)
                let fake = job.replacement(for: span.entity, original: original)
                output = TextRanges.replace(output, span.range, with: fake)
                let delta = (fake as NSString).length - span.range.count
                marks = marks.compactMap { mark in
                    if mark.range.overlaps(span.range) { return nil }
                    if mark.range.lowerBound >= span.range.upperBound { return Mark(range: (mark.range.lowerBound + delta)..<(mark.range.upperBound + delta), entity: mark.entity) }
                    return mark
                }
                marks.append(Mark(range: span.range.lowerBound..<(span.range.lowerBound + (fake as NSString).length), entity: span.entity))
            }
            marks.sort { $0.range.lowerBound < $1.range.lowerBound }
        }
        var unresolved = leftovers(in: output, marks: marks, job: job).map { Mark(range: $0.range, entity: $0.entity) }
        var seen: Set<String> = []
        unresolved = unresolved.filter { seen.insert("\($0.range.lowerBound):\($0.range.upperBound):\($0.entity)").inserted }
        return (output, marks, unresolved)
    }

    private static func leftovers(in output: String, marks: [Mark], job: Job) -> [Span] {
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
        let originals = Array(job.sensitiveOriginals.values) + job.replacements.map { SensitiveOriginal(original: $0.original, entity: $0.entity) }
        for (index, candidate) in originals.enumerated() {
            if index.isMultiple(of: 64) && Task.isCancelled { return found }
            for range in TextRanges.ranges(of: candidate.original, in: output) where !ours(range, "") {
                found.append(Span(range: range, entity: candidate.entity, score: 1.1))
            }
        }
        found.append(contentsOf: job.detector.find(output, gazetteer: job.gazetteer).filter { !ours($0.range, $0.entity) })
        return found
    }
}
