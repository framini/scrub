import Foundation
@testable import ScrubCore
import Testing

/// Byte-for-byte guard for changes that must not change any output, such as
/// speed work. SCRUB_ORACLE=/dir with SCRUB_ORACLE_RECORD=1 scrubs a fixed
/// corpus and saves every output; SCRUB_ORACLE=/dir alone scrubs it again and
/// fails on the first byte that differs. SCRUB_ORACLE_EXTRA=/dir adds every
/// file in that folder (large texts, logs, tables) to the corpus. Skipped when
/// SCRUB_ORACLE is unset.
@Test func outputsMatchTheRecordedOracle() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let folder = environment["SCRUB_ORACLE"] else { return }
    let root = URL(fileURLWithPath: folder)
    let record = environment["SCRUB_ORACLE_RECORD"] == "1"
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var documents = OracleCorpus.documents()
    if let extra = environment["SCRUB_ORACLE_EXTRA"] {
        let url = URL(fileURLWithPath: extra)
        for name in try FileManager.default.contentsOfDirectory(atPath: extra).sorted() where !name.hasPrefix(".") {
            documents.append((name, try Data(contentsOf: url.appendingPathComponent(name)), [1]))
        }
    }
    var compared = 0, differing: [String] = []
    for (name, data, seeds) in documents {
        for seed in seeds {
            let start = ContinuousClock.now
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            let counts = result.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            let saved = Data(("counts: \(counts)\n").utf8) + result.output
            let file = root.appendingPathComponent("\(name).\(seed).out")
            if environment["SCRUB_ORACLE_TIMES"] == "1" { print("ORACLE TIME \(name) seed=\(seed) \(start.duration(to: .now))") }
            // SCRUB_ORACLE_INPUTS=/dir keeps each input beside the record, to review what changed.
            if let inputs = environment["SCRUB_ORACLE_INPUTS"] { try data.write(to: URL(fileURLWithPath: inputs).appendingPathComponent("\(name).\(seed).in")) }
            if record { try saved.write(to: file); continue }
            compared += 1
            if (try? Data(contentsOf: file)) != saved { differing.append("\(name) seed=\(seed)") }
        }
    }
    print("ORACLE \(record ? "recorded" : "compared") \(documents.count) documents, \(compared) outputs, \(differing.count) differ")
    #expect(differing.isEmpty, "\(differing.prefix(20))")
}

/// A fixed corpus of every kind of input, from the generators other suites
/// use, with invented names throughout.
enum OracleCorpus {
    static func documents() -> [(String, Data, [UInt64])] {
        var documents: [(String, Data, [UInt64])] = []
        // Records in each file format, small and large, plain and capitalised.
        var gen = Gen(seed: 4_711)
        for index in 0..<96 {
            let format = ["json", "csv", "xml", "txt"][index % 4]
            if let doc = try? gen.document(format: format, plain: index % 3 == 0, capitalized: index % 5 == 0, large: index % 12 == 11) {
                documents.append(("record-\(index).\(format)", doc.data, [1, 2]))
            }
        }
        // API payloads in every way they arrive.
        for index in 0..<PayloadGen.shapes.count * 2 {
            var payloads = PayloadGen(seed: 9_100 + UInt64(index))
            let shape = PayloadGen.shapes[index % PayloadGen.shapes.count]
            let payload = payloads.payload(shape)
            for rendering in Rendering.allCases {
                guard let rendered = Render.render(payload, as: rendering, gen: &payloads.gen) else { continue }
                let ext = (rendering.filename as NSString).pathExtension
                documents.append(("payload-\(index)-\(shape)-\(rendering.rawValue).\(ext)", Data(rendered.text.utf8), [UInt64(index) + 1]))
            }
        }
        // Prose with names and labelled values, one sentence at a time and as long notes.
        var sentences: [String] = []
        for (position, category) in GapCategory.allCases.enumerated() {
            var cases = GapCaseGen(seed: 77 &+ UInt64(position))
            for index in 0..<6 {
                let sample = cases.make(category)
                documents.append(("names-\(category.rawValue)-\(index).\((sample.filename as NSString).pathExtension)", sample.data, [3]))
                sentences.append(sample.prose)
            }
        }
        for (position, category) in PIIGapCategory.allCases.enumerated() {
            var cases = PIIGapCaseGen(seed: 88 &+ UInt64(position))
            for index in 0..<6 {
                let sample = cases.make(category)
                documents.append(("values-\(category.rawValue)-\(index).txt", Data(sample.prose.utf8), [4]))
                sentences.append(sample.prose)
            }
        }
        var shuffle = Gen(seed: 31)
        for index in 0..<6 {
            let note = (0..<400).map { _ in shuffle.choose(sentences) }.joined(separator: index.isMultiple(of: 2) ? "\n" : " ")
            documents.append(("notes-\(index).txt", Data(note.utf8), [5]))
        }
        // Logs and code: mostly words that must stay.
        let users = ["kofi.mensah", "linnea_a", "priya.r", "tomasz.w", "aisha.haddad"]
        for index in 0..<4 {
            let lines = (0..<1_500).map { line -> String in
                let user = shuffle.choose(users)
                return shuffle.choose([
                    "2025-03-\(10 + index)T08:\(10 + line % 50):\(10 + line % 49)Z INFO auth login ok user=\(user) ip=10.\(index).\(line % 250).\(line % 200 + 1) session=\(shuffle.token())",
                    "2025-03-\(10 + index) WARN worker[\(line)] retry \(line % 7) for job \(40_000 + line) owner \(user)@corvane.test",
                    "    at com.corvane.billing.Invoice.render(Invoice.java:\(line % 900 + 10))",
                    "DEBUG cache miss key=orders:\(line * 37 % 99_991) took \(line % 300)ms",
                    "let total = items.reduce(0) { $0 + $1.price } // \(user) to check rounding",
                ])
            }
            documents.append(("log-\(index).txt", Data(lines.joined(separator: "\n").utf8), [6]))
        }
        return documents
    }
}
