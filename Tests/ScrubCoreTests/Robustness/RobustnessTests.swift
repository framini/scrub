import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// Known cases, transformed the ways real text arrives, checked for leaks
/// (by `ComponentLeaks`, on the output as a reader sees it), for structure
/// (the output still parses) and for consistency (a person's field and the
/// note about them take one stand-in). Generated text only: no evaluation text.
///
/// Each transform's tally is printed; `SCRUB_ROBUSTNESS_REPORT=/file` also
/// writes it. A transform listed in `known` is reported and not failed:
/// it is a limit the README names.
@Suite(.serialized)
struct Robustness {
    struct Person {
        let first: String, last: String, email: String, phone: String, ssn: String
        var full: String { first + " " + last }
        var last4: String { String(ssn.suffix(4)) }
    }

    /// Two invented people whose SSNs end alike.
    static func people(_ seed: UInt64) -> [Person] {
        var rng = SeededGenerator(seed: seed &+ 104_729)
        let names = [("Odalys", "Ferriter"), ("Teodoro", "Quillan"), ("Brisa", "Vantongeren"), ("Ingvar", "Peltomaa"), ("Thandeka", "Ravensworth"), ("Casimir", "Ambrosetti")]
        let pick = Int(seed % 3) * 2
        let ending = String(Int.random(in: 1001...9899, using: &rng))
        return (0..<2).map { index in
            let (first, last) = names[pick + index]
            let phone = "415-\(Int.random(in: 200...989, using: &rng))-\(Int.random(in: 1000...9999, using: &rng))"
            let ssn = "\(Int.random(in: 101...665, using: &rng))-\(Int.random(in: 10...99, using: &rng))-\(ending)"
            return Person(first: first, last: last, email: "\(first.lowercased()).\(last.lowercased())@kestrel.example", phone: phone, ssn: ssn)
        }
    }

    enum Format: String, CaseIterable { case text, json, csv, xml }

    /// How a value is written in the note, which transforms rewrite.
    struct Writing {
        var name: (Person) -> String = { $0.full }
        var email: (Person) -> String = { $0.email }
        var phone: (Person) -> String = { $0.phone }
        var note: (String) -> String = { $0 }
        var reorder = false
        var link = false
    }

    static func note(_ p: Person, _ w: Writing) -> String {
        var text = "\(w.name(p)) wrote from \(w.email(p)) and asked us to call \(w.phone(p)); the SSN on file ends in \(p.last4)."
        if w.link { text += " Profile: https://portal.example/verify?email=\(p.email.replacingOccurrences(of: "@", with: "%40"))&name=\(p.first)+\(p.last)" }
        return w.note(text)
    }

