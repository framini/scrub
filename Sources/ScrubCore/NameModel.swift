import Accelerate
import CryptoKit
import Foundation
import os
import Synchronization

/// A small network that reads each word with the words around it and says
/// whether it names a person. It catches what the system tagger cannot read:
/// a name alone after "Thanks,", a lowercase name in chat, a handle built
/// from a name. Tools/NameModel trains it; this mirrors model.py exactly, so
/// change both together.
final class NameModel: Sendable {
    static let shared: NameModel? = load()
    /// How sure a word must be, as a logit, before it counts as a name. The
    /// model scores the names it knows at 9 and more and the words it half
    /// suspects ("Street" in a form label) near 1; a plain lowercase word
    /// must be surer still, as ordinary ones ("hazel", "she") reach 2. Its
    /// spans also score below every other detector's, so where they overlap
    /// the other finding wins.
    static let threshold: Float = 2
    static let lowercaseThreshold: Float = 4
    static let score = 0.55

    struct Token {
        let range: Range<Int>
        let scalars: [Unicode.Scalar]
        var isWord: Bool { scalars.first.map(NameModel.isWord) == true }
    }

    private let buckets: Int
    private let embed: Int
    private let hidden: Int
    private let kernel: Int
    private let shapes: Int
    private let dilations: [Int]
    private let scales: [Float]
    private let table: [Int8]
    private let project: [Float]
    private let projectBias: [Float]
    private let convs: [[Float]]
    private let convBiases: [[Float]]
    private let out: [Float]
    private let outBias: Float
    /// Features by word, shared across calls: a document repeats its words in
    /// every row and every correction pass. Keyed by the word's exact scalars, as a
    /// String would take "é" and "e" with a combining accent as one word.
    private let known = Mutex<[[UInt32]: [Float]]>([:])
    private static let knownLimit = 100_000

    /// The SHA-256 of the shipped weights. A file that differs is not loaded:
    /// Scrub then runs without the model, and says why in the log.
    static let checksum = "0a3ff56f26b61c0bc4f28ae8f1e93e0b499633768a4b29cd3013791e2b8293e9"
    private static let log = Logger(subsystem: "Scrub", category: "NameModel")

    private static func load() -> NameModel? {
        guard let url = ModelResources.bundle?.url(forResource: "NameModel", withExtension: "bin"), let data = try? Data(contentsOf: url) else {
            log.error("Name model not loaded: resource missing")
            return nil
        }
        return verified(data)
    }

