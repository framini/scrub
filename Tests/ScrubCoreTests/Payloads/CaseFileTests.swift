import Foundation
@testable import ScrubCore
import Testing

/// Scrubs the "text" of each line of a JSONL file kept outside the repository,
/// as text and as a JSON note's value, and, where the line gives them, under a
/// "key" and after a prose "phrase", and writes one line per case with every
/// output, so what is kept or changed can be judged outside.
/// SCRUB_CASES=/path runs it; SCRUB_CASES_OUT=/path receives the outputs.
@Test func caseFile() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let input = environment["SCRUB_CASES"], let out = environment["SCRUB_CASES_OUT"] else { return }
    var lines: [String] = []
    for line in try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
        guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let text = row["text"] as? String else { continue }
        var counts: [String: Int] = [:]
        func scrub(_ source: String, _ name: String) -> String {
            guard let result = try? Scrubber.scrub(Data(source.utf8), name: name, forceFullDetection: false, seed: 7) else { return "<error>" }
            if name == "doc.txt", counts.isEmpty { counts = result.counts }
            return String(decoding: result.output, as: UTF8.self)
        }
        let note = String(decoding: try JSONSerialization.data(withJSONObject: ["note": text]), as: UTF8.self)
        let noted = scrub(note, "doc.json")
        let value = (try? JSONSerialization.jsonObject(with: Data(noted.utf8)) as? [String: Any])?["note"] as? String ?? "<unparsed>"
        var result: [String: Any] = ["text": text, "plain": scrub(text, "doc.txt"), "json": value]
        if let key = row["key"] as? String {
            let keyed = scrub(String(decoding: try JSONSerialization.data(withJSONObject: [key: text]), as: UTF8.self), "doc.json")
            result["keyed"] = (try? JSONSerialization.jsonObject(with: Data(keyed.utf8)) as? [String: Any])?[key] as? String ?? "<unparsed>"
        }
        if let phrase = row["phrase"] as? String { result["phrased"] = scrub(phrase + " " + text, "doc.txt") }
        result["counts"] = counts
        lines.append(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
}
