import Foundation

/// Key/value pairs inside text give their values the hints the same keys give in
/// a JSON file: a JSON body pasted in a curl command or a log line, object
/// literals in code (`given_name: 'Anna'` in JavaScript, Python's
/// `{'given_name': 'Anna'}`, Ruby's `"given_name" => "Anna"`) and YAML. Nesting is
/// followed, by brackets or by YAML's indentation, so `"id_number": {"value": …}`
/// is still read as an ID number, and array items take their array's key. A bare
/// "name" waits for its object to close, since a later sibling can say it is a
/// person's, and so does a form field's "value" until its "name" is known.
enum KeyedValues {
    private struct Level {
        let key: String?
        let isArray: Bool
        var id = 0
        /// The column of a YAML list item's dash; nil for brackets.
        var indent: Int? = nil
        var keys: [String] = []
        var names: [(Span, String)] = []
        var fields: [(String, String)] = []
        var unnamed: [(Range<Int>, String, String)] = []
        /// Values under a plain "id", which are a person's when the object holds their name or email.
        var ids: [Range<Int>] = []
        /// Bare numbers in an array, read when it closes: a point's order is only known then.
        var numbers: [Range<Int>] = []
    }
    struct Found {
        var spans: [Span] = []
        /// Values under keys that hold timestamps, IDs, codes and settings, and
        /// the keys themselves: none of them is read as a name or a date.
        var structural: [Range<Int>] = []
        /// The objects and lists the text nests, each with the one around it
        /// (0 stands for the text outside any), and every value read under a
        /// key with the one it sits in: what a JSON file's records tell.
        var parents: [Int?] = [nil]
        var fields: [(key: String, range: Range<Int>, level: Int)] = []
        func ancestry(_ level: Int) -> [Int] {
            var chain = [level]
            while let parent = parents[chain[0]] { chain.insert(parent, at: 0) }
            return chain
        }
    }
    private static let doubleQuote = UInt16(UInt8(ascii: "\"")), singleQuote = UInt16(UInt8(ascii: "'"))
    private static let backslash = UInt16(UInt8(ascii: "\\")), newline = UInt16(UInt8(ascii: "\n")), carriageReturn = UInt16(UInt8(ascii: "\r"))
    private static let colon = UInt16(UInt8(ascii: ":")), equals = UInt16(UInt8(ascii: "=")), greater = UInt16(UInt8(ascii: ">"))
    private static let openObject = UInt16(UInt8(ascii: "{")), closeObject = UInt16(UInt8(ascii: "}"))
    private static let openArray = UInt16(UInt8(ascii: "[")), closeArray = UInt16(UInt8(ascii: "]"))
    private static let comma = UInt16(UInt8(ascii: ",")), semicolon = UInt16(UInt8(ascii: ";")), hyphen = UInt16(UInt8(ascii: "-")), hash = UInt16(UInt8(ascii: "#"))
    private static let space = UInt16(32), tab = UInt16(9), slash = UInt16(UInt8(ascii: "/"))
    /// Unquoted words that are literals, not values.
    private static let literals: Set<String> = ["true", "false", "null", "none", "nil", "undefined", "yes", "no", "~"]

