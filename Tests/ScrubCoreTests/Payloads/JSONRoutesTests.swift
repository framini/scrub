import Foundation
@testable import ScrubCore
import Testing

// One JSON body, every way it arrives: a .json file, pasted alone (sniffed as
// JSON), a curl command's body, a log line's, and a .txt file. Each must come
// back parsing, with nothing personal left (in any value, key or string that
// holds a document), its other fields as written, and its people consistent.

enum Route: String, CaseIterable {
    case file, paste, curl, log, text

    func scrub(_ body: String, seed: UInt64 = 7) throws -> String {
        let (input, name): (String, String) = switch self {
        case .file: (body, "a.json")
        case .paste: (body, "")
        case .curl: ("curl -X POST https://api.example.com/v1/check -d '\(body.replacingOccurrences(of: "'", with: "'\\''"))'\n", "a.txt")
        case .log: ("2026-01-12T10:04:11Z INFO http - response body=\(body)\n", "a.txt")
        case .text: (body, "a.txt")
        }
        let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: seed).output, as: UTF8.self)
        switch self {
        case .curl:
            guard let start = output.range(of: "-d '"), let end = output.range(of: "'", options: .backwards), start.upperBound <= end.lowerBound else { return output }
            return String(output[start.upperBound..<end.lowerBound]).replacingOccurrences(of: "'\\''", with: "'")
        case .log:
            guard let start = output.range(of: "body=") else { return output }
            return String(output[start.upperBound...]).trimmingCharacters(in: .newlines)
        default: return output.trimmingCharacters(in: .newlines)
        }
    }
}

private func parsed(_ body: String) -> JSONValue? { try? OrderedJSON.parse(body) }

/// Every string in a document, and in each document a string holds, decoded.
private func strings(_ value: JSONValue) -> [String] {
    switch value {
    case .object(let pairs): return pairs.flatMap { [$0.0] + strings($0.1) }
    case .array(let members): return members.flatMap(strings)
    case .string(let text): return [text] + (parsed(text).map(strings) ?? [])
    case .number(let number): return [number]
    default: return []
    }
}
private func value(_ root: JSONValue, _ path: String...) -> String? {
    var node = root
    for key in path {
        switch node {
        case .object(let pairs): guard let next = pairs.first(where: { $0.0 == key })?.1 else { return nil }; node = next
        case .array(let members): guard let index = Int(key), members.indices.contains(index) else { return nil }; node = members[index]
        default: return nil
        }
    }
    switch node {
    case .string(let text): return text
    case .number(let number): return number
    case .bool(let flag): return flag ? "true" : "false"
    case .null: return "null"
    default: return nil
    }
}

/// `body` through every route: each output parses, and holds none of `gone`, raw or decoded.
private func check(_ body: String, gone: [String], seed: UInt64 = 7, _ more: (Route, JSONValue, String) -> Void = { _, _, _ in }) throws {
    for route in Route.allCases {
        let output = try route.scrub(body, seed: seed)
        guard let root = parsed(output) else { Issue.record("\(route): no longer parses: \(output)"); continue }
        let decoded = strings(root)
        for original in gone where output.contains(original) || decoded.contains(where: { $0.contains(original) }) {
            Issue.record("\(route): \(original) left: \(output)")
        }
        more(route, root, output)
    }
}

@Test func numericSecretsStayNumbersAndChange() throws {
    try check(#"{"password":-12345,"pin":12.50}"#, gone: ["12345", "12.50"]) { route, root, output in
        #expect(output.contains(#""password":-"#), "\(route): \(output)")
    }
}

@Test func escapedKeysAndValuesAreReadDecoded() throws {
    try check(#"{"\u0070assword":"quillharbor","note":"rosalind\u0040example.org","url":"https:\/\/example.org\/users\/rosalind.brightwater?email=rosalind%40example.org"}"#,
              gone: ["quillharbor", "rosalind", "brightwater"])
}

