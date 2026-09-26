import Foundation
@testable import ScrubCore

struct PlantedRange {
    let range: Range<Int>
    let original: String
}

extension GeneratedDocument {
    func leaks(in output: Data) throws -> [String] {
        let model = try DocumentModel(data: output, format: format, delimiter: delimiter, quote: quote)
        let values = [String(decoding: output, as: UTF8.self)] + model.leaves.map(\.value)
        return planted.map(\.original).filter { original in
            values.contains { $0.localizedCaseInsensitiveContains(original) }
        }
    }

    func ranges(in value: String) -> [PlantedRange] {
        let source = value as NSString
        var ranges: [PlantedRange] = []
        for original in Set(planted.map(\.original)) {
            var start = 0
            while start < source.length {
                let match = source.range(of: original, options: .caseInsensitive, range: NSRange(location: start, length: source.length - start))
                guard match.location != NSNotFound else { break }
                ranges.append(PlantedRange(range: match.location..<(match.location + match.length), original: original))
                start = match.location + match.length
            }
        }
        var end = 0
        return ranges.sorted { a, b in
            a.range.lowerBound == b.range.lowerBound ? a.range.count > b.range.count : a.range.lowerBound < b.range.lowerBound
        }.filter { span in
            guard span.range.lowerBound >= end else { return false }
            end = span.range.upperBound
            return true
        }
    }

    func surroundingTextKept(in output: Data) throws -> Bool {
        let before = try model()
        let after = try DocumentModel(data: output, format: format, delimiter: delimiter, quote: quote)
        let mapped = Dictionary(uniqueKeysWithValues: after.leaves.map { ($0.path, $0.value) })
        var replacements: [String: String] = [:]
        for leaf in before.leaves where !leaf.isName {
            if planted.contains(where: { $0.original == leaf.value }), let fake = mapped[leaf.path] {
                replacements[leaf.value] = fake
            }
        }
        for leaf in before.leaves where !leaf.isName && KeyHints.hint(leaf.key) == nil {
            let spans = plantedRanges[leaf.path] ?? ranges(in: leaf.value)
            guard !spans.isEmpty, let actual = mapped[leaf.path] else { continue }
            var pattern = "\\A"
            var offset = 0
            for span in spans {
                pattern += NSRegularExpression.escapedPattern(for: TextRanges.substring(leaf.value, offset..<span.range.lowerBound))
                pattern += replacements[span.original].map(NSRegularExpression.escapedPattern(for:)) ?? "[\\s\\S]+?"
                offset = span.range.upperBound
            }
            pattern += NSRegularExpression.escapedPattern(for: TextRanges.substring(leaf.value, offset..<(leaf.value as NSString).length)) + "\\z"
            guard actual.range(of: pattern, options: .regularExpression) != nil else { return false }
        }
        return true
    }
}
