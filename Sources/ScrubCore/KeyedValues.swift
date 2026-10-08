import Foundation

/// Key/value pairs inside text give their values the hints the same keys give in
/// a JSON file: a JSON body pasted in a curl command or a log line, object
/// literals in code (`given_name: 'Anna'` in JavaScript, Python's
/// `{'given_name': 'Anna'}`, Ruby's `"given_name" => "Anna"`), YAML and a
/// line's `given_name=Anna` in a properties, .env or INI file. Nesting is
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
        /// Values whose key names a date's part with nothing to say whose date: a birth's, once the record's kind or a name beside them says so.
        var dated: [(Range<Int>, String, String)] = []
        /// Values under an expiry's key, a card's or a document's once the record around them says so (see `KeyHints.expiry`).
        var expiring: [(Range<Int>, String, String)] = []
        /// Values under a plain "id", which are a person's when the object holds their name or email.
        var ids: [Range<Int>] = []
        /// Bare numbers in an array, read when it closes: a point's order is only known then.
        var numbers: [Range<Int>] = []
        /// Province codes no region table knows ("NA"), read when the object closes: one beside a city or postcode is that address's.
        var codes: [Range<Int>] = []
    }
    struct Found {
        var spans: [Span] = []
        /// Values under keys that hold timestamps, IDs, codes and settings, and
        /// the keys themselves: none of them is read as a name or a date.
        var structural: [Range<Int>] = []
        /// The keys alone, inside their quotes.
        var keys: [Range<Int>] = []
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
    /// What a string's prefix is written with before its quote (`r'…'`, `f'…'`, `rb'…'`).
    private static let stringPrefixes: Set<String> = ["r", "f", "b", "u", "rb", "br", "fr", "rf"]
    /// A letter beside an apostrophe inside a word: ASCII, or past Latin-1's signs, but no curly quote.
    private static func letter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) || unit >= 0xC0 && unit != 0x2019 }
    /// Unquoted words that are literals, not values.
    private static let literals: Set<String> = ["true", "false", "null", "none", "nil", "undefined", "yes", "no", "~"]

    private static func identifier(_ unit: UInt16, first: Bool) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 36 || !first && (48...57).contains(unit)
    }

    /// Spans less a part of a pasted object's key: "ledgerlyFees" stays the field's
    /// name, though "Ledgerly" was read as someone, or the object it names breaks.
    /// A span that is the whole key (a key that is a person's name) stays, but not
    /// one that names a field ("password" beside a password that is the same word).
    /// A key that holds data ("rosalind@example.org_token", "4417_pin") is read as any value.
    static func outsideKeys(_ spans: [Span], in text: String) -> [Span] {
        guard !spans.isEmpty, text.contains(":") || text.contains("=") else { return spans }
        let keys = scan(text).keys
        guard !keys.isEmpty else { return spans }
        return spans.filter { span in
            !keys.contains { key in
                let name = TextRanges.substring(text, key)
                return key.overlaps(span.range) && !KeyHints.holdsData(name) && (key != span.range || KeyHints.hint(name) != nil)
            }
        }
    }

    /// A record's dates that are a birth's, by its kind or a person's name beside them (see `KeyHints.birthField`).
    /// `around`: the object holding this one, whose fields say whose an expiry in parts is ("card": {"last4": …, "expiration": {"month": …}}).
    private static func births(_ level: Level, around: Level?) -> [Span] {
        guard !level.dated.isEmpty || !level.expiring.isEmpty else { return [] }
        let kind = Set(level.fields.filter { ["type", "kind", "object"].contains(KeyHints.words($0.0).joined()) }.flatMap { KeyHints.words($0.1) })
        let born: [Span] = level.dated.compactMap { range, key, value in
            guard let born = KeyHints.birthField(key, value: value, siblings: level.fields, kind: kind), KeyHints.fits(born, value) else { return nil }
            return Span(range: range, entity: "DATE_OF_BIRTH", score: 1)
        }
        let expiring: [Span] = level.expiring.compactMap { range, key, value in
            guard let expiry = KeyHints.expiry(key, siblings: level.keys, parent: level.key, kind: kind), KeyHints.fits(expiry, value) else { return nil }
            return Span(range: range, entity: "EXPIRY_DATE", score: 1)
        }
        // An expiry written in parts: its object's own key names it, the object around it says it is a card's.
        var parts: [Span] = []
        if let key = level.key, KeyHints.isExpiryKey(key), let around, KeyHints.expiry(key, siblings: around.keys, parent: around.key, kind: []) != nil {
            for (range, part, value) in level.dated where ["month", "year", "day", "mm", "yy", "yyyy", "dd"].contains(KeyHints.words(part).joined()) && value.contains(where: \.isNumber) {
                parts.append(Span(range: range, entity: "EXPIRY_DATE", score: 1))
            }
        }
        return born + expiring + parts
    }
    /// Whether a key holds a cookie header's pairs, not one cookie's value ("session_cookie").
    static func cookieKey(_ key: String?) -> Bool {
        ["cookie", "cookies", "setcookie", "cookieheader"].contains(KeyHints.words(key).joined())
    }
    /// What a set cookie says of itself, never a value to replace: "Path=/; Secure; SameSite=Lax".
    private static let cookieAttributes: Set<String> = ["path", "domain", "expires", "maxage", "samesite", "secure", "httponly", "priority", "partitioned", "version", "comment"]
    /// Parts of a cookie's name that say it holds a session or a credential, whatever its value looks like.
    private static let sessionParts = ["sess", "sid", "token", "auth", "jwt", "csrf", "xsrf", "remember", "login", "secret", "key", "saml", "oauth"]
    /// The values in a cookie header ("session=7f6e…; uid=u_55120; theme=dark") that are a secret or
    /// someone's: a session's or a credential's, a person's ID or what its name says it is, or any
    /// long generated token. Names, separators, settings ("theme=dark") and a set cookie's attributes
    /// stay. Nil when the text is not written as pairs, so it is read whole.
    static func cookies(_ text: String) -> [Span]? {
        let ns = text as NSString
        var spans: [Span] = [], pairs = 0, start = 0
        for end in 0...ns.length where end == ns.length || ns.character(at: end) == semicolon {
            defer { start = end + 1 }
            let piece = NSRange(location: start, length: end - start)
            let equal = ns.range(of: "=", range: piece)
            guard equal.location != NSNotFound else {
                // A flag ("Secure", "HttpOnly"), or nothing after a last separator.
                let word = ns.substring(with: piece).trimmingCharacters(in: .whitespaces)
                if word.isEmpty || cookieAttributes.contains(word.lowercased()) { continue }
                return nil
            }
            let name = ns.substring(with: NSRange(location: start, length: equal.location - start)).trimmingCharacters(in: .whitespaces)
            var lower = NSMaxRange(equal), upper = end
            while lower < upper, [space, tab, doubleQuote].contains(ns.character(at: lower)) { lower += 1 }
            while upper > lower, [space, tab, doubleQuote].contains(ns.character(at: upper - 1)) { upper -= 1 }
            // A name is one token, and a value never opens with "=": "dGVzdA==" is a bare value, not a pair.
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && !"\"(),/:<>?@[]{}".unicodeScalars.contains($0) }),
                  lower == upper || ns.character(at: lower) != equals else { return nil }
            pairs += 1
            guard lower < upper else { continue }
            let value = ns.substring(with: NSRange(location: lower, length: upper - lower))
            let compact = name.lowercased().filter { $0.isLetter || $0.isNumber }
            let entity: String?
            if cookieAttributes.contains(compact) { entity = nil }
            else if RecordIDs.identifying(key: name, value: value) { entity = "RECORD_ID" }
            else if let hint = KeyHints.hint(name), hint != "SECRET", KeyHints.fits(name, value) { entity = hint }
            else if value.count >= 4, sessionParts.contains(where: compact.contains) { entity = "SECRET" }
            else { entity = generatedToken(value) ? "SECRET" : nil }
            if let entity { spans.append(Span(range: lower..<upper, entity: entity, score: 1)) }
        }
        return pairs > 0 ? spans : nil
    }
    /// A value a system made rather than a word or a setting: twelve characters or more of a token's
    /// alphabet, with a digit ("GA1.2.1144832913.1696338125", "7f6e5d4c3b2a1908").
    private static func generatedToken(_ value: String) -> Bool {
        value.count >= 12 && value.contains(where: \.isNumber) && value.contains(where: { $0.isLetter }) || value.count >= 16 && value.allSatisfy(\.isNumber)
            ? value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.+/=%~".contains($0)) }) : false
    }
    /// The length of the birth date, or the list of them, that opens an unquoted value going on to
    /// something else ("2004-08-23, Ticket: 05252042103", "2015-06-17 and 1926-08-09 will be kept"),
    /// or nil when the value is all date. What comes before the first word no date is written with
    /// must hold a whole date, with its four-digit year: "12 März 1984" is left whole.
    static func birthDateLength(_ value: String) -> Int? {
        let ns = value as NSString
        var end = 0, cut: Int?
        for word in TextRanges.matches(wordPattern, in: value) {
            let bare = ns.substring(with: word.range).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;*"))
            let dated = bare.isEmpty || bare.allSatisfy({ $0.isNumber || "-/.:+,tz".contains($0) }) && bare.contains(where: \.isNumber)
                || NameShape.months.contains(bare) || ["and", "or", "&", "of", "am", "pm", "utc", "gmt"].contains(bare)
                || bare.range(of: #"^\d{1,2}(?:st|nd|rd|th)$"#, options: .regularExpression) != nil
            if !dated { cut = end; break }
            end = NSMaxRange(word.range)
        }
        guard let cut, cut > 0 else { return nil }
        var length = cut
        while length > 0, " \t,.;*".utf16.contains(ns.character(at: length - 1)) { length -= 1 }
        let date = ns.substring(to: length)
        guard date.range(of: #"(?<!\d)\d{4}(?!\d)"#, options: .regularExpression) != nil,
              date.range(of: #"\d+\D+\d+\D+\d+|\p{L}"#, options: .regularExpression) != nil else { return nil }
        return length
    }
    private static let wordPattern = TextPattern(#"\S+"#)
    static func find(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        scan(text, isCancelled: isCancelled).spans
    }

    static func scan(_ text: String, isCancelled: () -> Bool = { false }) -> Found {
        guard text.utf16.contains(where: { $0 == doubleQuote || $0 == singleQuote || $0 == colon || $0 == equals }) else { return Found() }
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
            if !level.codes.isEmpty, level.id > 0, level.keys.contains(where: { ["LOCATION", "POSTAL_CODE"].contains(KeyHints.hint($0) ?? "") }) {
                for range in level.codes { found.spans.append(Span(range: range, entity: "REGION", score: 1)) }
            }
            for (span, value) in level.names where KeyHints.bareNameIsPerson(value, siblings: level.keys, parent: level.key, inObject: level.id > 0) { found.spans.append(span) }
            // A name's parts under keys of their own ({"surname": …, "given": …}), or the name written another way ("pinyin"), as in a file.
            if level.id > 0, case let parts = KeyHints.nameParts(level.fields, parent: level.key), !parts.isEmpty {
                for field in found.fields where field.level == level.id {
                    if let part = parts[field.key], let entity = KeyHints.hint(part) { found.spans.append(Span(range: field.range, entity: entity, score: 1)) }
                }
            }
            // A person's own object: its "id" is theirs (see `RecordIDs`).
            let named = RecordIDs.isPersonCollection(KeyHints.words(level.key).last) || level.fields.contains(where: { RecordIDs.namesPersonType(key: $0.0, value: $0.1) })
            let beside = level.keys.contains(where: { ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS"].contains(KeyHints.hint($0) ?? "") })
            // At the top, outside any brackets (YAML, a log line), only with a few fields around.
            if !level.ids.isEmpty, named || beside, level.id > 0 || level.keys.count >= 3 {
                for range in level.ids where named || !RecordIDs.isUUID(string(range)) { found.spans.append(Span(range: range, entity: "RECORD_ID", score: 1)) }
            }
            // A record about a birth ({type: BIRTH, year: 1976}) or a person's search ({name: …, year: 1952}).
            if level.id > 0 { found.spans += births(level, around: levels.last) }
            // Outside brackets every key in the text is a "sibling"; a form field's name must share its object.
            for (range, key, value) in level.unnamed where level.id > 0 {
                if let field = KeyHints.namedField(key, siblings: level.fields), let entity = KeyHints.hint(field), KeyHints.fits(field, value) {
                    found.spans.append(Span(range: range, entity: entity, score: 1))
                }
            }
        }
        var pending: String?
        var nested: [Range<Int>] = []
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
        /// Where a line's "key=value" assignment starts its value, as in a
        /// properties, .env or INI file (`full_name=Odalys Ferriter`); only for
        /// a key that starts its line outside brackets, never "==".
        func assignment(after end: Int, start: Int) -> Int? {
            var at = end
            while at < units.count, units[at] == space || units[at] == tab { at += 1 }
            guard at < units.count, units[at] == equals, inYAML(), lineStart(start) else { return nil }
            if at + 1 < units.count, units[at + 1] == equals || units[at + 1] == greater { return nil }
            return at + 1
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
            let listed = levels.count >= 2 && !levels[levels.count - 1].isArray && levels[levels.count - 2].isArray
            let value = string(content)
            let key: String? = explicit ?? own.map { KeyHints.resolve($0, parent: parent, listed: listed, value: value) } ?? (levels.last?.isArray == true ? parent : nil)
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            pending = nil
            guard !trimmed.isEmpty else { return }
            if let own, trimmed.utf16.count <= 80 { levels[levels.count - 1].fields.append((own, trimmed)) }
            if let own, ["id", "uid"].contains(KeyHints.words(own).joined()), RecordIDs.plainID(trimmed) || RecordIDs.personTyped(trimmed) { levels[levels.count - 1].ids.append(content) }
            if let key { found.fields.append((key, content, levels[levels.count - 1].id)) }
            if KeyHints.hint(key) == nil, KeyHints.isStructural(key) {
                found.structural.append(content)
                // A time zone moves with the address beside it, if there is one.
                let words = KeyHints.words(key)
                if words.last == "timezone" || words.last == "tz" || words.suffix(2) == ["time", "zone"], trimmed.contains("/"), TimeZone(identifier: trimmed) != nil {
                    found.spans.append(Span(range: content, entity: "TIME_ZONE", score: 1))
                }
            }
            // A value with escapes other than an escaped quote ("O\'Sullivan") is read decoded
            // ("Ren\u00e9") and replaced whole: a part of it would shift offsets.
            var decoded: String?
            if units[content].contains(backslash),
               content.contains(where: { units[$0] == backslash && !($0 + 1 < content.upperBound && (units[$0 + 1] == doubleQuote || units[$0 + 1] == singleQuote)) }) {
                guard !unquoted, case .string(let text)? = try? OrderedJSON.parse("\"" + value + "\""), !text.isEmpty else { return }
                decoded = text.trimmingCharacters(in: .whitespaces)
            }
            if unquoted, !plausible(trimmed, key: key) { return }
            // A number written with an exponent (1.2e2), or a point anywhere but a coordinate, would lose its grammar to a stand-in written as text.
            if unquoted, !trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), trimmed.first.map({ $0.isNumber || $0 == "-" }) == true,
               case .number? = try? OrderedJSON.parse(trimmed),
               trimmed.lowercased().contains("e") || !["LATITUDE", "LONGITUDE", "COORDINATES"].contains(KeyHints.hint(key) ?? "") { return }
            // A cookie header's pairs ("Cookie: session=7f6e…; theme=dark"): each value read by its own name.
            if decoded == nil, cookieKey(own ?? key), let pairs = cookies(string(content)) {
                found.spans += pairs.map { Span(range: (content.lowerBound + $0.range.lowerBound)..<(content.lowerBound + $0.range.upperBound), entity: $0.entity, score: 1) }
                return
            }
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
            // A birth date written inline ends where the line goes on to another field or a sentence ("DOB: 2004-08-23, Ticket: …").
            if unquoted, decoded == nil, KeyHints.hint(key) == "DATE_OF_BIRTH", let length = birthDateLength(string(content)) {
                content = content.lowerBound..<(content.lowerBound + length)
            }
            let taken = decoded ?? string(content)
            if var entity = KeyHints.hint(key), KeyHints.fits(key, taken) {
                // A bare number keeps a bare number's stand-in, or the code around it breaks.
                if unquoted, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), !["PHONE_NUMBER", "US_SSN", "ID_NUMBER", "POSTAL_CODE", "DATE_OF_BIRTH", "SECRET", "AGE", "LAST_DIGITS", "ADDRESS"].contains(entity) { entity = "ID_NUMBER" }
                let span = Span(range: content, entity: entity, score: 1)
                if KeyHints.isBareName(own) { levels[levels.count - 1].names.append((span, taken)) }
                else { found.spans.append(span) }
            } else if decoded != nil {
                return
            } else if KeyHints.regionCode(key, taken) {
                levels[levels.count - 1].codes.append(content)
            } else if let own, KeyHints.fieldValueKeys.contains(KeyHints.words(own).joined()) {
                levels[levels.count - 1].unnamed.append((content, own, taken))
                if KeyHints.hint(key) == nil { levels[levels.count - 1].dated.append((content, own, taken)) }
            } else if let own, KeyHints.hint(key) == nil, KeyHints.isExpiryKey(own) {
                levels[levels.count - 1].expiring.append((content, own, taken))
            } else if let own, KeyHints.hint(key) == nil, KeyHints.mayBeBirthPart(own) {
                levels[levels.count - 1].dated.append((content, own, taken))
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
            // An apostrophe inside a word ("O'Sullivan") is no quote.
            let quoted = value.replacingOccurrences(of: #"(?<=\p{L})'(?=\p{L})"#, with: "", options: .regularExpression)
            if literals.contains(value.lowercased()) || quoted.contains(where: { "(\"'\\`".contains($0) }) || value.hasSuffix(";") { return false }
            guard let entity = KeyHints.hint(key), ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION"].contains(entity) else { return true }
            // A name is capitalised; one token with dots, underscores or a dollar sign is an identifier.
            guard value.first.map({ $0.isUppercase || !$0.isCased }) == true else { return false }
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
            // An apostrophe inside a word ("O'Sullivan") is part of the value, not a quote:
            // a letter on each side, after no string prefix (Python's r'…', f'…').
            func apostrophe(_ quote: Int) -> Bool {
                guard units[quote] == singleQuote, quote > at, quote + 1 < units.count, letter(units[quote - 1]), letter(units[quote + 1]) else { return false }
                var word = quote
                while word > at, letter(units[word - 1]) { word -= 1 }
                return !stringPrefixes.contains(string(word..<quote).lowercased())
            }
            // It stops before a quote or bracket, which the scan still has to read.
            while end < units.count, units[end] != newline, units[end] != carriageReturn,
                  ![doubleQuote, singleQuote, openObject, openArray].contains(units[end]) || apostrophe(end),
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
                    found.keys.append(content)
                    startsKey(string(content), at: index, resumingAt: next, colon: units[skipSpace(end + 1)] == colon)
                    continue
                }
                // A body sent as a string ("body": "{\"password\": …}") is read inside, after its quotes.
                if inner < end, units[inner] == openObject || units[inner] == openArray, units[content].contains(backslash) { nested.append(content) }
                take(content)
                index = end + 1
                continue
            }
            switch unit {
            case openObject, openArray:
                let parent = parentKey()
                let listed = levels.count >= 2 && !levels[levels.count - 1].isArray && levels[levels.count - 2].isArray
                let key = pending.map { KeyHints.resolveContainer($0, parent: parent, listed: listed) } ?? (levels.last?.isArray == true ? parent : nil)
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
                        if !inYAML() || !(65...90).contains(unit) { found.structural.append(index..<end); found.keys.append(index..<end) }
                        startsKey(string(index..<end), at: index, resumingAt: next, colon: units[skipSpace(end)] == colon)
                        continue
                    }
                    if let next = assignment(after: end, start: index) {
                        found.structural.append(index..<end)
                        startsKey(string(index..<end), at: index, resumingAt: next, colon: true)
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
        // Each escaped quote becomes a space and a quote, so the body keeps its length and every offset.
        for range in nested {
            var body = Array(units[range])
            var at = 0
            while at + 1 < body.count {
                if body[at] == backslash, body[at + 1] == doubleQuote { body[at] = space }
                at += body[at] == backslash ? 2 : 1
            }
            let inner = scan(String(utf16CodeUnits: body, count: body.count), isCancelled: isCancelled)
            func moved(_ r: Range<Int>) -> Range<Int> { (r.lowerBound + range.lowerBound)..<(r.upperBound + range.lowerBound) }
            // A value ends before the space its closing quote's backslash became.
            found.spans += inner.spans.compactMap { span in
                var end = span.range.upperBound
                while end > span.range.lowerBound, body[end - 1] == space { end -= 1 }
                return end > span.range.lowerBound ? Span(range: moved(span.range.lowerBound..<end), entity: span.entity, score: span.score) : nil
            }
            found.structural += inner.structural.map(moved)
            found.keys += inner.keys.map(moved)
        }
        // YAML's nested mappings write their fields at the root's level: a search's name and year are read there.
        for level in levels { found.spans += births(level, around: nil) }
        found.spans.sort { $0.range.lowerBound < $1.range.lowerBound }
        return found
    }
}
