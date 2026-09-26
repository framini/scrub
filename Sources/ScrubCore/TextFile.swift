import Foundation

public enum TextFile: FileFormat {
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        guard !data.prefix(8192).contains(0) else { throw ScrubError.notUTF8 }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ScrubError.notUTF8 }
        try Scrubber.checkCancellation()
        progress(.finding, 0, 1)
        let spans = job.observe([(text, nil)])[0]
        try Scrubber.checkCancellation()
        progress(.finding, 1, 1)
        let (initial, marks) = try job.apply(text, spans: spans)
        try Scrubber.checkCancellation()
        progress(.checking, 0, 1)
        let (output, finalMarks, unresolved) = try Correction.run(initial, marks: marks, job: job)
        try Scrubber.checkCancellation()
        progress(.checking, 1, 1)
        let length = (output as NSString).length
        let previewLength = min(200_000, length)
        let previewText = TextRanges.substring(output, 0..<previewLength)
        return ScrubResult(format: "text", output: Data(output.utf8), preview: .text(previewText, marks: finalMarks.filter { $0.range.upperBound <= previewLength }, truncated: length > previewLength), counts: job.counts, unresolved: unresolved)
    }
}
