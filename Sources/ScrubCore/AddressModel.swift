import Accelerate
import CryptoKit
import Foundation
import os
import Synchronization

/// A small network that reads text around lines with numbers in them and
/// marks the postal addresses there, each as one unit: its unit and building
/// lines, street, locality, postcode and country. It catches what the street
/// pattern and the system detector miss: a signature's address in another
/// country's format, a flat over its street, a street in prose with no
/// postcode. Tools/AddressModel trains it; this mirrors model.py exactly, so
/// change both together.
final class AddressModel: Sendable {
    static let shared: AddressModel? = load()
    /// How likely a token must be to sit inside an address, as the summed
    /// probability of beginning and continuing one.
    static let threshold: Float = 0.5
    /// Below every rule's score, and below the review line: an address only
    /// the model read is shown for review before sharing.
    static let score = 0.6
    /// Off only inside a test's `withValue` scope, to show what Scrub finds
    /// without the model. A detector reads it when it is made, so a scrub
    /// started in that scope runs without the model on every thread, and
    /// every other scrub runs with it.
    @TaskLocal static var active = true

    private let buckets: Int
    private let embed: Int
    private let hidden: Int
    private let kernel: Int
    private let shapes: Int
    private let labels: Int
    private let dilations: [Int]
    private let scales: [Float]
    private let table: [Int8]
    private let project: [Float]
    private let projectBias: [Float]
    private let convs: [[Float]]
    private let convBiases: [[Float]]
    private let out: [Float]
    private let outBias: [Float]
    /// Features by word, shared across calls.
    private let known = Mutex<[String: [Float]]>([:])
    private static let knownLimit = 100_000

    /// The SHA-256 of the shipped weights. A file that differs is not loaded:
    /// Scrub then runs without the model, and says why in the log.
    static let checksum = "68a0742d13a305b93762ffab2f076b956de7cfa8f8b805fa2cd81a18b7b07d59"
    private static let log = Logger(subsystem: "Scrub", category: "AddressModel")

    private static func load() -> AddressModel? {
        guard let url = ModelResources.bundle?.url(forResource: "AddressModel", withExtension: "bin"), let data = try? Data(contentsOf: url) else {
            log.error("Address model not loaded: resource missing")
            return nil
        }
        return verified(data)
    }

