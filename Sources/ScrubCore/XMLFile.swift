import Foundation

public enum XMLFile: FileFormat {
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        let text = try decodeXML(data)
        if unsafeDeclaration(in: text) {
            throw ScrubError.unsupported("xml_doctype")
        }
        let document: XMLDocument
        let trimmed = text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"encoding\s*=\s*[\"'][^\"']*[\"']"#, with: "encoding=\"UTF-8\"", options: .regularExpression)
        do { document = try XMLDocument(data: Data(trimmed.utf8), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]) }
        catch { throw ScrubError.unsupported("invalid_xml") }
        guard document.dtd == nil else { throw ScrubError.unsupported("xml_doctype") }
        guard let root = document.rootElement() else { throw ScrubError.unsupported("invalid_xml") }
        var markedValues: [(String, String)] = []
        var unresolved: [Mark] = []
        var visited = 0
        func walk(_ element: XMLElement, inherited: Persona?, keys: [String]) throws {
            visited += 1
            if visited.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            let children = element.children ?? []
            func local(_ name: String?) -> String? { name?.split(separator: ":").last.map(String.init) }
            let currentKeys = keys + [local(element.name) ?? ""]
            let first = children.first { KeyHints.hint(local($0.name)) == "FIRST_NAME" }?.stringValue
            let last = children.first { KeyHints.hint(local($0.name)) == "LAST_NAME" }?.stringValue
            let full = children.first { KeyHints.hint(local($0.name)) == "PERSON" }?.stringValue
            let email = children.first { KeyHints.hint(local($0.name)) == "EMAIL_ADDRESS" }?.stringValue
            let owner = job.associateRecord(first: first, last: last, full: full, email: email) ?? inherited
            for attribute in element.attributes ?? [] {
                guard let value = attribute.stringValue, !value.isEmpty else { continue }
                let (output, marks, rest) = try job.scrubValue(value, key: local(attribute.name), owner: owner, contextWords: Set(currentKeys.flatMap { KeyHints.words($0) }))
                attribute.stringValue = output
                unresolved += rest
                for mark in marks { markedValues.append((TextRanges.substring(output, mark.range), mark.entity)) }
            }
            for child in children {
                if let nested = child as? XMLElement { try walk(nested, inherited: owner, keys: currentKeys); continue }
                guard let value = child.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let key = child.kind == .text ? local(element.name) : nil
                let (output, marks, rest) = try job.scrubValue(value, key: key, owner: owner, contextWords: Set(currentKeys.flatMap { KeyHints.words($0) }))
                child.stringValue = output
                unresolved += rest
                for mark in marks { markedValues.append((TextRanges.substring(output, mark.range), mark.entity)) }
            }
        }
        progress(.finding, 0, 1)
        try walk(root, inherited: nil, keys: [])
        progress(.finding, 1, 1)
        progress(.checking, 0, 1)
        var output = document.xmlString(options: [.nodePreserveAll])
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<?xml") {
            output = output.replacingOccurrences(of: #"^<\?xml[^?]*\?>\s*"#, with: "", options: .regularExpression)
            output = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + output
        } else {
            output = output.replacingOccurrences(of: #"^<\?xml[^?]*\?>\s*"#, with: "", options: .regularExpression)
        }
        for match in TextRanges.matches(#"xmlns(?::[\w.-]+)?=\"[^\"]*\""#, in: output).reversed() {
            let range = match.range.location..<NSMaxRange(match.range)
            let attribute = TextRanges.substring(output, range)
            guard let firstQuote = attribute.firstIndex(of: "\"") else { continue }
            let start = attribute.index(after: firstQuote)
            let uri = String(attribute[start..<attribute.index(before: attribute.endIndex)])
            let (replacement, found, rest) = try job.scrubValue(uri)
            unresolved += rest
            if !found.isEmpty {
                output = TextRanges.replace(output, range, with: String(attribute[..<start]) + replacement.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;") + "\"")
                for mark in found { markedValues.append((TextRanges.substring(replacement, mark.range), mark.entity)) }
            }
        }
        for match in TextRanges.matches(#"(?<=[</?\s])[A-Za-z_][A-Za-z0-9_.:-]*(?=[\s/>=?])"#, in: output).reversed() {
            let range = match.range.location..<NSMaxRange(match.range)
            let name = TextRanges.substring(output, range)
            let (numbered, found) = JSONFile.replaceDigits(name, job: job)
            var renamed = numbered
            for person in job.gazetteer["PERSON"] ?? [] {
                let parts = person.split(separator: " ")
                guard parts.count == 2 else { continue }
                let camel = String(parts[0]) + String(parts[1])
                let snake = parts.joined(separator: "_").lowercased()
                guard renamed.contains(camel) || renamed.contains(snake) else { continue }
                let fake = job.replacement(for: "PERSON", original: person).split(separator: " ")
                guard fake.count == 2 else { continue }
                renamed = renamed.replacingOccurrences(of: camel, with: fake.joined())
                    .replacingOccurrences(of: snake, with: fake.joined(separator: "_").lowercased())
            }
            if renamed != name {
                output = TextRanges.replace(output, range, with: renamed)
                for mark in found { markedValues.append((TextRanges.substring(renamed, mark.range), mark.entity)) }
                if found.isEmpty { markedValues.append((renamed, "PERSON")) }
            }
        }
        var marks: [Mark] = []
        for (value, entity) in markedValues where !value.isEmpty {
            for range in TextRanges.ranges(of: value, in: output, options: []) where !marks.contains(where: { $0.range.overlaps(range) }) {
                marks.append(Mark(range: range, entity: entity))
            }
        }
        marks.sort { $0.range.lowerBound < $1.range.lowerBound }
        progress(.checking, 1, 1)
        let length = (output as NSString).length
        let limit = min(length, 200_000)
        return ScrubResult(format: "xml", output: Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<limit), marks: marks.filter { $0.range.upperBound <= limit }, truncated: length > limit), counts: job.counts, unresolved: unresolved)
    }
    static func parses(_ data: Data) -> Bool {
        guard let text = try? decodeXML(data), !unsafeDeclaration(in: text) else { return false }
        return (try? XMLDocument(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]))?.rootElement() != nil
    }
    private static func decodeXML(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { throw ScrubError.unsupported("invalid_xml") }
            return text
        }
        return try TextFile.decode(data)
    }
    // One left-to-right scan, like the parser's tokenizer: whichever construct
    // starts first owns the text, so "<!--" inside a processing instruction
    // cannot hide a later DOCTYPE. An unterminated construct falls through and
    // anything after it is still checked.
    private static func unsafeDeclaration(in text: String) -> Bool {
        let tokens = #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!\s*(DOCTYPE|ENTITY|ATTLIST|ELEMENT|NOTATION)\b"#
        return TextRanges.matches(tokens, in: text, options: [.caseInsensitive]).contains { $0.range(at: 1).location != NSNotFound }
    }
}
