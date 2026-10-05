import Foundation

/// The context model's tokenizer: the sentencepiece normaliser, a split on
/// whitespace with "▁" before each word, and the most likely pieces of a
/// unigram vocabulary. It gives the same pieces and offsets as the tokenizer
/// the model was trained with, quirks included (Tools/ContextModel/parity.py
/// checks it), since a piece cut differently reads differently.
struct PieceTokenizer: Sendable {
    struct Piece: Equatable {
        let id: Int32
        /// UTF-16 offsets in the text, as the training tokenizer reports them.
        let range: Range<Int>
    }

    let cls: Int32
    let sep: Int32
    private let unknown: Int32
    private let scores: [Double]
    private let unknownScore: Double
    /// Trie edges, keyed by the parent node and the scalar; a node's piece id, or -1.
    private let edges: [UInt64: Int32]
    private let terminal: [Int32]
    /// Marker tokens matched in the raw text before anything else.
    private let markers: [(text: [UInt16], id: Int32)]
    private let units: [UInt32]
    private let replacements: [UInt8]
    private static let metaspace: Unicode.Scalar = "\u{2581}"

    init?(pieces: [[UInt8]], scores: [Double], charsmap: Data, unknown: Int32, cls: Int32, sep: Int32) {
        guard pieces.count == scores.count, pieces.count > 4, charsmap.count >= 4 else { return nil }
        (self.unknown, self.cls, self.sep, self.scores) = (unknown, cls, sep, scores)
        unknownScore = (scores.min() ?? 0) - 10
        var edges: [UInt64: Int32] = [:], terminal: [Int32] = [-1]
        edges.reserveCapacity(pieces.count * 4)
        var markers: [(text: [UInt16], id: Int32)] = []
        for (id, piece) in pieces.enumerated() {
            let text = String(decoding: piece, as: UTF8.self)
            // The first four are markers (<s>, <pad>, </s>, <unk>), split out before the text is read.
            if id < 4 { markers.append((Array(text.utf16), Int32(id))); continue }
            var node: Int32 = 0
            for scalar in text.unicodeScalars {
                let edge = UInt64(node) << 21 | UInt64(scalar.value)
                if let next = edges[edge] { node = next; continue }
                terminal.append(-1)
                let next = Int32(terminal.count - 1)
                edges[edge] = next
                node = next
            }
            terminal[Int(node)] = Int32(id)
        }
        (self.edges, self.terminal) = (edges, terminal)
        self.markers = markers.sorted { $0.text.count > $1.text.count }
        let size = charsmap.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard size % 4 == 0, 4 + size <= charsmap.count else { return nil }
        units = charsmap.subdata(in: charsmap.startIndex + 4..<charsmap.startIndex + 4 + size).withUnsafeBytes { raw in
            (0..<size / 4).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        replacements = [UInt8](charsmap.subdata(in: charsmap.startIndex + 4 + size..<charsmap.endIndex))
    }

    /// The pieces of `text`, with their UTF-16 offsets.
    func pieces(_ text: String, isCancelled: () -> Bool = { false }) -> [Piece] {
        let utf16 = Array(text.utf16)
        var result: [Piece] = [], start = 0, index = 0
        // A marker written in the text is that marker, as the training tokenizer reads it.
        while index < utf16.count {
            if utf16[index] == 60, let marker = markers.first(where: { utf16[index...].starts(with: $0.text) }) {
                if start < index { result += segment(text, utf16: start..<index, isCancelled: isCancelled) }
                result.append(Piece(id: marker.id, range: index..<index + marker.text.count))
                index += marker.text.count
                start = index
            } else {
                index += 1
            }
        }
        if start < utf16.count { result += segment(text, utf16: start..<utf16.count, isCancelled: isCancelled) }
        return result
    }

    /// A normalised scalar and the UTF-16 range of the text it came from.
    private typealias Aligned = (scalar: Unicode.Scalar, range: Range<Int>)

    private func segment(_ text: String, utf16 range: Range<Int>, isCancelled: () -> Bool) -> [Piece] {
        let ns = text as NSString
        let part = ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
        let normalized = normalize(part, offset: range.lowerBound)
        var result: [Piece] = []
        var word: [Aligned] = []
        func flush() {
            guard !word.isEmpty else { return }
            // "▁" before each word, read from the word's first character.
            if word[0].scalar != Self.metaspace { word.insert((Self.metaspace, word[0].range), at: 0) }
            var from = 0
            for index in 1...word.count where index == word.count || word[index].scalar == Self.metaspace {
                result += unigram(word[from..<index])
                from = index
            }
            word.removeAll(keepingCapacity: true)
        }
        for (count, item) in normalized.enumerated() {
            if count.isMultiple(of: 4096), isCancelled() { return [] }
            if item.scalar.properties.isWhitespace { flush() } else { word.append(item) }
        }
        flush()
        return result
    }

    // MARK: Normaliser

    /// The sentencepiece normaliser, with its alignment: each grapheme under
    /// six bytes is looked up whole, otherwise each scalar on its own; a
    /// replacement takes the alignment the training tokenizer gives it.
    private func normalize(_ text: String, offset: Int) -> [Aligned] {
        var originals: [Range<Int>] = [], cursor = offset
        for scalar in text.unicodeScalars {
            originals.append(cursor..<cursor + scalar.utf16.count)
            cursor += scalar.utf16.count
        }
        var changes: [(scalar: Unicode.Scalar, change: Int)] = []
        var modified = false
        func replace(_ old: Int, with new: [UInt8]) {
            let scalars = Array(String(decoding: new, as: UTF8.self).unicodeScalars)
            let difference = scalars.count - old
            changes += scalars.map { ($0, 0) }
            if difference > 0 {
                for index in (changes.count - difference)..<changes.count { changes[index].change = 1 }
            } else if difference < 0, !changes.isEmpty {
                changes[changes.count - 1].change += difference
            }
        }
        for grapheme in text {
            let bytes = Array(grapheme.utf8)
            if bytes.count < 6, let found = replacement(bytes) {
                modified = true
                replace(grapheme.unicodeScalars.count, with: found)
                continue
            }
            for scalar in grapheme.unicodeScalars {
                if let found = replacement(Array(String(scalar).utf8)) {
                    modified = true
                    replace(1, with: found)
                } else {
                    changes.append((scalar, 0))
                }
            }
        }
        guard modified else { return zip(text.unicodeScalars, originals).map { ($0, $1) } }
        var result: [Aligned] = [], consumed = 0
        result.reserveCapacity(changes.count)
        for (scalar, change) in changes {
            let range: Range<Int>
            if change > 0 {
                // Inserted: aligned as the character before it.
                range = consumed > 0 ? originals[min(consumed, originals.count) - 1] : offset..<offset
            } else {
                range = originals[min(consumed, originals.count - 1)]
                consumed += 1 - change
            }
            result.append((scalar, range))
        }
        return result
    }

    /// The normaliser's replacement for the shortest key at the start of
    /// `bytes`, from its double-array trie.
    private func replacement(_ bytes: [UInt8]) -> [UInt8]? {
        func offset(_ unit: UInt32) -> Int { Int((unit >> 10) << ((unit & (1 << 9)) >> 6)) }
        guard !units.isEmpty else { return nil }
        var node = offset(units[0])
        for byte in bytes {
            if byte == 0 { return nil }
            node ^= Int(byte)
            guard node < units.count else { return nil }
            let unit = units[node]
            guard unit & ((1 << 31) | 0xFF) == UInt32(byte) else { return nil }
            node ^= offset(unit)
            guard node < units.count else { return nil }
            if (unit >> 8) & 1 == 1 {
                let start = Int(units[node] & ((1 << 31) - 1))
                guard start <= replacements.count else { return nil }
                let end = replacements[start...].firstIndex(of: 0) ?? replacements.count
                return Array(replacements[start..<end])
            }
        }
        return nil
    }

    // MARK: Unigram

    /// The most likely pieces of one word, by Viterbi over the vocabulary. A
    /// character no piece holds becomes the unknown piece; unknowns in a row
    /// are one.
    private func unigram(_ word: ArraySlice<Aligned>) -> [Piece] {
        let scalars = word.map(\.scalar), ranges = word.map(\.range)
        let count = scalars.count
        var best = [Double](repeating: 0, count: count + 1)
        var from = [Int](repeating: -1, count: count + 1)
        var ids = [Int32](repeating: 0, count: count + 1)
        for start in 0..<count {
            let here = best[start]
            var node: Int32 = 0, single = false
            for end in start..<count {
                guard let next = edges[UInt64(node) << 21 | UInt64(scalars[end].value)] else { break }
                node = next
                let id = terminal[Int(node)]
                guard id >= 0 else { continue }
                let candidate = here + scores[Int(id)]
                if from[end + 1] < 0 || candidate > best[end + 1] { (best[end + 1], from[end + 1], ids[end + 1]) = (candidate, start, id) }
                if end == start { single = true }
            }
            if !single {
                let candidate = here + unknownScore
                if from[start + 1] < 0 || candidate > best[start + 1] { (best[start + 1], from[start + 1], ids[start + 1]) = (candidate, start, unknown) }
            }
        }
        var pieces: [(id: Int32, start: Int, end: Int)] = []
        var end = count
        while end > 0 {
            let start = from[end], id = ids[end]
            if id == unknown, let last = pieces.last, last.id == unknown { pieces[pieces.count - 1] = (unknown, start, last.end) }
            else { pieces.append((id, start, end)) }
            end = start
        }
        return pieces.reversed().map { Piece(id: $0.id, range: ranges[$0.start].lowerBound..<ranges[$0.end - 1].upperBound) }
    }
}
