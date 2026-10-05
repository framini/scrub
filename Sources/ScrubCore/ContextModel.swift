import Accelerate
import CryptoKit
import Foundation
import os

/// A pretrained multilingual encoder, fine-tuned to read personal details from
/// the sentence around them: a town someone lives in, the company someone
/// works for, a name in a script the system tagger cannot read, a handle, and
/// IDs, secrets and birth dates no label announces. Tools/ContextModel builds
/// its weight file; this mirrors the tokenizer and network exactly, so change
/// both together.
///
/// The weights ship as ordinary resource files, split in parts, and must hash
/// to their checksum in `ContextWeights`. A missing or altered part leaves
/// Scrub without the model: every other detector still runs, and the reason is logged.
final class ContextModel: Sendable {
    static let shared: ContextModel? = load(ContextWeights.shipped)
    static let window = 128
    static let stride = 96
    private static let log = Logger(subsystem: "Scrub", category: "ContextModel")

    let tokenizer: PieceTokenizer
    let labels: [String]
    /// Ordinary words, for the gate: the commonest words of plain prose, and a
    /// dictionary's lowercase entries.
    let common: Set<String>
    let dictionary: Set<String>
    private let layers: [Layer]
    private let hidden: Int
    private let heads: Int
    private let inner: Int
    private let positions: Int
    private let epsilon: Float
    private let wordRows: [Int8]
    private let wordScales: [Float]
    private let position: [Float]
    private let embedNorm: (gain: [Float], bias: [Float])
    private let classifier: [Float]
    private let classifierBias: [Float]

    private struct Layer {
        let qkv: [Float], qkvBias: [Float]
        let out: [Float], outBias: [Float]
        let norm1: (gain: [Float], bias: [Float])
        let up: [Float], upBias: [Float]
        let down: [Float], downBias: [Float]
        let norm2: (gain: [Float], bias: [Float])
    }

    private static func load(_ weights: ContextWeights) -> ContextModel? {
        var parts: [Data] = []
        for index in 1...weights.parts {
            guard let url = weights.url(part: index), let part = try? Data(contentsOf: url, options: .alwaysMapped) else {
                log.error("Context model not loaded: part \(index) of \(weights.parts) missing")
                return nil
            }
            parts.append(part)
        }
        guard let data = verified(parts, weights: weights) else {
            log.error("Context model not loaded: its weights do not match the expected checksum")
            return nil
        }
        guard let model = ContextModel(data) else { log.error("Context model not loaded: weight file unreadable"); return nil }
        return model
    }

