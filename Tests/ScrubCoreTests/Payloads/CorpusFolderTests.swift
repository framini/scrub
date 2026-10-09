import Foundation
@testable import ScrubCore
import Testing

/// Scrubs a folder of JSON documents kept outside the repository, each with a
/// `<name>.truth.json` beside it: {"personal": [pointers], "keep": [pointers]},
/// RFC 6901 pointers to the leaves a person would call personal and to those
/// that must come out byte for byte. Each document goes in as a file and as
/// pasted text (alone, in a curl command, in a log line), and every rendering
/// must still parse with the same shape, change each personal leaf, keep each
/// kept one, and hold no personal value anywhere.
/// SCRUB_CORPUS=/path runs it; SCRUB_CORPUS_REPORT=/path writes every finding.
@Test func corpusFolder() throws {
    guard let root = ProcessInfo.processInfo.environment["SCRUB_CORPUS"], root.hasPrefix("/") else { return }
    let files = FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".truth.json") }.sorted() ?? []
    var findings: [String] = []
    var documents = 0, personalCount = 0
    for file in files {
        let path = root + "/" + file
        let truthPath = String(path.dropLast(5)) + ".truth.json"
        guard let truthData = FileManager.default.contents(atPath: truthPath),
              let truth = try? JSONSerialization.jsonObject(with: truthData) as? [String: Any],
              let source = FileManager.default.contents(atPath: path).map({ String(decoding: $0, as: UTF8.self) }),
              let parsed = try? OrderedJSON.parse(source) else { continue }
        let personal = Set(truth["personal"] as? [String] ?? []), keep = Set(truth["keep"] as? [String] ?? [])
        let leaves = CorpusLeaf.all(parsed)
        personalCount += leaves.filter { personal.contains($0.pointer) }.count
        let pretty = OrderedJSON.render(parsed).0
        let minified = CorpusLeaf.minified(parsed)
        let renderings: [(String, String, String)] = [
            ("json", "doc.json", source),
            ("pasted", "doc.txt", pretty),
            ("curl", "doc.txt", "curl -X POST https://api.example.com/v1/check \\\n  -H 'Content-Type: application/json' \\\n  -d '\(minified.replacingOccurrences(of: "'", with: "'\\''"))'\n"),
            ("log", "doc.txt", "2026-01-12T10:04:11Z INFO http - response body=\(minified)\n"),
        ]
        for (rendering, name, text) in renderings {
            documents += 1
            let output: String
            let started = Date()
            do { output = String(decoding: try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 7).output, as: UTF8.self) }
            catch { findings.append("\(file) [\(rendering)] error \(error)"); continue }
            // A scrub this slow on a document this size is a finding of its own.
            let seconds = Date().timeIntervalSince(started)
            if seconds > 10 { findings.append("\(file) [\(rendering)] slow \(Int(seconds))s for \(text.utf8.count) bytes") }
            for leaf in leaves where personal.contains(leaf.pointer) {
                let value = leaf.text.trimmingCharacters(in: .whitespaces)
                guard value.count >= 4, !leaf.isNumber || value.count >= 5 else { continue }
                if output.range(of: value, options: .caseInsensitive) != nil { findings.append("\(file) [\(rendering)] leak \(leaf.pointer) = \(value)") }
            }
            var body = output
            if rendering == "curl" || rendering == "log" {
                guard let open = output.firstIndex(where: { $0 == "{" || $0 == "[" }), let close = output.lastIndex(where: { $0 == "}" || $0 == "]" }) else { findings.append("\(file) [\(rendering)] no JSON left"); continue }
                body = String(output[open...close])
                if rendering == "curl" { body = body.replacingOccurrences(of: "'\\''", with: "'") }
            }
            guard let after = try? OrderedJSON.parse(body) else { findings.append("\(file) [\(rendering)] no longer parses"); continue }
            let out = Dictionary(CorpusLeaf.all(after).map { ($0.pointer, $0) }, uniquingKeysWith: { a, _ in a })
            if out.count != leaves.count { findings.append("\(file) [\(rendering)] shape: \(leaves.count) leaves → \(out.count)") }
            for leaf in leaves {
                guard let now = out[leaf.pointer] else { findings.append("\(file) [\(rendering)] missing \(leaf.pointer)"); continue }
                if now.isNumber != leaf.isNumber { findings.append("\(file) [\(rendering)] type \(leaf.pointer) = \(leaf.text) → \(now.text)") }
                if personal.contains(leaf.pointer), now.text == leaf.text, !leaf.text.isEmpty {
                    findings.append("\(file) [\(rendering)] unchanged \(leaf.pointer) = \(leaf.text)")
                }
                if keep.contains(leaf.pointer), now.text != leaf.text { findings.append("\(file) [\(rendering)] keptChanged \(leaf.pointer) = \(leaf.text) → \(now.text)") }
            }
        }
    }
    let report = "\(files.count) files, \(documents) documents, \(personalCount) personal leaves, \(findings.count) findings\n" + findings.joined(separator: "\n")
    if let out = ProcessInfo.processInfo.environment["SCRUB_CORPUS_REPORT"], out.hasPrefix("/") { try report.write(toFile: out, atomically: true, encoding: .utf8) }
    print(report.prefix(4000))
}

struct CorpusLeaf {
    let pointer: String
    let text: String
    let isNumber: Bool

    static func all(_ value: JSONValue, pointer: String = "") -> [CorpusLeaf] {
        func escape(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
        switch value {
        case .object(let pairs): return pairs.flatMap { all($0.1, pointer: pointer + "/" + escape($0.0)) }
        case .array(let members): return members.enumerated().flatMap { all($0.element, pointer: pointer + "/" + String($0.offset)) }
        case .string(let s): return [CorpusLeaf(pointer: pointer, text: s, isNumber: false)]
        case .number(let n): return [CorpusLeaf(pointer: pointer, text: n, isNumber: true)]
        default: return []
        }
    }
    static func minified(_ value: JSONValue) -> String {
        switch value {
        case .object(let pairs): return "{" + pairs.map { OrderedJSON.quote($0.0) + ":" + minified($0.1) }.joined(separator: ",") + "}"
        case .array(let members): return "[" + members.map(minified).joined(separator: ",") + "]"
        case .string(let s): return OrderedJSON.quote(s)
        case .number(let n): return n
        default: return OrderedJSON.render(value).0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
