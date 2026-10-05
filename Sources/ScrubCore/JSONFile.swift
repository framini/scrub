import Foundation

public enum JSONFile: FileFormat {
    private static let longDigits = TextPattern(#"[0-9]{7,}"#)
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        try process(data, job: job, progress: progress, forceFullDetection: false)
    }
    static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void, forceFullDetection: Bool) throws -> ScrubResult {
        let text = try TextFile.decode(data)
        let root = try OrderedJSON.parse(text)
        var leaves: [DocumentLeaf] = []
        var valueIDs: [String: Int] = [:]
        var keyIDs: [String: Int] = [:]
        var nextRecord = 0
        func collect(_ value: JSONValue, key: String?, path: String, records: [Int], keys: [String]) {
            switch value {
            case .object(let pairs):
                nextRecord += 1
                let ancestry = KeyHints.isWrapper(pairs.map(\.0)) && !records.isEmpty ? records : records + [nextRecord]
                let named = pairs.compactMap { pair in pair.1.stringValue.map { (pair.0, $0) } }
                for (index, pair) in pairs.enumerated() {
                    let childPath = path + "/" + String(index)
                    keyIDs[childPath] = leaves.count
                    leaves.append(DocumentLeaf(pair.0))
                    var inherited = KeyHints.namedField(pair.0, siblings: named) ?? KeyHints.resolve(pair.0, parent: key)
                    if KeyHints.isBareName(pair.0), case .string(let name) = pair.1,
                       !KeyHints.bareNameIsPerson(name, siblings: pairs.map(\.0), parent: key) { inherited = nil }
                    collect(pair.1, key: inherited, path: childPath, records: ancestry, keys: keys + [pair.0])
                }
            case .array(let values):
                let pair = coordinateKeys(key, values)
                for (index, child) in values.enumerated() {
                    // Several names or emails in one list may be several people's; one is the record's own.
                    collect(child, key: pair?[index] ?? key, path: path + "/" + String(index), records: values.count > 1 && KeyHints.hint(key).map({ ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME"].contains($0) }) == true ? [] : records, keys: keys)
                }
            case .string(let string):
                guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                valueIDs[path] = leaves.count
                leaves.append(DocumentLeaf(string, key: key, records: records, contextWords: Set(keys.flatMap { KeyHints.words($0) })))
            case .number(let number):
                guard let entity = numericEntity(key: key, number: number) else { break }
                valueIDs[path] = leaves.count
                leaves.append(DocumentLeaf(number, key: key, records: records, numericEntity: entity))
            default: break
            }
        }
        collect(root, key: nil, path: "", records: [], keys: [])
        progress(.finding, 0, leaves.count)
        var values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection, progress: progress)
        let records = leaves.map(\.lastRecord)
        progress(.finding, leaves.count, leaves.count)
        // A key's own long digits ("order_48213907") are replaced here, once, in the
        // order the file is written; each later writing reads them from the key's text.
        var numbered: [String: String] = [:], fakes: Set<String> = []
        func ownDigits(_ own: String) -> String {
            if let known = numbered[own] { return known }
            let (written, marks) = replaceDigits(own, job: job)
            for mark in marks { fakes.insert(TextRanges.substring(written, mark.range)) }
            numbered[own] = written
            return written
        }
        func numberKeys(_ value: JSONValue, path: String) {
            switch value {
            case .object(let pairs):
                for (index, pair) in pairs.enumerated() {
                    let childPath = path + "/" + String(index)
                    numberKeys(pair.1, path: childPath)
                    if let id = keyIDs[childPath] { values[id] = rewritingOwnText(values[id]) { (ownDigits($0), []) } }
                }
            case .array(let children):
                for (index, child) in children.enumerated() { numberKeys(child, path: path + "/" + String(index)) }
            default: break
            }
        }
        numberKeys(root, path: "")
        let keyNumbers = fakes
        func render(_ values: [DocumentValue], counts: [String: Int]) throws -> ScrubResult {
            var valueMarks: [String: [Mark]] = [:]
            var keyMarks: [String: [Mark]] = [:]
            let unresolved = values.flatMap(\.unresolved)
            func process(_ value: JSONValue, key: String?, path: String) throws -> JSONValue {
                switch value {
                case .object(let pairs):
                    var output: [(String, JSONValue)] = []
                    for (index, pair) in pairs.enumerated() {
                        let childPath = path + "/" + String(index)
                        let child = try process(pair.1, key: pair.0, path: childPath)
                        let scrubbed = keyIDs[childPath].map { values[$0] }
                        let written = scrubbed?.text ?? pair.0
                        keyMarks[childPath] = Self.marks(of: scrubbed, numbers: keyNumbers)
                        var unique = written
                        while output.contains(where: { $0.0 == unique }) { unique += "_" }
                        output.append((unique, child))
                    }
                    return .object(output)
                case .array(let children):
                    return .array(try children.enumerated().map { try process($0.element, key: key, path: path + "/" + String($0.offset)) })
                case .string:
                    guard let id = valueIDs[path] else { return value }
                    valueMarks[path] = values[id].marks
                    return .string(values[id].text)
                case .number:
                    guard let id = valueIDs[path] else { return value }
                    valueMarks[path] = values[id].marks
                    return .number(values[id].text)
                default: return value
                }
            }
            let scrubbed = try process(root, key: nil, path: "")
            let (rendered, marks) = OrderedJSON.render(scrubbed, valueMarks: valueMarks, keyMarks: keyMarks)
            let output = marks.isEmpty ? text : rendered
            let length = (output as NSString).length
            let limit = min(length, 200_000)
            // With nothing replaced, the input goes back byte for byte (BOM included) instead of re-indented.
            return ScrubResult(format: "json", output: marks.isEmpty ? data : Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<limit), marks: marks.filter { $0.range.upperBound <= limit }, truncated: length > limit), counts: counts, unresolved: unresolved)
        }
        progress(.checking, 0, 1)
        var result = try render(values, counts: job.counts)
        result.review = Review(values: values, counts: job.counts, records: records, people: job.personLinks(), numeric: Set(leaves.indices.filter { leaves[$0].numericEntity != nil }), render: render)
        progress(.checking, 1, 1)
        return result
    }
    /// A key's marks: its findings' stand-ins, and the numbers written in its own text.
    private static func marks(of key: DocumentValue?, numbers: Set<String>) -> [Mark] {
        guard let key else { return [] }
        var marks = key.marks
        if !numbers.isEmpty {
            for match in TextRanges.matches(longDigits, in: key.text) {
                let range = match.range.location..<NSMaxRange(match.range)
                guard numbers.contains(TextRanges.substring(key.text, range)), !marks.contains(where: { $0.range.overlaps(range) }) else { continue }
                marks.append(Mark(range: range, entity: "ID_NUMBER"))
            }
        }
        return marks.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
    /// `value` with each run of its own text, outside every stand-in and
    /// suspect, written as `rewrite` writes it, right to left, the marks and
    /// suspects moved to where they now stand. A key's or a tag's own digits
    /// are replaced so, once, when the file is scrubbed: the value's text then
    /// carries them into every later writing, and an edit, which writes only
    /// its findings' ranges, never draws them again or reaches into a typed
    /// replacement, a kept original or another finding's stand-in.
    /// `value` with each run of its text no mark holds written as `rewrite`
    /// writes it, and the marks `rewrite` gives each, set where it is written.
    static func rewritingOwnText(_ value: DocumentValue, with rewrite: (String) -> (String, [Mark])) -> DocumentValue {
        let length = (value.text as NSString).length
        var own: [Range<Int>] = []
        var cursor = 0
        for range in (value.marks + value.unresolved).map(\.range).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > cursor { own.append(cursor..<range.lowerBound) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < length { own.append(cursor..<length) }
        var edits: [(range: Range<Int>, value: String)] = [], added: [[Mark]] = []
        for range in own.reversed() {
            let text = TextRanges.substring(value.text, range), (written, marks) = rewrite(text)
            if written != text {
                edits.insert((range, written), at: 0)
                added.insert(marks, at: 0)
            }
        }
        guard !edits.isEmpty else { return value }
        var made: [Mark] = [], shift = 0
        for (edit, marks) in zip(edits, added) {
            let start = edit.range.lowerBound + shift
            made += marks.map { $0.moved(to: ($0.range.lowerBound + start)..<($0.range.upperBound + start)) }
            shift += (edit.value as NSString).length - edit.range.count
        }
        let marks = (TextRanges.shift(value.marks, by: edits) + made).sorted { $0.range.lowerBound < $1.range.lowerBound }
        return DocumentValue(text: TextRanges.apply(edits, to: value.text).0, marks: marks,
                             unresolved: TextRanges.shift(value.unresolved, by: edits), proposals: value.proposals, held: TextRanges.shift(value.held, by: edits))
    }
    static func replaceDigits(_ text: String, job: Job) -> (String, [Mark]) {
        var output = text
        var marks: [Mark] = []
        for match in TextRanges.matches(longDigits, in: text).reversed() {
            let range = match.range.location..<NSMaxRange(match.range)
            let fake = job.digits(TextRanges.substring(text, range))
            output = TextRanges.replace(output, range, with: fake)
            marks.append(Mark(range: range.lowerBound..<(range.lowerBound + (fake as NSString).length), entity: "ID_NUMBER"))
        }
        return (output, marks)
    }
    // Only these can be written as a bare number; a number under "last_name" is a count or a code.
    private static let numericEntities: Set<String> = ["PHONE_NUMBER", "US_SSN", "ID_NUMBER", "POSTAL_CODE", "DATE_OF_BIRTH", "SECRET", "USERNAME", "AGE", "LAST_DIGITS", "LATITUDE", "LONGITUDE"]
    /// A point written as two numbers: GeoJSON puts the longitude first, a
    /// "latlng" the latitude, and a number past ±90 can only be a longitude.
    static func coordinateKeys(_ key: String?, _ values: [JSONValue]) -> [String]? {
        guard KeyHints.hint(key) == "COORDINATES", values.count == 2 else { return nil }
        let numbers = values.compactMap { value -> Double? in if case .number(let n) = value { return Double(n) }; return nil }
        guard numbers.count == 2 else { return nil }
        let words = KeyHints.words(key).joined()
        let latitudeFirst = abs(numbers[0]) > 90 ? false : abs(numbers[1]) > 90 ? true : words.hasPrefix("lat")
        return latitudeFirst ? ["latitude", "longitude"] : ["longitude", "latitude"]
    }
    static func numericEntity(key: String?, number: String) -> String? {
        // A customer or patient number names them as an ID string would.
        if KeyHints.hint(key) == nil, RecordIDs.identifying(key: key, value: number), number.allSatisfy({ $0.isASCII && $0.isNumber }) { return "RECORD_ID" }
        if let hint = KeyHints.hint(key), ["AGE", "LAST_DIGITS", "LATITUDE", "LONGITUDE"].contains(hint) { return KeyHints.fits(key, number) ? hint : nil }
        if let hint = KeyHints.hint(key), !numericEntities.contains(hint) { return nil }
        guard let value = Double(number), value.isFinite else { return KeyHints.hint(key) }
        // A score like 0.99 under "dob" or "city" rates the field; it holds no value of it.
        // So is a small one written with a decimal point ("1.00"); 2128675309.0 is still a phone number.
        if let hint = KeyHints.hint(key) { return value.rounded() == value && (abs(value) >= 1000 || !number.contains(".") && !number.lowercased().contains("e")) ? hint : nil }
        let floating = number.contains(".") || number.contains("e") || number.contains("E")
        let integer = floating ? String(format: "%.0f", abs(value)) : (number.hasPrefix("-") ? String(number.dropFirst()) : number)
        let digits = integer.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return nil }
        let compact = (key ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if ["card", "cardnumber", "creditcard", "ccnumber", "pan"].contains(compact) { return "CREDIT_CARD" }
        return !floating && Patterns.luhn(digits) ? "CREDIT_CARD" : nil
    }
}

private extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
}
