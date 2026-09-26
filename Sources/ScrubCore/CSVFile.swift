import Foundation

public enum CSVFile: FileFormat {
    static let previewRows = 500
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        let text = try TextFile.decode(data)
        let delimiter = sniffDelimiter(text)
        let quoteCharacter = sniffQuote(text, delimiter: delimiter)
        let newline = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
        var rows = try parse(text, delimiter: delimiter, quoteCharacter: quoteCharacter)
        guard !rows.isEmpty else { throw ScrubError.unsupported("empty_file") }
        let width = rows.map(\.count).max() ?? 0
        let hasHeader = header(rows, job: job)
        var columns = hasHeader ? rows.removeFirst() : (0..<width).map { "column \($0 + 1)" }
        let hints = (0..<width).map { $0 < columns.count ? KeyHints.hint(columns[$0]) : nil }
        var marks: [TableMark] = []
        var unresolved: [Mark] = []
        let total = rows.reduce(0) { $0 + $1.count }
        var done = 0
        progress(.finding, 0, total)
        for row in rows.indices {
            if row.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            func field(_ entity: String) -> String? {
                guard let column = hints.firstIndex(of: entity), column < rows[row].count else { return nil }
                return rows[row][column]
            }
            let owner = job.associateRecord(first: field("FIRST_NAME"), last: field("LAST_NAME"), full: field("PERSON"), email: field("EMAIL_ADDRESS"))
            for column in rows[row].indices {
                let (output, found, rest) = try job.scrubValue(rows[row][column], key: column < columns.count ? columns[column] : nil, owner: owner)
                rows[row][column] = output
                if row < previewRows { marks += found.map { TableMark(row: row, column: column, range: $0.range, entity: $0.entity) } }
                unresolved += rest
                done += 1
            }
            progress(.finding, done, total)
        }
        if hasHeader {
            for index in columns.indices {
                let (output, _, rest) = try job.scrubValue(columns[index])
                columns[index] = output
                unresolved += rest
            }
        }
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
        let all = (hasHeader ? [columns] : []) + rows
        let output = all.map { $0.map { quote($0, delimiter: delimiter, quoteCharacter: quoteCharacter) }.joined(separator: String(delimiter)) }.joined(separator: newline) + newline
        progress(.checking, 1, 1)
        return ScrubResult(format: "csv", output: Data(output.utf8), preview: .table(columns: columns, rows: Array(rows.prefix(previewRows)), rowCount: rows.count, marks: marks), counts: job.counts, unresolved: unresolved, neutralized: neutralized)
    }
    static func sniffDelimiter(_ text: String) -> Character {
        let sample = String(text.prefix(65_536))
        let lines = sample.split(whereSeparator: \Character.isNewline).prefix(20)
        return [",", ";", "\t", "|"].max { a, b in
            let ac = lines.reduce(0) { $0 + $1.filter { $0 == a }.count }
            let bc = lines.reduce(0) { $0 + $1.filter { $0 == b }.count }
            return ac < bc
        } ?? ","
    }
    static func sniffQuote(_ text: String, delimiter: Character) -> Character {
        let escaped = NSRegularExpression.escapedPattern(for: String(delimiter))
        let pattern = "(?:^|[\\r\\n\(escaped)])'[^'\\r\\n]*'(?=[\\r\\n\(escaped)]|$)"
        return TextRanges.matches(pattern, in: String(text.prefix(65_536))).count >= 2 ? "'" : "\""
    }
    static func parse(_ text: String, delimiter: Character, quoteCharacter: Character = "\"") throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == quoteCharacter {
                    if index + 1 < chars.count && chars[index + 1] == quoteCharacter { field.append(quoteCharacter); index += 1 }
                    else { quoted = false }
                } else { field.append(char) }
            } else if char == quoteCharacter && field.isEmpty { quoted = true }
            else if char == delimiter { row.append(field); field = "" }
            else if char == "\n" || char == "\r" {
                row.append(field); field = ""
                if !row.isEmpty { rows.append(row) }
                row = []
                if char == "\r" && index + 1 < chars.count && chars[index + 1] == "\n" { index += 1 }
            } else { field.append(char) }
            index += 1
        }
        if quoted { throw ScrubError.unsupported("invalid_csv") }
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
    static func neutralize(_ cell: String) -> String? {
        if cell.hasPrefix("\t") || cell.hasPrefix("\r") || cell.hasPrefix("\n") { return "'" + cell }
        let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        if "=@＝＠".contains(first) { return "'" + cell }
        if "+-＋－".contains(first) {
            let numeric = #"^[+\-＋－]?[\d\s().,\-]*$"#
            if TextRanges.matches(numeric, in: trimmed).isEmpty { return "'" + cell }
        }
        return nil
    }
    private static func quote(_ cell: String, delimiter: Character, quoteCharacter: Character) -> String {
        guard cell.contains(delimiter) || cell.contains(quoteCharacter) || cell.contains("\r") || cell.contains("\n") else { return cell }
        let quote = String(quoteCharacter)
        return quote + cell.replacingOccurrences(of: quote, with: quote + quote) + quote
    }
}
