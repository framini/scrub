import Foundation

public enum Scrubber {
    public static func scrub(_ data: Data, name: String, progress: (Stage, Int, Int) -> Void = { _, _, _ in }) throws -> ScrubResult {
        try checkCancellation()
        progress(.starting, 0, 1)
        let format = try classify(data, name: name)
        progress(.starting, 1, 1)
        try checkCancellation()
        let job = Job()
        switch format {
        case "json": return try JSONFile.process(data, job: job, progress: progress)
        case "xml": return try XMLFile.process(data, job: job, progress: progress)
        case "csv": return try CSVFile.process(data, job: job, progress: progress)
        default: return try TextFile.process(data, job: job, progress: progress)
        }
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
        if (head.hasPrefix("{") || head.hasPrefix("[")), (try? OrderedJSON.parse(text)) != nil { return "json" }
        if head.hasPrefix("<") && XMLFile.parses(data) { return "xml" }
        let lines = text.split(whereSeparator: \.isNewline).prefix(20).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if lines.count >= 3 {
            let delimiter = CSVFile.sniffDelimiter(lines.joined(separator: "\n"))
            let quote = CSVFile.sniffQuote(lines.joined(separator: "\n"), delimiter: delimiter)
            if let rows = try? CSVFile.parse(lines.joined(separator: "\n"), delimiter: delimiter, quoteCharacter: quote), let width = rows.first?.count,
               width >= 2, rows.allSatisfy({ $0.count == width }) { return "csv" }
        }
        return "text"
    }
    static func checkCancellation() throws {
        if Task.isCancelled { throw ScrubError.cancelled }
    }
}
