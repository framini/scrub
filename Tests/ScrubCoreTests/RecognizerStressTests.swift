import Foundation
@testable import ScrubCore
import Testing

// The registry of national identifiers, stressed as a whole and generically:
// every recognizer in `Recognizers.all` is exercised through its own forms,
// context words, separators and draws, so one added later is covered too.
//
// 1. Values that fill API payloads and belong to no one (order numbers, dates,
//    hashes, amounts, references…) are seldom an identifier alone.
// 2. A drawn identifier, in every spelling its forms write and in variants of
//    them, is replaced wherever the registry's own rules say it is found, by a
//    stand-in passing the same check in the same layout, on every route.
// 3. The same seed gives the same output.

@Suite struct RecognizerStressTests {}

// MARK: - Shared helpers

private func stressSeed(_ text: String) -> UInt64 {
    text.utf8.reduce(1_469_598_103_934_665_603) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
}

/// Whether `form` matches the whole of `text`.
private func whole(_ form: Recognizer.Form, _ text: String) -> Bool {
    guard let regex = form.pattern.regex else { return false }
    let length = (text as NSString).length
    return regex.matches(in: text, range: NSRange(location: 0, length: length)).contains { $0.range.location == 0 && $0.range.length == length }
}

/// Whether one of the recognizer's forms writes `text` whole.
private func writes(_ recognizer: Recognizer, _ text: String) -> Bool {
    recognizer.forms.contains { whole($0, text) }
}

/// The registry's own rule: `text`, read whole, is found when some recognizer
/// passes it in a form that needs no word, or in any of its forms when one of
/// `words` (its key's, or those written before it) names it.
private func registryFinds(_ text: String, named words: Set<String>) -> Bool {
    Recognizers.all.contains { recognizer in
        recognizer.passes(text) && recognizer.forms.contains { form in
            whole(form, text) && (form.alone || !recognizer.context.isDisjoint(with: words))
        }
    }
}

private func registrySpans(_ text: String, contextWords: Set<String>) -> [Span] {
    let units = Array(text.utf16)
    return Recognizers.find(text, ns: text as NSString, units: units, contextWords: contextWords, isCancelled: { false })
}

/// A JSON string literal; the values written here hold no quote, backslash or control character.
private func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func node(_ root: JSONValue, _ path: [String]) -> JSONValue? {
    var current = root
    for key in path {
        switch current {
        case .object(let pairs): guard let next = pairs.first(where: { $0.0 == key })?.1 else { return nil }; current = next
        case .array(let members): guard let index = Int(key), members.indices.contains(index) else { return nil }; current = members[index]
        default: return nil
        }
    }
    return current
}

private func scalar(_ root: JSONValue, _ path: [String]) -> String? {
    switch node(root, path) {
    case .string(let text)?: return text
    case .number(let text)?: return text
    default: return nil
    }
}

/// Every key and scalar of a document, and of each document a string holds.
private func texts(_ value: JSONValue) -> [String] {
    switch value {
    case .object(let pairs): return pairs.flatMap { [$0.0] + texts($0.1) }
    case .array(let members): return members.flatMap(texts)
    case .string(let text): return [text] + ((try? OrderedJSON.parse(text)).map(texts) ?? [])
    case .number(let text): return [text]
    default: return []
    }
}

// MARK: - 1. False positives

/// Values of one kind that fill API payloads, none of them anyone's.
private struct Family: Sendable {
    let name: String
    /// The neutral key such a value sits under.
    let key: String
    /// Whether it is written as a JSON number.
    let number: Bool
    let make: @Sendable (inout Noise) -> String
}

private struct Noise {
    var rng: SeededGenerator
    init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
    mutating func digits(_ count: Int) -> String { String((0..<count).map { _ in Character(String(int(0...9))) }) }
    /// Digits not starting with zero.
    mutating func number(_ count: Int) -> String { String(int(1...9)) + digits(count - 1) }
    mutating func padded(_ value: Int, _ width: Int) -> String { String(repeating: "0", count: max(0, width - String(value).count)) + String(value) }
    mutating func from(_ alphabet: String, _ count: Int) -> String { let a = Array(alphabet); return String((0..<count).map { _ in a[int(0...(a.count - 1))] }) }
    mutating func hex(_ count: Int) -> String { from("0123456789abcdef", count) }
    mutating func upper(_ count: Int) -> String { from("ABCDEFGHIJKLMNOPQRSTUVWXYZ", count) }
    mutating func alnum(_ count: Int) -> String { from("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", count) }
    mutating func upperAlnum(_ count: Int) -> String { from("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", count) }
    mutating func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8(int(0...255)) }) }
    /// A recent date, as numbers.
    mutating func date() -> (y: Int, m: Int, d: Int) {
        let m = int(1...12)
        return (int(2015...2026), m, int(1...[31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]))
    }
    mutating func yymmdd() -> String { let d = date(); return padded(d.y % 100, 2) + padded(d.m, 2) + padded(d.d, 2) }
    mutating func ddmmyy() -> String { let d = date(); return padded(d.d, 2) + padded(d.m, 2) + padded(d.y % 100, 2) }
    mutating func yyyymmdd(_ separator: String = "") -> String { let d = date(); return String(d.y) + separator + padded(d.m, 2) + separator + padded(d.d, 2) }
    mutating func time(_ separator: String = ":") -> String { padded(int(0...23), 2) + separator + padded(int(0...59), 2) + separator + padded(int(0...59), 2) }
    mutating func uuid() -> String { hex(8) + "-" + hex(4) + "-4" + hex(3) + "-" + pick(["8", "9", "a", "b"]) + hex(3) + "-" + hex(12) }
}

