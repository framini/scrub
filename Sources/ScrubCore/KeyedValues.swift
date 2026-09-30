import Foundation

/// Key/value pairs inside text give their values the hints the same keys give in
/// a JSON file: a JSON body pasted in a curl command or a log line, and object
/// literals in code (`given_name: 'Anna'` in JavaScript, Python's
/// `{'given_name': 'Anna'}`, Ruby's `"given_name" => "Anna"`). Nesting is
/// followed so `"id_number": {"value": …}` is still read as an ID number, and
/// array items take their array's key. A bare "name" waits for its object to
/// close, since a later sibling can say it is a person's.
enum KeyedValues {
    private struct Level {
        let key: String?
        let isArray: Bool
        var keys: [String] = []
        var names: [(Span, String)] = []
    }
    private static let doubleQuote = UInt16(UInt8(ascii: "\"")), singleQuote = UInt16(UInt8(ascii: "'"))
    private static let backslash = UInt16(UInt8(ascii: "\\")), newline = UInt16(UInt8(ascii: "\n"))
    private static let colon = UInt16(UInt8(ascii: ":")), equals = UInt16(UInt8(ascii: "=")), greater = UInt16(UInt8(ascii: ">"))
    private static let openObject = UInt16(UInt8(ascii: "{")), closeObject = UInt16(UInt8(ascii: "}"))
    private static let openArray = UInt16(UInt8(ascii: "[")), closeArray = UInt16(UInt8(ascii: "]"))

    private static func identifier(_ unit: UInt16, first: Bool) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 36 || !first && (48...57).contains(unit)
    }

    static func find(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        guard text.utf16.contains(where: { $0 == doubleQuote || $0 == singleQuote }) else { return [] }
        let units = Array(text.utf16)
        var spans: [Span] = []
        // The root level stands for loose pairs outside any braces and is never closed.
        var levels = [Level(key: nil, isArray: false)]
        func close(_ level: Level) {
            for (span, value) in level.names where KeyHints.bareNameIsPerson(value, siblings: level.keys, parent: level.key) { spans.append(span) }
        }
        var pending: String?
        var index = 0
        func skipSpace(_ from: Int) -> Int {
            var at = from
            while at < units.count, units[at] == 32 || units[at] == 9 || units[at] == 10 || units[at] == 13 { at += 1 }
            return at
        }
        func string(_ range: Range<Int>) -> String { String(utf16CodeUnits: Array(units[range]), count: range.count) }
        // Where a key's separator ends: ":" (not Ruby's "::") or "=>".
        func separator(after end: Int) -> Int? {
            let at = skipSpace(end)
            guard at < units.count else { return nil }
            if units[at] == colon { return at + 1 < units.count && units[at + 1] == colon ? nil : at + 1 }
            if units[at] == equals, at + 1 < units.count, units[at + 1] == greater { return at + 2 }
            return nil
        }
        func startsKey(_ key: String, resumingAt next: Int) {
            levels[levels.count - 1].keys.append(key)
            pending = key
            index = next
        }
        while index < units.count {
            if index.isMultiple(of: 65_536) && isCancelled() { return spans }
            let unit = units[index]
            // An apostrophe inside a word ("it's") opens no string.
            let opensString = unit == doubleQuote || unit == singleQuote && (index == 0 || !identifier(units[index - 1], first: false))
            if opensString {
                // A string ends at the next unescaped matching quote on the same
                // line; a quote without one is prose, not a string.
                var end = index + 1
                var escaped = false
                while end < units.count, units[end] != newline, units[end] != unit || escaped {
                    escaped = !escaped && units[end] == backslash
                    end += 1
                }
                guard end < units.count, units[end] == unit else { pending = nil; index += 1; continue }
                let content = index + 1..<end
                if let next = separator(after: end + 1) { startsKey(string(content), resumingAt: next); continue }
                let parent = levels.last?.key
                let key = pending ?? (levels.last?.isArray == true ? parent : nil)
                let effective = pending != nil && KeyHints.inherits(pending, from: parent) ? parent : key
                // Escaped values would shift offsets on replacement, so they are left to detection.
                let value = string(content)
                if let entity = KeyHints.hint(effective), KeyHints.fits(effective, value), !units[content].contains(backslash),
                   !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    let span = Span(range: content, entity: entity, score: 1)
                    if pending != nil && KeyHints.isBareName(effective) { levels[levels.count - 1].names.append((span, value)) }
                    else { spans.append(span) }
                }
                pending = nil
                index = end + 1
                continue
            }
            switch unit {
            case openObject, openArray:
                let parent = levels.last
                let key = pending.map { KeyHints.inherits($0, from: parent?.key) ? parent?.key : $0 } ?? (parent?.isArray == true ? parent?.key : nil)
                levels.append(Level(key: key, isArray: unit == openArray))
                pending = nil
                index += 1
            case closeObject, closeArray:
                if levels.count > 1, levels[levels.count - 1].isArray == (unit == closeArray) { close(levels.removeLast()) }
                pending = nil
                index += 1
            case 32, 9, 10, 13:
                index += 1
            default:
                // A bare word followed by a separator is a key, as in `given_name: 'Anna'`.
                if identifier(unit, first: true), index == 0 || !identifier(units[index - 1], first: false) {
                    var end = index + 1
                    while end < units.count, identifier(units[end], first: false) { end += 1 }
                    if let next = separator(after: end) { startsKey(string(index..<end), resumingAt: next); continue }
                    index = end
                } else {
                    index += 1
                }
                pending = nil
            }
        }
        levels.reversed().forEach(close)
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