@Test func bodiesSentAsStringsAreScrubbedAtEveryLevel() throws {
    try check(#"{"body":"{\"body\":\"{\\\"password\\\":\\\"quillharbor\\\"}\"}"}"#, gone: ["quillharbor"])
    try check(#"{"body":"{\"password\":\"abc\\\"def\",\"last_name\":\"Brightwater\"}"}"#, gone: ["abc\"def", "Brightwater"]) { route, root, output in
        #expect(value(root, "body").flatMap(parsed) != nil, "\(route): \(output)")
    }
}

@Test func credentialMapsAreSecretAtAnyDepth() throws {
    try check(#"{"credentials":{"primary":{"value":"t7Pq9mN2sV4bX6kL"},"api":{"key":"quillharbor"}}}"#, gone: ["t7Pq9mN2sV4bX6kL", "quillharbor"])
    try check(#"{"credentials":[{"primary":"t7Pq9mN2sV4bX6kL","category":"SELFIE","classifier":"FACE"}]}"#, gone: ["t7Pq9mN2sV4bX6kL"]) { route, root, output in
        #expect(value(root, "credentials", "0", "category") == "SELFIE" && value(root, "credentials", "0", "classifier") == "FACE", "\(route): \(output)")
    }
}

@Test func secretsWrittenIntoKeysAreReplaced() throws {
    try check(#"{"password":"quillharbor","quillharbor_token":"active"}"#, gone: ["quillharbor"]) { route, _, output in
        #expect(output.contains(#""password""#), "\(route): \(output)")
    }
}

/// A secret's bytes in a status, an amount or an object's reference are the field's own.
@Test func fieldsThatHoldNoOnesDataKeepTheirValues() throws {
    try check(#"{"password":"retry","status":"retry"}"#, gone: []) { route, root, output in
        #expect(value(root, "status") == "retry" && value(root, "password") != "retry", "\(route): \(output)")
    }
    try check(#"{"secret":"12345","amount":12345}"#, gone: []) { route, root, output in
        #expect(value(root, "amount") == "12345" && value(root, "secret") != "12345", "\(route): \(output)")
    }
    try check(#"{"entity_token":"P-MSBW0ff3TQG7IYPvaoHs","access_token":"P-MSBW0ff3TQG7IYPvaoHs","request_id":"req_A12345678","amount":1200,"status":"active"}"#, gone: []) { route, root, output in
        #expect(value(root, "entity_token") == "P-MSBW0ff3TQG7IYPvaoHs" && value(root, "access_token") != "P-MSBW0ff3TQG7IYPvaoHs", "\(route): \(output)")
        #expect(value(root, "request_id") == "req_A12345678" && value(root, "amount") == "1200" && value(root, "status") == "active", "\(route): \(output)")
    }
}

@Test func aSurnameThatReadsAsALiteralIsReplaced() throws {
    try check(#"{"last_name":"True","first_name":"Rosalind","verified":true}"#, gone: ["Rosalind"]) { route, root, output in
        #expect(value(root, "last_name") != "True" && value(root, "verified") == "true", "\(route): \(output)")
    }
}

@Test func peopleInListsStayApartAndTheirCopiesAgree() throws {
    try check(#"{"first_names":["Rosalind","Odile"],"emails":["rosalind@example.org","odile@example.org"]}"#, gone: ["Rosalind", "Odile", "rosalind@", "odile@"]) { route, root, output in
        #expect(value(root, "first_names", "0") != value(root, "first_names", "1") && value(root, "emails", "0") != value(root, "emails", "1"), "\(route): \(output)")
    }
    try check(#"{"first_name":"Rosalind","last_name":"Brightwater","email":"rosalind\u0040example.org","copy":"rosalind\u0040example.org"}"#, gone: ["Rosalind", "Brightwater", "rosalind"]) { route, root, output in
        #expect(value(root, "email") == value(root, "copy"), "\(route): \(output)")
    }
}

/// Only what changed is written again: other tokens keep their escapes, number spellings and spacing.
@Test func untouchedTokensKeepTheirBytes() throws {
    let body = #"{"password":"quillharbor",  "status":"\u006f\u006b","timestamp":1.700000000000e12,"amount":1.00,"path":"\/v1\/checks"}"#
    try check(body, gone: ["quillharbor"]) { route, _, output in
        for token in [#""status":"\u006f\u006b""#, #""timestamp":1.700000000000e12"#, #""amount":1.00"#, #""path":"\/v1\/checks""#, #"",  "status""#] {
            #expect(output.contains(token), "\(route): \(token) in \(output)")
        }
    }
}

@Test func personalNumbersInAnySpellingAreReplaced() throws {
    try check(#"{"phone":2.128675309e9,"building_number":12,"street_name":"Via Garibaldi","country":"IT"}"#, gone: ["2.128675309e9", "Garibaldi"])
}

/// A long list of records through text is read as JSON, not scanned as prose.
@Test func longListsInTextScrubPromptly() throws {
    let record = #"{"first_name":"Rosalind","last_name":"Brightwater","password":"quillharbor","status":"ok"}"#
    let body = "[" + Array(repeating: record, count: 300).joined(separator: ",") + "]"
    for route in [Route.curl, .log, .text] {
        let start = Date()
        let output = try route.scrub(body)
        #expect(Date().timeIntervalSince(start) < 20, "\(route) took \(Date().timeIntervalSince(start))s")
        #expect(!output.contains("Rosalind") && !output.contains("quillharbor") && parsed(output) != nil, "\(route)")
    }
}

/// A body in base64, and a token whose payload is unsigned, hold no one's data readable once decoded.
@Test func encodedBodiesAreScrubbedInside() throws {
    try check(#"{"body_b64":"eyJwYXNzd29yZCI6InF1aWxsaGFyYm9yIiwibGFzdF9uYW1lIjoiQnJpZ2h0d2F0ZXIifQ=="}"#, gone: ["eyJwYXNzd29yZCI6InF1aWxsaGFyYm9yIiwibGFzdF9uYW1lIjoiQnJpZ2h0d2F0ZXIifQ=="]) { route, root, output in
        let decoded = value(root, "body_b64").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(parsed(decoded) != nil && !decoded.contains("quillharbor") && !decoded.contains("Brightwater"), "\(route): \(decoded)")
    }
    try check(#"{"jwt":"eyJhbGciOiJub25lIn0.eyJlbWFpbCI6InJvc2FsaW5kQGV4YW1wbGUub3JnIn0."}"#, gone: ["eyJlbWFpbCI6InJvc2FsaW5kQGV4YW1wbGUub3JnIn0"])
}

/// An apostrophe in a curl body is written as the shell writes it; the body is still read as JSON.
@Test func apostrophesInACurlBodyKeepItJSON() throws {
    try check(#"{"first_name":"Siobhan","last_name":"O'Bannon","note":"don't call after 6pm","status":"ok"}"#, gone: ["Siobhan", "O'Bannon"]) { route, root, output in
        #expect(value(root, "note") == "don't call after 6pm" && value(root, "status") == "ok", "\(route): \(output)")
    }
}

/// Fields identity and payment responses name their own way: an embossed name, a debtor's,
/// a document's bare number, national registry numbers, aliases, a masked card, a house's name.
@Test func identityResponseFieldsAreReadByWhatTheyHold() throws {
    let body = #"{"card_number":"999911XXXXXX4417","emboss_name":"Rosalind Brightwater","chosen_name":"Ros","debtor":{"name":"Odile Vandermeer"},"document":{"number":"QX7731905LK","type":"PASSPORT"},"identity_documents":[{"number":"LGQR882T4","country":"DEU"}],"cpfNumber":"39184726051","electorKey":"BRTRSL81092309M100","license_plate":"7QKW214","hits":[{"aka":["Linnea Achterberg","Achterberg Linnea"]}],"address":{"houseName":"Kestrel Lodge","country":"GB"}}"#
    try check(body, gone: ["4417", "Brightwater", "Vandermeer", "QX7731905LK", "LGQR882T4", "39184726051", "BRTRSL81092309M100", "7QKW214", "Achterberg", "Kestrel Lodge"]) { route, root, output in
        #expect(value(root, "document", "type") == "PASSPORT" && value(root, "identity_documents", "0", "country") == "DEU" && value(root, "address", "country") == "GB", "\(route): \(output)")
    }
}

/// Under a credential's own key any spelling is a secret: capitals, or a word that reads as a literal.
@Test func credentialKeysHoldSecretsWhateverTheirSpelling() throws {
    try check(#"{"api_key":"QWERTYASDFGHZXCV","client_secret":"UPPER_SECRET","password":"false","verified":false}"#, gone: ["QWERTYASDFGHZXCV", "UPPER_SECRET"]) { route, root, output in
        #expect(value(root, "password") != "false" && value(root, "verified") == "false" && output.contains("false}"), "\(route): \(output)")
    }
    try check(#"{"credentials":[{"key":{"value":"t7Pq9mN2sV4bX6kL"}}]}"#, gone: ["t7Pq9mN2sV4bX6kL"])
}

/// A list written alone, of strings or encoded bodies, is read as JSON on every route.
@Test func listsOfStringsAreReadAsJSON() throws {
    try check(#"["rosalind\u0040example.org","Rosalind Brightwater"]"#, gone: ["rosalind", "Brightwater"])
    try check(#"["eyJwYXNzd29yZCI6InF1aWxsaGFyYm9yIn0="]"#, gone: ["eyJwYXNzd29yZCI6InF1aWxsaGFyYm9yIn0="]) { route, root, output in
        let decoded = value(root, "0").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!decoded.contains("quillharbor"), "\(route): \(decoded)")
    }
}

/// A pretty-printed body in base64 is read as one, whatever it opens with.
@Test func prettyBase64BodiesAreScrubbed() throws {
    try check(#"{"body_b64":"ewogInBhc3N3b3JkIjogInF1aWxsaGFyYm9yIgp9"}"#, gone: ["ewogInBhc3N3b3JkIjogInF1aWxsaGFyYm9yIgp9"]) { route, root, output in
        let decoded = value(root, "body_b64").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!decoded.contains("quillharbor") && parsed(decoded) != nil, "\(route): \(decoded)")
    }
}

/// A key that only ends like a field's name holds data: a password written into it goes.
@Test func keysEndingLikeFieldsStillHoldData() throws {
    try check(#"{"password":"quillharbor_token","quillharbor_token":"active"}"#, gone: ["quillharbor"])
}

/// A broken body is read as text whole; an object after a key in code is read under that key.
@Test func brokenBodiesAndBodiesInCodeKeepTheirContext() throws {
    for input in [#"INFO body={"bad":, "credentials":{"primary":"quillharbor"}} tail"#, #"credentials = {"primary":"quillharbor"}"#] {
        let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.txt", forceFullDetection: false, seed: 7).output, as: UTF8.self)
        #expect(!output.contains("quillharbor"), "\(output)")
    }
}

/// Apostrophes in a curl body leave every other character as written, emoji too.
@Test func shellEscapesKeepSurrogatePairs() throws {
    let output = try Route.curl.scrub(#"{"note":"don't 😀 email rosalind@example.org"}"#)
    #expect(output.contains("don't 😀 email") && !output.contains("rosalind@"), "\(output)")
}

/// A value written with escapes is picked in the preview as the value it decodes to.
@Test func escapedValuesArePickedInThePreview() throws {
    for route in Route.allCases where route != .curl {
        let body = #"{"password":"quillharbor","opaque":"Qz\u0061x\u0076orn"}"#
        let (input, name): (String, String) = route == .log ? ("INFO body=" + body, "a.txt") : (body, route == .file ? "a.json" : route == .paste ? "" : "a.txt")
        let result = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 7)
        guard case .text(let preview, let marks, _) = result.preview else { Issue.record("no text preview"); continue }
        let at = (preview as NSString).range(of: "Qz\\u0061x")
        guard at.location != NSNotFound else { Issue.record("\(route): \(preview)"); continue }
        let picked = result.pick(in: preview, marks: marks, range: at.location..<(at.location + 20))
        #expect(picked.missed == ["Qzaxvorn"], "\(route): \(picked.missed)")
    }
}

/// A sample's stand-in for a key ("YOUR_API_KEY") is kept; a real key beside it is not.
@Test func samplePlaceholdersAreKept() throws {
    try check(#"{"sample_api_key":"YOUR_API_KEY","secret_key":"your-secret-key","api_key":"QWERTYASDFGHZXCV"}"#, gone: ["QWERTYASDFGHZXCV"]) { route, root, output in
        #expect(value(root, "sample_api_key") == "YOUR_API_KEY" && value(root, "secret_key") == "your-secret-key", "\(route): \(output)")
    }
}

/// A field read across its values: names most of a list's entries are read as make the rest names
/// too, and a few codes written again and again are a category, kept as written.
@Test func fieldsAreReadAcrossTheirValues() throws {
    let body = #"{"hits":[{"aka":["Linnea Achterberg","Odile Vandermeer","Qorwyn Tessaly","Brightwater Rosalind"],"source":"WATCHLIST"},{"aka":["Ysolde Marrick"],"source":"WATCHLIST"}],"checks":[{"part":"FRONT"},{"part":"BACK"},{"part":"FRONT"},{"part":"BACK"},{"part":"FACE"}]}"#
    try check(body, gone: ["Achterberg", "Vandermeer", "Qorwyn", "Tessaly", "Brightwater", "Ysolde", "Marrick"]) { route, root, output in
        #expect(value(root, "checks", "4", "part") == "FACE" && value(root, "hits", "0", "source") == "WATCHLIST", "\(route): \(output)")
    }
    #expect(Fields.categorical(["FACE", "FRONT", "FACE", "BACK", "FACE"].map { DocumentLeaf($0) }))
    #expect(!Fields.categorical(["Rosalind", "Odile", "Linnea", "Ysolde"].map { DocumentLeaf($0) }))
}
