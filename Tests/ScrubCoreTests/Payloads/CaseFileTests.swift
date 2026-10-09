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

/// Scrubs whole JSON documents from a JSONL file kept outside the repository: a
/// line's "json_b64" (its exact bytes) or "json" as a file's bytes, or
/// its "json_doc" (an object, or a string holding one), and writes one line per
/// case with the status, the output and any error, so a parser's acceptance and
/// what is kept or changed can be judged outside.
/// SCRUB_JSON_CASES=/path runs it; SCRUB_JSON_CASES_OUT=/path receives the outputs.
@Test func jsonCaseFile() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let input = environment["SCRUB_JSON_CASES"], let out = environment["SCRUB_JSON_CASES_OUT"] else { return }
    var lines: [String] = []
    for line in try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
        let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
        var source = Data()
        // The bytes as given, where a line gives them: a string read from JSON may lose a leading byte order mark.
        if let encoded = row["json_b64"] as? String, let bytes = Data(base64Encoded: encoded) { source = bytes }
        else if let text = row["json"] as? String { source = Data(text.utf8) }
        else if let text = row["json_doc"] as? String { source = Data(text.utf8) }
        else if let doc = row["json_doc"], JSONSerialization.isValidJSONObject(doc) { source = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) }
        var result: [String: Any] = [:]
        if let sha = row["sha1"] { result["sha1"] = sha }
        do {
            let output = try Scrubber.scrub(source, name: "doc.json", forceFullDetection: false, seed: 7).output
            result["status"] = "ok"
            // Decoded so a leading byte order mark stays in the text, as `String(data:encoding:)` would drop it.
            if String(data: output, encoding: .utf8) != nil { result["out"] = String(decoding: output, as: UTF8.self) } else { result["out_b64"] = output.base64EncodedString() }
        } catch {
            result["status"] = "error"
            result["out"] = "<error>"
            result["message"] = String(describing: error)
        }
        lines.append(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
}