    /// The parts joined in order, if they hash to the weights' checksum.
    static func verified(_ parts: [Data], weights: ContextWeights = .shipped, checksum: String? = nil) -> Data? {
        let checksum = checksum ?? weights.checksum
        guard parts.count == weights.parts else { return nil }
        var data = Data(capacity: parts.reduce(0) { $0 + $1.count })
        for part in parts { data.append(part) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == checksum ? data : nil
    }

    init?(_ data: Data) {
        var reader = WeightReader(data: data)
        guard reader.bytes(4) == Data("SCM1".utf8) else { return nil }
        let sizes = (0..<7).map { _ in Int(reader.uint32()) }
        let (layerCount, hidden, heads, inner, positions, vocabulary, labelCount) = (sizes[0], sizes[1], sizes[2], sizes[3], sizes[4], sizes[5], sizes[6])
        guard hidden > 0, heads > 0, hidden % heads == 0, vocabulary > 4, labelCount > 0, positions >= Self.window else { return nil }
        (self.hidden, self.heads, self.inner, self.positions) = (hidden, heads, inner, positions)
        epsilon = reader.floats(1).first ?? 1e-12
        let ids = (0..<4).map { _ in Int32(bitPattern: reader.uint32()) }
        let pieces = reader.strings()
        let scores = reader.doubles(vocabulary)
        let charsmap = reader.bytes(Int(reader.uint32()))
        labels = reader.strings().map { String(decoding: $0, as: UTF8.self) }
        common = Set(reader.strings().map { String(decoding: $0, as: UTF8.self) })
        dictionary = Set(reader.strings().map { String(decoding: $0, as: UTF8.self) })
        guard pieces.count == vocabulary, scores.count == vocabulary, labels.count == labelCount,
              let tokenizer = PieceTokenizer(pieces: pieces, scores: scores, charsmap: charsmap, unknown: ids[0], cls: ids[2], sep: ids[3]) else { return nil }
        self.tokenizer = tokenizer
        wordScales = reader.floats(vocabulary)
        wordRows = reader.int8s(vocabulary * hidden)
        position = reader.floats(positions * hidden)
        embedNorm = (reader.floats(hidden), reader.floats(hidden))
        var layers: [Layer] = []
        for _ in 0..<layerCount {
            let qkv = reader.halves(hidden * 3 * hidden), qkvBias = reader.floats(3 * hidden)
            let out = reader.halves(hidden * hidden), outBias = reader.floats(hidden)
            let norm1 = (reader.floats(hidden), reader.floats(hidden))
            let up = reader.halves(hidden * inner), upBias = reader.floats(inner)
            let down = reader.halves(inner * hidden), downBias = reader.floats(hidden)
            let norm2 = (reader.floats(hidden), reader.floats(hidden))
            layers.append(Layer(qkv: qkv, qkvBias: qkvBias, out: out, outBias: outBias, norm1: norm1, up: up, upBias: upBias, down: down, downBias: downBias, norm2: norm2))
        }
        self.layers = layers
        classifier = reader.floats(hidden * labelCount)
        classifierBias = reader.floats(labelCount)
        guard reader.isValid, reader.offset == data.count else { return nil }
    }

    // MARK: - Network

    /// Logits for one window of piece ids, `labels.count` a piece.
    func logits(_ ids: [Int32]) -> [Float] {
        let count = ids.count
        guard count > 0, count <= positions else { return [] }
        var state = [Float](repeating: 0, count: count * hidden)
        state.withUnsafeMutableBufferPointer { into in
            wordRows.withUnsafeBufferPointer { rows in
                for (row, id) in ids.enumerated() {
                    let piece = Int(id), target = into.baseAddress! + row * hidden
                    vDSP_vflt8(rows.baseAddress! + piece * hidden, 1, target, 1, vDSP_Length(hidden))
                    var scale = wordScales[piece]
                    vDSP_vsmul(target, 1, &scale, target, 1, vDSP_Length(hidden))
                }
            }
        }
        // In place: passing an array as input and output copies it first, and
        // a sum or product rounds once, so the result is the same.
        state.withUnsafeMutableBufferPointer { into in vDSP_vadd(into.baseAddress!, 1, position, 1, into.baseAddress!, 1, vDSP_Length(count * hidden)) }
        normalize(&state, rows: count, embedNorm)
        var scratch = Scratch()
        for layer in layers { apply(layer, to: &state, rows: count, scratch: &scratch) }
        var result = multiply(state, rows: count, inner: hidden, classifier, columns: labels.count)
        add(classifierBias, to: &result, rows: count)
        return result
    }

    private func apply(_ layer: Layer, to state: inout [Float], rows: Int, scratch: inout Scratch) {
        let width = hidden / heads
        var qkv = multiply(state, rows: rows, inner: hidden, layer.qkv, columns: 3 * hidden)
        add(layer.qkvBias, to: &qkv, rows: rows)
        var context = [Float](repeating: 0, count: rows * hidden)
        var query = [Float](repeating: 0, count: rows * width), key = query, value = query
        var keyT = [Float](repeating: 0, count: width * rows)
        var weights = [Float](repeating: 0, count: rows * rows), mixed = [Float](repeating: 0, count: rows * width)
        var scale = 1 / Float(width).squareRoot()
        for head in 0..<heads {
            qkv.withUnsafeBufferPointer { all in
                vDSP_mmov(all.baseAddress! + head * width, &query, vDSP_Length(width), vDSP_Length(rows), vDSP_Length(3 * hidden), vDSP_Length(width))
                vDSP_mmov(all.baseAddress! + hidden + head * width, &key, vDSP_Length(width), vDSP_Length(rows), vDSP_Length(3 * hidden), vDSP_Length(width))
                vDSP_mmov(all.baseAddress! + 2 * hidden + head * width, &value, vDSP_Length(width), vDSP_Length(rows), vDSP_Length(3 * hidden), vDSP_Length(width))
            }
            vDSP_mtrans(key, 1, &keyT, 1, vDSP_Length(width), vDSP_Length(rows))
            vDSP_mmul(query, 1, keyT, 1, &weights, 1, vDSP_Length(rows), vDSP_Length(rows), vDSP_Length(width))
            weights.withUnsafeMutableBufferPointer { into in vDSP_vsmul(into.baseAddress!, 1, &scale, into.baseAddress!, 1, vDSP_Length(rows * rows)) }
            Self.softmax(&weights, rows: rows)
            vDSP_mmul(weights, 1, value, 1, &mixed, 1, vDSP_Length(rows), vDSP_Length(width), vDSP_Length(rows))
            context.withUnsafeMutableBufferPointer { into in
                vDSP_mmov(mixed, into.baseAddress! + head * width, vDSP_Length(width), vDSP_Length(rows), vDSP_Length(width), vDSP_Length(hidden))
            }
        }
        var attended = multiply(context, rows: rows, inner: hidden, layer.out, columns: hidden)
        add(layer.outBias, to: &attended, rows: rows)
        state.withUnsafeMutableBufferPointer { into in vDSP_vadd(into.baseAddress!, 1, attended, 1, into.baseAddress!, 1, vDSP_Length(rows * hidden)) }
        normalize(&state, rows: rows, layer.norm1)
        var raised = multiply(state, rows: rows, inner: hidden, layer.up, columns: inner)
        add(layer.upBias, to: &raised, rows: rows)
        Self.gelu(&raised, scratch: &scratch)
        var lowered = multiply(raised, rows: rows, inner: inner, layer.down, columns: hidden)
        add(layer.downBias, to: &lowered, rows: rows)
        state.withUnsafeMutableBufferPointer { into in vDSP_vadd(into.baseAddress!, 1, lowered, 1, into.baseAddress!, 1, vDSP_Length(rows * hidden)) }
        normalize(&state, rows: rows, layer.norm2)
    }

    private func multiply(_ left: [Float], rows: Int, inner: Int, _ right: [Float], columns: Int) -> [Float] {
        // Every element is written, so the result needs no zeros first.
        [Float](unsafeUninitializedCapacity: rows * columns) { result, count in
            vDSP_mmul(left, 1, right, 1, result.baseAddress!, 1, vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
            count = rows * columns
        }
    }

    private func add(_ bias: [Float], to values: inout [Float], rows: Int) {
        let width = bias.count
        values.withUnsafeMutableBufferPointer { into in
            for row in 0..<rows { vDSP_vadd(into.baseAddress! + row * width, 1, bias, 1, into.baseAddress! + row * width, 1, vDSP_Length(width)) }
        }
    }

    /// Layer norm over each row, then its gain and bias.
    private func normalize(_ values: inout [Float], rows: Int, _ norm: (gain: [Float], bias: [Float])) {
        let width = hidden
        values.withUnsafeMutableBufferPointer { into in
            for row in 0..<rows {
                let start = into.baseAddress! + row * width
                var mean: Float = 0, square: Float = 0
                vDSP_meanv(start, 1, &mean, vDSP_Length(width))
                var shift = -mean
                vDSP_vsadd(start, 1, &shift, start, 1, vDSP_Length(width))
                vDSP_measqv(start, 1, &square, vDSP_Length(width))
                var scale = 1 / (square + epsilon).squareRoot()
                vDSP_vsmul(start, 1, &scale, start, 1, vDSP_Length(width))
                vDSP_vma(start, 1, norm.gain, 1, norm.bias, 1, start, 1, vDSP_Length(width))
            }
        }
    }

    private static func softmax(_ values: inout [Float], rows: Int) {
        let width = values.count / rows
        var count = Int32(values.count)
        values.withUnsafeMutableBufferPointer { into in
            for row in 0..<rows {
                let start = into.baseAddress! + row * width
                var top: Float = 0
                vDSP_maxv(start, 1, &top, vDSP_Length(width))
                var shift = -top
                vDSP_vsadd(start, 1, &shift, start, 1, vDSP_Length(width))
            }
            vvexpf(into.baseAddress!, into.baseAddress!, &count)
            for row in 0..<rows {
                let start = into.baseAddress! + row * width
                var sum: Float = 0
                vDSP_sve(start, 1, &sum, vDSP_Length(width))
                vDSP_vsdiv(start, 1, &sum, start, 1, vDSP_Length(width))
            }
        }
    }

    /// Room for the activation's working values, one block long: fresh
    /// arrays as long as a layer's whole output, each step a full pass over
    /// them, cost a third of the model's time once every core ran a window.
    struct Scratch {
        static let block = 4096
        var x: [Float], magnitude: [Float], t: [Float], poly: [Float], negative: [Float], sign: [Float], spare: [Float], ones: [Float]
        init() {
            func zeros() -> [Float] { [Float](repeating: 0, count: Self.block) }
            (x, magnitude, t, poly, negative, sign, spare) = (zeros(), zeros(), zeros(), zeros(), zeros(), zeros(), zeros())
            ones = [Float](repeating: 1, count: Self.block)
        }
    }

    /// x·Φ(x), the exact form the network was trained with. erf comes from
    /// Abramowitz and Stegun 7.1.26 (error below 1.5e-7), in vector operations,
    /// a block at a time so the working values stay in cache. Each value goes
    /// through the same operations whatever block it is in.
    static func gelu(_ values: inout [Float], scratch: inout Scratch) {
        values.withUnsafeMutableBufferPointer { all in
            var start = 0
            while start < all.count {
                let length = min(Scratch.block, all.count - start)
                gelu(all.baseAddress! + start, length, scratch: &scratch)
                start += length
            }
        }
    }

    /// Each step writes a buffer other than the ones it reads, then swaps it
    /// in, as separate arrays did.
    private static func gelu(_ values: UnsafeMutablePointer<Float>, _ length: Int, scratch s: inout Scratch) {
        let count = vDSP_Length(length)
        var count32 = Int32(length)
        var scale: Float = 1 / Float(2).squareRoot()
        vDSP_vsmul(values, 1, &scale, &s.x, 1, count)
        vDSP_vabs(s.x, 1, &s.magnitude, 1, count)
        var p: Float = 0.3275911, one: Float = 1
        vDSP_vsmsa(s.magnitude, 1, &p, &one, &s.spare, 1, count)
        vvrecf(&s.t, s.spare, &count32)
        var first: Float = 1.061405429
        vDSP_vfill(&first, &s.poly, 1, count)
        for coefficient: Float in [-1.453152027, 1.421413741, -0.284496736, 0.254829592] {
            var c = coefficient
            vDSP_vmsa(s.poly, 1, s.t, 1, &c, &s.spare, 1, count)
            swap(&s.poly, &s.spare)
        }
        vDSP_vmul(s.poly, 1, s.t, 1, &s.spare, 1, count)
        swap(&s.poly, &s.spare)
        vDSP_vmul(s.magnitude, 1, s.magnitude, 1, &s.negative, 1, count)
        vDSP_vneg(s.negative, 1, &s.spare, 1, count)
        swap(&s.negative, &s.spare)
        vvexpf(&s.spare, s.negative, &count32)
        swap(&s.negative, &s.spare)
        // erf(|x|) = 1 - poly·e^(-x²); Φ = (1 + sign(x)·erf(|x|)) / 2.
        vDSP_vmul(s.poly, 1, s.negative, 1, &s.spare, 1, count)
        swap(&s.poly, &s.spare)
        var minusOne: Float = -1
        vDSP_vsmsa(s.poly, 1, &minusOne, &one, &s.spare, 1, count)
        swap(&s.poly, &s.spare)
        vvcopysignf(&s.sign, s.ones, s.x, &count32)
        vDSP_vmul(s.poly, 1, s.sign, 1, &s.spare, 1, count)
        swap(&s.poly, &s.spare)
        var half: Float = 0.5
        vDSP_vsmsa(s.poly, 1, &half, &half, &s.spare, 1, count)
        swap(&s.poly, &s.spare)
        // A product rounds once, so writing it over its input changes nothing.
        vDSP_vmul(values, 1, s.poly, 1, values, 1, count)
    }

    // MARK: - Reading text

    struct Found {
        let range: Range<Int>
        let kind: String
        /// The most any of its pieces leaned to no label at all.
        let doubt: Float
    }

    /// A piece's label and how likely it was to have none.
    struct Decision: Sendable {
        let label: Int
        let none: Float
    }

    /// Windows of piece ids over `pieces`, with the piece each id came from:
    /// 126 pieces between the start and end markers, each window 96 on from the last.
    func windows(_ pieces: [PieceTokenizer.Piece]) -> [(first: Int, ids: [Int32])] {
        let inner = Self.window - 2
        var result: [(Int, [Int32])] = [], start = 0
        while true {
            let slice = pieces[start..<min(pieces.count, start + inner)]
            result.append((start, [tokenizer.cls] + slice.map(\.id) + [tokenizer.sep]))
            if start + inner >= pieces.count { break }
            start += Self.stride
        }
        return result
    }

    /// The label of each piece, from the windows that read it: the first
    /// window to read a piece decides it.
    func labelled(_ pieces: [PieceTokenizer.Piece], windows: [(first: Int, ids: [Int32])], predictions: [[Decision]?]) -> [Decision?] {
        var result = [Decision?](repeating: nil, count: pieces.count)
        var seen = Set<Range<Int>>()
        for (window, predicted) in zip(windows, predictions) {
            guard let predicted else { continue }
            for offset in 0..<(window.ids.count - 2) {
                let index = window.first + offset, range = pieces[index].range
                guard !range.isEmpty, seen.insert(range).inserted else { continue }
                result[index] = predicted[offset + 1]
            }
        }
        return result
    }

    /// Spans from piece labels: B starts one, I continues one of its class.
    func spans(_ pieces: [PieceTokenizer.Piece], labels pieceLabels: [Decision?], in text: String) -> [Found] {
        var ordered: [(Range<Int>, Decision)] = []
        var seen = Set<Range<Int>>()
        for (piece, decision) in zip(pieces, pieceLabels) {
            guard let decision, !piece.range.isEmpty, seen.insert(piece.range).inserted else { continue }
            ordered.append((piece.range, decision))
        }
        ordered.sort { $0.0.lowerBound != $1.0.lowerBound ? $0.0.lowerBound < $1.0.lowerBound : $0.0.upperBound < $1.0.upperBound }
        var found: [(start: Int, end: Int, kind: String, doubt: Float)] = []
        var open = false
        for (range, decision) in ordered {
            let name = labels[decision.label]
            guard name != "O", let dash = name.firstIndex(of: "-") else { open = false; continue }
            let kind = String(name[name.index(after: dash)...]), inside = name.hasPrefix("I")
            if open, inside, let last = found.last, last.kind == kind, last.end <= range.lowerBound {
                found[found.count - 1].end = range.upperBound
                found[found.count - 1].doubt = max(last.doubt, decision.none)
            } else {
                found.append((range.lowerBound, range.upperBound, kind, decision.none))
                open = true
            }
        }
        // A piece of "▁" alone shares its character with the piece after it, so
        // one name can come out as two spans that overlap ("สมชาย ใ", "ใจดี"): they are one.
        var merged: [(start: Int, end: Int, kind: String, doubt: Float)] = []
        for span in found.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, last.kind == span.kind, span.start < last.end {
                merged[merged.count - 1] = (last.start, max(last.end, span.end), last.kind, max(last.doubt, span.doubt))
            } else {
                merged.append(span)
            }
        }
        let ns = text as NSString
        return merged.compactMap { span in
            var start = span.start
            while start < span.end, let scalar = Unicode.Scalar(ns.character(at: start)), scalar.properties.isWhitespace { start += 1 }
            return start < span.end ? Found(range: start..<span.end, kind: span.kind, doubt: span.doubt) : nil
        }
    }

    /// Every window's labels, one leaf at a time; for tests and short texts.
    func find(_ text: String) -> [Found] {
        let pieces = tokenizer.pieces(text)
        guard !pieces.isEmpty else { return [] }
        let windows = windows(pieces)
        let predictions = windows.map { Optional(decide(logits($0.ids))) }
        return spans(pieces, labels: labelled(pieces, windows: windows, predictions: predictions), in: text)
    }

    /// Each piece's most likely label, and the probability of none.
    func decide(_ logits: [Float]) -> [Decision] {
        let width = labels.count
        return Swift.stride(from: 0, to: logits.count, by: width).map { start in
            let row = logits[start..<(start + width)]
            let top = row.max() ?? 0
            var best = start, total: Float = 0
            for index in row.indices {
                total += Foundation.exp(logits[index] - top)
                if logits[index] > logits[best] { best = index }
            }
            return Decision(label: best - start, none: Foundation.exp(logits[start] - top) / total)
        }
    }

    func argmax(_ logits: [Float]) -> [Int] {
        let width = labels.count
        return Swift.stride(from: 0, to: logits.count, by: width).map { start in
            var best = start
            for index in start..<(start + width) where logits[index] > logits[best] { best = index }
            return best - start
        }
    }
}

/// The context model's weights as Scrub ships them (Tools/ContextModel builds
/// them): the parts' resource name and count, the SHA-256 they must hash to,
/// and the threshold its non-Latin names were calibrated against.
struct ContextWeights: Sendable, Equatable {
    /// The parts' resource name: `name`.1.bin, `name`.2.bin, …
    let name: String
    let parts: Int
    let checksum: String
    /// The most a non-Latin name's pieces may lean to no label (see ContextStage).
    let nonLatinDoubt: Float

