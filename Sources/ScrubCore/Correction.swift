import Foundation

struct Replacement {
    let original: String
    let fake: String
    let entity: String
}

enum Correction {
    static func run(_ initial: String, marks initialMarks: [Mark], job: Job) -> (String, [Mark], [Mark]) {
        var output = initial
        var marks = initialMarks
        for _ in 0..<3 {
            let spans = Detector.resolve(leftovers(in: output, marks: marks, job: job))
            if spans.isEmpty { break }
            for span in spans.reversed() {
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

    /// Originals still in the output, and new detections, outside the stand-ins
    /// already placed. The model can tag part of a stand-in ("Washington" in a
    /// fake name), so anything overlapping one is ours, not a leak.
    private static func leftovers(in output: String, marks: [Mark], job: Job) -> [Span] {
        let ours = { (range: Range<Int>) in marks.contains { $0.range.overlaps(range) } || job.isEmitted(TextRanges.substring(output, range)) }
        var found: [Span] = []
        for replacement in job.replacements {
            for range in TextRanges.ranges(of: replacement.original, in: output) where !ours(range) {
                found.append(Span(range: range, entity: replacement.entity, score: 1.1))
            }
        }
        found.append(contentsOf: job.detector.find(output, gazetteer: job.gazetteer).filter { !ours($0.range) })
        return found
    }
}