    /// The model in `data`, or nil when its bytes are not the ones `checksum` names.
    static func verified(_ data: Data, checksum: String = checksum) -> NameModel? {
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
            log.error("Name model not loaded: its weights do not match the expected checksum")
            return nil
        }
        return NameModel(data)
    }

    init?(_ data: Data) {
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("SNM1".utf8) else { return nil }
        let sizes = (0..<6).map { _ in Int(reader.uint32()) }
        (buckets, embed, hidden, kernel, shapes) = (sizes[0], sizes[1], sizes[2], sizes[3], sizes[5])
        dilations = (0..<sizes[4]).map { _ in Int(reader.uint32()) }
        scales = reader.floats(buckets)
        table = reader.int8s(buckets * embed)
        project = reader.floats((embed + shapes) * hidden)
        projectBias = reader.floats(hidden)
        var convs: [[Float]] = [], convBiases: [[Float]] = []
        for _ in dilations {
            convs.append(reader.floats(kernel * hidden * hidden))
            convBiases.append(reader.floats(hidden))
        }
        (self.convs, self.convBiases) = (convs, convBiases)
        out = reader.floats(hidden)
        outBias = reader.floats(1).first ?? 0
        guard reader.isValid, reader.offset == data.count else { return nil }
    }

    /// Each token of a text and how sure the model is that it names someone.
    struct Reading {
        let tokens: [Token]
        let scores: [Float]

        /// The model's surest score for a word inside `range`, or nil when no word is.
        func score(in range: Range<Int>) -> Float? {
            var low = 0, high = tokens.count
            while low < high {
                let middle = (low + high) / 2
                if tokens[middle].range.upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
            }
            var best: Float?
            var index = low
            while index < tokens.count, tokens[index].range.lowerBound < range.upperBound {
                if tokens[index].isWord { best = max(best ?? -.infinity, scores[index]) }
                index += 1
            }
            return best
        }
    }

    /// Person names and handles in `text`, in UTF-16 offsets.
    func find(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        read(text, isCancelled: isCancelled).map { find(text, reading: $0) } ?? []
    }

    /// The model's score for every token of `text`, or nil when it has
    /// too few words to read or the read was cancelled.
    func read(_ text: String, isCancelled: () -> Bool = { false }) -> Reading? {
        guard !isCancelled() else { return nil }
        let tokens = Self.tokens(text)
        // The model reads a name from the words around it. A value that is
        // nothing but one word ("Path", a key) gives it none, and the field's
        // key and the other rules judge it better.
        guard tokens.filter(\.isWord).count >= 2 else { return nil }
        let scores = logits(tokens, isCancelled: isCancelled)
        guard scores.count == tokens.count else { return nil }
        return Reading(tokens: tokens, scores: scores)
    }

    /// The names and handles a reading holds.
    func find(_ text: String, reading: Reading) -> [Span] {
        let tokens = reading.tokens, scores = reading.scores
        var spans: [Span] = []
        var index = 0
        while index < tokens.count {
            guard tokens[index].isWord, scores[index] >= Self.threshold(tokens[index]), !Self.settingValue(tokens, at: index) else { index += 1; continue }
            var end = index
            // Words of one name sit next to each other with only spaces between.
            while end + 1 < tokens.count, tokens[end + 1].isWord, scores[end + 1] >= Self.threshold(tokens[end + 1]),
                  Self.onlySpaces(text, tokens[end].range.upperBound..<tokens[end + 1].range.lowerBound) {
                end += 1
            }
            var upper = tokens[end].range.upperBound
            let last = tokens[end].scalars
            // "Priya's" names Priya.
            if last.count > 2, last[last.count - 1] == "s", last[last.count - 2] == "'" || last[last.count - 2] == "’" { upper -= 2 }
            let range = tokens[index].range.lowerBound..<upper
            let handle = index == end && Self.looksLikeHandle(tokens[index].scalars)
            // A file's name ("./bin/tool-cli.js") is no one's handle.
            if handle, let dot = last.lastIndex(of: "."), ContextStage.fileExtensions.contains(String(String.UnicodeScalarView(last[(dot + 1)...])).lowercased()) { index = end + 1; continue }
            let alone = !tokens[..<index].contains(where: \.isWord) && !tokens[(end + 1)...].contains(where: \.isWord)
            if !alone, Self.couldName(tokens[index...end]), handle || !NameTagger.partOfOrganisation(range, in: text) {
                spans.append(Span(range: range, entity: handle ? "USERNAME" : "PERSON", score: Self.score))
            }
            index = end + 1
        }
        return spans
    }

    /// A plain lowercase word right after "=" or ":" ("brand = visa",
    /// "gender: female") is a setting's value; a person there is written
    /// with capitals or as a handle.
    private static func settingValue(_ tokens: [Token], at index: Int) -> Bool {
        guard index > 0, tokens[index].scalars.first?.properties.isLowercase == true, tokens[index].scalars.allSatisfy(isLetter) else { return false }
        let assigns: Set<[Unicode.Scalar]> = [["="], [":"]]
        var before = index - 1
        // A quoted value: `brand: "visa"`.
        if before > 0, tokens[before].scalars == ["\""] || tokens[before].scalars == ["'"] { before -= 1 }
        return assigns.contains(tokens[before].scalars)
    }

    /// The stricter bar is for a plain lowercase word, which may be an
    /// ordinary one; a handle ("maria.gonzalez", "jdoe42") is no dictionary word.
    private static func threshold(_ token: Token) -> Float {
        token.scalars.first?.properties.isLowercase == true && token.scalars.allSatisfy(isLetter) ? lowercaseThreshold : threshold
    }

    /// One score per token; at or above the threshold means a person.
    func logits(_ tokens: [Token], isCancelled: () -> Bool = { false }) -> [Float] {
        // Each token sees 14 tokens either side, so windows overlapping by a
        // wider margin give the same scores as one pass over the whole text.
        let reach = dilations.reduce(0) { $0 + $1 * (kernel / 2) }
        let margin = reach + 2
        let step = 2048
        var result = [Float](repeating: 0, count: tokens.count)
        var start = 0
        while start < tokens.count {
            if isCancelled() { return [] }
            let from = max(0, start - margin), to = min(tokens.count, start + step + margin)
            let window = run(tokens[from..<to])
            for index in start..<min(tokens.count, start + step) { result[index] = window[index - from] }
            start += step
        }
        return result
    }

    private func run(_ tokens: ArraySlice<Token>) -> [Float] {
        let count = tokens.count, width = embed + shapes
        var input = [Float](repeating: 0, count: count * width)
        let keys = tokens.map { $0.scalars.map(\.value) }
        var found = known.withLock { cache in keys.map { cache[$0] } }
        var fresh: [[UInt32]: [Float]] = [:]
        for (row, token) in tokens.enumerated() where found[row] == nil {
            let features = fresh[keys[row]] ?? self.features(token.scalars)
            fresh[keys[row]] = features
            found[row] = features
        }
        if !fresh.isEmpty {
            known.withLock { cache in
                if cache.count + fresh.count > Self.knownLimit { cache.removeAll(keepingCapacity: true) }
                cache.merge(fresh) { old, _ in old }
            }
        }
        for row in 0..<count { input.replaceSubrange(row * width..<(row + 1) * width, with: found[row]!) }
        var state = [Float](repeating: 0, count: count * hidden)
        vDSP_mmul(input, 1, project, 1, &state, 1, vDSP_Length(count), vDSP_Length(hidden), vDSP_Length(width))
        let biases = Self.tiled(projectBias, rows: count)
        vDSP_vadd(state, 1, biases, 1, &state, 1, vDSP_Length(count * hidden))
        Self.relu(&state)
        var product = [Float](repeating: 0, count: count * hidden)
        for (layer, dilation) in dilations.enumerated() {
            var sum = Self.tiled(convBiases[layer], rows: count)
            for tap in 0..<kernel {
                let shift = (tap - kernel / 2) * dilation
                let rows = count - abs(shift)
                guard rows > 0 else { continue }
                let source = max(0, shift), target = max(0, -shift)
                state.withUnsafeBufferPointer { from in
                    convs[layer].withUnsafeBufferPointer { weights in
                        product.withUnsafeMutableBufferPointer { into in
                            vDSP_mmul(from.baseAddress! + source * hidden, 1, weights.baseAddress! + tap * hidden * hidden, 1,
                                      into.baseAddress!, 1, vDSP_Length(rows), vDSP_Length(hidden), vDSP_Length(hidden))
                        }
                    }
                }
                sum.withUnsafeMutableBufferPointer { into in
                    product.withUnsafeBufferPointer { from in
                        vDSP_vadd(into.baseAddress! + target * hidden, 1, from.baseAddress!, 1, into.baseAddress! + target * hidden, 1, vDSP_Length(rows * hidden))
                    }
                }
            }
            Self.relu(&sum)
            vDSP_vadd(state, 1, sum, 1, &state, 1, vDSP_Length(count * hidden))
        }
        var result = [Float](repeating: outBias, count: count)
        var scores = [Float](repeating: 0, count: count)
        vDSP_mmul(state, 1, out, 1, &scores, 1, vDSP_Length(count), 1, vDSP_Length(hidden))
        vDSP_vadd(result, 1, scores, 1, &result, 1, vDSP_Length(count))
        return result
    }

    private static func tiled(_ row: [Float], rows: Int) -> [Float] {
        var result = [Float](repeating: 0, count: row.count * rows)
        for index in 0..<rows { result.replaceSubrange(index * row.count..<(index + 1) * row.count, with: row) }
        return result
    }

    private static func relu(_ values: inout [Float]) {
        var zero: Float = 0
        let count = vDSP_Length(values.count)
        values.withUnsafeMutableBufferPointer { buffer in
            vDSP_vthres(buffer.baseAddress!, 1, &zero, buffer.baseAddress!, 1, count)
        }
    }

    /// The token's embedding (the mean of its hashed pieces' rows) followed by its shape.
    private func features(_ scalars: [Unicode.Scalar]) -> [Float] {
        let rows = Self.buckets(scalars, count: buckets)
        var result = [Float](repeating: 0, count: embed)
        var unpacked = [Float](repeating: 0, count: embed)
        table.withUnsafeBufferPointer { table in
            for row in rows {
                vDSP_vflt8(table.baseAddress! + row * embed, 1, &unpacked, 1, vDSP_Length(embed))
                var scale = scales[row] / Float(rows.count)
                vDSP_vsma(unpacked, 1, &scale, result, 1, &result, 1, vDSP_Length(embed))
            }
        }
        return result + Self.shape(scalars)
    }

    static func tokens(_ text: String) -> [Token] {
        let scalars = Array(text.unicodeScalars)
        var offsets = [Int](), offset = 0
        offsets.reserveCapacity(scalars.count + 1)
        for scalar in scalars { offsets.append(offset); offset += scalar.utf16.count }
        offsets.append(offset)
        var tokens: [Token] = [], index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if isWord(scalar) {
                var end = index + 1
                while end < scalars.count, isWord(scalars[end]) || (connectors.contains(scalars[end]) && end + 1 < scalars.count && isWord(scalars[end + 1])) {
                    end += 1
                }
                tokens.append(Token(range: offsets[index]..<offsets[end], scalars: Array(scalars[index..<end])))
                index = end
            } else {
                if scalar == "\n" || !isSpace(scalar) { tokens.append(Token(range: offsets[index]..<offsets[index + 1], scalars: [scalar])) }
                index += 1
            }
        }
        return tokens
    }

    private static let connectors: Set<Unicode.Scalar> = [".", "-", "_", "'", "’", "@"]

    static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    /// Python's str.isspace, which model.py uses.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    private static func onlySpaces(_ text: String, _ range: Range<Int>) -> Bool {
        let ns = text as NSString
        return range.allSatisfy { ns.character(at: $0) == 32 || ns.character(at: $0) == 9 }
    }

    /// A lone word of one or two letters ("e", "Id") names no one, a lone word
    /// in capitals is a code or acronym ("WA", "IBAN") far more often than a
    /// name, and a literal ("false", "null") replaced would break the file it is in.
    private static func couldName(_ words: ArraySlice<Token>) -> Bool {
        let letters = words.map { $0.scalars.filter(isLetter) }
        guard letters.contains(where: { $0.count >= 2 }) else { return false }
        if words.count == 1 {
            if letters[0].count < 3 || letters[0].allSatisfy(\.properties.isUppercase) { return false }
            if literals.contains(String(String.UnicodeScalarView(words[words.startIndex].scalars)).lowercased()) { return false }
        }
        return true
    }
    private static let literals: Set<String> = ["true", "false", "null", "nil", "none", "undefined", "nan", "yes", "no"]

    private static func looksLikeHandle(_ scalars: [Unicode.Scalar]) -> Bool {
        scalars.contains { "._".unicodeScalars.contains($0) || $0.properties.generalCategory == .decimalNumber }
            || (scalars.contains("-") && !scalars.contains { $0.properties.isUppercase })
    }

    static func buckets(_ scalars: [Unicode.Scalar], count: Int) -> [Int] {
        var marked: [Unicode.Scalar] = ["<"]
        for scalar in scalars { marked.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars) }
        marked.append(">")
        var rows: [Int] = []
        func add(_ piece: ArraySlice<Unicode.Scalar>) {
            var hash: UInt32 = 0x811C_9DC5
            for scalar in piece {
                for byte in UTF8.encode(scalar)! { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
            }
            rows.append(Int(hash % UInt32(count)))
            rows.append(Int((hash >> 16) % UInt32(count)))
        }
        add(marked[...])
        for size in 2...4 where marked.count >= size {
            for start in 0...(marked.count - size) { add(marked[start..<(start + size)]) }
        }
        return rows
    }

    static func shape(_ scalars: [Unicode.Scalar]) -> [Float] {
        let letters = scalars.filter(isLetter)
        let upper = letters.filter(\.properties.isUppercase)
        let length = scalars.count
        func flag(_ value: Bool) -> Float { value ? 1 : 0 }
        return [
            flag(scalars.first?.properties.isUppercase == true),
            flag(letters.count > 1 && upper.count == letters.count),
            flag(!letters.isEmpty && upper.isEmpty),
            flag(scalars.contains { $0.properties.generalCategory == .decimalNumber }),
            flag(scalars.contains(".") && length > 1),
            flag(scalars.contains("_")),
            flag(scalars.contains("-") && length > 1),
            flag(scalars.contains("@") && length > 1),
            flag(scalars == ["\n"]),
            flag(length == 1 && !isWord(scalars[0]) && scalars[0] != "\n"),
            Float(min(length, 20)) / 20,
            flag(letters.contains { $0.value > 127 }),
            flag(!upper.isEmpty && upper.count < letters.count && scalars.dropFirst().contains { $0.properties.isUppercase }),
            flag(scalars.contains("'") || scalars.contains("’")),
        ]
    }

    private struct Reader {
        let data: Data
        var offset = 0
        var isValid = true

        mutating func bytes(_ count: Int) -> Data {
            guard count >= 0, offset + count <= data.count else { isValid = false; return Data() }
            defer { offset += count }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }

        mutating func uint32() -> UInt32 {
            bytes(4).withUnsafeBytes { $0.count == 4 ? UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) : 0 }
        }

        mutating func floats(_ count: Int) -> [Float] {
            let raw = bytes(count * 4)
            guard raw.count == count * 4 else { return [] }
            // The file is little-endian, as is every Mac Scrub runs on.
            return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
                initialized = count
            }
        }

        mutating func int8s(_ count: Int) -> [Int8] {
            let raw = bytes(count)
            guard raw.count == count else { return [] }
            return [Int8](unsafeUninitializedCapacity: count) { buffer, initialized in
                _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
                initialized = count
            }
        }
    }
}