    /// The model in `data`, or nil when its bytes are not the ones `checksum` names.
    static func verified(_ data: Data, checksum: String = checksum) -> AddressModel? {
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
            log.error("Address model not loaded: its weights do not match the expected checksum")
            return nil
        }
        return AddressModel(data)
    }

    init?(_ data: Data) {
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("SAM1".utf8) else { return nil }
        let sizes = (0..<7).map { _ in Int(reader.uint32()) }
        (buckets, embed, hidden, kernel, shapes, labels) = (sizes[0], sizes[1], sizes[2], sizes[3], sizes[5], sizes[6])
        guard buckets > 0, embed > 0, hidden > 0, kernel > 0, labels == 3, sizes[4] <= 16 else { return nil }
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
        out = reader.floats(hidden * labels)
        outBias = reader.floats(labels)
        guard reader.isValid, reader.offset == data.count, shapes == Self.shapeCount else { return nil }
    }

    // MARK: Finding addresses

    /// Postal addresses in `text`, in UTF-16 offsets. Only the lines around
    /// one with a digit and a word are read; text with no digit holds none.
    func find(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        guard !isCancelled(), text.utf16.contains(where: { (48...57).contains($0) }) else { return [] }
        var spans: [Span] = []
        for window in Self.windows(text) {
            if isCancelled() { return [] }
            let part = TextRanges.substring(text, window)
            let tokens = NameModel.tokens(part)
            guard tokens.contains(where: { $0.scalars.contains(where: Self.isDigit) }) else { continue }
            let probabilities = self.probabilities(tokens, isCancelled: isCancelled)
            guard probabilities.count == tokens.count else { return [] }
            for range in Self.decode(tokens, probabilities).compactMap({ Self.refined($0, tokens) }) {
                spans.append(Span(range: (range.lowerBound + window.lowerBound)..<(range.upperBound + window.lowerBound), entity: "ADDRESS", score: Self.score))
            }
        }
        return spans
    }

    /// The stretches worth reading: every line with a decimal digit and a
    /// word of two letters, with the two lines either side (a city or a
    /// country on a line of its own), joined where they meet.
    static func windows(_ text: String) -> [Range<Int>] {
        let ns = text as NSString
        var lines: [(range: Range<Int>, candidate: Bool)] = []
        var start = 0
        while start < ns.length {
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            let range = line.location..<NSMaxRange(line)
            lines.append((range, candidate(ns, range)))
            start = NSMaxRange(line)
        }
        var windows: [Range<Int>] = []
        for (index, line) in lines.enumerated() where line.candidate {
            let from = lines[max(0, index - 2)].range.lowerBound, to = lines[min(lines.count - 1, index + 2)].range.upperBound
            if let last = windows.last, last.upperBound >= from {
                windows[windows.count - 1] = last.lowerBound..<max(last.upperBound, to)
            } else {
                windows.append(from..<to)
            }
        }
        return windows
    }

    private static func candidate(_ ns: NSString, _ range: Range<Int>) -> Bool {
        var digit = false, letters = 0, best = 0
        for index in range {
            let unit = ns.character(at: index)
            if (48...57).contains(unit) { digit = true; letters = 0; continue }
            if let scalar = Unicode.Scalar(unit), scalar.properties.isAlphabetic { letters += 1; best = max(best, letters) } else if !(0xD800...0xDFFF).contains(unit) { letters = 0 }
            if digit && best >= 2 { return true }
        }
        return digit && best >= 2
    }

    /// Address spans from per-token probabilities of O, B and I, in the
    /// window's UTF-16 offsets. A run of tokens inside an address is one, split
    /// where a token is likelier to begin an address than continue it; its
    /// ends lose punctuation and line breaks, but a closing bracket whose
    /// opening one is inside stays. An address holds a digit and two words.
    static func decode(_ tokens: [NameModel.Token], _ probabilities: [[Float]]) -> [Range<Int>] {
        var runs: [(Int, Int)] = [], current: (Int, Int)?
        for (index, p) in probabilities.enumerated() {
            let inside = p[1] + p[2] >= threshold
            if inside, current != nil, p[1] > p[2], p[1] > p[0] {
                runs.append(current!)
                current = nil
            }
            if inside {
                current = current.map { ($0.0, index) } ?? (index, index)
            } else if let run = current {
                runs.append(run)
                current = nil
            }
        }
        if let current { runs.append(current) }
        var result: [Range<Int>] = []
        for (start, end) in runs {
            var first = start, last = end
            while first <= last, !tokens[first].isWord { first += 1 }
            while last >= first, !tokens[last].isWord {
                if tokens[last].scalars == [")"], tokens[first..<last].contains(where: { $0.scalars == ["("] }) { break }
                last -= 1
            }
            guard first <= last else { continue }
            let span = tokens[first...last]
            guard span.filter({ $0.scalars.contains(where: isLetter) }).count >= 2, span.contains(where: { $0.scalars.contains(where: isDigit) }) else { continue }
            result.append(tokens[first].range.lowerBound..<tokens[last].range.upperBound)
        }
        return result
    }

    /// An address without the ordinary words the model let run into it: a
    /// lowercase word or two before it ("be Apt 1205, …"), or after its last
    /// number or capitalised word ("… 44100 Nantes s'il", "… QLD 4006 shortly").
    /// A street written in lowercase ("12 rue de la paix") keeps its words: only
    /// a piece that holds a capitalised word loses a lowercase tail.
    static func refined(_ range: Range<Int>, _ tokens: [NameModel.Token]) -> Range<Int>? {
        guard var first = tokens.firstIndex(where: { $0.range.lowerBound == range.lowerBound }),
              var last = tokens.lastIndex(where: { $0.range.upperBound == range.upperBound }) else { return range }
        func text(_ index: Int) -> String { String(String.UnicodeScalarView(tokens[index].scalars)) }
        func lowercaseWord(_ index: Int) -> Bool { tokens[index].isWord && tokens[index].scalars.allSatisfy { isLetter($0) || $0 == "'" || $0 == "’" } && tokens[index].scalars.first?.properties.isLowercase == true }
        func marked(_ index: Int) -> Bool { tokens[index].scalars.contains(where: isDigit) || tokens[index].scalars.first?.properties.isUppercase == true }
        // The last piece: what follows the last comma or line break.
        let pieceStart = ((first...last).last { [",", "\n", ";"].contains(text($0)) }).map { $0 + 1 } ?? first
        if let anchor = (pieceStart...last).last(where: marked), anchor < last,
           (anchor + 1...last).allSatisfy({ lowercaseWord($0) || !tokens[$0].isWord && text($0) != "\n" }),
           (pieceStart...anchor).contains(where: { tokens[$0].scalars.first?.properties.isUppercase == true }) {
            last = anchor
        }
        while first < last, lowercaseWord(first), !leadWords.contains(text(first).lowercased()), (first + 1...last).contains(where: marked) {
            first += 1
            while first < last, !tokens[first].isWord { first += 1 }
        }
        // ")" closes "(FI)"; "." ends "St." only when the model kept it, which decode never does.
        while last > first, !tokens[last].isWord, text(last) != ")" { last -= 1 }
        let words = tokens[first...last].filter { $0.scalars.contains(where: isLetter) }
        guard words.count >= 2, tokens[first...last].contains(where: { $0.scalars.contains(where: isDigit) }) else { return nil }
        return tokens[first].range.lowerBound..<tokens[last].range.upperBound
    }
    /// Lowercase words that open an address: a kind of street or a box.
    private static let leadWords: Set<String> = ["rue", "avenue", "allée", "chemin", "impasse", "quai", "place", "route", "boulevard", "via", "viale", "piazza", "corso",
                                                 "calle", "avenida", "rua", "travessa", "ul", "al", "os", "pl", "po", "p", "box", "c", "flat", "apt", "suite", "unit",
                                                 "rang", "chaussée", "plaza", "paseo", "camino", "largo", "vicolo", "strada", "alameda", "estrada", "praça", "postfach", "postbus"]

    // MARK: The network

    /// Softmax probabilities of O, B and I for each token.
    func probabilities(_ tokens: [NameModel.Token], isCancelled: () -> Bool = { false }) -> [[Float]] {
        logits(tokens, isCancelled: isCancelled).map { row in
            let top = row.max() ?? 0
            let exps = row.map { Foundation.exp($0 - top) }
            let sum = exps.reduce(0, +)
            return exps.map { $0 / sum }
        }
    }

    /// Three logits per token, in windows that overlap by more than the
    /// network's reach, so a long text scores as one pass would.
    func logits(_ tokens: [NameModel.Token], isCancelled: () -> Bool = { false }) -> [[Float]] {
        let reach = dilations.reduce(0) { $0 + $1 * (kernel / 2) }
        let margin = reach + 2
        let step = 2048
        var result = [[Float]](repeating: [], count: tokens.count)
        let lines = Self.lineShapes(tokens)
        var start = 0
        while start < tokens.count {
            if isCancelled() { return [] }
            let from = max(0, start - margin), to = min(tokens.count, start + step + margin)
            let window = run(tokens[from..<to], lines: lines[from..<to])
            for index in start..<min(tokens.count, start + step) {
                result[index] = Array(window[(index - from) * labels..<(index - from + 1) * labels])
            }
            start += step
        }
        return result
    }

    private func run(_ tokens: ArraySlice<NameModel.Token>, lines: ArraySlice<[Float]>) -> [Float] {
        let count = tokens.count, width = embed + shapes
        var input = [Float](repeating: 0, count: count * width)
        let keys = tokens.map { String(String.UnicodeScalarView($0.scalars)) }
        var found = known.withLock { cache in keys.map { cache[$0] } }
        var fresh: [String: [Float]] = [:]
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
        for (row, line) in zip(0..<count, lines) {
            input.replaceSubrange(row * width..<(row * width + width - line.count), with: found[row]!)
            input.replaceSubrange((row * width + width - line.count)..<(row + 1) * width, with: line)
        }
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
        var result = Self.tiled(outBias, rows: count)
        var scores = [Float](repeating: 0, count: count * labels)
        vDSP_mmul(state, 1, out, 1, &scores, 1, vDSP_Length(count), vDSP_Length(labels), vDSP_Length(hidden))
        vDSP_vadd(result, 1, scores, 1, &result, 1, vDSP_Length(count * labels))
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

    // MARK: Features

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

    /// Pieces of the word lowercased, with every decimal digit read as 0: the
    /// whole word and its 2-, 3- and 4-grams, two rows each.
    static func buckets(_ scalars: [Unicode.Scalar], count: Int) -> [Int] {
        var marked: [Unicode.Scalar] = ["<"]
        for scalar in scalars {
            if isDigit(scalar) { marked.append("0") } else { marked.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars) }
        }
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

    /// The token's own shape; three more features, of its line, follow (see `lineShapes`).
    static let shapeCount = 18
    static func shape(_ scalars: [Unicode.Scalar]) -> [Float] {
        let letters = scalars.filter(isLetter)
        let upper = letters.filter(\.properties.isUppercase)
        let digits = scalars.filter(isDigit).count
        let length = scalars.count
        func flag(_ value: Bool) -> Float { value ? 1 : 0 }
        return [
            flag(scalars.first?.properties.isUppercase == true),
            flag(letters.count > 1 && upper.count == letters.count),
            flag(!letters.isEmpty && upper.isEmpty),
            flag(digits > 0),
            flag(digits > 0 && digits == length),
            flag((1...2).contains(digits)),
            flag(digits == 3),
            flag(digits == 4),
            flag(digits == 5),
            flag(digits >= 6),
            flag(digits > 0 && !letters.isEmpty),
            flag(scalars == ["\n"]),
            flag(length == 1 && !NameModel.isWord(scalars[0]) && scalars[0] != "\n"),
            Float(min(length, 20)) / 20,
            flag(letters.contains { $0.value > 127 }),
        ]
    }

    /// For each token: whether it opens its line, whether its line holds a
    /// digit, and whether it holds a comma. A line ends with its newline token.
    static func lineShapes(_ tokens: [NameModel.Token]) -> [[Float]] {
        var result = [[Float]](repeating: [0, 0, 0], count: tokens.count)
        var start = 0
        while start < tokens.count {
            var end = start
            while end < tokens.count, tokens[end].scalars != ["\n"] { end += 1 }
            let last = min(end, tokens.count - 1)
            let words = tokens[start..<min(end, tokens.count)]
            let digit: Float = words.contains { $0.scalars.contains(where: isDigit) } ? 1 : 0
            let comma: Float = words.contains { $0.scalars == [","] } ? 1 : 0
            for index in start...last {
                result[index] = [index == start && tokens[index].scalars != ["\n"] ? 1 : 0, digit, comma]
            }
            start = end + 1
        }
        return result
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .decimalNumber }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
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
