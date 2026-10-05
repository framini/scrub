import Foundation

public enum JSONFile: FileFormat {
    private static let longDigits = TextPattern(#"[0-9]{7,}"#)
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        try process(data, job: job, progress: progress, forceFullDetection: false)
    }
    static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void, forceFullDetection: Bool) throws -> ScrubResult {
        let text = try TextFile.decode(data)
        let collector = JSONDocument.Collector()
        let document = collector.add(try JSONSource.read(text))
        let leaves = collector.leaves
        // A key's own long digits ("order_48213907") are drawn first, as any
        // value's: the same number written in a value ("Archived under 48213907")
        // is then found as theirs and replaced alike.
        let drawn = drawDigits(collector.names, job: job)
        progress(.finding, 0, leaves.count)
        var values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection, progress: progress)
        let records = leaves.map(\.lastRecord)
        progress(.finding, leaves.count, leaves.count)
        // Each key then writes them, with marks holding what they replaced, so
        // the review reports them and every edit writes them as reported.
        document.writeKeyDigits(&values, drawn: drawn)
        func render(_ values: [DocumentValue], counts: [String: Int]) throws -> ScrubResult {
            let (output, marks) = document.render(values)
            let length = (output as NSString).length
            let limit = min(length, 200_000)
            // With nothing replaced, the input goes back byte for byte (BOM included).
            return ScrubResult(format: "json", output: marks.isEmpty && output == text ? data : Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<limit), marks: marks.filter { $0.range.upperBound <= limit }, truncated: length > limit), counts: counts, unresolved: values.flatMap(\.unresolved))
        }
        progress(.checking, 0, 1)
        var result = try render(values, counts: job.counts)
        result.review = Review(values: values, counts: job.counts, records: records, people: job.personLinks(), numeric: Set(leaves.indices.filter { leaves[$0].numericEntity != nil }), render: render)
        progress(.checking, 1, 1)
        return result
    }
    /// `value` with each run of its own text, outside every stand-in and
    /// suspect, written as `rewrite` writes it, right to left, the marks and
    /// suspects moved to where they now stand, and the marks `rewrite` gives
    /// each set where it is written. A key's or a tag's own digits and names
    /// are replaced so, once, when the file is scrubbed: their marks make them
    /// findings, which every later writing writes as edits and choices leave them.
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
    /// The long digits in `names` (keys, or element and attribute names), each
    /// drawn its stand-in once, in the order they are written, before any value
    /// is read: the pipeline then finds each where a value writes it too.
    static func drawDigits(_ names: [String], job: Job) -> [String: String] {
        var drawn: [String: String] = [:]
        for name in names {
            for match in TextRanges.matches(longDigits, in: name) {
                let digits = TextRanges.substring(name, match.range.location..<NSMaxRange(match.range))
                if drawn[digits] == nil { drawn[digits] = job.digits(digits) }
            }
        }
        return drawn
    }
    /// `text` with each of its long digits written as drawn, each marked with what it replaced.
    static func replaceDigits(_ text: String, drawn: [String: String]) -> (String, [Mark]) {
        var output = text
        var marks: [Mark] = []
        for match in TextRanges.matches(longDigits, in: text).reversed() {
            let range = match.range.location..<NSMaxRange(match.range)
            let digits = TextRanges.substring(text, range)
            guard let fake = drawn[digits] else { continue }
            output = TextRanges.replace(output, range, with: fake)
            let length = (fake as NSString).length - range.count
            marks = marks.map { $0.moved(to: ($0.range.lowerBound + length)..<($0.range.upperBound + length)) }
            marks.insert(Mark(range: range.lowerBound..<(range.lowerBound + (fake as NSString).length), entity: "ID_NUMBER", original: digits), at: 0)
        }
        return (output, marks)
    }
    // Only these can be written as a bare number; a number under "last_name" is a count or a code,
    // under "address" only a house or unit number ("building_number": 12) is one.
    private static let numericEntities: Set<String> = ["PHONE_NUMBER", "US_SSN", "ID_NUMBER", "CREDIT_CARD", "POSTAL_CODE", "DATE_OF_BIRTH", "SECRET", "USERNAME", "AGE", "LAST_DIGITS", "LATITUDE", "LONGITUDE", "ADDRESS"]
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
        // A secret written as a number, whole or not ("password": -12345, "pin": 12.50), is one.
        if KeyHints.hint(key) == "SECRET" { return KeyHints.fits(key, number) ? "SECRET" : nil }
        if let hint = KeyHints.hint(key), !numericEntities.contains(hint) { return nil }
        if KeyHints.hint(key) == "ADDRESS" { return KeyHints.addressNumberKey(key) && KeyHints.fits(key, number) && number.allSatisfy({ $0.isASCII && $0.isNumber }) && number.count <= 5 ? "ADDRESS" : nil }
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
        return !floating && Patterns.luhn(digits) && !Patterns.epochMilliseconds(digits) ? "CREDIT_CARD" : nil
    }
}
