import Foundation

public enum Stage: String, Sendable { case starting, finding, checking }
public struct Mark: Sendable, Equatable {
    public let range: Range<Int>
    public let entity: String
    public init(range: Range<Int>, entity: String) { self.range = range; self.entity = entity }
}
public enum Preview: Sendable { case text(String, marks: [Mark], truncated: Bool) }
public struct ScrubResult: Sendable {
    public let format: String
    public let output: Data
    public let preview: Preview
    public let counts: [String: Int]
    public let unresolved: [Mark]
    public init(format: String, output: Data, preview: Preview, counts: [String: Int], unresolved: [Mark]) {
        self.format = format; self.output = output; self.preview = preview; self.counts = counts; self.unresolved = unresolved
    }
}
public enum ScrubError: Error, Equatable { case notUTF8, tooLarge, empty, unsupported(String) }
public protocol FileFormat { static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult }
public struct Span: Sendable, Equatable {
    public let range: Range<Int>
    public let entity: String
    public let score: Double
    public init(range: Range<Int>, entity: String, score: Double) { self.range = range; self.entity = entity; self.score = score }
}

enum TextRanges {
    static func substring(_ text: String, _ range: Range<Int>) -> String {
        let ns = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= ns.length else { return "" }
        return ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }
    static func replace(_ text: String, _ range: Range<Int>, with value: String) -> String {
        (text as NSString).replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: value)
    }
    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
    static func ranges(of literal: String, in text: String, options: NSString.CompareOptions = [.caseInsensitive]) -> [Range<Int>] {
        guard !literal.isEmpty else { return [] }
        let ns = text as NSString
        var result: [Range<Int>] = []
        var start = 0
        while start < ns.length {
            let match = ns.range(of: literal, options: options, range: NSRange(location: start, length: ns.length - start))
            if match.location == NSNotFound { break }
            result.append(match.location..<(match.location + match.length))
            start = match.location + max(1, match.length)
        }
        return result
    }
}
