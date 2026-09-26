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
                let ancestry = records + [nextRecord]
                for (index, pair) in pairs.enumerated() {
                    let childPath = path + "/" + String(index)
                    keyIDs[childPath] = leaves.count
                    leaves.append(DocumentLeaf(pair.0))
                    let inherited = KeyHints.hint(pair.0) == nil && KeyHints.hint(key) == "SECRET" ? key : pair.0
                    collect(pair.1, key: inherited, path: childPath, records: ancestry, keys: keys + [pair.0])
                }
            case .array(let values):
                for (index, child) in values.enumerated() {
                    collect(child, key: key, path: path + "/" + String(index), records: KeyHints.hint(key).map({ ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME"].contains($0) }) == true ? [] : records, keys: keys)
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
        let values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection)
        progress(.finding, leaves.count, leaves.count)
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
                    let (numbered, digitMarks) = replaceDigits(scrubbed?.text ?? pair.0, job: job)
                    keyMarks[childPath] = (scrubbed?.marks ?? []) + digitMarks
                    var unique = numbered
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
        progress(.checking, 0, 1)
        let (rendered, marks) = OrderedJSON.render(scrubbed, valueMarks: valueMarks, keyMarks: keyMarks)
        // With nothing replaced, the input goes back byte for byte instead of re-indented.
        let output = marks.isEmpty ? text : rendered
        progress(.checking, 1, 1)
        let length = (output as NSString).length
        let limit = min(length, 200_000)
        return ScrubResult(format: "json", output: Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<limit), marks: marks.filter { $0.range.upperBound <= limit }, truncated: length > limit), counts: job.counts, unresolved: unresolved)
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
    static func numericEntity(key: String?, number: String) -> String? {
        if let hint = KeyHints.hint(key) { return hint }
        guard let value = Double(number), value.isFinite else { return nil }
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