private let families: [Family] = [
    Family(name: "order number", key: "order_id", number: false) { n in
        switch n.int(0...8) {
        case 0: return "ORD-" + n.digits(n.int(6...10))
        case 1: return n.number(n.int(8...12))
        case 2: return "#" + n.number(6)
        case 3: return "PO-\(n.date().y)-" + n.digits(5)
        case 4: return "SO" + n.digits(n.int(6...9))
        case 5: return n.digits(3) + "-" + n.digits(7) + "-" + n.digits(7)
        case 6: return n.number(4) + "-" + n.digits(4) + "-" + n.digits(4)
        case 7: return n.number(3) + "-" + n.digits(3) + "-" + n.digits(3)
        default: return n.number(6) + "-" + n.digits(4)
        }
    },
    Family(name: "date-prefixed order", key: "order_number", number: false) { n in
        switch n.int(0...7) {
        case 0: return n.yymmdd() + "-" + n.padded(n.int(1...9999), 4)
        case 1: return n.yymmdd() + "-" + n.padded(n.int(1...9_999_999), 7)
        case 2: return n.yyyymmdd() + "-" + n.padded(n.int(1...999_999), n.int(4...6))
        case 3: return n.yymmdd() + n.padded(n.int(1...9999), 4)
        case 4: return n.ddmmyy() + "-" + n.padded(n.int(1...9999), 4)
        case 5: return n.yyyymmdd() + "-" + n.upperAlnum(4)
        case 6: return n.yymmdd() + "-" + n.padded(n.int(1...999), 3) + n.upperAlnum(1)
        default: return n.yyyymmdd() + n.padded(n.int(1...999), 3)
        }
    },
    Family(name: "invoice number", key: "invoice_number", number: false) { n in
        switch n.int(0...6) {
        case 0: return "INV-\(n.date().y)-" + n.padded(n.int(1...999_999), 6)
        case 1: return "INV" + n.digits(8)
        case 2: return "F\(n.date().y)/" + n.padded(n.int(1...99999), 5)
        case 3: return "\(n.date().y)/" + n.padded(n.int(1...999_999), 6)
        case 4: return "A-\(n.date().y)-" + n.padded(n.int(1...999_999), 6)
        case 5: return "\(n.date().y)-" + n.padded(n.int(1...99999), 5)
        default: let d = n.date(); return "FAC-" + n.padded(d.y % 100, 2) + n.padded(d.m, 2) + "-" + n.padded(n.int(1...9999), 4)
        }
    },
    Family(name: "transaction id", key: "transaction_id", number: false) { n in
        switch n.int(0...5) {
        case 0: return "txn_" + n.alnum(24)
        case 1: return "T" + n.digits(12)
        case 2: return n.yyyymmdd() + n.time("") + n.digits(6)
        case 3: return "ch_" + n.alnum(24)
        case 4: return "TX-" + n.digits(4) + "-" + n.digits(4) + "-" + n.digits(4)
        default: return n.number(10) + n.upperAlnum(6)
        }
    },
    Family(name: "date or timestamp", key: "created_at", number: false) { n in
        let d = n.date()
        let y = String(d.y), m = n.padded(d.m, 2), day = n.padded(d.d, 2)
        switch n.int(0...7) {
        case 0: return "\(y)-\(m)-\(day)"
        case 1: return "\(y)-\(m)-\(day)T\(n.time())Z"
        case 2: return "\(y)-\(m)-\(day)T\(n.time()).\(n.digits(3))+0\(n.int(0...9)):00"
        case 3: return "\(day).\(m).\(y)"
        case 4: return "\(day)/\(m)/\(y)"
        case 5: return "\(m)/\(day)/\(y)"
        case 6: return "\(y).\(m).\(day)"
        default: return "\(y)-\(m)-\(day) \(n.time())"
        }
    },
    Family(name: "compact timestamp", key: "timestamp", number: false) { n in
        switch n.int(0...5) {
        case 0: return n.yyyymmdd() + "T" + n.time("") + "Z"
        case 1: return n.yyyymmdd()
        case 2: return n.yyyymmdd() + n.time("")
        case 3: return n.yymmdd()
        case 4: return n.yyyymmdd() + "_" + n.time("")
        default: return n.yyyymmdd("-") + "-" + n.time("-")
        }
    },
    Family(name: "epoch seconds", key: "created", number: true) { n in String(n.int(1_400_000_000...1_900_000_000)) },
    Family(name: "epoch milliseconds", key: "updated_ms", number: true) { n in String(n.int(1_400_000_000_000...1_900_000_000_000)) },
    Family(name: "uuid or fragment", key: "request_id", number: false) { n in
        let uuid = n.uuid()
        switch n.int(0...5) {
        case 0: return uuid
        case 1: return uuid.uppercased()
        case 2: return String(uuid.prefix(8))
        case 3: return String(uuid.suffix(12))
        case 4: return uuid.replacingOccurrences(of: "-", with: "")
        default: return String(uuid.prefix(13))
        }
    },
    Family(name: "hex hash or sha", key: "checksum", number: false) { n in
        switch n.int(0...5) {
        case 0: return n.hex(8)
        case 1: return n.hex(32)
        case 2: return n.hex(40)
        case 3: return n.hex(64)
        case 4: return n.hex(7)
        default: return n.hex(12).uppercased()
        }
    },
    Family(name: "base64 nonce", key: "nonce", number: false) { n in
        let encoded = n.bytes(n.pick([9, 12, 16, 24, 32])).base64EncodedString()
        return n.int(0...1) == 0 ? encoded : encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    },
    Family(name: "sku", key: "sku", number: false) { n in
        switch n.int(0...6) {
        case 0: return "SKU-" + n.digits(5) + "-" + n.upper(2) + "-" + n.pick(["S", "M", "L", "XL"])
        case 1: return n.upper(2) + "-" + n.digits(4) + "-" + n.upper(2)
        case 2: return n.digits(5) + "-" + n.digits(3)
        case 3: return n.upper(3) + n.digits(6)
        case 4: return n.digits(8) + n.upper(1)
        case 5: return n.upper(1) + n.digits(7) + n.upper(1)
        default: return n.upper(4) + n.digits(6) + n.upperAlnum(3)
        }
    },
    Family(name: "semver", key: "version", number: false) { n in
        let core = "\(n.int(0...20)).\(n.int(0...40)).\(n.int(0...99))"
        switch n.int(0...4) {
        case 0: return core
        case 1: return core + "-beta.\(n.int(1...9))"
        case 2: return "\(n.date().y).\(n.int(1...12)).\(n.int(1...31))"
        case 3: return "v" + core + "+build." + n.yyyymmdd()
        default: return core + "-rc.\(n.int(1...5))"
        }
    },
    Family(name: "amount", key: "amount", number: false) { n in
        let whole = n.int(1000...99_999_999), cents = n.padded(n.int(0...99), 2)
        let grouped = { (separator: String) -> String in
            var digits = Array(String(whole)), out: [Character] = []
            while digits.count > 3 { out = Array(separator) + digits.suffix(3) + out; digits.removeLast(3) }
            return String(digits + out)
        }
        switch n.int(0...5) {
        case 0: return grouped(".") + "," + cents
        case 1: return grouped(",") + "." + cents
        case 2: return "\(whole).\(cents)"
        case 3: return grouped(" ") + "," + cents
        case 4: return "-" + grouped(",") + "." + cents
        default: return grouped(".")
        }
    },
    Family(name: "snowflake id", key: "id", number: false) { n in n.number(n.int(18...19)) },
    Family(name: "tracking number", key: "tracking_number", number: false) { n in
        switch n.int(0...6) {
        case 0: return "1Z" + n.upperAlnum(16)
        case 1: return n.number(12)
        case 2: return n.number(15)
        case 3: return n.number(n.int(20...22))
        case 4: return n.upper(2) + n.digits(9) + n.upper(2)
        case 5: return "JD" + n.digits(18)
        default: return "9400" + n.digits(18)
        }
    },
    Family(name: "iso code", key: "currency", number: false) { n in
        n.pick(["US", "DE", "BR", "IN", "USD", "EUR", "BRL", "DEU", "FRA", "JPY", "en-US", "pt-BR", "978", "840", "ISO 4217", "USD/EUR"])
    },
    Family(name: "enum code", key: "code", number: false) { n in
        switch n.int(0...4) {
        case 0: return n.pick(["PAYMENT_CAPTURED", "REFUND_PENDING", "KYC_REVIEW", "ACTIVE", "CLOSED"])
        case 1: return "E" + n.digits(4)
        case 2: return "ERR_" + n.digits(4)
        case 3: return "STATUS_" + n.digits(3)
        default: return "V\(n.int(1...9))_" + n.upper(n.int(4...8))
        }
    },
    Family(name: "http status", key: "status", number: false) { n in
        let (code, reason) = n.pick([(200, "OK"), (201, "Created"), (204, "No Content"), (301, "Moved Permanently"), (400, "Bad Request"), (401, "Unauthorized"), (404, "Not Found"), (409, "Conflict"), (422, "Unprocessable Entity"), (429, "Too Many Requests"), (500, "Internal Server Error"), (503, "Service Unavailable")])
        switch n.int(0...2) {
        case 0: return "\(code) \(reason)"
        case 1: return "HTTP/1.1 \(code) \(reason)"
        default: return "\(code)"
        }
    },
    Family(name: "ip-like", key: "client_ip", number: false) { n in
        switch n.int(0...3) {
        case 0: return "\(n.int(1...223)).\(n.int(0...255)).\(n.int(0...255)).\(n.int(1...254))"
        case 1: return "10.\(n.int(0...255)).\(n.int(0...255)).\(n.int(1...254)):\(n.int(1024...65535))"
        case 2: return "\(n.int(10...192)).\(n.int(0...255)).0.0/\(n.int(8...30))"
        default: return "2001:db8:" + (0..<4).map { _ in n.hex(4) }.joined(separator: ":")
        }
    },
    Family(name: "bank reference", key: "reference", number: false) { n in
        switch n.int(0...7) {
        case 0: return "RF" + n.digits(2) + n.digits(n.int(10...20))
        case 1: return "SEPA-" + n.yyyymmdd() + "-" + n.padded(n.int(1...999_999), 6)
        case 2: return "/RFB/" + n.digits(9)
        case 3: return "E2E-" + n.yyyymmdd() + "-" + n.upperAlnum(8)
        case 4: return n.yyyymmdd() + n.digits(8)
        case 5: return "REF " + n.digits(16)
        case 6: return n.upper(4) + n.yymmdd() + n.upperAlnum(3)
        default: return "NOTPROVIDED"
        }
    },
    Family(name: "file name", key: "file", number: false) { n in
        switch n.int(0...2) {
        case 0: return "export_" + n.yyyymmdd() + "_" + n.time("") + ".csv"
        case 1: return "report-" + n.yyyymmdd("-") + ".pdf"
        default: return "IMG_" + n.yyyymmdd() + "_" + n.digits(6) + ".jpg"
        }
    },
    Family(name: "page cursor", key: "next_cursor", number: false) { n in
        switch n.int(0...2) {
        case 0: return "page_" + String(n.int(1...5000))
        case 1: return "cursor:" + n.bytes(12).base64EncodedString()
        default: return String(n.int(1_000_000...99_999_999)) + ":" + String(n.int(0...999))
        }
    },
]

