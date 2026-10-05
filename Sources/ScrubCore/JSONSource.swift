import Foundation

/// A JSON document read without losing a byte: the tree `OrderedJSON` reads,
/// and where in the text each value's and each key's token sits (UTF-16, a
/// string's with its quotes), by the path `JSONFile` gives it ("/2/0"). A
/// scrubbed document is the text with only the tokens that changed written
/// again, so its spacing, escapes, number spellings and every value left
/// alone stay as they were. Keys written twice stay twice, each its own.
struct JSONSource {
    let text: String
    let root: JSONValue
    /// Written inside a shell's single quotes (`-d '{…}'`), where an apostrophe is `'\''`:
    /// read as one, and each written so again.
    let shell: Bool
    private(set) var values: [String: Range<Int>] = [:]
    private(set) var keys: [String: Range<Int>] = [:]

    /// The document `text` is, with nothing but white space around it.
    static func read(_ text: String, shell: Bool = false) throws -> JSONSource {
        let units = Array(text.utf16)
        var reader = Reader(units: units, shell: shell)
        reader.space()
        let start = reader.index
        let root = try reader.value(path: "", depth: 0)
        reader.space()
        guard reader.index == units.count, start < units.count else { throw ScrubError.unsupported("invalid_json") }
        return JSONSource(text: text, root: root, shell: shell, values: reader.values, keys: reader.keys)
    }

