import Foundation

public enum XMLFile: FileFormat {
    public static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void) throws -> ScrubResult {
        try process(data, job: job, progress: progress, forceFullDetection: false)
    }
    static func process(_ data: Data, job: Job, progress: (Stage, Int, Int) -> Void, forceFullDetection: Bool) throws -> ScrubResult {
        let source = try decodeXML(data)
        let text = normalizedDeclaration(source)
        guard !unsafeDeclaration(in: text) else { throw ScrubError.unsupported("xml_doctype") }
        try XMLDepth.check(Data(text.utf8))
        let document: XMLDocument
        do { document = try XMLDocument(data: Data(text.utf8), options: XMLSerialization.parseOptions) }
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
        func walk(_ node: XMLNode, records: [Int], keys: [String], parentKey: String?) throws {
            try Scrubber.checkCancellation()
            if let element = node as? XMLElement {
                nextRecord += 1
                let childNames = (element.children ?? []).compactMap { ($0 as? XMLElement).flatMap { local($0.name) } }
                let ancestry = KeyHints.isWrapper(childNames) && !records.isEmpty ? records : records + [nextRecord]
                let currentKeys = keys + [local(element.name) ?? ""]
                let words = Set(currentKeys.flatMap { KeyHints.words($0) })
                // What the element's text is read as: its name, read under its
                // parent's key, or what a naming sibling says (<name>ssn</name><value>…).
                var elementKey = KeyHints.resolve(local(element.name), parent: parentKey)
                // A list's items take the list's key: <given><given>Anna</given></given>, <phones><item>…</item></phones>.
                if KeyHints.hint(elementKey) == nil, KeyHints.hint(parentKey) != nil, let name = local(element.name)?.lowercased(),
                   let container = keys.last?.lowercased(), name == container || container.hasPrefix(name) && container.count <= name.count + 2 || ["item", "entry", "element", "value", "li"].contains(name) {
                    elementKey = parentKey
                }
                // A point listed as two numbers: <coordinates><c>-122.44</c><c>47.25</c></coordinates>.
                if KeyHints.hint(elementKey) == "COORDINATES", let parent = element.parent as? XMLElement {
                    let items = (parent.children ?? []).compactMap { $0 as? XMLElement }
                    if let position = items.firstIndex(where: { $0 === element }),
                       let pair = JSONFile.coordinateKeys(parentKey, items.map { JSONValue.number(($0.stringValue ?? "").trimmingCharacters(in: .whitespaces)) }) {
                        elementKey = pair[position]
                    }
                }
                if let name = local(element.name), KeyHints.fieldValueKeys.contains(KeyHints.words(name).joined()) {
                    let siblingTexts: [(String, String)] = ((element.parent as? XMLElement)?.children ?? []).prefix(64).compactMap { node in
                        guard let sibling = node as? XMLElement, sibling !== element, sibling.childCount <= 1, let name = local(sibling.name) else { return nil }
                        return (name, sibling.stringValue ?? "")
                    }
                    elementKey = KeyHints.namedField(name, siblings: siblingTexts) ?? elementKey
                }
                func key(_ name: String?, resolved: String?, parent: String?, value: String?, siblings: @autoclosure () -> [String]) -> String? {
                    if KeyHints.isBareName(name), KeyHints.isBareName(resolved), let value, !KeyHints.bareNameIsPerson(value, siblings: siblings(), parent: parent) { return nil }
                    return resolved
                }
                func names(_ element: XMLElement?) -> [String] {
                    ((element?.attributes ?? []) + (element?.children ?? []).filter { $0 is XMLElement }).compactMap { local($0.name) }
                }
                addName(element, records: ancestry)
                for namespace in element.namespaces ?? [] {
                    addName(namespace, records: ancestry)
                    add(namespace, key: nil, records: ancestry, words: words)
                }
                for attribute in element.attributes ?? [] {
                    addName(attribute, records: ancestry)
                    let attributeTexts = (element.attributes ?? []).compactMap { a in local(a.name).map { ($0, a.stringValue ?? "") } }
                    let resolved = local(attribute.name).flatMap { KeyHints.namedField($0, siblings: attributeTexts) } ?? KeyHints.resolve(local(attribute.name), parent: elementKey)
                    add(attribute, key: key(local(attribute.name), resolved: resolved, parent: local(element.name), value: attribute.stringValue, siblings: names(element)), records: ancestry, words: words)
                }
                for child in element.children ?? [] {
                    if child is XMLElement { try walk(child, records: ancestry, keys: currentKeys, parentKey: elementKey) }
                    else {
                        if child.kind == .processingInstruction { addName(child, records: ancestry) }
                        // <attribute name="email">…</attribute> names its own text.
                        let attributeTexts = (element.attributes ?? []).compactMap { a in local(a.name).map { ($0, a.stringValue ?? "") } }
                        let named = attributeTexts.first { KeyHints.fieldNameKeys.contains(KeyHints.words($0.0).joined()) }.flatMap { KeyHints.header($0.1) }
                        add(child, key: child.kind == .text ? key(local(element.name), resolved: KeyHints.hint(elementKey) == nil ? named ?? elementKey : elementKey, parent: keys.last, value: child.stringValue, siblings: names(element.parent as? XMLElement)) : nil, records: records.isEmpty ? ancestry : records, words: words)
                    }
                }
            } else {
                if node.kind == .processingInstruction { addName(node, records: []) }
                add(node, key: nil, records: [], words: [])
            }
        }
        for child in document.children ?? [] { try walk(child, records: [], keys: [], parentKey: nil) }
        progress(.finding, 0, leaves.count)
        let values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection, progress: progress)
        let records = leaves.map(\.lastRecord)
        progress(.finding, leaves.count, leaves.count)
        // Element and attribute names first; then the values, written again whenever a review takes findings back.
        var markedValues: [(String, String)] = []
        progress(.checking, 0, 1)
        let originalNames = Set(namedNodes.compactMap(\.name))
        var usedNames = originalNames
        var renamedNames: [String: String] = [:]
        var prefixes: [String: String] = [:]
        func safeName(_ local: String, original: String, prefix: String? = nil) -> String {
            let candidate = prefix.map { $0 + ":" + local } ?? local
            guard candidate != original else { return original }
            var value = String(local.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
            if value.first.map({ !$0.isLetter && $0 != "_" }) ?? true { value = "n" + value }
            let base = value
            var qualified = prefix.map { $0 + ":" + value } ?? value
            var counter = 2
            while usedNames.contains(qualified) && qualified != original {
                value = base + String(counter)
                qualified = prefix.map { $0 + ":" + value } ?? value
                counter += 1
            }
            usedNames.insert(qualified)
            return qualified
        }
        func renamed(_ name: String, value: DocumentValue) -> String {
            var candidate = value.marks.isEmpty ? name : value.text
            let (numbered, _) = JSONFile.replaceDigits(candidate, job: job)
            candidate = numbered
            // In a fixed order: a stand-in drawn here, or one name's replacement
            // reaching into another's, must not follow a set's hash order.
            for person in (job.gazetteer["PERSON"] ?? []).sorted() {
                let parts = person.split(separator: " ")
                guard parts.count == 2 else { continue }
                let camel = String(parts[0]) + String(parts[1])
                let snake = parts.joined(separator: "_").lowercased()
                guard candidate.localizedCaseInsensitiveContains(camel) || candidate.localizedCaseInsensitiveContains(snake) else { continue }
                let fake = job.replacement(for: "PERSON", original: person).split(separator: " ").map { $0.filter { $0.isASCII && $0.isLetter } }
                guard fake.count == 2 else { continue }
                candidate = candidate.replacingOccurrences(of: camel, with: fake.joined(), options: .caseInsensitive)
                    .replacingOccurrences(of: snake, with: fake.joined(separator: "_").lowercased(), options: .caseInsensitive)
            }
            return candidate
        }
        for (index, node) in namedNodes.enumerated() where node.kind == .namespace {
            guard let name = node.name else { continue }
            let replacement = renamedNames[name] ?? safeName(renamed(name, value: values[nameIDs[index]]), original: name)
            renamedNames[name] = replacement
            if replacement != name { prefixes[name] = replacement; node.name = replacement; markedValues.append((replacement, "PERSON")) }
        }
        for (index, node) in namedNodes.enumerated() where node.kind != .namespace {
            guard let name = node.name else { continue }
            let pieces = name.split(separator: ":", maxSplits: 1).map(String.init)
            let candidate: String
            if let existing = renamedNames[name] {
                candidate = existing
            } else if pieces.count == 2 {
                let prefix = prefixes[pieces[0]] ?? pieces[0]
                let raw = renamed(name, value: values[nameIDs[index]])
                let local = raw.split(separator: ":").last.map(String.init) ?? raw
                candidate = safeName(local, original: name, prefix: prefix)
            } else {
                candidate = safeName(renamed(name, value: values[nameIDs[index]]), original: name)
            }
            renamedNames[name] = candidate
            if candidate != name { node.name = candidate; markedValues.append((candidate, "PERSON")) }
        }
        let nameMarks = markedValues
        func render(_ values: [DocumentValue], counts: [String: Int]) throws -> ScrubResult {
            var markedValues: [(String, String)] = []
            for (index, node) in nodes.enumerated() {
                let value = values[valueIDs[index]]
                if node.stringValue != value.text { node.stringValue = value.text }
                for mark in value.marks { markedValues.append((TextRanges.substring(value.text, mark.range), mark.entity)) }
            }
            markedValues += nameMarks
            let unresolved = values.flatMap(\.unresolved)
            var output = counts.isEmpty ? text : XMLSerialization.render(document)
            output = output.replacingOccurrences(of: #"^<\?xml(?=\s)[\s\S]*?\?>\s*"#, with: "", options: .regularExpression)
            if declarationEnd(in: source) != nil, let end = text.range(of: "?>") { output = String(text[..<end.upperBound]) + "\n" + output }
            guard try parses(Data(output.utf8)) else { throw ScrubError.unsupported("internal") }
            var marks: [Mark] = []
            for (value, entity) in markedValues where !value.isEmpty {
                for range in TextRanges.ranges(of: value, in: output, options: []) where !marks.contains(where: { $0.range.overlaps(range) }) { marks.append(Mark(range: range, entity: entity)) }
            }
            marks.sort { $0.range.lowerBound < $1.range.lowerBound }
            let length = (output as NSString).length
            let limit = min(length, 200_000)
            return ScrubResult(format: "xml", output: Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<limit), marks: marks.filter { $0.range.upperBound <= limit }, truncated: length > limit), counts: counts, unresolved: unresolved)
        }
        var result = try render(values, counts: job.counts)
        result.review = Review(values: values, counts: job.counts, records: records, render: render)
        progress(.checking, 1, 1)
        return result
    }
    static func parses(_ data: Data) throws -> Bool {
        guard let source = try? decodeXML(data) else { return false }
        let text = normalizedDeclaration(source)
        guard !unsafeDeclaration(in: text) else { return false }
        try XMLDepth.check(Data(text.utf8))
        guard let document = try? XMLDocument(data: Data(text.utf8), options: XMLSerialization.parseOptions) else { return false }
        return document.dtd == nil && document.rootElement() != nil
    }
    private static func declarationEnd(in text: String) -> String.Index? {
        let start = text.hasPrefix("\u{FEFF}") ? text.index(after: text.startIndex) : text.startIndex
        guard text[start...].range(of: #"^<\?xml(?=\s)[\s\S]*?\?>"#, options: .regularExpression)?.lowerBound == start else { return nil }
        return text[start...].range(of: "?>")?.upperBound
    }
    private static func normalizedDeclaration(_ text: String) -> String {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard let end = declarationEnd(in: source) else { return source }
        var declaration = String(source[..<end])
        let pattern = #"\bencoding\s*=\s*(['\"])[^'\"]*\1"#
        declaration = declaration.replacingOccurrences(of: pattern, with: "encoding=\"UTF-8\"", options: .regularExpression)
        return declaration + source[end...]
    }
    private static func decodeXML(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { throw ScrubError.unsupported("invalid_xml") }
            return text
        }
        return try TextFile.decode(data)
    }
    private static let comment = TextPattern(#"<!--[\s\S]*?-->"#)
    private static let declarationTokens = TextPattern(#"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!\s*(DOCTYPE|ENTITY|ATTLIST|ELEMENT|NOTATION)\b"#, options: [.caseInsensitive])
    private static func unsafeDeclaration(in text: String) -> Bool {
        for comment in TextRanges.matches(comment, in: text) {
            let content = TextRanges.substring(text, comment.range.location..<NSMaxRange(comment.range))
            if content.contains("?>") && content.range(of: #"<!\s*DOCTYPE\b"#, options: .regularExpression) != nil { return true }
        }
        return TextRanges.matches(declarationTokens, in: text).contains { $0.range(at: 1).location != NSNotFound }
    }
}
