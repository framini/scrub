import Accelerate
import CryptoKit
import Foundation
import os
import Synchronization

/// A multilingual encoder with a span head: it reads a text and scores every
/// run of up to eight words against labels named at call time. It is for
/// review only: nothing it reads should be replaced on its word alone, and
/// nothing a rule finds overruled. scripts/make-span-tagger.py builds its weights, which
/// ship apart from the code; without them, or with other bytes than
/// `checksum` names, Scrub runs as it would without the model. This mirrors
/// the reference implementation exactly, so change both together.
final class SpanTagger: Sendable {
    static let shared: SpanTagger? = load()

    /// The SHA-256 of the weights the script builds.
    static let checksum = "2472afd86d89067a126258e31a111b3efdab68632d53e2d72333a8ccb429bc49"
    /// Where the weights are looked for: the app's resources, then Scrub's
    /// support folder, then (in a debug build) the git-ignored Models folder.
    static var locations: [URL] {
        var urls: [URL] = []
        if let url = ModelResources.bundle?.url(forResource: "SpanTagger", withExtension: "bin") { urls.append(url) }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support.appendingPathComponent("Scrub/SpanTagger.bin"))
        }
        #if DEBUG
        urls.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Models/SpanTagger.bin").standardizedFileURL)
        #endif
        return urls
    }
    private static let log = Logger(subsystem: "Scrub", category: "SpanTagger")

    static let hidden = 768, heads = 12, inner = 3072, layers = 12, widths = 8, counts = 20
    /// Relative positions fold into 256 buckets each way, logarithmic past 128.
    private static let buckets = 256, positions = 512

    struct Linear {
        /// Row-major, inputs by outputs: the checkpoint's own matrix transposed.
        let weight: [Float]
        let bias: [Float]
        var inputs: Int { weight.count / bias.count }
        var outputs: Int { bias.count }
    }
    struct Norm { let gain: [Float]; let bias: [Float] }
    struct Layer { let query, key, value, out, up, down: Linear; let norm1, norm2: Norm }

    private let pieces: [[UInt8]: Int32]
    private let longest: Int
    private let unknown: Int32 = 3
    private let unknownScore: Double
    private let pieceScores: [Double]
    private let textMark, promptMark, labelMark: Int32
    private let embeddings: Data
    private let embeddingsOffset: Int
    private let embedNorm: Norm
    private let relative: [Float]
    private let encoderLayers: [Layer]
    private let start1, start2, end1, end2, spanUp, spanDown: Linear
    private let countPosition: [Float]
    private let gruInput, gruHidden: Linear
    private let projectUp, projectDown, countUp, countDown: Linear
    private let tokenized = Mutex<[String: [Int32]]>([:])
    private static let tokenizedLimit = 100_000

    private static func load() -> SpanTagger? { load(from: locations) }

    /// The tagger in the first of `urls` that exists, or nil when none does or its bytes are not the expected ones.
    static func load(from urls: [URL]) -> SpanTagger? {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            return verified(data)
        }
        log.info("Span tagger not loaded: no weights installed")
        return nil
    }

    /// The tagger in `data`, or nil when its bytes are not the ones `checksum` names.
    static func verified(_ data: Data, checksum: String = checksum) -> SpanTagger? {
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
            log.error("Span tagger not loaded: its weights do not match the expected checksum")
            return nil
        }
        return SpanTagger(data)
    }

    init?(_ data: Data) {
        var reader = Reader(data: data)
        guard reader.bytes(4) == Array("STG1".utf8) else { return nil }
        let count = Int(reader.uint32())
        var pieces: [[UInt8]: Int32] = [:]
        pieces.reserveCapacity(count)
        var longest = 0
        for id in 0..<count {
            let piece = reader.bytes(Int(reader.uint16()))
            // The first spelling wins, as in the reference vocabulary.
            if pieces[piece] == nil { pieces[piece] = Int32(id) }
            longest = max(longest, piece.count)
        }
        let scores = reader.doubles(count)
        (self.pieces, self.longest, pieceScores) = (pieces, longest, scores)
        unknownScore = (scores.min() ?? 0) - 10
        (textMark, promptMark, labelMark) = (Int32(reader.uint32()), Int32(reader.uint32()), Int32(reader.uint32()))
        let vocabulary = 250_112, h = Self.hidden
        reader.skip((64 - reader.offset % 64) % 64)
        embeddingsOffset = reader.offset
        reader.skip(vocabulary * h * 2)
        embeddings = data
        func norm() -> Norm { Norm(gain: reader.halves(h), bias: reader.halves(h)) }
        func linear(_ inputs: Int, _ outputs: Int) -> Linear {
            let weight = reader.halves(outputs * inputs)
            var transposed = [Float](repeating: 0, count: weight.count)
            vDSP_mtrans(weight, 1, &transposed, 1, vDSP_Length(inputs), vDSP_Length(outputs))
            return Linear(weight: transposed, bias: reader.halves(outputs))
        }
        embedNorm = norm()
        let rows = reader.halves(Self.positions * h)
        let relNorm = norm()
        var layers: [Layer] = []
        for _ in 0..<Self.layers {
            let (q, k, v, o) = (linear(h, h), linear(h, h), linear(h, h), linear(h, h))
            let n1 = norm()
            let (up, down) = (linear(h, Self.inner), linear(Self.inner, h))
            layers.append(Layer(query: q, key: k, value: v, out: o, up: up, down: down, norm1: n1, norm2: norm()))
        }
        encoderLayers = layers
        (start1, start2) = (linear(h, 4 * h), linear(4 * h, h))
        (end1, end2) = (linear(h, 4 * h), linear(4 * h, h))
        (spanUp, spanDown) = (linear(2 * h, 4 * h), linear(4 * h, h))
        countPosition = reader.halves(Self.counts * h)
        let wih = reader.halves(3 * h * h), whh = reader.halves(3 * h * h)
        func transposed(_ w: [Float], _ inputs: Int, _ outputs: Int) -> [Float] {
            var t = [Float](repeating: 0, count: w.count)
            vDSP_mtrans(w, 1, &t, 1, vDSP_Length(inputs), vDSP_Length(outputs))
            return t
        }
        gruInput = Linear(weight: transposed(wih, h, 3 * h), bias: reader.halves(3 * h))
        gruHidden = Linear(weight: transposed(whh, h, 3 * h), bias: reader.halves(3 * h))
        (projectUp, projectDown) = (linear(2 * h, 4 * h), linear(4 * h, h))
        (countUp, countDown) = (linear(h, 2 * h), linear(2 * h, Self.counts))
        guard reader.isValid, reader.offset == data.count else { return nil }
        var normalized = rows
        Self.normalize(&normalized, rows: Self.positions, relNorm)
        relative = normalized
    }

    // MARK: Words and pieces

    /// The words the tagger reads, as scalar offsets: links, emails, handles,
    /// runs of word characters joined by hyphens, and any other single non-space.
    static func words(_ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        let n = scalars.count
        func space(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace || (0x1C...0x1F).contains(c.value) }
        func word(_ c: Unicode.Scalar) -> Bool {
            if c == "_" { return true }
            switch c.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return c.properties.numericType != nil
            }
        }
        func letter(_ c: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || [0x17F, 0x212A, 0x130, 0x131].contains(c.value)
        }
        func alnum(_ c: Unicode.Scalar) -> Bool { letter(c) || ("0"..."9").contains(c) }
        func starts(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix.unicodeScalars)
            guard index + p.count <= n else { return false }
            for (k, c) in p.enumerated() where String(scalars[index + k]).lowercased() != String(c) { return false }
            return true
        }
        func link(_ index: Int) -> Int? {
            for prefix in ["http://", "https://", "www."] where starts(prefix, at: index) {
                var end = index + prefix.unicodeScalars.count
                let from = end
                while end < n, !space(scalars[end]) { end += 1 }
                if end > from { return end }
            }
            return nil
        }
        func email(_ index: Int) -> Int? {
            var at = index
            while at < n, alnum(scalars[at]) || ".%+-_".unicodeScalars.contains(scalars[at]) { at += 1 }
            guard at > index, at < n, scalars[at] == "@" else { return nil }
            var domainEnd = at + 1
            while domainEnd < n, alnum(scalars[domainEnd]) || ".-".unicodeScalars.contains(scalars[domainEnd]) { domainEnd += 1 }
            var dot = domainEnd - 1
            while dot > at + 1 {
                if scalars[dot] == "." {
                    var end = dot + 1
                    while end < n, letter(scalars[end]) { end += 1 }
                    if end - dot - 1 >= 2 { return end }
                }
                dot -= 1
            }
            return nil
        }
        while i < n {
            if space(scalars[i]) { i += 1; continue }
            var end: Int
            if let e = link(i) ?? email(i) {
                end = e
            } else if scalars[i] == "@", i + 1 < n, alnum(scalars[i + 1]) || scalars[i + 1] == "_" {
                end = i + 1
                while end < n, alnum(scalars[end]) || scalars[end] == "_" { end += 1 }
            } else if word(scalars[i]) {
                end = i + 1
                while end < n, word(scalars[end]) { end += 1 }
                while end + 1 < n, scalars[end] == "-", word(scalars[end + 1]) {
                    end += 2
                    while end < n, word(scalars[end]) { end += 1 }
                }
            } else {
                end = i + 1
            }
            out.append(i..<end)
            i = end
        }
        return out
    }

    /// The vocabulary ids of one word, read as the reference reads it: composed,
    /// after a word-start mark, split by the most likely pieces.
    func pieces(of word: String) -> [Int32] {
        switch word {
        case "[SEP_TEXT]": return [textMark]
        case "[P]": return [promptMark]
        case "[E]": return [labelMark]
        default: break
        }
        if let known = tokenized.withLock({ $0[word] }) { return known }
        let ids = segment("\u{2581}" + word.precomposedStringWithCanonicalMapping)
        tokenized.withLock { cache in
            if cache.count >= Self.tokenizedLimit { cache.removeAll() }
            cache[word] = ids
        }
        return ids
    }

    private func segment(_ text: String) -> [Int32] {
        let bytes = Array(text.utf8)
        var bounds: [Int] = [0]
        var offset = 0
        for scalar in text.unicodeScalars {
            offset += UTF8.width(scalar)
            bounds.append(offset)
        }
        let n = bounds.count - 1
        var best = [(score: Double, from: Int, id: Int32)](repeating: (0, -1, -1), count: n + 1)
        best[0] = (0, 0, -1)
        for from in 0..<n where best[from].from >= 0 || from == 0 {
            let base = best[from].score
            var single = false
            var to = from + 1
            while to <= n, bounds[to] - bounds[from] <= longest {
                if let id = pieces[Array(bytes[bounds[from]..<bounds[to]])] {
                    let candidate = base + pieceScores[Int(id)]
                    if best[to].from < 0 || candidate > best[to].score { best[to] = (candidate, from, id) }
                    if to == from + 1 { single = true }
                }
                to += 1
            }
            if !single {
                let candidate = base + unknownScore
                if best[from + 1].from < 0 || candidate > best[from + 1].score { best[from + 1] = (candidate, from, unknown) }
            }
        }
        var ids: [Int32] = []
        var at = n
        while at > 0 {
            let step = best[at]
            // Runs of unknown characters read as one unknown piece.
            if !(step.id == unknown && ids.last == unknown) { ids.append(step.id) }
            at = step.from
        }
        return ids.reversed()
    }

    // MARK: Scoring

    /// A labelled run of words and the tagger's confidence in it, in scalar offsets.
    struct Hit: Equatable {
        let range: Range<Int>
        let label: String
        let score: Float
    }

    /// Texts longer than this are read in parts, each ending at a line or space.
    static let chunk = 1500

    /// Every labelled run in `scalars` that scores at least `threshold`,
    /// each label's runs kept surest first where they overlap.
    func hits(_ scalars: [Unicode.Scalar], labels: [String], threshold: Float) -> [Hit] {
        var out: [Hit] = []
        var start = 0
        while start < scalars.count {
            var end = min(scalars.count, start + Self.chunk)
            if end < scalars.count {
                let from = start + Self.chunk / 2
                let line = (from..<end).last { scalars[$0] == "\n" }
                let space = (from..<end).last { scalars[$0] == " " }
                end = line ?? space ?? end
            }
            out += hits(Array(scalars[start..<end]), labels: labels, threshold: threshold, offset: start)
            start = end
        }
        return out
    }

    private func hits(_ chunk: [Unicode.Scalar], labels: [String], threshold: Float, offset: Int) -> [Hit] {
        // The reference ends every text it reads with a stop.
        let scalars = [".", "!", "?"].contains(chunk.last ?? " ") ? chunk : chunk + ["."]
        let input = self.input(scalars, labels: labels)
        let (spans, ids, promptAt, labelAt, firsts) = (input.spans, input.ids, input.promptAt, input.labelAt, input.firsts)
        guard !spans.isEmpty, !labels.isEmpty else { return [] }
        let words = spans
        let state = encode(ids)
        let h = Self.hidden
        func row(_ index: Int) -> ArraySlice<Float> { state[(index * h)..<((index + 1) * h)] }

        let prompt = Array(row(promptAt))
        let countLogits = apply(countDown, relu(apply(countUp, prompt, rows: 1)), rows: 1)
        guard let count = countLogits.indices.max(by: { countLogits[$0] < countLogits[$1] }), count > 0 else { return [] }

        let fields = labelAt.flatMap { row($0) }
        let structure = labelStates(fields, labels: labels.count)
        let tokens = firsts.flatMap { row($0) }
        let scores = spanScores(tokens, words: words.count, structure: structure, labels: labels.count)

        var out: [Hit] = []
        for (l, label) in labels.enumerated() {
            var candidates: [(Range<Int>, Float)] = []
            for i in 0..<words.count {
                for k in 0..<Self.widths where i + k < words.count {
                    let score = scores[(i * Self.widths + k) * labels.count + l]
                    if score >= threshold { candidates.append((spans[i].lowerBound..<spans[i + k].upperBound, score)) }
                }
            }
            var kept: [(Range<Int>, Float)] = []
            for candidate in candidates.enumerated().sorted(by: { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }).map(\.element)
            where !kept.contains(where: { $0.0.overlaps(candidate.0) }) {
                kept.append(candidate)
            }
            out += kept.map { Hit(range: ($0.0.lowerBound + offset)..<($0.0.upperBound + offset), label: label, score: $0.1) }
        }
        return out
    }

    /// What the encoder reads: the labels as a prompt, then the words, each in pieces.
    func input(_ scalars: [Unicode.Scalar], labels: [String]) -> (spans: [Range<Int>], ids: [Int32], promptAt: Int, labelAt: [Int], firsts: [Int]) {
        let spans = Self.words(scalars)
        var ids: [Int32] = []
        var labelAt: [Int] = []
        var promptAt = 0
        let schema = ["(", "[P]", "entities", "("] + labels.flatMap { ["[E]", $0] } + [")", ")", "[SEP_TEXT]"]
        for (index, token) in schema.enumerated() {
            if index == 1 { promptAt = ids.count }
            if index >= 4, index < schema.count - 3, index % 2 == 0 { labelAt.append(ids.count) }
            ids += pieces(of: token)
        }
        var firsts: [Int] = []
        for span in spans {
            firsts.append(ids.count)
            ids += pieces(of: String(String.UnicodeScalarView(scalars[span])).lowercased())
        }
        return (spans, ids, promptAt, labelAt, firsts)
    }

    /// Each label's state after one step of the counting unit, then projected.
    private func labelStates(_ fields: [Float], labels: Int) -> [Float] {
        let h = Self.hidden
        let input = apply(gruInput, Array(countPosition[0..<h]), rows: 1)
        let recurrent = apply(gruHidden, fields, rows: labels)
        var joined = [Float](repeating: 0, count: labels * 2 * h)
        for l in 0..<labels {
            for d in 0..<h {
                let gh = { (gate: Int) in recurrent[l * 3 * h + gate * h + d] }
                let r = Self.sigmoid(input[d] + gh(0))
                let z = Self.sigmoid(input[h + d] + gh(1))
                let n = tanh(input[2 * h + d] + r * gh(2))
                let previous = fields[l * h + d]
                joined[l * 2 * h + d] = (1 - z) * n + z * previous
                joined[l * 2 * h + h + d] = previous
            }
        }
        return apply(projectDown, relu(apply(projectUp, joined, rows: labels)), rows: labels)
    }

    /// The sigmoid score of every (start word, width, label), widths running fastest but labels.
    private func spanScores(_ tokens: [Float], words: Int, structure: [Float], labels: Int) -> [Float] {
        let h = Self.hidden, wide = 4 * h
        let starts = relu(apply(start2, relu(apply(start1, tokens, rows: words)), rows: words))
        let ends = relu(apply(end2, relu(apply(end1, tokens, rows: words)), rows: words))
        // The span layer's first matrix splits into a start half and an end half,
        // and its last one folds into each label's state.
        let left = multiply(starts, rows: words, inner: h, Array(spanUp.weight[0..<(h * wide)]), columns: wide)
        let right = multiply(ends, rows: words, inner: h, Array(spanUp.weight[(h * wide)...]), columns: wide)
        var structureT = [Float](repeating: 0, count: structure.count)
        vDSP_mtrans(structure, 1, &structureT, 1, vDSP_Length(h), vDSP_Length(labels))
        let folded = multiply(spanDown.weight, rows: wide, inner: h, structureT, columns: labels)
        let offsets = multiply(spanDown.bias, rows: 1, inner: h, structureT, columns: labels)
        var hiddenRows = [Float](repeating: 0, count: words * Self.widths * wide)
        hiddenRows.withUnsafeMutableBufferPointer { into in
            for i in 0..<words {
                for k in 0..<Self.widths where i + k < words {
                    let target = into.baseAddress! + (i * Self.widths + k) * wide
                    left.withUnsafeBufferPointer { l in
                        right.withUnsafeBufferPointer { r in
                            vDSP_vadd(l.baseAddress! + i * wide, 1, r.baseAddress! + (i + k) * wide, 1, target, 1, vDSP_Length(wide))
                        }
                    }
                    vDSP_vadd(target, 1, spanUp.bias, 1, target, 1, vDSP_Length(wide))
                    var zero: Float = 0
                    vDSP_vthr(target, 1, &zero, target, 1, vDSP_Length(wide))
                }
            }
        }
        var logits = multiply(hiddenRows, rows: words * Self.widths, inner: wide, folded, columns: labels)
        for index in logits.indices { logits[index] = Self.sigmoid(logits[index] + offsets[index % labels]) }
        return logits
    }

    // MARK: Encoder

    /// The encoder's last hidden state for `ids`, row by token.
    func encode(_ ids: [Int32]) -> [Float] {
        let h = Self.hidden, n = ids.count
        var state = [Float](repeating: 0, count: n * h)
        embeddings.withUnsafeBytes { raw in
            state.withUnsafeMutableBufferPointer { into in
                for (row, id) in ids.enumerated() {
                    var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress! + embeddingsOffset + Int(id) * h * 2), height: 1, width: vImagePixelCount(h), rowBytes: h * 2)
                    var target = vImage_Buffer(data: into.baseAddress! + row * h, height: 1, width: vImagePixelCount(h), rowBytes: h * 4)
                    vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
                }
            }
        }
        Self.normalize(&state, rows: n, embedNorm)
        // Every relative position the text needs, as one band of bucket rows.
        let bucket = (0..<(2 * n - 1)).map { Self.bucket($0 - (n - 1)) }
        let low = bucket.first!, high = bucket.last!
        let band = Array(relative[(low * h)..<((high + 1) * h)])
        let rows = high - low + 1
        // Where each (query, key) pair reads its position scores, counted from one as vDSP gathers.
        var toPosition = [vDSP_Length](repeating: 0, count: n * n), fromPosition = toPosition
        for i in 0..<n {
            for j in 0..<n {
                let p = bucket[i - j + n - 1] - low
                toPosition[i * n + j] = vDSP_Length(i * rows + p + 1)
                fromPosition[i * n + j] = vDSP_Length(j * rows + p + 1)
            }
        }
        let gather = (to: toPosition, from: fromPosition)
        for layer in encoderLayers { apply(layer, to: &state, rows: n, band: band, bandRows: rows, gather: gather) }
        return state
    }

    /// The row of the relative-position table for a query `distance` tokens after its key.
    static func bucket(_ distance: Int) -> Int {
        let mid = buckets / 2
        var position = distance
        if abs(distance) > mid {
            let ratio = Float(abs(distance)) / Float(mid)
            let scaled = Foundation.log(ratio) / Foundation.log(Float(positions - 1) / Float(mid)) * Float(mid - 1)
            position = (Int(scaled.rounded(.up)) + mid) * (distance < 0 ? -1 : 1)
        }
        return min(max(position + buckets, 0), 2 * buckets - 1)
    }

    private func apply(_ layer: Layer, to state: inout [Float], rows n: Int, band: [Float], bandRows: Int, gather: (to: [vDSP_Length], from: [vDSP_Length])) {
        let h = Self.hidden, width = h / Self.heads
        let query = apply(layer.query, state, rows: n), key = apply(layer.key, state, rows: n), value = apply(layer.value, state, rows: n)
        let positionKey = apply(layer.key, band, rows: bandRows), positionQuery = apply(layer.query, band, rows: bandRows)
        let scale = (Float(width) * 3).squareRoot()
        var context = [Float](repeating: 0, count: n * h)
        var q = [Float](repeating: 0, count: n * width), k = q, v = q
        var pk = [Float](repeating: 0, count: bandRows * width), pq = pk
        var kT = [Float](repeating: 0, count: width * n), pkT = [Float](repeating: 0, count: width * bandRows), pqT = pkT
        var weights = [Float](repeating: 0, count: n * n)
        var toPosition = [Float](repeating: 0, count: n * bandRows), fromPosition = toPosition
        var mixed = [Float](repeating: 0, count: n * width)
        var gathered = [Float](repeating: 0, count: n * n), sum = gathered
        var divisor = scale
        func take(_ all: [Float], _ head: Int, _ rows: Int, into: inout [Float]) {
            all.withUnsafeBufferPointer { all in
                vDSP_mmov(all.baseAddress! + head * width, &into, vDSP_Length(width), vDSP_Length(rows), vDSP_Length(h), vDSP_Length(width))
            }
        }
        for head in 0..<Self.heads {
            take(query, head, n, into: &q); take(key, head, n, into: &k); take(value, head, n, into: &v)
            take(positionKey, head, bandRows, into: &pk); take(positionQuery, head, bandRows, into: &pq)
            vDSP_mtrans(k, 1, &kT, 1, vDSP_Length(width), vDSP_Length(n))
            vDSP_mtrans(pk, 1, &pkT, 1, vDSP_Length(width), vDSP_Length(bandRows))
            vDSP_mtrans(pq, 1, &pqT, 1, vDSP_Length(width), vDSP_Length(bandRows))
            vDSP_mmul(q, 1, kT, 1, &weights, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(width))
            vDSP_mmul(q, 1, pkT, 1, &toPosition, 1, vDSP_Length(n), vDSP_Length(bandRows), vDSP_Length(width))
            vDSP_mmul(k, 1, pqT, 1, &fromPosition, 1, vDSP_Length(n), vDSP_Length(bandRows), vDSP_Length(width))
            vDSP_vgathr(toPosition, gather.to, 1, &gathered, 1, vDSP_Length(n * n))
            vDSP_vadd(weights, 1, gathered, 1, &sum, 1, vDSP_Length(n * n))
            vDSP_vgathr(fromPosition, gather.from, 1, &gathered, 1, vDSP_Length(n * n))
            vDSP_vadd(sum, 1, gathered, 1, &sum, 1, vDSP_Length(n * n))
            vDSP_vsdiv(sum, 1, &divisor, &weights, 1, vDSP_Length(n * n))
            Self.softmax(&weights, rows: n)
            vDSP_mmul(weights, 1, v, 1, &mixed, 1, vDSP_Length(n), vDSP_Length(width), vDSP_Length(n))
            context.withUnsafeMutableBufferPointer { into in
                vDSP_mmov(mixed, into.baseAddress! + head * width, vDSP_Length(width), vDSP_Length(n), vDSP_Length(width), vDSP_Length(h))
            }
        }
        var attended = apply(layer.out, context, rows: n)
        attended.withUnsafeMutableBufferPointer { into in vDSP_vadd(into.baseAddress!, 1, state, 1, into.baseAddress!, 1, vDSP_Length(n * h)) }
        Self.normalize(&attended, rows: n, layer.norm1)
        var raised = apply(layer.up, attended, rows: n)
        Self.gelu(&raised)
        var lowered = apply(layer.down, raised, rows: n)
        lowered.withUnsafeMutableBufferPointer { into in vDSP_vadd(into.baseAddress!, 1, attended, 1, into.baseAddress!, 1, vDSP_Length(n * h)) }
        Self.normalize(&lowered, rows: n, layer.norm2)
        state = lowered
    }

    // MARK: Arithmetic

    /// GELU through the error function, which vDSP lacks: a rational
    /// approximation good to 1.5e-7 (Abramowitz and Stegun 7.1.26), in whole-vector steps.
    private static func gelu(_ values: inout [Float]) {
        let count = values.count
        var n = Int32(count)
        var x = values
        var scaled = [Float](repeating: 0, count: count), t = scaled, poly = scaled, e = scaled
        var root = 1 / Float(2).squareRoot(), one: Float = 1, p: Float = 0.3275911
        vDSP_vsmul(x, 1, &root, &scaled, 1, vDSP_Length(count))
        vDSP_vabs(scaled, 1, &t, 1, vDSP_Length(count))
        // e = exp(-z²) with z = |x|/√2.
        vDSP_vsq(t, 1, &e, 1, vDSP_Length(count))
        var minus: Float = -1
        vDSP_vsmul(e, 1, &minus, &e, 1, vDSP_Length(count))
        vvexpf(&e, e, &n)
        // t = 1 / (1 + p z).
        vDSP_vsmsa(t, 1, &p, &one, &t, 1, vDSP_Length(count))
        vDSP_svdiv(&one, t, 1, &t, 1, vDSP_Length(count))
        var a: [Float] = [1.061405429, -1.453152027, 1.421413741, -0.284496736, 0.254829592]
        vDSP_vfill(&a[0], &poly, 1, vDSP_Length(count))
        for k in 1..<a.count {
            vDSP_vmul(poly, 1, t, 1, &poly, 1, vDSP_Length(count))
            vDSP_vsadd(poly, 1, &a[k], &poly, 1, vDSP_Length(count))
        }
        vDSP_vmul(poly, 1, t, 1, &poly, 1, vDSP_Length(count))
        // erf(|z|) = 1 - poly·e, signed as x; then GELU = x (1 + erf) / 2.
        vDSP_vmul(poly, 1, e, 1, &poly, 1, vDSP_Length(count))
        vDSP_vneg(poly, 1, &poly, 1, vDSP_Length(count))
        vDSP_vsadd(poly, 1, &one, &poly, 1, vDSP_Length(count))
        var sign = [Float](repeating: 0, count: count)
        var zero: Float = 0
        // Copy the sign of x onto erf(|z|).
        vDSP_vthrsc(x, 1, &zero, &one, &sign, 1, vDSP_Length(count))
        vDSP_vmul(poly, 1, sign, 1, &poly, 1, vDSP_Length(count))
        vDSP_vsadd(poly, 1, &one, &poly, 1, vDSP_Length(count))
        var half: Float = 0.5
        vDSP_vmul(poly, 1, x, 1, &x, 1, vDSP_Length(count))
        vDSP_vsmul(x, 1, &half, &values, 1, vDSP_Length(count))
    }

    private func apply(_ linear: Linear, _ input: [Float], rows: Int) -> [Float] {
        var out = multiply(input, rows: rows, inner: linear.inputs, linear.weight, columns: linear.outputs)
        out.withUnsafeMutableBufferPointer { into in
            for row in 0..<rows {
                vDSP_vadd(into.baseAddress! + row * linear.outputs, 1, linear.bias, 1, into.baseAddress! + row * linear.outputs, 1, vDSP_Length(linear.outputs))
            }
        }
        return out
    }

    private func multiply(_ left: [Float], rows: Int, inner: Int, _ right: [Float], columns: Int) -> [Float] {
        [Float](unsafeUninitializedCapacity: rows * columns) { result, count in
            vDSP_mmul(left, 1, right, 1, result.baseAddress!, 1, vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
            count = rows * columns
        }
    }

    private func relu(_ values: [Float]) -> [Float] {
        var out = values
        var zero: Float = 0
        vDSP_vthr(values, 1, &zero, &out, 1, vDSP_Length(values.count))
        return out
    }

    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    private static func normalize(_ values: inout [Float], rows: Int, _ norm: Norm) {
        let width = norm.gain.count
        values.withUnsafeMutableBufferPointer { into in
            for row in 0..<rows {
                let start = into.baseAddress! + row * width
                var mean: Float = 0, square: Float = 0
                vDSP_meanv(start, 1, &mean, vDSP_Length(width))
                var negated = -mean
                vDSP_vsadd(start, 1, &negated, start, 1, vDSP_Length(width))
                vDSP_measqv(start, 1, &square, vDSP_Length(width))
                var scale = 1 / (square + 1e-7).squareRoot()
                vDSP_vsmul(start, 1, &scale, start, 1, vDSP_Length(width))
                vDSP_vmul(start, 1, norm.gain, 1, start, 1, vDSP_Length(width))
                vDSP_vadd(start, 1, norm.bias, 1, start, 1, vDSP_Length(width))
            }
        }
    }

    private static func softmax(_ values: inout [Float], rows: Int) {
        let width = values.count / max(rows, 1)
        values.withUnsafeMutableBufferPointer { into in
            for row in 0..<rows {
                let start = into.baseAddress! + row * width
                var top: Float = 0
                vDSP_maxv(start, 1, &top, vDSP_Length(width))
                var negated = -top
                vDSP_vsadd(start, 1, &negated, start, 1, vDSP_Length(width))
                var count = Int32(width)
                vvexpf(start, start, &count)
                var sum: Float = 0
                vDSP_sve(start, 1, &sum, vDSP_Length(width))
                var inverse = 1 / sum
                vDSP_vsmul(start, 1, &inverse, start, 1, vDSP_Length(width))
            }
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        var isValid = true

        mutating func bytes(_ count: Int) -> [UInt8] {
            guard count >= 0, offset + count <= data.count else { isValid = false; return [] }
            defer { offset += count }
            return [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
        }
        mutating func skip(_ count: Int) {
            guard offset + count <= data.count else { isValid = false; return }
            offset += count
        }
        mutating func uint16() -> UInt16 { bytes(2).withUnsafeBytes { $0.count == 2 ? UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) : 0 } }
        mutating func uint32() -> UInt32 { bytes(4).withUnsafeBytes { $0.count == 4 ? UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) : 0 } }
        mutating func doubles(_ count: Int) -> [Double] {
            guard count >= 0, offset + count * 8 <= data.count else { isValid = false; return [] }
            defer { offset += count * 8 }
            return data.withUnsafeBytes { raw in
                (0..<count).map { Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + $0 * 8, as: UInt64.self))) }
            }
        }
        /// Half-precision values widened to single.
        mutating func halves(_ count: Int) -> [Float] {
            guard count >= 0, offset + count * 2 <= data.count else { isValid = false; return [] }
            defer { offset += count * 2 }
            return data.withUnsafeBytes { raw in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress! + offset), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                    var target = vImage_Buffer(data: buffer.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
                    initialized = count
                }
            }
        }
    }
}
