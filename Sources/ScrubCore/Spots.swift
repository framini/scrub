import Foundation

/// Where each place in a value's text sits: which sentence and which
/// paragraph, counted from its start. Counts, not offsets, so a place keeps
/// its scopes once stand-ins of other lengths are written before it: a
/// stand-in adds no blank line and ends no sentence.
struct Spots {
    private let value: String
    // Fetched once: each read of a system set builds it again.
    private static let capitals = CharacterSet.uppercaseLetters, digits = CharacterSet.decimalDigits
    private var paragraphs: [Int] = []
    private var sentences: [Int] = []

    init(_ text: String, value: String) {
        self.value = value
        let ns = text as NSString
        let length = ns.length
        var index = 0
        while index < length {
            let unit = ns.character(at: index)
            if unit == 10 {
                // A line break ends a sentence; a blank line, a paragraph.
                sentences.append(index + 1)
                var next = index + 1
                while next < length, [32, 9, 13].contains(ns.character(at: next)) { next += 1 }
                if next < length, ns.character(at: next) == 10 { paragraphs.append(next + 1) }
            } else if unit == 46 || unit == 33 || unit == 63 {
                // ". " before a capital or a digit ends a sentence; "e.g. the" and "3.5" do not.
                var next = index + 1
                while next < length, ns.character(at: next) == 32 { next += 1 }
                if next > index + 1, next < length, let scalar = Unicode.Scalar(ns.character(at: next)),
                   Self.capitals.contains(scalar) || Self.digits.contains(scalar) { sentences.append(next) }
            }
            index += 1
        }
    }

    /// The scopes of the place at `offset`, innermost first: its sentence, its paragraph, its value.
    func scopes(at offset: Int) -> [String] {
        ["\(value)s\(Self.count(sentences, before: offset))", "\(value)p\(Self.count(paragraphs, before: offset))", value]
    }

    /// How many of the sorted `starts` are at or before `offset`.
    private static func count(_ starts: [Int], before offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