private let perFamily = 1000

private func noiseValues(seed: UInt64) -> [(family: Int, value: String)] {
    var noise = Noise(seed: seed)
    var values: [(Int, String)] = []
    for (index, family) in families.enumerated() {
        for _ in 0..<perFamily { values.append((index, family.make(&noise))) }
    }
    return values
}

private struct FormKey: Hashable, Comparable {
    let family: Int, recognizer: Int, form: Int
    static func < (a: FormKey, b: FormKey) -> Bool { (a.family, a.recognizer, a.form) < (b.family, b.recognizer, b.form) }
}

extension RecognizerStressTests {
@Test func payloadValuesAreSeldomAnIdentifier() throws {
    let values = noiseValues(seed: 20_240_115)
    #expect(values.count >= 20_000)
    var found: [FormKey: Int] = [:], latent: [FormKey: Int] = [:]
    var examples: [FormKey: [String]] = [:]
    for (family, value) in values {
        let spans = Patterns.find(value, isCancelled: { false }).filter { $0.entity == Recognizers.entity }
        let matchesByForm = Recognizers.all.enumerated().flatMap { r, recognizer in
            recognizer.forms.enumerated().flatMap { f, form in
                TextRanges.matches(form.pattern, in: value).compactMap { match -> (FormKey, Range<Int>)? in
                    let range = match.range.location..<NSMaxRange(match.range)
                    return recognizer.passes(TextRanges.substring(value, range)) ? (FormKey(family: family, recognizer: r, form: f), range) : nil
                }
            }
        }
        // Latent: a form matches and the check passes, so a word naming it would make it one.
        for key in Set(matchesByForm.map(\.0)) { latent[key, default: 0] += 1 }
        // A span is a form's when that form matched its range and, with no word naming it, scores enough alone.
        let flagged = Set(matchesByForm.filter { pair in
            let form = Recognizers.all[pair.0.recognizer].forms[pair.0.form]
            return (form.alone || form.score >= 0.4) && spans.contains { $0.range == pair.1 }
        }.map(\.0))
        for key in flagged {
            found[key, default: 0] += 1
            if examples[key, default: []].count < 4 { examples[key, default: []].append(value) }
        }
    }
    var rows: [String] = []
    for key in Set(found.keys).union(latent.keys).sorted() {
        let recognizer = Recognizers.all[key.recognizer], form = recognizer.forms[key.form]
        let hits = found[key] ?? 0, total = Double(perFamily)
        func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0) }
        func rate(_ count: Int) -> String { String(format: "%5d (%.4f)", count, Double(count) / total) }
        rows.append(pad(families[key.family].name, 20) + " " + pad(recognizer.name, 24) + " form \(key.form) " + pad(form.alone ? "alone" : "named", 5)
                    + "  found " + rate(hits) + "  latent " + rate(latent[key] ?? 0) + "  e.g. " + (examples[key] ?? []).joined(separator: ", "))
        if form.alone {
            #expect(Double(hits) / total < 1.0 / 10_000, "\(families[key.family].name): \(recognizer.name) form \(key.form) finds \(hits) of \(perFamily) alone, e.g. \(examples[key] ?? [])")
        }
    }
    print("RECOGNIZER FALSE POSITIVES (\(values.count) values, \(perFamily) per family; found = flagged with no context, latent = form + check pass, needing a naming word)")
    rows.forEach { print("FP | " + $0) }
}
}

