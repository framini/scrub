import Foundation

public enum JSONFile: FileFormat {
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        let text = try TextFile.decode(data)
        let root = try OrderedJSON.parse(text)
        var valueMarks: [String: [Mark]] = [:]
        var keyMarks: [String: [Mark]] = [:]
        var unresolved: [Mark] = []
        var visited = 0
        func process(_ value: JSONValue, key: String?, path: String, owner: Persona?, keys: [String]) throws -> JSONValue {
            visited += 1
            if visited.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            switch value {
            case .object(let pairs):
                let first = pairs.first { KeyHints.hint($0.0) == "FIRST_NAME" }?.1.stringValue
                let last = pairs.first { KeyHints.hint($0.0) == "LAST_NAME" }?.1.stringValue
                let full = pairs.first { KeyHints.hint($0.0) == "PERSON" }?.1.stringValue
                let email = pairs.first { KeyHints.hint($0.0) == "EMAIL_ADDRESS" }?.1.stringValue
                let currentOwner = job.associateRecord(first: first, last: last, full: full, email: email) ?? owner
                var output: [(String, JSONValue)] = []
                for (index, pair) in pairs.enumerated() {
                    let childPath = path + "/" + String(index)
                    let child = try process(pair.1, key: pair.0, path: childPath, owner: currentOwner, keys: keys + [pair.0])
                    let (scrubbedKey, marks, rest) = try job.scrubValue(pair.0)
                    let (numbered, digitMarks) = replaceDigits(scrubbedKey, job: job)
                    keyMarks[childPath] = marks + digitMarks
                    unresolved += rest
                    var unique = numbered
                    while output.contains(where: { $0.0 == unique }) { unique += "_" }
                    output.append((unique, child))
                }
                return .object(output)
            case .array(let values):
                var output: [JSONValue] = []
                for (index, child) in values.enumerated() { output.append(try process(child, key: key, path: path + "/" + String(index), owner: owner, keys: keys)) }
                return .array(output)
            case .string(let string):
                guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return value }
                let (out, marks, rest) = try job.scrubValue(string, key: key, owner: owner, contextWords: Set(keys.flatMap { KeyHints.words($0) }))
                valueMarks[path] = marks
                unresolved += rest
                return .string(out)
            case .number(let number):
                guard let entity = numericEntity(key: key, number: number), let value = Double(number), value.isFinite else { return value }
                let original = String(format: "%.0f", value)
                let fake: String
                if entity == "DATE_OF_BIRTH", original.count == 8 {
                    fake = job.replacement(for: entity, original: original).filter(\.isNumber)
                } else {
                    fake = job.number(original, entity: entity)
                }
                let shaped = fake.isEmpty ? job.digits(original) : fake
                return .number(number.contains(".") || number.contains("e") || number.contains("E") ? shaped + ".0" : shaped)
            default: return value
            }
        }
        progress(.finding, 0, 1)
        let scrubbed = try process(root, key: nil, path: "", owner: nil, keys: [])
        progress(.finding, 1, 1)
        progress(.checking, 0, 1)
        let (output, marks) = OrderedJSON.render(scrubbed, valueMarks: valueMarks, keyMarks: keyMarks)
        progress(.checking, 1, 1)
        let length = (output as NSString).length
        let limit = min(length, 200_000)
        return ScrubResult(format: "json", output: Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<limit), marks: marks.filter { $0.range.upperBound <= limit }, truncated: length > limit), counts: job.counts, unresolved: unresolved)
    }
    static func replaceDigits(_ text: String, job: Job) -> (String, [Mark]) {
        var output = text
        var marks: [Mark] = []
        for match in TextRanges.matches(#"[0-9]{7,}"#, in: text).reversed() {
            let range = match.range.location..<NSMaxRange(match.range)
            let fake = job.digits(TextRanges.substring(text, range))
            output = TextRanges.replace(output, range, with: fake)
            marks.append(Mark(range: range.lowerBound..<(range.lowerBound + (fake as NSString).length), entity: "ID_NUMBER"))
        }
        return (output, marks)
    }
    private static func numericEntity(key: String?, number: String) -> String? {
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
