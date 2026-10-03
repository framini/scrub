import Foundation

enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

enum OrderedJSON {
    private static let numberGrammar = TextPattern(#"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#)
    static func parse(_ text: String) throws -> JSONValue {
        var reader = Reader(Array(text.utf8))
        let value = try reader.value()
        reader.space()
        guard reader.index == reader.bytes.count else { throw ScrubError.unsupported("invalid_json") }
        return value
    }
    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 34: out += "\\\""
            case 92: out += "\\\\"
            case 8: out += "\\b"
            case 9: out += "\\t"
            case 10: out += "\\n"
            case 12: out += "\\f"
            case 13: out += "\\r"
            case 0..<32: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
    static func render(_ value: JSONValue, valueMarks: [String: [Mark]] = [:], keyMarks: [String: [Mark]] = [:]) -> (String, [Mark]) {
        var output = ""
        var marks: [Mark] = []
        func write(_ text: String) { output += text }
        func writeString(_ value: String, _ source: [Mark]) {
            if source.isEmpty { write(quote(value)); return }
            write("\"")
            var cursor = 0
            for mark in source.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where mark.range.lowerBound >= cursor {
                write(String(quote(TextRanges.substring(value, cursor..<mark.range.lowerBound)).dropFirst().dropLast()))
                let start = (output as NSString).length
                write(String(quote(TextRanges.substring(value, mark.range)).dropFirst().dropLast()))
                marks.append(Mark(range: start..<(output as NSString).length, entity: mark.entity, byHand: mark.byHand))
                cursor = mark.range.upperBound
            }
            write(String(quote(TextRanges.substring(value, cursor..<(value as NSString).length)).dropFirst().dropLast()))
            write("\"")
        }
        func node(_ value: JSONValue, _ depth: Int, _ path: String) {
            switch value {
            case .object(let pairs):
                if pairs.isEmpty { write("{}"); return }
                write("{\n")
                for (index, pair) in pairs.enumerated() {
                    let childPath = path + "/" + String(index)
                    write(String(repeating: "  ", count: depth + 1))
                    writeString(pair.0, keyMarks[childPath] ?? [])
                    write(": ")
                    node(pair.1, depth + 1, childPath)
                    write(index + 1 == pairs.count ? "\n" : ",\n")
                }
                write(String(repeating: "  ", count: depth) + "}")
            case .array(let values):
                if values.isEmpty { write("[]"); return }
                write("[\n")
                for (index, child) in values.enumerated() {
                    write(String(repeating: "  ", count: depth + 1))
                    node(child, depth + 1, path + "/" + String(index))
                    write(index + 1 == values.count ? "\n" : ",\n")
                }
                write(String(repeating: "  ", count: depth) + "]")
            case .string(let string): writeString(string, valueMarks[path] ?? [])
            case .number(let number):
                let start = (output as NSString).length
                write(number)
                for mark in valueMarks[path] ?? [] { marks.append(Mark(range: (start + mark.range.lowerBound)..<(start + mark.range.upperBound), entity: mark.entity, byHand: mark.byHand)) }
            case .bool(let bool): write(bool ? "true" : "false")
            case .null: write("null")
            }
        }
        node(value, 0, "")
        write("\n")
        return (output, marks)
    }
    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool { space(); guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
        mutating func value(depth: Int = 0) throws -> JSONValue {
            space()
            guard index < bytes.count else { throw ScrubError.unsupported("invalid_json") }
            if bytes[index] == 123 || bytes[index] == 91 {
                guard depth < 64 else { throw ScrubError.unsupported("too_deep") }
            }
            switch bytes[index] {
            case 123:
                index += 1
                var pairs: [(String, JSONValue)] = []
                if take(125) { return .object(pairs) }
                while true {
                    guard index < bytes.count, bytes[index] == 34 else { throw ScrubError.unsupported("invalid_json") }
                    let key = try string()
                    guard take(58) else { throw ScrubError.unsupported("invalid_json") }
                    let child = try value(depth: depth + 1)
                    if let at = pairs.firstIndex(where: { $0.0 == key }) { pairs[at].1 = child }
                    else { pairs.append((key, child)) }
                    if take(125) { break }
                    guard take(44) else { throw ScrubError.unsupported("invalid_json") }
                    space()
                }
                return .object(pairs)
            case 91:
                index += 1
                var values: [JSONValue] = []
                if take(93) { return .array(values) }
                while true {
                    values.append(try value(depth: depth + 1))
                    if take(93) { break }
                    guard take(44) else { throw ScrubError.unsupported("invalid_json") }
                }
                return .array(values)
            case 34: return .string(try string())
            case 116: return try literal("true", .bool(true))
            case 102: return try literal("false", .bool(false))
            case 110: return try literal("null", .null)
            default: return try number()
            }
        }
        mutating func literal(_ value: String, _ result: JSONValue) throws -> JSONValue {
            let expected = Array(value.utf8)
            guard bytes[index...].starts(with: expected) else { throw ScrubError.unsupported("invalid_json") }
            index += expected.count
            return result
        }
        mutating func string() throws -> String {
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 && !escaped {
                    let data = Data(bytes[start..<index])
                    guard let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { throw ScrubError.unsupported("invalid_json") }
                    return decoded
                }
                if byte == 92 && !escaped { escaped = true } else { escaped = false }
            }
            throw ScrubError.unsupported("invalid_json")
        }
        mutating func number() throws -> JSONValue {
            let start = index
            while index < bytes.count && (bytes[index] == 45 || bytes[index] == 43 || bytes[index] == 46 || (48...57).contains(bytes[index]) || bytes[index] == 69 || bytes[index] == 101) { index += 1 }
            guard index > start else { throw ScrubError.unsupported("invalid_json") }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !TextRanges.matches(OrderedJSON.numberGrammar, in: raw).isEmpty else { throw ScrubError.unsupported("invalid_json") }
            return .number(raw)
        }
    }
}
