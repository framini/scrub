import Foundation

public enum XMLFile: FileFormat {
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        let source = try decodeXML(data)
        let text = normalizedDeclaration(source)
        guard !unsafeDeclaration(in: text) else { throw ScrubError.unsupported("xml_doctype") }
        let document: XMLDocument
        do { document = try XMLDocument(data: Data(text.utf8), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]) }
        catch { throw ScrubError.unsupported("invalid_xml") }
        guard document.dtd == nil else { throw ScrubError.unsupported("xml_doctype") }
        guard document.rootElement() != nil else { throw ScrubError.unsupported("invalid_xml") }
        var leaves: [DocumentLeaf] = []
        var nodes: [XMLNode] = []
        var valueIDs: [Int] = []
        var namedNodes: [XMLNode] = []
        var nameIDs: [Int] = []
        var nextRecord = 0
        func local(_ name: String?) -> String? { name?.split(separator: ":").last.map(String.init) }
        func add(_ node: XMLNode, key: String?, records: [Int], words: Set<String>) {
            guard let value = node.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            nodes.append(node)
            valueIDs.append(leaves.count)
            leaves.append(DocumentLeaf(value, key: key, records: records, contextWords: words))
        }
        func addName(_ node: XMLNode, records: [Int]) {
            guard let name = node.name else { return }
            namedNodes.append(node)
            nameIDs.append(leaves.count)
            leaves.append(DocumentLeaf(name, records: records))
        }
        func walk(_ node: XMLNode, records: [Int], keys: [String]) throws {
            try Scrubber.checkCancellation()
            if let element = node as? XMLElement {
                nextRecord += 1
                let ancestry = records + [nextRecord]
                let currentKeys = keys + [local(element.name) ?? ""]
                let words = Set(currentKeys.flatMap { KeyHints.words($0) })
                addName(element, records: ancestry)
                for namespace in element.namespaces ?? [] { add(namespace, key: nil, records: ancestry, words: words) }
                for attribute in element.attributes ?? [] {
                    addName(attribute, records: ancestry)
                    add(attribute, key: local(attribute.name), records: ancestry, words: words)
                }
                for child in element.children ?? [] {
                    if child is XMLElement { try walk(child, records: ancestry, keys: currentKeys) }
                    else {
                        if child.kind == .processingInstruction { addName(child, records: ancestry) }
                        add(child, key: child.kind == .text ? local(element.name) : nil, records: records.isEmpty ? ancestry : records, words: words)
                    }
                }
            } else {
                if node.kind == .processingInstruction { addName(node, records: []) }
                add(node, key: nil, records: [], words: [])
            }
        }
        for child in document.children ?? [] { try walk(child, records: [], keys: []) }
        progress(.finding, 0, leaves.count)
        let values = try DocumentPipeline.run(leaves, job: job)
        progress(.finding, leaves.count, leaves.count)
        var markedValues: [(String, String)] = []
        for (index, node) in nodes.enumerated() {
            let value = values[valueIDs[index]]
            node.stringValue = value.text
            for mark in value.marks { markedValues.append((TextRanges.substring(value.text, mark.range), mark.entity)) }
        }
        let unresolved = values.flatMap(\.unresolved)
        progress(.checking, 0, 1)
        for (index, node) in namedNodes.enumerated() {
            guard let name = node.name else { continue }
            let value = values[nameIDs[index]]
            let clean = value.marks.isEmpty ? name : value.text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_.:-".contains($0)) }
            let (numbered, digitMarks) = JSONFile.replaceDigits(clean, job: job)
            var renamed = numbered
            for person in job.gazetteer["PERSON"] ?? [] {
                let parts = person.split(separator: " ")
                guard parts.count == 2 else { continue }
                let camel = String(parts[0]) + String(parts[1])
                let snake = parts.joined(separator: "_").lowercased()
                guard renamed.localizedCaseInsensitiveContains(camel) || renamed.localizedCaseInsensitiveContains(snake) else { continue }
                let fake = job.replacement(for: "PERSON", original: person).split(separator: " ").map { $0.filter { $0.isASCII && $0.isLetter } }
                guard fake.count == 2 else { continue }
                renamed = renamed.replacingOccurrences(of: camel, with: fake.joined(), options: .caseInsensitive)
                    .replacingOccurrences(of: snake, with: fake.joined(separator: "_").lowercased(), options: .caseInsensitive)
            }
            if renamed != name {
                node.name = renamed
                for mark in digitMarks { markedValues.append((TextRanges.substring(renamed, mark.range), mark.entity)) }
                if digitMarks.isEmpty { markedValues.append((renamed, "PERSON")) }
            }
        }
        var output = document.xmlString(options: [.nodePreserveAll])
        output = output.replacingOccurrences(of: #"^<\?xml[\s\S]*?\?>\s*"#, with: "", options: .regularExpression)
        if source.hasPrefix("<?xml"), let end = text.range(of: "?>") { output = String(text[..<end.upperBound]) + "\n" + output }
        guard parses(Data(output.utf8)) else { throw ScrubError.unsupported("internal") }
        var marks: [Mark] = []
        for (value, entity) in markedValues where !value.isEmpty {
            for range in TextRanges.ranges(of: value, in: output, options: []) where !marks.contains(where: { $0.range.overlaps(range) }) { marks.append(Mark(range: range, entity: entity)) }
        }
        marks.sort { $0.range.lowerBound < $1.range.lowerBound }
        progress(.checking, 1, 1)
        let length = (output as NSString).length
        let limit = min(length, 200_000)
        return ScrubResult(format: "xml", output: Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<limit), marks: marks.filter { $0.range.upperBound <= limit }, truncated: length > limit), counts: job.counts, unresolved: unresolved)
    }
    static func parses(_ data: Data) -> Bool {
        guard let source = try? decodeXML(data) else { return false }
        let text = normalizedDeclaration(source)
        guard !unsafeDeclaration(in: text), let document = try? XMLDocument(data: Data(text.utf8), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]) else { return false }
        return document.dtd == nil && document.rootElement() != nil
    }
    private static func normalizedDeclaration(_ text: String) -> String {
        let text = text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else { return text }
        var declaration = String(text[..<end.upperBound])
        let pattern = #"\bencoding\s*=\s*(['\"])[^'\"]*\1"#
        declaration = declaration.replacingOccurrences(of: pattern, with: "encoding=\"UTF-8\"", options: .regularExpression)
        return declaration + text[end.upperBound...]
    }
    private static func decodeXML(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { throw ScrubError.unsupported("invalid_xml") }
            return text
        }
        return try TextFile.decode(data)
    }
    private static func unsafeDeclaration(in text: String) -> Bool {
        for comment in TextRanges.matches(#"<!--[\s\S]*?-->"#, in: text) {
            let content = TextRanges.substring(text, comment.range.location..<NSMaxRange(comment.range))
            if content.contains("?>") && content.range(of: #"<!\s*DOCTYPE\b"#, options: .regularExpression) != nil { return true }
        }
        let tokens = #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!\s*(DOCTYPE|ENTITY|ATTLIST|ELEMENT|NOTATION)\b"#
        return TextRanges.matches(tokens, in: text, options: [.caseInsensitive]).contains { $0.range(at: 1).location != NSNotFound }
    }
}
