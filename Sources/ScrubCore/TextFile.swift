import Foundation

public enum TextFile: FileFormat {
    static func decode(_ data: Data) throws -> String {
        // A binary file, or text in UTF-16, writes NULs throughout; text with a stray one is still text.
        let head = data.prefix(8192)
        guard head.lazy.filter({ $0 == 0 }).count * 8 <= head.count else { throw ScrubError.unsupported("binary_file") }
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
        let regions = JSONSource.regions(in: text)
        if !regions.isEmpty { return try process(text, regions: regions, job: job, progress: progress, forceFullDetection: forceFullDetection) }
        progress(.finding, 0, 1)
        let values = try DocumentPipeline.run([DocumentLeaf(text)], job: job, forceFullDetection: forceFullDetection, progress: progress)
        try Scrubber.checkCancellation()
        progress(.finding, 1, 1)
        progress(.checking, 0, 1)
        try Scrubber.checkCancellation()
        progress(.checking, 1, 1)
        func render(_ values: [DocumentValue], counts: [String: Int]) -> ScrubResult {
            let (output, finalMarks, unresolved) = (values[0].text, values[0].marks, values[0].unresolved)
            let length = (output as NSString).length
            let previewLength = min(200_000, length)
            let previewText = TextRanges.substring(output, 0..<previewLength)
            return ScrubResult(format: "text", output: Data(output.utf8), preview: .text(previewText, marks: finalMarks.filter { $0.range.upperBound <= previewLength }, truncated: length > previewLength), counts: counts, unresolved: unresolved)
        }
        var result = render(values, counts: job.counts)
        result.review = Review(values: values, counts: job.counts, people: job.personLinks(), render: render)
        return result
    }

    /// JSON Lines (.jsonl, .ndjson, or pasted so): each line read as a .json file is, all
    /// of them in one scrub, so a value written on two lines takes one stand-in, and the
    /// line breaks and blank lines between them written back as they were.
    static func processLines(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void, forceFullDetection: Bool) throws -> ScrubResult {
        let text = try decode(data)
        try Scrubber.checkCancellation()
        guard let lines = try JSONSource.lines(in: text) else { throw ScrubError.unsupported("invalid_json") }
        return try process(text, regions: lines.map { ($0, false, nil) }, format: "jsonl", job: job, progress: progress, forceFullDetection: forceFullDetection)
    }

    /// Text with JSON written inside it (a curl command's body, a log line's):
    /// each body is read and written as a .json file is (see `JSONDocument`),
    /// and the text between them as text, each part its own value.
    private static func process(_ text: String, regions: [(range: Range<Int>, shell: Bool, key: String?)], format: String = "text", job: Job, progress: (Stage, Int, Int) -> Void, forceFullDetection: Bool) throws -> ScrubResult {
        enum Part { case text(Int), json(JSONDocument) }
        let collector = JSONDocument.Collector()
        var parts: [Part] = []
        var gaps: [(Int, String)] = []
        var cursor = 0
        func gap(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let piece = TextRanges.substring(text, range)
            gaps.append((parts.count, piece))
            parts.append(.text(-1))
        }
        for (region, shell, key) in regions {
            gap(cursor..<region.lowerBound)
            parts.append(.json(collector.add(try JSONSource.read(TextRanges.substring(text, region), shell: shell), key: key)))
            cursor = region.upperBound
        }
        gap(cursor..<(text as NSString).length)
        // The text between bodies follows them: its leaves come after theirs.
        var leaves = collector.leaves
        for (part, piece) in gaps {
            parts[part] = .text(leaves.count)
            leaves.append(DocumentLeaf(piece))
        }
        let drawn = JSONFile.drawDigits(collector.names, job: job)
        progress(.finding, 0, leaves.count)
        var values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection, progress: progress)
        progress(.finding, leaves.count, leaves.count)
        for case .json(let document) in parts { document.writeKeyDigits(&values, drawn: drawn) }
        func render(_ values: [DocumentValue], counts: [String: Int]) -> ScrubResult {
            var output = "", marks: [Mark] = [], length = 0
            for part in parts {
                let (written, placed): (String, [Mark])
                switch part {
                case .text(let id): (written, placed) = (values[id].text, values[id].marks)
                case .json(let document): (written, placed) = document.render(values)
                }
                marks += placed.map { $0.moved(to: ($0.range.lowerBound + length)..<($0.range.upperBound + length)) }
                output += written
                length += (written as NSString).length
            }
            let previewLength = min(200_000, length)
            return ScrubResult(format: format, output: Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<previewLength), marks: marks.filter { $0.range.upperBound <= previewLength }, truncated: length > previewLength), counts: counts, unresolved: values.flatMap(\.unresolved))
        }
        progress(.checking, 0, 1)
        var result = render(values, counts: job.counts)
        result.review = Review(values: values, counts: job.counts, records: leaves.map(\.lastRecord), people: job.personLinks(), numeric: Set(leaves.indices.filter { leaves[$0].numericEntity != nil }), render: render)
        progress(.checking, 1, 1)
        return result
    }
}