/// Payload values the registry flags come back byte for byte when they sit under neutral keys, on every route.
extension RecognizerStressTests {
@Test func payloadValuesSurviveEveryRoute() throws {
    let values = noiseValues(seed: 20_240_115)
    var flagged: [(Int, String)] = [], other: [(Int, String)] = []
    for (family, value) in values {
        let words = Set(KeyHints.words(families[family].key))
        if !registrySpans(value, contextWords: words).isEmpty { flagged.append((family, value)) } else { other.append((family, value)) }
    }
    var noise = Noise(seed: 99)
    var chosen = Array(flagged.prefix(120))
    while chosen.count < 200, !other.isEmpty { chosen.append(other.remove(at: noise.int(0...(other.count - 1)))) }
    let registry = Set(flagged.map(\.1))
    var changedElsewhere: [String] = []
    for (family, value) in chosen {
        let key = families[family].key
        let literal = families[family].number ? value : quoted(value)
        let body = "{" + quoted(key) + ":" + literal + #","status":"ok","currency":"EUR"}"#
        for route in Route.allCases {
            let output = try route.scrub(body)
            let kept = output.contains(quoted(key) + ":" + literal)
            if registry.contains(value) {
                #expect(kept, "flagged by the registry and changed: \(route): \(body) → \(output)")
            } else if !kept {
                changedElsewhere.append("\(route): \(body) → \(output)")
            }
        }
    }
    print("NEUTRAL VALUES: \(chosen.count) through \(Route.allCases.count) routes, \(min(120, flagged.count)) of \(flagged.count) registry-flagged among them")
    for line in changedElsewhere { print("CHANGED BY ANOTHER DETECTOR | " + line) }
}
}