    static let shipped = ContextWeights(name: "ContextModel", parts: 2, checksum: "7a403a6536d0205b9eccad7dded5216fb04dfe7a403bff5ab445a10fd1f9dd28", nonLatinDoubt: 0.004)

    func url(part index: Int) -> URL? {
        ModelResources.bundle?.url(forResource: "\(name).\(index)", withExtension: "bin")
    }
}

/// The resource bundle the models live in. A built app carries it in
/// Contents/Resources, where SwiftPM's own accessor does not look; in an app
/// that accessor would stop the process, so it is only for tests and `swift run`.
enum ModelResources {
    static var bundle: Bundle? {
        Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.url(forResource: "Scrub_ScrubCore", withExtension: "bundle").flatMap(Bundle.init(url:))
            : Bundle.module
    }
}

struct WeightReader {
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

    // The file is little-endian, as is every Mac Scrub runs on.
    private mutating func array<T>(_ count: Int, of _: T.Type) -> [T] {
        let raw = bytes(count * MemoryLayout<T>.stride)
        guard raw.count == count * MemoryLayout<T>.stride else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
    }

    mutating func floats(_ count: Int) -> [Float] { array(count, of: Float.self) }
    mutating func doubles(_ count: Int) -> [Double] { array(count, of: Double.self) }
    mutating func int8s(_ count: Int) -> [Int8] { array(count, of: Int8.self) }

    /// fp16 values, widened to Float.
    mutating func halves(_ count: Int) -> [Float] {
        var halves = array(count, of: UInt16.self)
        guard halves.count == count else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            halves.withUnsafeMutableBytes { from in
                var source = vImage_Buffer(data: from.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var target = vImage_Buffer(data: buffer.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&source, &target, vImage_Flags(kvImageNoFlags))
            }
            initialized = count
        }
    }

    /// Strings, each a UTF-8 run after its 16-bit length.
    mutating func strings() -> [[UInt8]] {
        let count = Int(uint32())
        var result: [[UInt8]] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let length = bytes(2).withUnsafeBytes { $0.count == 2 ? Int(UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))) : 0 }
            result.append([UInt8](bytes(length)))
            if !isValid { return [] }
        }
        return result
    }
}
