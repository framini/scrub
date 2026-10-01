import Foundation

public enum TextFile: FileFormat {
    static func decode(_ data: Data) throws -> String {
        guard !data.prefix(8192).contains(0) else { throw ScrubError.unsupported("binary_file") }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ScrubError.unsupported("not_utf8") }
        return text
    }
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        try process(data, job: job, progress: progress, forceFullDetection: false)
    }
    static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void, forceFullDetection: Bool) throws -> ScrubResult {
        let text = try decode(data)
        try Scrubber.checkCancellation()
        progress(.finding, 0, 1)
        let result = try DocumentPipeline.run([DocumentLeaf(text)], job: job, forceFullDetection: forceFullDetection, progress: progress)[0]
        let (output, finalMarks, unresolved) = (result.text, result.marks, result.unresolved)
        try Scrubber.checkCancellation()
        progress(.finding, 1, 1)
        progress(.checking, 0, 1)
        try Scrubber.checkCancellation()
        progress(.checking, 1, 1)
        let length = (output as NSString).length
        let previewLength = min(200_000, length)
        let previewText = TextRanges.substring(output, 0..<previewLength)
        return ScrubResult(format: "text", output: Data(output.utf8), preview: .text(previewText, marks: finalMarks.filter { $0.range.upperBound <= previewLength }, truncated: length > previewLength), counts: job.counts, unresolved: unresolved)
    }
}