// MARK: - 2. Misses and layouts

/// Separators between a value's characters: before character `cuts[i]`, `marks[i]`.
private struct Layout: Hashable {
    let cuts: [Int]
    let marks: [Character]
    func write(_ characters: [Character]) -> String {
        var out = "", next = 0
        for (index, character) in characters.enumerated() {
            if next < cuts.count, cuts[next] == index { out.append(marks[next]); next += 1 }
            out.append(character)
        }
        return out
    }
}

private func combinations(_ n: Int, _ k: Int) -> [[Int]] {
    var out: [[Int]] = []
    func walk(_ from: Int, _ chosen: [Int]) {
        if chosen.count == k { out.append(chosen); return }
        guard from < n else { return }
        for cut in from..<n where n - cut >= k - chosen.count { walk(cut + 1, chosen + [cut]) }
    }
    walk(1, [])
    return out
}

private func binomial(_ n: Int, _ k: Int) -> Double {
    guard k >= 0, k <= n else { return 0 }
    return (0..<k).reduce(1.0) { $0 * Double(n - $1) / Double($1 + 1) }
}

/// Every placement of the recognizer's separators its forms write whole, found
/// by trying them on `sample`: up to four cuts with any mix of separators, up
/// to six with one, within a budget per count.
private func layouts(of recognizer: Recognizer, sample: [Character]) -> [Layout] {
    let marks = recognizer.separators.sorted()
    var out: [Layout] = []
    func consider(_ layout: Layout) { if writes(recognizer, layout.write(sample)) { out.append(layout) } }
    consider(Layout(cuts: [], marks: []))
    let n = sample.count
    guard !marks.isEmpty else { return out }
    for k in 1...6 where k < n {
        let positions = binomial(n - 1, k)
        let mixed = positions * pow(Double(marks.count), Double(k)) <= 150_000
        guard mixed || positions * Double(marks.count) <= 60_000 else { continue }
        for cuts in combinations(n, k) {
            if mixed {
                var choice = Array(repeating: 0, count: k)
                while true {
                    consider(Layout(cuts: cuts, marks: choice.map { marks[$0] }))
                    var i = k - 1
                    while i >= 0, choice[i] == marks.count - 1 { choice[i] = 0; i -= 1 }
                    if i < 0 { break }
                    choice[i] += 1
                }
            } else {
                for mark in marks { consider(Layout(cuts: cuts, marks: Array(repeating: mark, count: k))) }
            }
        }
    }
    // A mark written before the first character: "+27 82 …", once more with each layout's own marks.
    if marks.contains("+") {
        let plain = out.isEmpty ? [Layout(cuts: [], marks: [])] : out
        var spaced = Set(out)
        for layout in plain + marks.filter({ $0 != "+" }).map({ Layout(cuts: [2, 4, 7], marks: [$0, $0, $0]) }) {
            let led = Layout(cuts: [0] + layout.cuts, marks: ["+"] + layout.marks)
            if !spaced.contains(led), writes(recognizer, led.write(sample)) { out.append(led); spaced.insert(led) }
        }
    }
    return out
}

