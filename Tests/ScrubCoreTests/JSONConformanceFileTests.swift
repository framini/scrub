import Foundation
@testable import ScrubCore
import Testing

/// Opt-in: SCRUB_JSON_CONFORMANCE names a JSONL file of {id, json, expect, numeric} cases.
@Test func jsonConformanceFile() throws {
    guard let path = ProcessInfo.processInfo.environment["SCRUB_JSON_CONFORMANCE"] else { return }
    struct Case: Decodable {
        let id: String
        let json: String
        let expect: String
        let numeric: Bool?
    }
    let cases = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(Case.self, from: Data($0.utf8))
    }
    #expect(!cases.isEmpty)
    for item in cases {
        if item.expect == "reject" {
            #expect(throws: (any Error).self, "JSONSource accepted \(item.id)") { try JSONSource.read(item.json) }
            #expect(throws: (any Error).self, "OrderedJSON accepted \(item.id)") { try OrderedJSON.parse(item.json) }
        } else {
            _ = try JSONSource.read(item.json)
            _ = try OrderedJSON.parse(item.json)
            if item.numeric == true {
                // The count must keep its exact spelling even when an adjacent value changes.
                let text = "{\r\n\t\"count\" : \(item.json), \"email\": \"quill.harbor@example.org\" }\n"
                let result = try Scrubber.scrub(Data(text.utf8), name: "numbers.json", forceFullDetection: false, seed: 7)
                let output = String(decoding: result.output, as: UTF8.self)
                #expect(output.hasPrefix("{\r\n\t\"count\" : \(item.json), \"email\": "), "Number or layout changed: \(item.id)")
                #expect(output.hasSuffix(" }\n"))
                #expect(!output.contains("quill.harbor@example.org"))
                _ = try JSONSource.read(output)
            }
        }
    }
    print("JSON conformance: \(cases.count) parser cases, \(cases.filter { $0.numeric == true }.count) replacement checks")
}
