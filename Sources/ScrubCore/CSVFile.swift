import Foundation

public enum CSVFile: FileFormat {
    static let previewRows = 500
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        try process(data, job: job, progress: progress, forceFullDetection: false)
    }
    static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void, forceFullDetection: Bool) throws -> ScrubResult {
        var text = try TextFile.decode(data)
        let (delimiter, quoteCharacter) = sniffFormat(text)
        let newline = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
        var rows = try parse(text, delimiter: delimiter, quoteCharacter: quoteCharacter)
        text = ""
        guard !rows.isEmpty else { throw ScrubError.unsupported("empty_file") }
        let width = rows.map(\.count).max() ?? 0
        let hasHeader = header(rows, job: job)
        var columns = hasHeader ? rows.removeFirst() : (0..<width).map { "column \($0 + 1)" }
        var leaves: [DocumentLeaf] = []
        // Exports flatten nested records into headers ("billing.address.city").
        let keys = columns.map { KeyHints.header($0) ?? $0 }
        // A flattened form field ("fields.0.value") is named by its sibling column ("fields.0.name").
        let named: [Int: [Int]] = Dictionary(uniqueKeysWithValues: columns.indices.compactMap { column in
            let parts = KeyHints.words(columns[column])
            guard let last = parts.last, KeyHints.fieldValueKeys.contains(last), KeyHints.hint(keys[column]) == nil else { return nil }
            let siblings = columns.indices.filter { other in
                let words = KeyHints.words(columns[other])
                return other != column && words.dropLast() == parts.dropLast() && words.last.map(KeyHints.fieldNameKeys.contains) == true
            }
            return siblings.isEmpty ? nil : (column, siblings)
        })
        let naming = Set(named.values.flatMap { $0 })
        for row in rows.indices {
            if row.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
            for column in rows[row].indices {
                var key = column < keys.count ? keys[column] : nil
                // A column naming fields holds field names ("zip", "email"), and a bare
                // "name" is a person's only as it is in JSON.
                if naming.contains(column) || KeyHints.isBareName(key) && !KeyHints.bareNameIsPerson(rows[row][column], siblings: keys, parent: nil) { key = nil }
                if let siblings = named[column] {
                    let texts = siblings.compactMap { $0 < rows[row].count ? (KeyHints.words(columns[$0]).last!, rows[row][$0]) : nil }
                    key = KeyHints.namedField("value", siblings: texts) ?? key
                }
                leaves.append(DocumentLeaf(rows[row][column], key: key, records: [row]))
            }
        }
        var headerIDs: [Int] = []
        if hasHeader {
            for column in columns.indices {
                headerIDs.append(leaves.count)
                leaves.append(DocumentLeaf(columns[column], fieldName: true))
            }
        }
        progress(.finding, 0, leaves.count)
        let values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection, progress: progress)
        let found = leaves.count
        leaves.removeAll(keepingCapacity: false)
        progress(.finding, found, found)
        try Scrubber.checkCancellation()
        var marks: [TableMark] = []
        let unresolved = values.flatMap(\.unresolved)
        var valueIndex = 0
        for row in rows.indices {
            if row.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
            for column in rows[row].indices {
                rows[row][column] = values[valueIndex].text
                if row < previewRows {
                    marks += values[valueIndex].marks.map { TableMark(row: row, column: column, range: $0.range, entity: $0.entity) }
                }
                valueIndex += 1
            }
        }
        for (column, index) in headerIDs.enumerated() {
            columns[column] = values[index].text
            marks += values[index].marks.map { TableMark(row: TableMark.header, column: column, range: $0.range, entity: $0.entity) }
        }
        let previewWidth = max(columns.count, rows.prefix(previewRows).map(\.count).max() ?? 0)
        let previewColumns = columns + Array(repeating: "", count: previewWidth - columns.count)
        progress(.checking, 0, 1)
        var neutralized = 0
        func shift(row: Int, column: Int) {
            for mark in marks.indices where marks[mark].row == row && marks[mark].column == column {
                let old = marks[mark]
                marks[mark] = TableMark(row: row, column: column, range: (old.range.lowerBound + 1)..<(old.range.upperBound + 1), entity: old.entity)
            }
        }
        if hasHeader {
            for column in columns.indices {
                if let safe = neutralize(columns[column]) {
                    columns[column] = safe
                    neutralized += 1
                    shift(row: TableMark.header, column: column)
                }
            }
        }
        for row in rows.indices {
            if row.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            for column in rows[row].indices {
                if let safe = neutralize(rows[row][column]) {
                    rows[row][column] = safe
                    neutralized += 1
                    if row < previewRows { shift(row: row, column: column) }
                }
            }
        }
        var output = Data()
        output.reserveCapacity(data.count + data.count / 4)
        func append(_ row: [String]) {
            for column in row.indices {
                if column > 0 { output.append(contentsOf: String(delimiter).utf8) }
                output.append(contentsOf: quote(row[column], delimiter: delimiter, quoteCharacter: quoteCharacter).utf8)
            }
            output.append(contentsOf: newline.utf8)
        }
        if hasHeader { append(columns) }
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
            append(row)
        }
        progress(.checking, 1, 1)
        return ScrubResult(format: "csv", output: output, preview: .table(columns: previewColumns, rows: Array(rows.prefix(previewRows)), rowCount: rows.count, marks: marks), counts: job.counts, unresolved: unresolved, neutralized: neutralized)
    }
    static func sniffDelimiter(_ text: String) -> Character { sniffFormat(text).0 }
    static func sniffQuote(_ text: String, delimiter: Character) -> Character { sniffFormat(text, delimiters: [delimiter]).1 }
    private static func sniffFormat(_ text: String, delimiters: [Character] = [",", ";", "\t", "|"]) -> (Character, Character) {
        let sample = String(text.prefix(65_536))
        var best: (Character, Character) = (",", "\"")
        var bestScore = -1
        for delimiter in delimiters {
            var doubleQuoteConsistent = false
            for quote: Character in ["\"", "'"] {
                guard let rows = try? parse(sample, delimiter: delimiter, quoteCharacter: quote, incompleteFinalRecord: true) else { continue }
                let widths = rows.prefix(50).map(\.count)
                guard let width = widths.first, width > 1 else { continue }
                // A wrong quote character splits multiline cells into extra rows.
                // Reward agreement with the header, not the number of split rows.
                let matching = widths.filter { $0 == width }.count
                let score = matching * 10_000 / widths.count + min(width, 99)
                if quote == "\"" { doubleQuoteConsistent = matching == widths.count }
                if quote == "'" && doubleQuoteConsistent { continue }
                if score > bestScore {
                    best = (delimiter, quote)
                    bestScore = score
                }
            }
        }
        return best
    }
    static func parse(_ text: String, delimiter: Character, quoteCharacter: Character = "\"", incompleteFinalRecord: Bool = false, onQuotedField: (() -> Void)? = nil) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text.unicodeScalars)
        let separator = delimiter.unicodeScalars.first
        let quote = quoteCharacter.unicodeScalars.first
        var index = 0
        while index < chars.count {
            if index.isMultiple(of: 65_536) { try Scrubber.checkCancellation() }
            let char = chars[index]
            if quoted {
                if char == quote {
                    if index + 1 < chars.count && chars[index + 1] == quote { field.unicodeScalars.append(char); index += 1 }
                    else { quoted = false }
                } else { field.unicodeScalars.append(char) }
            } else if char == quote && field.isEmpty { quoted = true; onQuotedField?() }
            else if char == separator { row.append(field); field = "" }
            else if char == "\n" || char == "\r" {
                row.append(field); field = ""
                rows.append(row)
                row = []
                if char == "\r" && index + 1 < chars.count && chars[index + 1] == "\n" { index += 1 }
            } else { field.unicodeScalars.append(char) }
            index += 1
        }
        if quoted {
            if incompleteFinalRecord { return rows }
            throw ScrubError.unsupported("invalid_csv")
        }
        if !row.isEmpty || !field.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
    private static func header(_ rows: [[String]], job: Job) -> Bool {
        guard let first = rows.first else { return false }
        if first.contains(where: { KeyHints.hint($0) != nil || KeyHints.isRole($0) }) { return true }
        // A key/value export: a column naming the field beside the column holding it ("Field,Value").
        let plain = first.map { KeyHints.words($0).joined() }
        if plain.contains(where: KeyHints.fieldValueKeys.contains), plain.contains(where: KeyHints.fieldNameKeys.contains) { return true }
        // A flattened field name ("Applicant Address Postcode"), unlike a value, has no number or @ of its own.
        if first.contains(where: { cell in KeyHints.header(cell) != nil && !cell.contains("@") && !KeyHints.words(cell).contains { $0.allSatisfy(\.isNumber) && $0.count > 1 } }) { return true }
        if first.contains(where: { cell in job.detector.find(cell).contains { ["EMAIL_ADDRESS", "PHONE_NUMBER", "CREDIT_CARD", "US_SSN", "IP_ADDRESS", "IBAN_CODE"].contains($0.entity) } }) { return false }
        guard rows.count > 1 else { return true }
        let firstNumeric = first.filter { Double($0) != nil }.count
        let nextNumeric = rows.dropFirst().prefix(5).flatMap { $0 }.filter { Double($0) != nil }.count
        return nextNumeric > firstNumeric
    }
    private static let signedNumber = TextPattern(#"^[+\-＋－]?[\d\s().,\-]*$"#)
    static func neutralize(_ cell: String) -> String? {
        if cell.hasPrefix("\t") || cell.hasPrefix("\r") || cell.hasPrefix("\n") { return "'" + cell }
        let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        if "=@＝＠".contains(first) { return "'" + cell }
        if "+-＋－".contains(first) {
            if TextRanges.matches(signedNumber, in: trimmed).isEmpty { return "'" + cell }
        }
        return nil
    }
    private static func quote(_ cell: String, delimiter: Character, quoteCharacter: Character) -> String {
        guard cell.contains(delimiter) || cell.contains(quoteCharacter) || cell.contains("\r") || cell.contains("\n") else { return cell }
        let quote = String(quoteCharacter)
        return quote + cell.replacingOccurrences(of: quote, with: quote + quote) + quote
    }
}