private struct Failure {
    let cause: String
    let recognizer: String
    let variant: String
    let route: Route
    let input: String
    let output: String
    var line: String { "[\(cause)] \(recognizer) \(variant) \(route): \(input) → \(output)" }
    /// The variant without the value's own context word: "layout/key", "bare/typed".
    var shape: String { variant.split(separator: "=").first.map(String.init) ?? variant }
}

/// One way a spelled value is sent, and what the registry says about it.
private struct Case {
    let variant: String
    let spelled: String
    let body: String
    /// Where the value sits, as a JSON path; nil when it sits in text.
    let path: [String]?
    /// For a value in text: the text before and after it.
    let around: (String, String)?
    /// Whether the registry's own rules say it is found.
    let expected: Bool
    /// Whether the body is prose rather than JSON.
    var prose: Bool = false
}

/// The replacement of `spelled` in `output`, when one can be read.
private func replacement(_ item: Case, in output: String, root: JSONValue?) -> String? {
    if let path = item.path, let root { return scalar(root, path) }
    guard let (before, after) = item.around, let text = item.prose ? output : root.flatMap({ scalar($0, ["note"]) }),
          text.hasPrefix(before), text.hasSuffix(after), text.count >= before.count + after.count else { return nil }
    return String(text.dropFirst(before.count).dropLast(after.count))
}

/// Separators where they were and letters in their case.
private func keepsLayout(_ original: String, _ made: String, _ recognizer: Recognizer) -> Bool {
    let a = Array(original), b = Array(made)
    guard a.count == b.count else { return false }
    return zip(a, b).allSatisfy { x, y in
        if recognizer.separators.contains(x) || recognizer.separators.contains(y) { return x == y }
        // Case is layout only where the kind folds it; a Base58 address's case is its value.
        return !recognizer.folds || !(x.isLowercase && y.isUppercase) && !(x.isUppercase && y.isLowercase)
    }
}

/// A draw shaped like the recognizer's sample, cut or padded to `length`.
private func drawn(_ recognizer: Recognizer, _ length: Int, _ rng: inout any RandomNumberGenerator) -> [Character] {
    let sample = recognizer.kept(recognizerSamples[recognizer.name] ?? "")
    let like = Array(sample.prefix(length)) + Array(repeating: Character("1"), count: max(0, length - sample.count))
    return recognizer.draw(like, &rng)
}

/// Distinct lengths a recognizer draws, asked for every count from 4 to 24.
private func drawnLengths(_ recognizer: Recognizer) -> [Int] {
    var rng: any RandomNumberGenerator = SeededGenerator(seed: 1)
    // Only lengths whose draws pass its check: a draw shaped like a cut sample may be no value at all.
    return Array(Set((4...96).map { drawn(recognizer, $0, &rng) }.filter { recognizer.check($0) }.map(\.count))).sorted()
}

private let separatorSwaps: [(String, Character)] = [("space", " "), ("dot", "."), ("dash", "-")]
/// Prose is no JSON: a .json file would refuse it.
private let proseRoutes: [Route] = [.paste, .curl, .log, .text]

