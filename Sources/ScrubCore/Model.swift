import Foundation

public enum Stage: String, Sendable { case starting, finding, checking }
public struct Mark: Sendable, Equatable {
    public let range: Range<Int>
    public let entity: String
    public init(range: Range<Int>, entity: String) { self.range = range; self.entity = entity }
}
public struct TableMark: Sendable, Equatable {
    public let row: Int
    public let column: Int
    public let range: Range<Int>
    public let entity: String
    public init(row: Int, column: Int, range: Range<Int>, entity: String) {
        self.row = row; self.column = column; self.range = range; self.entity = entity
    }
}
public enum Preview: Sendable {
    case text(String, marks: [Mark], truncated: Bool)
    case table(columns: [String], rows: [[String]], rowCount: Int, marks: [TableMark])
}
public struct ScrubResult: Sendable {
    public let format: String
    public let output: Data
    public let preview: Preview
    public let counts: [String: Int]
    public let unresolved: [Mark]
    public let neutralized: Int
    public init(format: String, output: Data, preview: Preview, counts: [String: Int], unresolved: [Mark], neutralized: Int = 0) {
        self.format = format; self.output = output; self.preview = preview; self.counts = counts; self.unresolved = unresolved; self.neutralized = neutralized
    }
}
public enum ScrubError: Error, Equatable { case cancelled, unsupported(String) }
public protocol FileFormat { static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult }
public struct Span: Sendable, Equatable {
    public let range: Range<Int>
    public let entity: String
    public let score: Double
    public init(range: Range<Int>, entity: String, score: Double) { self.range = range; self.entity = entity; self.score = score }
}

// Compiling a pattern costs far more than matching it, so patterns are
// compiled once as static constants rather than at each call.
struct TextPattern: Sendable {
    let regex: NSRegularExpression?
    init(_ pattern: String, options: NSRegularExpression.Options = []) { regex = try? NSRegularExpression(pattern: pattern, options: options) }
}

enum TextRanges {
    static func substring(_ text: String, _ range: Range<Int>) -> String {
        let ns = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= ns.length else { return "" }
        if range.lowerBound == 0 && range.upperBound == ns.length { return text }
        return ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }
    static func replace(_ text: String, _ range: Range<Int>, with value: String) -> String {
        (text as NSString).replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: value)
    }
    static func matches(_ pattern: TextPattern, in text: String) -> [NSTextCheckingResult] {
        guard let regex = pattern.regex else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
    // One pass over the text: replacing edits one at a time copies the whole
    // text per edit. Edits are sorted by start and disjoint (resolved spans).
    static func apply(_ edits: [(range: Range<Int>, value: String)], to text: String) -> (String, [Range<Int>]) {
        let ns = text as NSString
        let output = NSMutableString(capacity: ns.length)
        var placed: [Range<Int>] = []
        var cursor = 0
        for edit in edits where edit.range.lowerBound >= cursor && edit.range.upperBound <= ns.length {
            output.append(ns.substring(with: NSRange(location: cursor, length: edit.range.lowerBound - cursor)))
            let start = output.length
            output.append(edit.value)
            placed.append(start..<output.length)
            cursor = edit.range.upperBound
        }
        output.append(ns.substring(from: cursor))
        return (String(output), placed)
    }
    // Drops marks that overlap an edit and moves the rest by the length change
    // of the edits before them.
    static func shift(_ marks: [Mark], by edits: [(range: Range<Int>, value: String)]) -> [Mark] {
        var offsets = [0]
        for edit in edits { offsets.append(offsets[offsets.count - 1] + (edit.value as NSString).length - edit.range.count) }
        return marks.compactMap { mark in
            var low = 0, high = edits.count
            while low < high {
                let middle = (low + high) / 2
                if edits[middle].range.upperBound <= mark.range.lowerBound { low = middle + 1 } else { high = middle }
            }
            if low < edits.count && edits[low].range.overlaps(mark.range) { return nil }
            return Mark(range: (mark.range.lowerBound + offsets[low])..<(mark.range.upperBound + offsets[low]), entity: mark.entity)
        }
    }
    static func ranges(of literal: String, in text: String, options: NSString.CompareOptions = [.caseInsensitive]) -> [Range<Int>] {
        guard !literal.isEmpty else { return [] }
        let ns = text as NSString
        var result: [Range<Int>] = []
        var start = 0
        while start < ns.length {
            if Task.isCancelled { return result }
            let match = ns.range(of: literal, options: options, range: NSRange(location: start, length: ns.length - start))
            if match.location == NSNotFound { break }
            result.append(match.location..<(match.location + match.length))
            start = match.location + max(1, match.length)
        }
        return result
    }
}
