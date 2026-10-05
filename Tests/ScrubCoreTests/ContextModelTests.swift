import Accelerate
import Foundation
@testable import ScrubCore
import Testing

private struct TokenCase: Decodable {
    let text: String
    let ids: [Int32]
    let offsets: [[Int]]
}

private struct WindowCase: Decodable {
    let ids: [Int32]
    let logits: [Float]
}

/// `@testable` makes Bundle.module mean ScrubCore's bundle here, so fixtures are read from source.
private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
}

/// The parity fixture Tools/ContextModel/parity.py wrote for the shipped weights.
private func parityFixture(_ kind: String) -> URL {
    fixture("context-\(kind)-parity.json")
}

@Test func contextModelLoads() throws {
    #expect(ContextModel.shared != nil)
}

/// The weights are used only as shipped: a part altered, missing, out of
/// order or extra leaves Scrub without the model rather than with a damaged one.
@Test func contextModelChecksWeights() throws {
    let weights = ContextWeights.shipped
    let parts = try (1...weights.parts).map { index in
        try Data(contentsOf: try #require(weights.url(part: index)))
    }
    #expect(ContextModel.verified(parts) != nil)
    var altered = parts
    altered[0][altered[0].count / 2] ^= 0x01
    #expect(ContextModel.verified(altered) == nil)
    #expect(ContextModel.verified(Array(parts.dropLast())) == nil)
    #expect(ContextModel.verified(parts.reversed()) == nil)
    #expect(ContextModel.verified(parts + [Data()]) == nil)
    #expect(ContextModel.verified(parts, checksum: String(repeating: "0", count: 64)) == nil)
    // Weights that claim a different part count are refused too.
    let other = ContextWeights(name: weights.name, parts: weights.parts + 1, checksum: weights.checksum, nonLatinDoubt: weights.nonLatinDoubt)
    #expect(ContextModel.verified(parts, weights: other) == nil)
    #expect(ContextModel(Data("SCM1".utf8)) == nil)
    #expect(ContextModel(Data()) == nil)
}

/// The tokenizer cuts text into the same pieces, with the same offsets, as the
/// one the model was trained with: generated documents, written edge cases
/// and random runs of characters from many scripts.
@Test func contextTokenizerMatchesTraining() throws {
    let model = try #require(ContextModel.shared)
    let cases = try JSONDecoder().decode([TokenCase].self, from: Data(contentsOf: parityFixture("tokenizer")))
    #expect(cases.count > 400)
    var failures = 0
    for sample in cases {
        let pieces = model.tokenizer.pieces(sample.text)
        let same = pieces.map(\.id) == sample.ids && pieces.map { [$0.range.lowerBound, $0.range.upperBound] } == sample.offsets
        if !same {
            failures += 1
            if failures <= 5 {
                Issue.record("\(sample.text.unicodeScalars.map { String($0.value, radix: 16) }.prefix(40)): \(pieces.map { "\($0.id)@\($0.range)" }) vs \(zip(sample.ids, sample.offsets).map { "\($0)@\($1)" })")
            }
        }
    }
    #expect(failures == 0)
}

/// The network gives the same labels as the trained model, from the weights
/// as stored, with logits within rounding.
@Test func contextModelMatchesTraining() throws {
    let model = try #require(ContextModel.shared)
    let cases = try JSONDecoder().decode([WindowCase].self, from: Data(contentsOf: parityFixture("model")))
    let width = model.labels.count
    var worst: Float = 0
    for sample in cases {
        let logits = model.logits(sample.ids)
        #expect(logits.count == sample.logits.count)
        #expect(model.argmax(logits) == model.argmax(sample.logits))
        for (swift, python) in zip(logits, sample.logits) { worst = max(worst, abs(swift - python)) }
        #expect(logits.count == sample.ids.count * width)
    }
    #expect(worst < 0.01, "largest logit difference \(worst)")
}

/// The model's pass shows as `reading`, window by window, inside `finding`.
@Test func contextStageReportsReadingProgress() throws {
    let text = (0..<300).map { "Kofi Mensah moved to Tromsø in \(2001 + $0 % 12) and works at Orrinvale Freight." }.joined(separator: "\n")
    var stages: [Stage] = [], reading: [(done: Int, total: Int)] = []
    _ = try Scrubber.scrub(Data(text.utf8), name: "notes.txt") { stage, done, total in
        stages.append(stage)
        if stage == .reading { reading.append((done, total)) }
    }
    let total = try #require(reading.last?.total)
    #expect(total > 1 && reading.last?.done == total)
    #expect(zip(reading, reading.dropFirst()).allSatisfy { $0.done <= $1.done && $0.total == $1.total })
    let first = try #require(stages.firstIndex(of: .reading))
    #expect(stages.firstIndex(of: .finding)! < first && first < stages.lastIndex(of: .finding)!)
}

/// The gate passes a sentence with something the model could find, and
/// leaves plain prose and log lines alone.
@Test func contextGatePicksSentencesWorthReading() throws {
    let model = try #require(ContextModel.shared)
    let worth = ["She moved to Łódź last year.", "Kofi works at Orrinvale Freight.", "ping k.osei_42 about the deploy", "王小明 called about the refund.",
                 "my password is velvet-Cobalt-47", "born 3 May 1984 in a small town", "account 4471 9902 1835 is closed", "files are in /Users/kmensah/notes"]
    let plain = ["The build finished in 4 minutes.", "Please restart the server after the update.", "Reset your password from the settings page.",
                 "The cache is cleared every night at 02:00.", "Version 2.4.1 fixed the crash on launch."]
    for sentence in worth { #expect(ContextGate.trigger(sentence, model: model) != nil, "\(sentence)") }
    for sentence in plain { #expect(ContextGate.trigger(sentence, model: model) == nil, "\(sentence)") }
    #expect(ContextGate.sentences("Dr. Osei called. D.O.B. 4 May 1984. Then nothing.\nNext line") .count == 4)
}

@Test func freeTextIsThreeWordsOrAnotherScript() {
    #expect(ContextStage.isFreeText("moved to Delft"))
    #expect(ContextStage.isFreeText("王小明"))
    #expect(!ContextStage.isFreeText("Kofi Mensah"))
    #expect(!ContextStage.isFreeText("4471 9902 1835 77"))
}

/// An employer becomes an invented company, the same one wherever it appears,
/// in every input path.
@Test func employersBecomeOneInventedCompany() throws {
    let prose = "Kofi works at Orrinvale Freight as a driver. His manager at Orrinvale Freight signed the letter."
    for path in PIIGaps.InputPath.allCases {
        let (data, name) = PIIGaps.wrap(prose, path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 3)
        let output = PIIGaps.readable(result.output, path)
        let first = try #require(output.firstMatch(of: /works at (.+?) as a driver/)?.1)
        let second = try #require(output.firstMatch(of: /manager at (.+?) signed/)?.1)
        #expect(!output.contains("Orrinvale") && first == second && result.counts["EMPLOYER"] == 2, "[\(path)] \(output)")
    }
}

/// A country, a continent or a nationality the model reads as a place is no
/// one's place; a town is.
@Test func nationsAreNoOnesPlace() throws {
    let text = "Ingrid Halvorsen, a Danish citizen, moved from the United Kingdom's north to Ålesund, then to Norway."
    let ns = text as NSString
    func place(_ value: String) -> Span? {
        let range = ns.range(of: value)
        return ContextStage.span(ContextModel.Found(range: range.location..<NSMaxRange(range), kind: "LOCATION", doubt: 0.01), in: text)
    }
    for nation in ["Danish", "United Kingdom's", "Norway"] { #expect(place(nation) == nil, "\(nation)") }
    #expect(place("Ålesund")?.entity == "LOCATION")
    #expect(ContextStage.normalPlace("the United Kingdom’s") == "united kingdom")
    // A holiday is a day, not a place; a calendar date is a date, not an ID.
    let note = "We visit at Easter. Last backup 2022-11-28, case reference 4471-9902-18."
    let notes = note as NSString
    func found(_ value: String, _ kind: String) -> Span? {
        let range = notes.range(of: value)
        return ContextStage.span(ContextModel.Found(range: range.location..<NSMaxRange(range), kind: kind, doubt: 0.01), in: note)
    }
    #expect(found("Easter", "LOCATION") == nil)
    #expect(found("2022-11-28", "ID") == nil)
    #expect(found("4471-9902-18", "ID")?.entity == "ID_NUMBER")

    let prose = "The tenant, a Swedish national, now lives in Kalmar with her sister."
    for path in PIIGaps.InputPath.allCases {
        let (data, name) = PIIGaps.wrap(prose, path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 5)
        let output = PIIGaps.readable(result.output, path)
        #expect(output.contains("a Swedish national") && !output.contains("Kalmar") && result.counts["LOCATION"] == 1, "[\(path)] \(output)")
    }
}

/// The activation, run a block at a time without allocating, gives every value
/// bit for bit what one pass of whole-array operations gave, for each length a
/// window's layer produces: pieces × 1536 for the shipped model, and × 3072,
/// the width of the base-size encoder Tools/ContextModel can also train.
@Test func geluMatchesWholeArrayOperations() {
    func reference(_ values: [Float]) -> [Float] {
        let count = vDSP_Length(values.count)
        var count32 = Int32(values.count), x = values, result = values
        var scale: Float = 1 / Float(2).squareRoot(), p: Float = 0.3275911, one: Float = 1, minusOne: Float = -1, half: Float = 0.5
        vDSP_vsmul(x, 1, &scale, &x, 1, count)
        var magnitude = [Float](repeating: 0, count: values.count), t = magnitude, negative = magnitude, sign = magnitude
        vDSP_vabs(x, 1, &magnitude, 1, count)
        vDSP_vsmsa(magnitude, 1, &p, &one, &t, 1, count)
        vvrecf(&t, t, &count32)
        var poly = [Float](repeating: 1.061405429, count: values.count)
        for coefficient: Float in [-1.453152027, 1.421413741, -0.284496736, 0.254829592] {
            var c = coefficient
            vDSP_vmsa(poly, 1, t, 1, &c, &poly, 1, count)
        }
        vDSP_vmul(poly, 1, t, 1, &poly, 1, count)
        vDSP_vmul(magnitude, 1, magnitude, 1, &negative, 1, count)
        vDSP_vneg(negative, 1, &negative, 1, count)
        vvexpf(&negative, negative, &count32)
        vDSP_vmul(poly, 1, negative, 1, &poly, 1, count)
        vDSP_vsmsa(poly, 1, &minusOne, &one, &poly, 1, count)
        vvcopysignf(&sign, [Float](repeating: 1, count: values.count), x, &count32)
        vDSP_vmul(poly, 1, sign, 1, &poly, 1, count)
        vDSP_vsmsa(poly, 1, &half, &half, &poly, 1, count)
        vDSP_vmul(result, 1, poly, 1, &result, 1, count)
        return result
    }
    var gen = SeededGenerator(seed: 1_536)
    var scratch = ContextModel.Scratch()
    for inner in [1536, 3072] {
        for rows in 1...128 {
            var values = (0..<(rows * inner)).map { index -> Float in
                switch index % 97 {
                case 0: return 0
                case 1: return -0.0
                case 2: return Float.leastNormalMagnitude
                case 3: return -40
                default: return Float(Int64(bitPattern: gen.next()) % 2_000_000) / 100_000
                }
            }
            let expected = reference(values)
            ContextModel.gelu(&values, scratch: &scratch)
            #expect(values.elementsEqual(expected) { $0.bitPattern == $1.bitPattern }, "\(rows) pieces × \(inner)")
        }
    }
}