extension RecognizerStressTests {
@Test(arguments: Recognizers.all.map { $0.name })
func identifiersAreReplacedInEverySpelling(name: String) throws {
    let recognizer = try #require(Recognizers.all.first { $0.name == name })
    var rng: any RandomNumberGenerator = SeededGenerator(seed: stressSeed(name))
    let lengths = drawnLengths(recognizer)
    let context = recognizer.context.sorted()
    var templates: [Int: [Layout]] = [:]
    var failures: [Failure] = []
    var stats: [String: (sent: Int, gone: Int, expected: Int)] = [:]
    var elsewhere: [String: Int] = [:]
    var elsewhereExample: [String: String] = [:]
    var uncovered: [String: (sent: Int, replaced: Int)] = [:]
    var tried = 0

    for index in 0..<20 {
        guard !lengths.isEmpty else { Issue.record("\(name) draws nothing passing its check"); return }
        let length = lengths[index % lengths.count]
        var canonical = drawn(recognizer, length, &rng)
        if canonical.count != length { canonical = drawn(recognizer, canonical.count, &rng) }
        if templates[canonical.count] == nil { templates[canonical.count] = layouts(of: recognizer, sample: canonical) }
        let written = (templates[canonical.count] ?? []).map { $0.write(canonical) }.filter { writes(recognizer, $0) && recognizer.passes($0) }
        if written.isEmpty { failures.append(Failure(cause: "no form writes the draw", recognizer: name, variant: "draw", route: .file, input: String(canonical), output: "")) }

        // Spellings: each layout its forms write, in small letters, bare, and with its separators swapped.
        // A kind whose forms make separators optional writes many layouts (nine, sixteen): each value
        // sends four of them, turning through the list, so twenty values send every one.
        let sent = written.count <= 4 ? written : (0..<4).map { written[(index * 4 + $0) % written.count] }
        var spellings: [(String, String)] = sent.map { ("layout", $0) }
        for layout in sent where layout.lowercased() != layout { spellings.append(("lower", layout.lowercased())) }
        spellings.append(("bare", String(canonical)))
        if let layout = written.first(where: { $0.contains(where: recognizer.separators.contains) }) {
            for (label, swap) in separatorSwaps {
                spellings.append(("sep" + label, String(layout.map { recognizer.separators.contains($0) ? swap : $0 })))
            }
        }
        var seen = Set<String>()
        spellings = spellings.filter { seen.insert($0.1).inserted }

        var cases: [Case] = []
        for (offset, (kind, spelled)) in spellings.enumerated() {
            // Each value takes the context words in turn, so twenty values name it every way.
            let word = context[(index + offset) % context.count]
            cases.append(Case(variant: "\(kind)/ref", spelled: spelled, body: #"{"ref":\#(quoted(spelled)),"status":"ok"}"#,
                              path: ["ref"], around: nil, expected: registryFinds(spelled, named: Set(KeyHints.words("ref")))))
            cases.append(Case(variant: "\(kind)/key=\(word)", spelled: spelled, body: "{\(quoted(word)):\(quoted(spelled)),\"status\":\"ok\"}",
                              path: [word], around: nil, expected: registryFinds(spelled, named: Set(KeyHints.words(word)))))
            let named = ("Holder \(word) ", " on file")
            cases.append(Case(variant: "\(kind)/note=\(word)", spelled: spelled, body: #"{"note":\#(quoted(named.0 + spelled + named.1))}"#,
                              path: nil, around: named, expected: registryFinds(spelled, named: [word])))
            guard kind == "layout" else { continue }
            // A typed record names it by the word written just before it: {"type":"CPF","number":"…"}.
            cases.append(Case(variant: "\(kind)/typed=\(word.uppercased())", spelled: spelled, body: "{\"type\":\(quoted(word.uppercased())),\"number\":\(quoted(spelled))}",
                              path: ["number"], around: nil, expected: registryFinds(spelled, named: [word])))
            let plain = ("Reference ", " on file")
            cases.append(Case(variant: "\(kind)/note", spelled: spelled, body: #"{"note":\#(quoted(plain.0 + spelled + plain.1))}"#,
                              path: nil, around: plain, expected: registryFinds(spelled, named: [])))
            cases.append(Case(variant: "\(kind)/prose=\(word)", spelled: spelled, body: named.0 + spelled + named.1,
                              path: nil, around: named, expected: registryFinds(spelled, named: [word]), prose: true))
            cases.append(Case(variant: "\(kind)/prose", spelled: spelled, body: plain.0 + spelled + plain.1,
                              path: nil, around: plain, expected: registryFinds(spelled, named: []), prose: true))
        }
        // As a JSON number: found only when its key names it.
        let bare = String(canonical)
        if bare.allSatisfy({ $0.isASCII && $0.isNumber }), bare.first != "0" {
            let word = context[index % context.count]
            cases.append(Case(variant: "number/ref", spelled: bare, body: #"{"ref":\#(bare)}"#, path: ["ref"], around: nil, expected: false))
            cases.append(Case(variant: "number/key=\(word)", spelled: bare, body: "{\(quoted(word)):\(bare)}", path: [word], around: nil,
                              expected: registryFinds(bare, named: Set(KeyHints.words(word)))))
        }

        for item in cases {
            let known = Recognizers.recognizing(item.spelled)
            for route in item.prose ? proseRoutes : Route.allCases {
                tried += 1
                let output = try route.scrub(item.body)
                func fail(_ cause: String, _ shown: String = output) {
                    failures.append(Failure(cause: cause, recognizer: name, variant: item.variant, route: route, input: item.body, output: shown))
                }
                let root = try? OrderedJSON.parse(output)
                if !item.prose && root == nil { fail("output no longer parses"); continue }
                let left = output.contains(item.spelled) || (root.map(texts) ?? []).contains { $0.contains(item.spelled) }
                let shape = String(item.variant.split(separator: "/").last ?? "").split(separator: "=").first.map(String.init) ?? ""
                var tally = stats[shape, default: (0, 0, 0)]
                tally.sent += 1
                if !left { tally.gone += 1 }
                if item.expected { tally.expected += 1 }
                stats[shape] = tally
                if item.expected && left { fail("missed where the registry finds it") }
                if !item.expected && known == nil {
                    let kind = item.variant.split(separator: "/").first.map(String.init) ?? ""
                    var counts = uncovered[kind, default: (0, 0)]
                    counts.sent += 1
                    if !left { counts.replaced += 1 }
                    uncovered[kind] = counts
                }
                // A postcode's stand-in is its stand-in place's and a phone's its numbering's, not the registry's draw.
                guard !left, var known, Recognizers.drawn.contains(recognizer.entity), let made = replacement(item, in: output, root: root) else { continue }
                // A value several kinds pass takes a stand-in of the kind its word names.
                if let word = item.variant.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) {
                    let kinds = Recognizers.candidates(item.spelled), words = Set(KeyHints.words(word))
                    if let named = kinds.first(where: { $0.name == recognizer.name }) ?? kinds.first(where: { Recognizers.named($0.context, among: words) }) { known = named }
                }
                let checked = known.passes(made) && writes(known, made), laidOut = keepsLayout(item.spelled, made, known)
                if item.expected {
                    if !checked { fail("stand-in fails \(known.name)'s check or forms", item.spelled + " → " + made) }
                    if !laidOut { fail("stand-in loses the layout", item.spelled + " → " + made) }
                } else if !checked || !laidOut {
                    // Not the registry's to find: another detector took it, with a stand-in of its own kind.
                    let shape = item.variant.split(separator: "=").first.map(String.init) ?? item.variant
                    elsewhere[shape, default: 0] += 1
                    if elsewhereExample[shape] == nil { elsewhereExample[shape] = "\(route): \(item.body) → \(made)" }
                }
            }
        }

        // Two spellings of one identifier in one document, separated and bare, take one stand-in.
        if Recognizers.drawn.contains(recognizer.entity), let separated = written.first(where: { $0.contains(where: recognizer.separators.contains) }), separated != bare {
            let word = context[index % context.count]
            let words = Set(KeyHints.words(word))
            // Only where both are its spellings: "AIM2" is no German plate, "A IM 2" is.
            let spells = { (value: String) in Recognizers.candidates(value).contains { $0.name == recognizer.name } }
            if registryFinds(separated, named: words) || registryFinds(bare, named: words), spells(separated) && spells(bare) {
                let body = "{\"a\":{\(quoted(word)):\(quoted(separated))},\"b\":{\(quoted(word)):\(quoted(bare))}}"
                let owner = Recognizers.candidates(separated).contains { $0.name == recognizer.name } ? recognizer : Recognizers.recognizing(separated) ?? recognizer
                for route in Route.allCases {
                    tried += 1
                    let output = try route.scrub(body)
                    guard let root = try? OrderedJSON.parse(output), let first = scalar(root, ["a", word]), let second = scalar(root, ["b", word]) else {
                        failures.append(Failure(cause: "output no longer parses", recognizer: name, variant: "pair", route: route, input: body, output: output)); continue
                    }
                    if first == separated || second == bare || owner.kept(first) != owner.kept(second) {
                        failures.append(Failure(cause: "two spellings of one identifier differ", recognizer: name, variant: "pair/key=\(word)", route: route, input: body, output: output))
                    }
                }
            }
        }
    }

    let layoutsShown = templates.sorted { $0.key < $1.key }.map { "\($0.key) chars: \($0.value.count) layouts" }.joined(separator: "; ")
    print("REGISTRY \(name): \(tried) scrubs; \(layoutsShown); gone/sent (registry expects): " + stats.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.gone)/\($0.value.sent) (\($0.value.expected))" }.joined(separator: ", "))
    if !uncovered.isEmpty {
        print("UNCOVERED \(name) (no form writes the spelling): " + uncovered.sorted { $0.key < $1.key }.map { "\($0.key) replaced \($0.value.replaced)/\($0.value.sent)" }.joined(separator: ", "))
    }
    for (shape, count) in elsewhere.sorted(by: { $0.key < $1.key }) {
        print("ELSEWHERE \(name) \(shape): \(count) replaced by another detector, not as \(name), e.g. \(elsewhereExample[shape] ?? "")")
    }
    // Every failure printed with its exact input; one issue per cause and shape, with its count and first input.
    var groups: [String: [Failure]] = [:]
    for failure in failures {
        print("FAILURE | " + failure.line)
        groups["[\(failure.cause)] \(failure.recognizer) \(failure.shape)", default: []].append(failure)
    }
    for (group, members) in groups.sorted(by: { $0.key < $1.key }) {
        let routes = Set(members.map(\.route.rawValue)).sorted().joined(separator: ",")
        Issue.record(Comment(rawValue: "\(group): \(members.count) on \(routes), e.g. \(members[0].route): \(members[0].input) → \(members[0].output)"))
    }
}
}

// MARK: - 3. Determinism

extension RecognizerStressTests {
@Test func theSameSeedGivesTheSameOutput() throws {
    func draws(_ seed: UInt64) -> [String] {
        var rng: any RandomNumberGenerator = SeededGenerator(seed: seed)
        return Recognizers.all.map { String(drawn($0, drawnLengths($0).first ?? 0, &rng)) }
    }
    #expect(draws(5) == draws(5))
    #expect(noiseValues(seed: 3).map(\.value) == noiseValues(seed: 3).map(\.value))
    let values = draws(5)
    let body = "{" + zip(Recognizers.all, values).enumerated().map { index, pair in
        "\(quoted("r\(index)")):{\(quoted(pair.0.context.sorted().first ?? "ref")):\(quoted(pair.1)),\"ref\":\(quoted(pair.1))}"
    }.joined(separator: ",") + "}"
    for route in Route.allCases {
        let first = try route.scrub(body, seed: 7), second = try route.scrub(body, seed: 7)
        #expect(first == second, "\(route): \(first) ≠ \(second)")
        var rng: any RandomNumberGenerator = SeededGenerator(seed: 7)
        var again: any RandomNumberGenerator = SeededGenerator(seed: 7)
        for value in values {
            #expect(Recognizers.standIn(for: value, using: &rng) == Recognizers.standIn(for: value, using: &again), "\(value)")
        }
    }
}
}
