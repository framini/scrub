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
        for row in rows.indices {
            for column in rows[row].indices {
                leaves.append(DocumentLeaf(rows[row][column], key: column < columns.count ? columns[column] : nil, records: [row]))
            }
        }
        var headerIDs: [Int] = []
        if hasHeader {
            for column in columns.indices {
                headerIDs.append(leaves.count)
                leaves.append(DocumentLeaf(columns[column]))
            }
        }
        progress(.finding, 0, leaves.count)
        let values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection)
        leaves.removeAll(keepingCapacity: false)
        progress(.finding, leaves.count, leaves.count)
        var marks: [TableMark] = []
        let unresolved = values.flatMap(\.unresolved)
        var valueIndex = 0
        for row in rows.indices {
            for column in rows[row].indices {
                rows[row][column] = values[valueIndex].text
                if row < previewRows {
                    marks += values[valueIndex].marks.map { TableMark(row: row, column: column, range: $0.range, entity: $0.entity) }
                }
                valueIndex += 1
            }
        }
        for (column, index) in headerIDs.enumerated() { columns[column] = values[index].text }
        let previewWidth = max(columns.count, rows.prefix(previewRows).map(\.count).max() ?? 0)
        let previewColumns = columns + Array(repeating: "", count: previewWidth - columns.count)
        progress(.checking, 0, 1)
        var neutralized = 0
        if hasHeader {
            for column in columns.indices {
                if let safe = neutralize(columns[column]) { columns[column] = safe; neutralized += 1 }
            }
        }
        for row in rows.indices {
            if row.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            for column in rows[row].indices {
                if let safe = neutralize(rows[row][column]) {
                    rows[row][column] = safe
                    neutralized += 1
                    for mark in marks.indices where marks[mark].row == row && marks[mark].column == column {
                        let old = marks[mark]
                        marks[mark] = TableMark(row: row, column: column, range: (old.range.lowerBound + 1)..<(old.range.upperBound + 1), entity: old.entity)
                    }
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
        for row in rows { append(row) }
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
            for quote: Character in ["\"", "'"] {
                guard let rows = try? parse(sample, delimiter: delimiter, quoteCharacter: quote, incompleteFinalRecord: true) else { continue }
                let widths = rows.prefix(50).map(\.count)
                guard let common = Dictionary(grouping: widths, by: { $0 }).max(by: { $0.value.count < $1.value.count }), common.key > 1 else { continue }
                let score = common.value.count * 100 + common.key
                if score > bestScore { best = (delimiter, quote); bestScore = score }
            }
        }
        return best
    }
    static func parse(_ text: String, delimiter: Character, quoteCharacter: Character = "\"", incompleteFinalRecord: Bool = false) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text.unicodeScalars)
        let separator = delimiter.unicodeScalars.first
        let quote = quoteCharacter.unicodeScalars.first
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == quote {
                    if index + 1 < chars.count && chars[index + 1] == quote { field.unicodeScalars.append(char); index += 1 }
                    else { quoted = false }
                } else { field.unicodeScalars.append(char) }
            } else if char == quote && field.isEmpty { quoted = true }
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
        if first.contains(where: { KeyHints.hint($0) != nil }) { return true }
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