    static func render(_ people: [Person], _ format: Format, _ w: Writing) -> String {
        let ordered = w.reorder ? Array(people.reversed()) : people
        switch format {
        case .text:
            return ordered.map { "\(note($0, w))\nSSN: \($0.ssn)" }.joined(separator: "\n\n")
        case .json:
            let records = ordered.map { p in
                var pairs = [("full_name", p.full), ("email", p.email), ("phone", p.phone), ("ssn", p.ssn), ("ssn_last4", p.last4), ("note", note(p, w))]
                if w.reorder { pairs.reverse() }
                return "{" + pairs.map { "\"\($0.0)\": \"\($0.1)\"" }.joined(separator: ", ") + "}"
            }
            return "{\"people\": [" + records.joined(separator: ", ") + "]}"
        case .csv:
            var columns = ["full_name", "email", "phone", "ssn", "ssn_last4", "note"]
            if w.reorder { columns.reverse() }
            let rows = ordered.map { p -> String in
                let values = ["full_name": p.full, "email": p.email, "phone": p.phone, "ssn": p.ssn, "ssn_last4": p.last4, "note": note(p, w)]
                return columns.map { "\"" + values[$0]!.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
            }
            return columns.joined(separator: ",") + "\n" + rows.joined(separator: "\n") + "\n"
        case .xml:
            func escaped(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;") }
            let records = ordered.map { p in
                "<person><full_name>\(p.full)</full_name><email>\(p.email)</email><phone>\(p.phone)</phone><ssn>\(p.ssn)</ssn><ssn_last4>\(p.last4)</ssn_last4><note>\(escaped(note(p, w)))</note></person>"
            }
            return "<people>" + records.joined() + "</people>"
        }
    }

    /// A transform: how the case is written, and how its bytes are encoded.
    struct Transform {
        let name: String
        let column: String
        var writing = Writing()
        var encode: (String, Format) -> Data? = { text, _ in Data(text.utf8) }
        var formats = Format.allCases
    }

    static let zwsp = "\u{200B}", zwj = "\u{200D}", shy = "\u{00AD}", nbsp = "\u{00A0}"
    static func split(_ word: String, _ insert: String) -> String {
        let middle = word.index(word.startIndex, offsetBy: word.count / 2)
        return String(word[..<middle]) + insert + String(word[middle...])
    }

    nonisolated(unsafe) static let transforms: [Transform] = [
        Transform(name: "plain", column: "-"),
        Transform(name: "utf8BOM", column: "BOM/encoding", encode: { text, _ in Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8) }),
        Transform(name: "utf16XML", column: "BOM/encoding", encode: { text, _ in ("<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + text).data(using: .utf16) }, formats: [.xml]),
        Transform(name: "zeroWidthInNames", column: "Invisible chars", writing: Writing(name: { split($0.first, zwsp) + " " + split($0.last, zwj) })),
        Transform(name: "softHyphenInNames", column: "Invisible chars", writing: Writing(name: { $0.first + " " + split($0.last, shy) })),
        Transform(name: "noBreakSpaceInNames", column: "Invisible chars", writing: Writing(name: { $0.first + nbsp + $0.last })),
        Transform(name: "zeroWidthInEmails", column: "Invisible chars", writing: Writing(email: { split($0.email, zwsp) })),
        Transform(name: "zeroWidthInNumbers", column: "Invisible chars", writing: Writing(phone: { split($0.phone, zwsp) })),
        Transform(name: "allCaps", column: "Casing", writing: Writing(note: { $0.uppercased() })),
        Transform(name: "allLower", column: "Casing", writing: Writing(note: { $0.lowercased() })),
        Transform(name: "boldSplit", column: "Markup splits", writing: Writing(name: { "<b>" + split($0.first, "</b>") + " " + $0.last }), formats: [.text, .json, .csv]),
        Transform(name: "markdownSplit", column: "Markup splits", writing: Writing(name: { "**" + split($0.first, "**") + " " + $0.last })),
        Transform(name: "markdownEmphasis", column: "Markup splits", writing: Writing(name: { "*\($0.first)* **\($0.last)**" })),
        Transform(name: "xmlElementSplit", column: "Markup splits", writing: Writing(name: { "<i>" + split($0.first, "</i>") + " " + $0.last }), formats: [.xml]),
        Transform(name: "reordered", column: "Reordered records", writing: Writing(reorder: true)),
        Transform(name: "sharedLastFour", column: "Shared last-four"),
        Transform(name: "links", column: "URLs", writing: Writing(link: true)),
    ]
    /// Limits the README names: a value split across XML elements is read element by element.
    static let known: Set<String> = ["xmlElementSplit"]

    /// The output as a reader sees it: hidden characters gone, a no-break
    /// space a space, inline tags and emphasis marks gone, entities read.
    static func readable(_ text: String) -> String {
        var result = text
        for hidden in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}"] { result = result.replacingOccurrences(of: hidden, with: "") }
        result = result.replacingOccurrences(of: "\u{00A0}", with: " ")
        result = result.replacingOccurrences(of: #"</?(?:b|i|em|strong)>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "*", with: "")
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func decoded(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) ?? "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the output still reads in its format.
    static func parses(_ data: Data, _ format: Format) -> Bool {
        switch format {
        case .text: return true
        case .json:
            let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
            return (try? JSONSerialization.jsonObject(with: Data(body))) != nil
        case .csv: return (try? CSVReader.rows(decoded(data).replacingOccurrences(of: "\u{FEFF}", with: ""))).map { $0.count == 3 && $0.allSatisfy { $0.count == 6 } } ?? false
        case .xml: return (try? XMLDocument(data: data)) != nil
        }
    }

    /// Each person's name field, and whether the note about them uses its stand-in.
    static func inconsistent(_ output: String, _ format: Format, _ people: [Person]) -> [String] {
        guard format != .text else { return [] }
        var problems: [String] = []
        let records: [(name: String, note: String)]
        switch format {
        case .json:
            let object = (try? JSONSerialization.jsonObject(with: Data(output.replacingOccurrences(of: "\u{FEFF}", with: "").utf8))) as? [String: Any]
            records = ((object?["people"] as? [[String: Any]]) ?? []).map { ($0["full_name"] as? String ?? "", $0["note"] as? String ?? "") }
        case .csv:
            let rows = (try? CSVReader.rows(output.replacingOccurrences(of: "\u{FEFF}", with: ""))) ?? []
            guard let header = rows.first, let name = header.firstIndex(of: "full_name"), let note = header.firstIndex(of: "note") else { return ["no header"] }
            records = rows.dropFirst().map { ($0[name], $0[note]) }
        case .xml:
            let document = try? XMLDocument(data: Data(output.utf8))
            records = ((try? document?.nodes(forXPath: "//person")) ?? []).map { node in
                func text(_ path: String) -> String { ((try? node.nodes(forXPath: path))?.first?.stringValue) ?? "" }
                return (text("full_name"), text("note"))
            }
        case .text: records = []
        }
        for record in records where !readable(record.note).lowercased().hasPrefix(record.name.lowercased() + " wrote") {
            problems.append("note \(readable(record.note).prefix(40)) does not follow \(record.name)")
        }
        return problems
    }

    struct Tally { var cases = 0, leaks = 0, broken = 0, inconsistent = 0; var examples: [String] = [] }

    static func run(seeds: Range<UInt64>) throws -> [String: Tally] {
        var tallies: [String: Tally] = [:]
        for transform in transforms {
            var tally = Tally()
            for seed in seeds {
                let people = people(seed)
                let planted = people.flatMap { p in
                    [ComponentLeaks.Planted(p.full, kind: .name), .init(p.email, kind: .email), .init(p.phone, kind: .number), .init(p.ssn, kind: .number)]
                }
                for format in transform.formats {
                    let text = render(people, format, transform.writing)
                    guard let data = transform.encode(text, format) else { continue }
                    let name = "case.\(format == .text ? "txt" : format.rawValue)"
                    tally.cases += 1
                    let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                    let output = decoded(result.output)
                    let plain = render(people, format, Writing(reorder: transform.writing.reorder, link: transform.writing.link))
                    let leaked = ComponentLeaks.leaks(planted, input: plain, output: readable(output))
                    let broken = !parses(result.output, format)
                    let mismatched = broken ? [] : inconsistent(output, format, people)
                    if !leaked.isEmpty { tally.leaks += 1 }
                    if broken { tally.broken += 1 }
                    if !mismatched.isEmpty { tally.inconsistent += 1 }
                    if (!leaked.isEmpty || broken || !mismatched.isEmpty) && tally.examples.count < 3 {
                        tally.examples.append("[\(format) \(seed)] leaked \(leaked) broken \(broken) \(mismatched)\n\(output.prefix(700))")
                    }
                }
            }
            tallies[transform.name] = tally
        }
        return tallies
    }

    static func report(_ tallies: [String: Tally]) -> String {
        var lines = ["| transform | column | cases | leaking | broken | inconsistent |", "|---|---|---|---|---|---|"]
        for transform in transforms {
            let t = tallies[transform.name] ?? Tally()
            lines.append("| \(transform.name)\(known.contains(transform.name) ? " (known limit)" : "") | \(transform.column) | \(t.cases) | \(t.leaks) | \(t.broken) | \(t.inconsistent) |")
        }
        for transform in transforms { for example in tallies[transform.name]?.examples ?? [] { lines.append("\n\(transform.name) \(example)") } }
        return lines.joined(separator: "\n")
    }

    @Test func transformedCasesLeakNothingAndStayWhole() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["SCRUB_ROBUSTNESS_CASES"].flatMap(UInt64.init) ?? 6
        let tallies = try Self.run(seeds: 0..<count)
        let report = Self.report(tallies)
        print(report)
        if let file = environment["SCRUB_ROBUSTNESS_REPORT"] { try report.write(toFile: file, atomically: true, encoding: .utf8) }
        for transform in Self.transforms where !Self.known.contains(transform.name) {
            let t = tallies[transform.name] ?? Tally()
            #expect(t.leaks == 0 && t.broken == 0 && t.inconsistent == 0, "\(transform.name): \(t.leaks) leaking, \(t.broken) broken, \(t.inconsistent) inconsistent of \(t.cases)\n\(t.examples.joined(separator: "\n"))")
        }
    }
}