    /// The objects and lists written whole inside other text: a curl command's
    /// body, a log line's, a document pasted between notes. Each is a range of
    /// `text` that reads as JSON on its own, outermost first, never overlapping,
    /// with the key written just before it (`credentials = {…}`), which it is read under.
    static func regions(in text: String) -> [(range: Range<Int>, shell: Bool, key: String?)] {
        let units = Array(text.utf16)
        guard units.contains(123) || units.contains(91) else { return [] }
        var found: [(range: Range<Int>, shell: Bool, key: String?)] = []
        var index = 0
        while index < units.count {
            guard units[index] == 123 || units[index] == 91 else { index += 1; continue }
            // Only what opens as JSON does: `{"`, `{}`, `[{`, `["`, `[[`, not a template's "{name}" or a log's "[INFO]".
            var next = index + 1
            while next < units.count, [9, 10, 13, 32].contains(units[next]) { next += 1 }
            let opens = next < units.count && (units[index] == 123 ? units[next] == 34 || units[next] == 125 : [34, 123, 91].contains(units[next]))
            guard opens else { index += 1; continue }
            // After a single quote, a shell's: its apostrophes are `'\''`.
            let shell = index > 0 && units[index - 1] == 39
            var reader = Reader(units: units, index: index, shell: shell)
            if let value = try? reader.value(path: "", depth: 0) {
                if holds(value) { found.append((index..<reader.index, shell, key(before: index, in: units))) }
                index = reader.index
            } else {
                // A body broken partway ("note": "said "hi"") is read as text whole, its keys around its values:
                // never the objects inside it, cut from the keys they sit under.
                index = max(index + 1, closing(from: index, in: units))
            }
        }
        return found
    }
    /// Past the bracket that closes the one at `start`, strings skipped; the end of its line
    /// if none does, so one cut-off body in a log leaves the lines after it read.
    private static func closing(from start: Int, in units: [UInt16]) -> Int {
        var depth = 0, at = start, quote: UInt16? = nil
        while at < units.count {
            let unit = units[at]
            if let open = quote {
                if unit == 92 { at += 2; continue }
                if unit == open || unit == 10 { quote = nil }
            } else if unit == 34 {
                quote = unit
            } else if unit == 123 || unit == 91 {
                depth += 1
            } else if unit == 125 || unit == 93 {
                depth -= 1
                if depth == 0 { return at + 1 }
            }
            at += 1
        }
        return units[start...].firstIndex(of: 10) ?? units.count
    }
    /// The key written just before `start` and its ":" or "=": `credentials = `, `"body": `, `data=`.
    private static func key(before start: Int, in units: [UInt16]) -> String? {
        var at = start - 1
        while at >= 0, units[at] == 32 || units[at] == 9 || units[at] == 39 { at -= 1 }
        guard at >= 0, units[at] == 58 || units[at] == 61 else { return nil }
        at -= 1
        while at >= 0, units[at] == 32 || units[at] == 9 { at -= 1 }
        guard at >= 0 else { return nil }
        let end: Int
        if units[at] == 34 || units[at] == 39 {
            let quote = units[at]
            end = at
            at -= 1
            while at >= 0, units[at] != quote, units[at] != 10 { at -= 1 }
            guard at >= 0, units[at] == quote, end - at > 1 else { return nil }
            return String(utf16CodeUnits: Array(units[(at + 1)..<end]), count: end - at - 1)
        }
        end = at + 1
        while at >= 0, (65...90).contains(units[at]) || (97...122).contains(units[at]) || (48...57).contains(units[at]) || units[at] == 95 || units[at] == 45 || units[at] == 46 { at -= 1 }
        return end - at > 1 ? String(utf16CodeUnits: Array(units[(at + 1)..<end]), count: end - at - 1) : nil
    }
    /// Whether a value found in text has anything in it to read: a key, or a string.
    private static func holds(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let pairs): return !pairs.isEmpty
        case .array(let members): return members.contains(where: holds) || members.contains { if case .string = $0 { return true }; return false }
        default: return false
        }
    }

    private struct Reader {
        let units: [UInt16]
        var index = 0
        var shell = false
        var values: [String: Range<Int>] = [:]
        var keys: [String: Range<Int>] = [:]

        mutating func space() { while index < units.count, [9, 10, 13, 32].contains(units[index]) { index += 1 } }
        mutating func take(_ unit: UInt16) -> Bool {
            space()
            guard index < units.count, units[index] == unit else { return false }
            index += 1
            return true
        }
        mutating func value(path: String, depth: Int) throws -> JSONValue {
            space()
            guard index < units.count else { throw ScrubError.unsupported("invalid_json") }
            if units[index] == 123 || units[index] == 91 {
                guard depth < 64 else { throw ScrubError.unsupported("too_deep") }
            }
            let start = index
            let value: JSONValue
            switch units[index] {
            case 123:
                index += 1
                var pairs: [(String, JSONValue)] = []
                if !take(125) {
                    while true {
                        space()
                        let childPath = path + "/" + String(pairs.count)
                        let keyStart = index
                        guard index < units.count, units[index] == 34 else { throw ScrubError.unsupported("invalid_json") }
                        let key = try string()
                        keys[childPath] = keyStart..<index
                        guard take(58) else { throw ScrubError.unsupported("invalid_json") }
                        pairs.append((key, try self.value(path: childPath, depth: depth + 1)))
                        if take(125) { break }
                        guard take(44) else { throw ScrubError.unsupported("invalid_json") }
                    }
                }
                value = .object(pairs)
            case 91:
                index += 1
                var members: [JSONValue] = []
                if !take(93) {
                    while true {
                        members.append(try self.value(path: path + "/" + String(members.count), depth: depth + 1))
                        if take(93) { break }
                        guard take(44) else { throw ScrubError.unsupported("invalid_json") }
                    }
                }
                value = .array(members)
            case 34: value = .string(try string())
            case 116: value = try literal("true", .bool(true))
            case 102: value = try literal("false", .bool(false))
            case 110: value = try literal("null", .null)
            default: value = try number()
            }
            values[path] = start..<index
            return value
        }
        mutating func literal(_ word: String, _ result: JSONValue) throws -> JSONValue {
            let expected = Array(word.utf16)
            guard units[index...].starts(with: expected) else { throw ScrubError.unsupported("invalid_json") }
            index += expected.count
            return result
        }
        /// A string token, decoded; a raw line break or control character inside one is no JSON.
        mutating func string() throws -> String {
            let start = index
            index += 1
            var escaped = false, escapes = false
            while index < units.count {
                let unit = units[index]
                index += 1
                if unit < 32 { throw ScrubError.unsupported("invalid_json") }
                if shell, unit == 39 {
                    // `'\''` closes the shell's quote, writes an apostrophe and opens it again.
                    guard index + 2 < units.count, units[index] == 92, units[index + 1] == 39, units[index + 2] == 39 else { throw ScrubError.unsupported("invalid_json") }
                    index += 3; escapes = true; escaped = false
                    continue
                }
                if unit == 34 && !escaped {
                    guard escapes else { return String(utf16CodeUnits: Array(units[(start + 1)..<(index - 1)]), count: index - 1 - start - 1) }
                    var token = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                    if shell { token = token.replacingOccurrences(of: "'\\''", with: "'") }
                    guard let decoded = try? JSONSerialization.jsonObject(with: Data(token.utf8), options: [.fragmentsAllowed]) as? String else { throw ScrubError.unsupported("invalid_json") }
                    return decoded
                }
                if unit == 92 && !escaped { escaped = true; escapes = true } else { escaped = false }
            }
            throw ScrubError.unsupported("invalid_json")
        }
        mutating func number() throws -> JSONValue {
            let start = index
            while index < units.count, units[index] == 45 || units[index] == 43 || units[index] == 46 || (48...57).contains(units[index]) || units[index] == 69 || units[index] == 101 { index += 1 }
            guard index > start else { throw ScrubError.unsupported("invalid_json") }
            let raw = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
            guard !TextRanges.matches(OrderedJSON.numberGrammar, in: raw).isEmpty else { throw ScrubError.unsupported("invalid_json") }
            return .number(raw)
        }
    }
}
