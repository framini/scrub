import Foundation

public enum TextFile: FileFormat {
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        guard !data.prefix(8192).contains(0) else { throw ScrubError.notUTF8 }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ScrubError.notUTF8 }
        progress(.finding, 0, 1)
        let spans = job.observe([(text, nil)])[0]
        progress(.finding, 1, 1)
        let (initial, marks) = job.apply(text, spans: spans)
        progress(.checking, 0, 1)
        let (output, finalMarks, unresolved) = Correction.run(initial, marks: marks, job: job)
        progress(.checking, 1, 1)
        let length = (output as NSString).length
        let previewLength = min(200_000, length)
        let previewText = TextRanges.substring(output, 0..<previewLength)
        return ScrubResult(format: "text", output: Data(output.utf8), preview: .text(previewText, marks: finalMarks.filter { $0.range.upperBound <= previewLength }, truncated: length > previewLength), counts: job.counts, unresolved: unresolved)
    }
}
