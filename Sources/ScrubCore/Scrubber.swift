import Foundation

public enum Scrubber {
    public static func scrub(_ data: Data, name: String, progress: (Stage, Int, Int) -> Void = { _, _, _ in }) throws -> ScrubResult {
        try scrub(data, name: name, forceFullDetection: false, seed: nil, progress: progress)
    }
    static func scrub(_ data: Data, name: String, forceFullDetection: Bool, seed: UInt64? = nil, progress: (Stage, Int, Int) -> Void = { _, _, _ in }) throws -> ScrubResult {
        try checkCancellation()
        progress(.starting, 0, 1)
        let format = try classify(data, name: name)
        progress(.starting, 1, 1)
        try checkCancellation()
        let coverage = Coverage.current()
        let job = seed.map { Job(seed: $0) } ?? Job()
        var result: ScrubResult
        switch format {
        case "json": result = try JSONFile.process(data, job: job, progress: progress, forceFullDetection: forceFullDetection)
        case "xml": result = try XMLFile.process(data, job: job, progress: progress, forceFullDetection: forceFullDetection)
        case "csv": result = try CSVFile.process(data, job: job, progress: progress, forceFullDetection: forceFullDetection)
        default: result = try TextFile.process(data, job: job, progress: progress, forceFullDetection: forceFullDetection)
        }
        // Cancelling stops a scrub; it never hands back one that stopped looking partway.
        try checkCancellation()
        result.coverage = coverage
        // Stand-ins drawn for values marked later follow the seed, as every other does.
        result.review?.salt = seed ?? UInt64.random(in: .min ... .max)
        return result
    }
    public static func classify(_ data: Data, name: String) throws -> String {
        guard !data.isEmpty, !data.allSatisfy({ [9, 10, 11, 12, 13, 32].contains($0) }) else { throw ScrubError.unsupported("empty_file") }
        guard data.count <= 50 * 1024 * 1024 else { throw ScrubError.unsupported("too_large") }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) || data.starts(with: [0xFF, 0xD8, 0xFF]) { throw ScrubError.unsupported("images_not_supported_yet") }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "json": return "json"
        case "xml": return "xml"
        case "csv", "tsv": return "csv"
        case "txt", "md", "markdown", "log", "text": return "text"
        case "": return try sniff(data)
        default: throw ScrubError.unsupported("unsupported_type")
        }
    }
    private static func sniff(_ data: Data) throws -> String {
        let text = try TextFile.decode(data)
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("{") || head.hasPrefix("[") {
            do { _ = try OrderedJSON.parse(text); return "json" }
            catch ScrubError.unsupported("too_deep") { throw ScrubError.unsupported("too_deep") }
            catch {}
        }
        if head.hasPrefix("<"), try XMLFile.parses(Data(head.utf8)) { return "xml" }
        let lines = text.split(whereSeparator: \.isNewline).prefix(20).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if lines.count >= 2 {
            let delimiter = CSVFile.sniffDelimiter(lines.joined(separator: "\n"))
            let quote = CSVFile.sniffQuote(lines.joined(separator: "\n"), delimiter: delimiter)
            if let rows = try? CSVFile.parse(lines.joined(separator: "\n"), delimiter: delimiter, quoteCharacter: quote), let header = rows.first,
               rows.allSatisfy({ $0.count == header.count }) {
                // A header naming a personal field is strong evidence on its own,
                // so a one-row or one-column export still gets its field hints.
                let named = header.contains { KeyHints.hint($0.trimmingCharacters(in: .whitespaces)) != nil }
                if named || header.count >= 2 && lines.count >= 3 { return "csv" }
            }
        }
        return "text"
    }
    static func checkCancellation() throws {
        if Task.isCancelled { throw ScrubError.cancelled }
    }
}
