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
        // Each header's words read once, and the columns under each path, so a header of many
        // columns is read in one pass, never once per column.
        let words = try columns.indices.map { column in
            if column.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
            return KeyHints.words(columns[column])
        }
        var namesUnder: [[String]: [Int]] = [:]
        for column in columns.indices where words[column].last.map(KeyHints.fieldNameKeys.contains) == true {
            namesUnder[Array(words[column].dropLast()), default: []].append(column)
        }
        // A flattened form field ("fields.0.value") is named by its sibling column ("fields.0.name").
        let named: [Int: [Int]] = Dictionary(uniqueKeysWithValues: columns.indices.compactMap { column in
            let parts = words[column]
            guard let last = parts.last, KeyHints.fieldValueKeys.contains(last), KeyHints.hint(keys[column]) == nil else { return nil }
            // The first few: an export names a field once, and a header that repeats it must not cost a pass per column.
            let siblings = Array((namesUnder[Array(parts.dropLast())] ?? []).lazy.filter { $0 != column }.prefix(4))
            return siblings.isEmpty ? nil : (column, siblings)
        })
        let naming = Set(named.values.flatMap { $0 })
        // A flattened name under a business, a product or an app ("application.name") is no
        // one's, unless the columns beside it under the same object make it a person's own
        // ("application.dob"): then it is read as a bare "name" is in JSON.
        // The object a column sits under: its path before the last dot, so a field of several
        // words ("application.date_of_birth") is one field; without a dot, all but its last word.
        let parents: [[String]] = columns.indices.map { column in
            let header = columns[column]
            if let dot = header.lastIndex(of: ".") { return KeyHints.words(String(header[..<dot])) }
            return Array(words[column].dropLast())
        }
        var under: [[String]: [Int]] = [:]
        for column in columns.indices { under[parents[column], default: []].append(column) }
        // Each object's fields read once: a name column is never among them, being a bare name.
        let fieldsUnder = under.mapValues { KeyHints.RecordFields($0.map { keys[$0] }) }
        let owned: [Int: KeyHints.RecordFields] = Dictionary(uniqueKeysWithValues: columns.indices.compactMap { column in
            let parts = words[column], parent = parents[column]
            guard parts.count >= 2, !parent.isEmpty, KeyHints.isBareName(parts.last), KeyHints.hint(keys[column]) == nil,
                  KeyHints.isNotPeople(parent.joined(separator: "_")), (under[parent]?.count ?? 0) > 1, let fields = fieldsUnder[parent] else { return nil }
            return (column, fields)
        })
        // Whether the columns make a bare "name" a person's, read once for every cell.
        let personsRecord = KeyHints.isPersonsRecord(siblings: keys, parent: nil)
        // A bare "name" column at least half of whose cells are people's names holds people's names in the rest:
        // "Venkataraman" under "Name" beside "Тобиас Хальворсен".
        let peopleColumns = Set(keys.indices.filter { column in
            guard KeyHints.isBareName(keys[column]) else { return false }
            let cells = rows.indices.compactMap { column < rows[$0].count ? rows[$0][column] : nil }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let people = cells.filter { KeyHints.bareNameIsPerson($0, personsRecord: personsRecord) }.count
            return people > 0 && people * 2 >= cells.count
        })
        for row in rows.indices {
            if row.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
            for column in rows[row].indices {
                var key = column < keys.count ? keys[column] : nil
                // A column naming fields holds field names ("zip", "email"), and a bare
                // "name" is a person's only as it is in JSON.
                // Under a list of a person's other names ("aka.0.name") a name is one whatever it is.
                // A row may run past its header: its extra cells have no column.
                let underNames = column < parents.count && ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(KeyHints.hint(parents[column].filter { !$0.allSatisfy(\.isNumber) }.joined(separator: "_")) ?? "")
                let cell = rows[row][column], peopleColumn = peopleColumns.contains(column) && cell.split(separator: " ").count <= 5 && cell.first?.isUppercase == true && cell.allSatisfy { $0.isLetter || " .'’-".contains($0) }
                if naming.contains(column) || KeyHints.isBareName(key) && !underNames && !peopleColumn && !KeyHints.bareNameIsPerson(cell, personsRecord: personsRecord) { key = nil }
                if let fields = owned[column], KeyHints.ownRecord(fields, value: rows[row][column]) { key = "name" }
                if let siblings = named[column] {
                    let texts = siblings.compactMap { $0 < rows[row].count ? (KeyHints.words(columns[$0]).last!, rows[row][$0]) : nil }
                    key = KeyHints.namedField("value", siblings: texts) ?? key
                }
                let header = column < columns.count ? columns[column] : ""
                leaves.append(DocumentLeaf(rows[row][column], key: key, records: [row], objectPath: header.contains(".") ? String(header[..<header.lastIndex(of: ".")!]).lowercased() : ""))
            }
        }
        var headerIDs: [Int] = []
        if hasHeader {
            for column in columns.indices {
                headerIDs.append(leaves.count)
                leaves.append(DocumentLeaf(columns[column], fieldName: true))
            }
        }
        // A heading's own long digits ("order_48213907") are drawn first, as in
        // a JSON key, so a cell writing the same number is replaced alike.
        let drawn = hasHeader ? JSONFile.drawDigits(columns, job: job) : [:]
        progress(.finding, 0, leaves.count)
        var values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection, progress: progress)
        if !drawn.isEmpty {
            for index in headerIDs { values[index] = JSONFile.rewritingOwnText(values[index]) { JSONFile.replaceDigits($0, drawn: drawn) } }
        }
        let records = leaves.map(\.lastRecord)
        let found = leaves.count
        leaves.removeAll(keepingCapacity: false)
        progress(.finding, found, found)
        try Scrubber.checkCancellation()
        // Rows are written again from the values, so a review can write them with some findings taken back.
        let widths = rows.map(\.count), headings = columns
        rows = []
        func render(_ values: [DocumentValue], counts: [String: Int]) throws -> ScrubResult {
            var rows = widths.map { [String](repeating: "", count: $0) }, columns = headings
            var marks: [TableMark] = []
            let unresolved = values.flatMap(\.unresolved)
            var valueIndex = 0
            for row in rows.indices {
                if row.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
                for column in rows[row].indices {
                    rows[row][column] = values[valueIndex].text
                    if row < previewRows {
                        marks += values[valueIndex].marks.map { TableMark(row: row, column: column, range: $0.range, entity: $0.entity, byHand: $0.byHand) }
                    }
                    valueIndex += 1
                }
            }
            for (column, index) in headerIDs.enumerated() {
                columns[column] = values[index].text
                marks += values[index].marks.map { TableMark(row: TableMark.header, column: column, range: $0.range, entity: $0.entity, byHand: $0.byHand) }
            }
            let previewWidth = max(columns.count, rows.prefix(previewRows).map(\.count).max() ?? 0)
            let previewColumns = columns + Array(repeating: "", count: previewWidth - columns.count)
            var neutralized = 0
            func shift(row: Int, column: Int) {
                for mark in marks.indices where marks[mark].row == row && marks[mark].column == column {
                    let old = marks[mark]
                    marks[mark] = TableMark(row: row, column: column, range: (old.range.lowerBound + 1)..<(old.range.upperBound + 1), entity: old.entity, byHand: old.byHand)
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
            return ScrubResult(format: "csv", output: output, preview: .table(columns: previewColumns, rows: Array(rows.prefix(previewRows)), rowCount: rows.count, marks: marks), counts: counts, unresolved: unresolved, neutralized: neutralized)
        }
        progress(.checking, 0, 1)
        var result = try render(values, counts: job.counts)
        result.review = Review(values: values, counts: job.counts, records: records, people: job.personLinks(), render: render)
        progress(.checking, 1, 1)
        return result
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
        // "customer_id" names a person's ID column, as "email" names an email's.
        if first.contains(where: { KeyHints.hint($0) != nil || KeyHints.isRole($0) || RecordIDs.isPersonKey($0) }) { return true }
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
