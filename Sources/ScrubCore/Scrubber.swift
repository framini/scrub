import Foundation

public enum Scrubber {
    public static func scrub(_ data: Data, name: String, progress: (Stage, Int, Int) -> Void = { _, _, _ in }) throws -> ScrubResult {
        try checkCancellation()
        progress(.starting, 0, 1)
        guard !data.isEmpty, !data.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw ScrubError.empty }
        guard data.count <= 50 * 1024 * 1024 else { throw ScrubError.tooLarge }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) { throw ScrubError.unsupported("image") }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty && !["txt", "md", "markdown", "log", "text", "json", "xml", "csv", "tsv"].contains(ext) { throw ScrubError.unsupported(ext) }
        progress(.starting, 1, 1)
        try checkCancellation()
        return try TextFile.process(data, job: Job(), progress: progress)
    }
    static func checkCancellation() throws {
        if Task.isCancelled { throw ScrubError.cancelled }
    }
}