    private static func identifier(_ unit: UInt16, first: Bool) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 36 || !first && (48...57).contains(unit)
    }

    static func find(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        scan(text, isCancelled: isCancelled).spans
    }

    static func scan(_ text: String, isCancelled: () -> Bool = { false }) -> Found {
        guard text.utf16.contains(where: { $0 == doubleQuote || $0 == singleQuote || $0 == colon }) else { return Found() }
        let units = Array(text.utf16)
        var found = Found()
        // The root level stands for loose pairs outside any braces and is never closed.
        var levels = [Level(key: nil, isArray: false)]
        // YAML's nesting: the keys of open blocks, with the column each starts at.
        var blocks: [(indent: Int, key: String?)] = []
        func close(_ level: Level) {
            // A value wrapper's fields belong to the object around it.
            if level.id > 0, !level.isArray, KeyHints.isWrapper(level.keys), let parent = found.parents[level.id] {
                for index in found.fields.indices where found.fields[index].level == level.id { found.fields[index].level = parent }
            }
            if !level.numbers.isEmpty {
                let values = level.numbers.map { JSONValue.number(string($0)) }
                if let pair = JSONFile.coordinateKeys(level.key, values) {
                    for (range, key) in zip(level.numbers, pair) where KeyHints.fits(key, string(range)) {
                        found.spans.append(Span(range: range, entity: KeyHints.hint(key)!, score: 1))
                        found.fields.append((key, range, found.parents[level.id] ?? level.id))
                    }
                } else if let entity = KeyHints.hint(level.key) {
                    for range in level.numbers where KeyHints.fits(level.key, string(range)) && string(range).allSatisfy({ $0.isASCII && $0.isNumber }) {
                        found.spans.append(Span(range: range, entity: ["PHONE_NUMBER", "US_SSN", "POSTAL_CODE", "DATE_OF_BIRTH", "AGE", "LAST_DIGITS"].contains(entity) ? entity : "ID_NUMBER", score: 1))
                        if let key = level.key { found.fields.append((key, range, found.parents[level.id] ?? level.id)) }
                    }
                }
            }
            for (span, value) in level.names where KeyHints.bareNameIsPerson(value, siblings: level.keys, parent: level.key, inObject: level.id > 0) { found.spans.append(span) }
            // A person's own object: its "id" is theirs (see `RecordIDs`).
            let named = RecordIDs.isPersonCollection(KeyHints.words(level.key).last) || level.fields.contains(where: { RecordIDs.namesPersonType(key: $0.0, value: $0.1) })
            let beside = level.keys.contains(where: { ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS"].contains(KeyHints.hint($0) ?? "") })
            // At the top, outside any brackets (YAML, a log line), only with a few fields around.
            if !level.ids.isEmpty, named || beside, level.id > 0 || level.keys.count >= 3 {
                for range in level.ids where named || !RecordIDs.isUUID(string(range)) { found.spans.append(Span(range: range, entity: "RECORD_ID", score: 1)) }
            }
            // Outside brackets every key in the text is a "sibling"; a form field's name must share its object.
            for (range, key, value) in level.unnamed where level.id > 0 {
                if let field = KeyHints.namedField(key, siblings: level.fields), let entity = KeyHints.hint(field), KeyHints.fits(field, value) {
                    found.spans.append(Span(range: range, entity: entity, score: 1))
                }
            }
        }
        var pending: String?
        var point: (list: Int, count: Int)?
        var index = 0
        func skipSpace(_ from: Int) -> Int {
            var at = from
            while at < units.count, units[at] == space || units[at] == tab || units[at] == newline || units[at] == carriageReturn { at += 1 }
            return at
        }
        func string(_ range: Range<Int>) -> String { String(utf16CodeUnits: Array(units[range]), count: range.count) }
        func column(_ at: Int) -> Int {
            var start = at
            while start > 0, units[start - 1] != newline { start -= 1 }
            return at - start
        }
        func lineStart(_ at: Int) -> Bool {
            var before = at
            while before > 0, units[before - 1] == space || units[before - 1] == tab { before -= 1 }
            return before == 0 || units[before - 1] == newline
        }
        // Where a key's separator ends: ":" (not Ruby's "::") or "=>".
        func separator(after end: Int) -> Int? {
            let at = skipSpace(end)
            guard at < units.count else { return nil }
            if units[at] == colon {
                // Not Ruby's "::", nor a URL's "https://".
                if at + 1 < units.count, units[at + 1] == colon || units[at + 1] == slash && at + 2 < units.count && units[at + 2] == slash { return nil }
                return at + 1
            }
            if units[at] == equals, at + 1 < units.count, units[at + 1] == greater { return at + 2 }
            return nil
        }
        /// The key a new container or value is read under.
        func parentKey() -> String? {
            inYAML() ? blocks.last?.key : levels.last?.key
        }
        func inYAML() -> Bool { levels.count == 1 || levels[levels.count - 1].indent != nil }
        /// Ends YAML list items that a line at this column is outside of.
        func endItems(at indent: Int) {
            while let last = levels.last, let item = last.indent, item >= indent { close(levels.removeLast()) }
        }
        func take(_ content: Range<Int>, key explicit: String? = nil, unquoted: Bool = false) {
            let parent = parentKey()
            let own = pending
            let key: String? = explicit ?? own.map { KeyHints.resolve($0, parent: parent) } ?? (levels.last?.isArray == true ? parent : nil)
            let value = string(content)
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            pending = nil
            guard !trimmed.isEmpty else { return }
            if let own, trimmed.utf16.count <= 80 { levels[levels.count - 1].fields.append((own, trimmed)) }
            if let own, ["id", "uid"].contains(KeyHints.words(own).joined()), RecordIDs.plainID(trimmed) { levels[levels.count - 1].ids.append(content) }
            if let key { found.fields.append((key, content, levels[levels.count - 1].id)) }
            if KeyHints.hint(key) == nil, KeyHints.isStructural(key) {
                found.structural.append(content)
                // A time zone moves with the address beside it, if there is one.
                let words = KeyHints.words(key)
                if words.last == "timezone" || words.last == "tz" || words.suffix(2) == ["time", "zone"], trimmed.contains("/"), TimeZone(identifier: trimmed) != nil {
                    found.spans.append(Span(range: content, entity: "TIME_ZONE", score: 1))
                }
            }
            // Escapes other than an escaped quote ("O\'Sullivan") would shift offsets, so those values are left to detection.
            if units[content].contains(backslash) {
                for at in content where units[at] == backslash && !(at + 1 < content.upperBound && (units[at + 1] == doubleQuote || units[at + 1] == singleQuote)) { return }
            }
            if unquoted, !plausible(trimmed, key: key) { return }
            var content = content
            // An unquoted secret is one token, after its scheme: "Authorization: Bearer 9f8e… rejected".
            if unquoted, KeyHints.hint(key) == "SECRET" {
                var tokens: [Range<Int>] = []
                var at = content.lowerBound
                while at < content.upperBound, tokens.count < 2 {
                    while at < content.upperBound, units[at] == space || units[at] == tab { at += 1 }
                    let start = at
                    while at < content.upperBound, units[at] != space, units[at] != tab { at += 1 }
                    if at > start { tokens.append(start..<at) }
                }
                guard let first = tokens.first else { return }
                let scheme = ["bearer", "basic", "token", "digest", "apikey"].contains(string(first).lowercased())
                content = scheme && tokens.count > 1 ? tokens[1] : first
            }
            let taken = string(content)
            if var entity = KeyHints.hint(key), KeyHints.fits(key, taken) {
                // A bare number keeps a bare number's stand-in, or the code around it breaks.
                if unquoted, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), !["PHONE_NUMBER", "US_SSN", "ID_NUMBER", "POSTAL_CODE", "DATE_OF_BIRTH", "SECRET", "AGE", "LAST_DIGITS"].contains(entity) { entity = "ID_NUMBER" }
                let span = Span(range: content, entity: entity, score: 1)
                if KeyHints.isBareName(own) { levels[levels.count - 1].names.append((span, taken)) }
                else { found.spans.append(span) }
            } else if let own, KeyHints.fieldValueKeys.contains(KeyHints.words(own).joined()) {
                levels[levels.count - 1].unnamed.append((content, own, taken))
            } else if KeyHints.hint(key) == nil, RecordIDs.identifying(key: key, value: taken) {
                // "customer_id": "cus_4TUvJh" in a pasted body: the person's ID, as in a file.
                found.spans.append(Span(range: content, entity: "RECORD_ID", score: 1))
            } else if KeyHints.isRole(key), let name = Detector.writtenName(taken) {
                // "Customer: Priyanka Szymanski", "assignee": "Dana Whitfield": a name written as one.
                found.spans.append(Span(range: (content.lowerBound + name.lowerBound)..<(content.lowerBound + name.upperBound), entity: "PERSON", score: 0.9))
            }
        }
        /// An unquoted value reads as data, not as code (`email: user.email`,
        /// `firstName: string;`) or a literal.
        func plausible(_ value: String, key: String?) -> Bool {
            if literals.contains(value.lowercased()) || value.contains(where: { "(\"'\\`".contains($0) }) || value.hasSuffix(";") { return false }
            guard let entity = KeyHints.hint(key), ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION"].contains(entity) else { return true }
            // A name is capitalised; one token with dots, underscores or a dollar sign is an identifier.
            guard value.first?.isUppercase == true else { return false }
            return value.contains(" ") || !value.contains(where: { $0 == "." || $0 == "_" || $0 == "$" })
        }
        /// The unquoted value after a key, up to the end of the line (or, inside
        /// brackets, a comma or closing bracket), without a YAML comment.
        func scalar(from start: Int) -> (Range<Int>, Int)? {
            var at = start
            while at < units.count, units[at] == space || units[at] == tab { at += 1 }
            guard at < units.count else { return nil }
            let first = units[at]
            if [newline, carriageReturn, doubleQuote, singleQuote, openObject, openArray, UInt16(UInt8(ascii: "|")), greater, UInt16(UInt8(ascii: "&")), UInt16(UInt8(ascii: "*")), UInt16(UInt8(ascii: "!")), hash].contains(first) { return nil }
            let inside = !inYAML()
            var end = at
            // Outside brackets a comma ends the value only before another quoted key, as in a pasted fragment.
            func continues(_ at: Int) -> Bool {
                var next = at + 1
                while next < units.count, units[next] == space || units[next] == tab { next += 1 }
                return next < units.count && (units[next] == doubleQuote || units[next] == singleQuote)
            }
            // It stops before a quote or bracket, which the scan still has to read.
            while end < units.count, units[end] != newline, units[end] != carriageReturn,
                  ![doubleQuote, singleQuote, openObject, openArray].contains(units[end]),
                  !(inside && (units[end] == comma || units[end] == closeObject || units[end] == closeArray)),
                  !(!inside && units[end] == comma && continues(end)),
                  !(units[end] == hash && end > at && (units[end - 1] == space || units[end - 1] == tab)) { end += 1 }
            // A word run into a quote is a string's prefix or tag (Python's f"…", r'…', JavaScript's sql`…`), not a value.
            if end < units.count, [doubleQuote, singleQuote, UInt16(UInt8(ascii: "`"))].contains(units[end]), end > at, units[end - 1] != space, units[end - 1] != tab { return nil }
            var stop = end
            while stop > at, [space, tab, comma].contains(units[stop - 1]) { stop -= 1 }
            return stop > at ? (at..<stop, end) : nil
        }
        func startsKey(_ key: String, at start: Int, resumingAt next: Int, colon isColon: Bool) {
            if inYAML(), lineStart(start) || isYAMLItem(start) {
                let indent = column(start)
                if lineStart(start) { endItems(at: indent) }
                while let last = blocks.last, last.indent >= indent { blocks.removeLast() }
            }
            levels[levels.count - 1].keys.append(key)
            pending = key
            index = next
            guard isColon else { return }
            if let (content, end) = scalar(from: next) {
                take(content, unquoted: true)
                index = end
            } else if inYAML() {
                // A key alone on its line opens a YAML block.
                var at = next
                while at < units.count, units[at] == space || units[at] == tab { at += 1 }
                if at >= units.count || units[at] == newline || units[at] == carriageReturn {
                    blocks.append((column(start), KeyHints.resolve(key, parent: blocks.last?.key)))
                }
            }
        }
        func isYAMLItem(_ start: Int) -> Bool {
            var before = start
            while before > 0, units[before - 1] == space || units[before - 1] == tab { before -= 1 }
            return before > 0 && units[before - 1] == hyphen && lineStart(before - 1)
        }
        while index < units.count {
            if index.isMultiple(of: 65_536) && isCancelled() { return found }
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
                // A body quoted whole for the shell (`-d '{"email": …}'`) is read inside.
                let inner = skipSpace(content.lowerBound)
                if inner < end, units[inner] == openObject || units[inner] == openArray, pending == nil, unit == singleQuote || !units[content].contains(backslash) {
                    index += 1
                    continue
                }
                if let next = separator(after: end + 1) {
                    found.structural.append(content)
                    startsKey(string(content), at: index, resumingAt: next, colon: units[skipSpace(end + 1)] == colon)
                    continue
                }
                take(content)
                index = end + 1
                continue
            }
            switch unit {
            case openObject, openArray:
                let parent = parentKey()
                let key = pending.map { KeyHints.resolve($0, parent: parent) } ?? (levels.last?.isArray == true ? parent : nil)
                found.parents.append(levels.last?.id)
                levels.append(Level(key: key, isArray: unit == openArray, id: found.parents.count - 1))
                pending = nil
                index += 1
            case closeObject, closeArray:
                if levels.count > 1, levels[levels.count - 1].indent == nil, levels[levels.count - 1].isArray == (unit == closeArray) { close(levels.removeLast()) }
                pending = nil
                index += 1
            case space, tab, newline, carriageReturn:
                index += 1
            case hyphen where inYAML() && lineStart(index) && index + 1 < units.count && units[index + 1] == space:
                // A YAML list item: a record whose keys follow, or a value of its list.
                let indent = column(index)
                endItems(at: indent)
                while let last = blocks.last, last.indent > indent { blocks.removeLast() }
                let after = index + 2
                var wordEnd = after
                while wordEnd < units.count, identifier(units[wordEnd], first: wordEnd == after) { wordEnd += 1 }
                if wordEnd > after, separator(after: wordEnd) != nil {
                    found.parents.append(levels.last?.id)
                    levels.append(Level(key: blocks.last?.key, isArray: false, id: found.parents.count - 1, indent: indent))
                    index = after
                    continue
                }
                if let (content, end) = scalar(from: after), let list = blocks.last, list.indent <= indent {
                    pending = nil
                    // A point as a YAML list: "coordinates:\n  - -122.4443\n  - 47.2529".
                    var key = list.key
                    if KeyHints.hint(list.key) == "COORDINATES", let value = Double(string(content)) {
                        if point?.list != list.indent { point = (list.indent, 0) }
                        let position = point!.count
                        point!.count += 1
                        let latitudeFirst = KeyHints.words(list.key).joined().hasPrefix("lat")
                        key = abs(value) > 90 ? "longitude" : ((position == 0) == latitudeFirst ? "latitude" : "longitude")
                    }
                    take(content, key: key, unquoted: true)
                    index = end
                } else {
                    index = after
                }
            case _ where levels.count > 1 && levels[levels.count - 1].isArray && levels[levels.count - 1].indent == nil && ((48...57).contains(unit) || unit == hyphen && index + 1 < units.count && (48...57).contains(units[index + 1])):
                // A bare number in a list: `"coordinates": [-122.4443, 47.2529]`, `"phones": [2067349021]`.
                var end = index + 1
                while end < units.count, (48...57).contains(units[end]) || [UInt16(UInt8(ascii: ".")), UInt16(UInt8(ascii: "e")), UInt16(UInt8(ascii: "E")), hyphen, UInt16(UInt8(ascii: "+"))].contains(units[end]) { end += 1 }
                levels[levels.count - 1].numbers.append(index..<end)
                pending = nil
                index = end
            default:
                // A bare word followed by a separator is a key, as in `given_name: 'Anna'`.
                if identifier(unit, first: true), index == 0 || !identifier(units[index - 1], first: false) {
                    var end = index + 1
                    while end < units.count, identifier(units[end], first: false) || units[end] == hyphen && end + 1 < units.count && identifier(units[end + 1], first: false) { end += 1 }
                    if let next = separator(after: end) {
                        // A capitalised word before a colon in prose may be a name ("Ticket from Daniel Ferreira: …").
                        if !inYAML() || !(65...90).contains(unit) { found.structural.append(index..<end) }
                        startsKey(string(index..<end), at: index, resumingAt: next, colon: units[skipSpace(end)] == colon)
                        continue
                    }
                    index = end
                } else {
                    index += 1
                }
                pending = nil
            }
        }
        levels.reversed().forEach(close)
        found.spans.sort { $0.range.lowerBound < $1.range.lowerBound }
        return found
    }
}
