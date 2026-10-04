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
        // Each value's nodes: one, or the text nodes of an element with inline elements, read as one (see `inline`).
        var nodes: [[XMLNode]] = []
        var valueIDs: [Int] = []
        var namedNodes: [XMLNode] = []
        var nameIDs: [Int] = []
        var nextRecord = 0
        func local(_ name: String?) -> String? { name?.split(separator: ":").last.map(String.init) }
        func add(_ node: XMLNode, key: String?, records: [Int], words: Set<String>) {
            guard let value = node.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            nodes.append([node])
            valueIDs.append(leaves.count)
            leaves.append(DocumentLeaf(value, key: key, records: records, contextWords: words))
        }
        /// Text split by inline elements ("<i>Odal</i>ys Ferriter wrote…") read as one value: its
        /// pieces joined by `Visible.joint`, which detection reads through and stand-ins keep.
        func addJoined(_ texts: [XMLNode], key: String?, records: [Int], words: Set<String>) {
            let values = texts.map { $0.stringValue ?? "" }
            guard values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
            nodes.append(texts)
            valueIDs.append(leaves.count)
            leaves.append(DocumentLeaf(values.joined(separator: Visible.joint), key: key, records: records, contextWords: words))
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
                elementKey = Self.labelledField(element) ?? elementKey
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
                // The inline elements' names and attributes are read as any; their text with the element's.
                func readNames(within node: XMLNode) {
                    for child in node.children ?? [] {
                        guard let inner = child as? XMLElement else {
                            if child.kind == .comment || child.kind == .processingInstruction {
                                if child.kind == .processingInstruction { addName(child, records: ancestry) }
                                add(child, key: nil, records: ancestry, words: words)
                            }
                            continue
                        }
                        readInline(inner)
                    }
                }
                func readInline(_ inner: XMLElement) {
                    addName(inner, records: ancestry)
                    for attribute in inner.attributes ?? [] {
                        addName(attribute, records: ancestry)
                        add(attribute, key: KeyHints.resolve(local(attribute.name), parent: elementKey), records: ancestry, words: words)
                    }
                    readNames(within: inner)
                }
                // <attribute name="email">…</attribute> names its own text.
                let attributeTexts = (element.attributes ?? []).compactMap { a in local(a.name).map { ($0, a.stringValue ?? "") } }
                let named = attributeTexts.first { KeyHints.fieldNameKeys.contains(KeyHints.words($0.0).joined()) }.flatMap { KeyHints.header($0.1) }
                let textKey = KeyHints.hint(elementKey) == nil ? named ?? elementKey : elementKey
                let textRecords = records.isEmpty ? ancestry : records
                func addRun(_ texts: [XMLNode]) {
                    let joined = texts.map { $0.stringValue ?? "" }.joined()
                    addJoined(texts, key: key(local(element.name), resolved: textKey, parent: keys.last, value: joined, siblings: names(element.parent as? XMLElement)), records: textRecords, words: words)
                }
                if let texts = Self.inline(element) {
                    readNames(within: element)
                    addRun(texts)
                    return
                }
                func read(_ child: XMLNode) throws {
                    if child is XMLElement { return try walk(child, records: ancestry, keys: currentKeys, parentKey: elementKey) }
                    if child.kind == .processingInstruction { addName(child, records: ancestry) }
                    add(child, key: child.kind == .text ? key(local(element.name), resolved: textKey, parent: keys.last, value: child.stringValue, siblings: names(element.parent as? XMLElement)) : nil, records: textRecords, words: words)
                }
                // Text beside fields: each run of it between them is read as one with
                // the formatting inside it ("Spoke with <i>Odal</i>ys … <password>…"),
                // and each field under its own name.
                var run: [XMLNode] = [], texts: [XMLNode] = []
                func flush() throws {
                    defer { run = []; texts = [] }
                    let own = run.contains { $0.kind == .text && !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if own, texts.count > 1, texts.count <= 512, run.contains(where: { $0 is XMLElement }) {
                        for case let inner as XMLElement in run { readInline(inner) }
                        addRun(texts)
                    } else {
                        for node in run { try read(node) }
                    }
                }
                for child in element.children ?? [] {
                    if let inner = child as? XMLElement, !Self.namesField(inner), let inside = Self.texts(in: inner, depth: 1) {
                        run.append(inner)
                        texts += inside
                    } else if child.kind == .text, !(child.stringValue ?? "").contains(Visible.joint) {
                        run.append(child)
                        texts.append(child)
                    } else {
                        try flush()
                        try read(child)
                    }
                }
                try flush()
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
            var markedValues: [(String, String, Bool)] = []
            for (index, group) in nodes.enumerated() {
                let value = values[valueIDs[index]]
                if group.count == 1 {
                    if group[0].stringValue != value.text { group[0].stringValue = value.text }
                } else {
                    // Parted where they were joined; were a joint ever lost, the text goes whole into the first piece.
                    let pieces = value.text.components(separatedBy: Visible.joint)
                    let written = pieces.count == group.count ? pieces : [pieces.joined()] + Array(repeating: "", count: group.count - 1)
                    for (node, piece) in zip(group, written) where node.stringValue != piece { node.stringValue = piece }
                }
                for mark in value.marks { markedValues.append((TextRanges.substring(value.text, mark.range).replacingOccurrences(of: Visible.joint, with: ""), mark.entity, mark.byHand)) }
            }
            markedValues += nameMarks.map { ($0.0, $0.1, false) }
            let unresolved = values.flatMap(\.unresolved)
            var output = counts.isEmpty ? text : XMLSerialization.render(document)
            output = output.replacingOccurrences(of: #"^<\?xml(?=\s)[\s\S]*?\?>\s*"#, with: "", options: .regularExpression)
            if declarationEnd(in: source) != nil, let end = text.range(of: "?>") { output = String(text[..<end.upperBound]) + "\n" + output }
            guard try parses(Data(output.utf8)) else { throw ScrubError.unsupported("internal") }
            var marks: [Mark] = []
            for (value, entity, byHand) in markedValues where !value.isEmpty {
                for range in TextRanges.ranges(of: value, in: output, options: []) where !marks.contains(where: { $0.range.overlaps(range) }) { marks.append(Mark(range: range, entity: entity, byHand: byHand)) }
            }
            marks.sort { $0.range.lowerBound < $1.range.lowerBound }
            let length = (output as NSString).length
            let limit = min(length, 200_000)
            return ScrubResult(format: "xml", output: Data(output.utf8), preview: .text(TextRanges.substring(output, 0..<limit), marks: marks.filter { $0.range.upperBound <= limit }, truncated: length > limit), counts: counts, unresolved: unresolved)
        }
        var result = try render(values, counts: job.counts)
        result.review = Review(values: values, counts: job.counts, records: records, people: job.personLinks(), render: render)
        progress(.checking, 1, 1)
        return result
    }
    /// The text nodes of an element whose text runs around inline elements
    /// ("<note><i>Oda</i>lys Ferriter wrote…</note>", "<name><b>Odal</b>ys</name>"),
    /// in document order; nil for any other element. It holds text of its own
    /// beside its elements, and those hold only text and such elements, a few
    /// levels deep, so a record's fields (<first>, <last> under <person>) are
    /// each still read under their own name. So is a field beside text of
    /// the record's own ("<account>Active<password>…</password></account>"):
    /// only formatting and elements that name no field are read through. Then
    /// each run of text between the fields is read whole on its own instead.
    static func inline(_ element: XMLElement) -> [XMLNode]? {
        let children = element.children ?? []
        guard children.contains(where: { $0 is XMLElement }),
              children.contains(where: { $0.kind == .text && !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let texts = texts(in: element, depth: 0), texts.count > 1 else { return nil }
        return texts
    }
    /// The text nodes inside an element, in document order, when it holds
    /// only text and elements that name no field, at most four levels down
    /// from `depth`; nil otherwise.
    static func texts(in element: XMLElement, depth: Int) -> [XMLNode]? {
        var texts: [XMLNode] = []
        func collect(_ node: XMLNode, depth: Int) -> Bool {
            guard depth <= 4 else { return false }
            for child in node.children ?? [] {
                if let inner = child as? XMLElement {
                    guard !namesField(inner), collect(inner, depth: depth + 1) else { return false }
                } else if child.kind == .text {
                    // A text that already holds a joint could not be parted again.
                    guard !(child.stringValue ?? "").contains(Visible.joint) else { return false }
                    texts.append(child)
                }
                if texts.count > 512 { return false }
            }
            return true
        }
        return collect(element, depth: depth) ? texts : nil
    }
    /// Elements that format a run of text, which a word may be split across.
    private static let phrasing: Set<String> = ["a", "abbr", "b", "bdi", "bdo", "big", "br", "cite", "code", "data", "del", "dfn", "em", "emphasis", "font", "i", "ins", "kbd",
                                                "mark", "q", "s", "samp", "small", "span", "strike", "strong", "sub", "sup", "time", "tt", "u", "var", "wbr"]
    /// Whether an element names a field of its own, which keeps its own key
    /// whatever text sits beside it: an attribute says what it holds
    /// (<field name="ssn">, <data key="password">, even on formatting), or
    /// its name does ("password", "nationalId", "customer_id", "manager"),
    /// or an element beside it does (<name>ssn</name><value>…</value>), as
    /// it would with no text around. Formatting with none of these never does.
    static func namesField(_ element: XMLElement) -> Bool {
        guard let name = element.name?.split(separator: ":").last.map(String.init) else { return false }
        let named = (element.attributes ?? []).contains { attribute in
            guard let key = attribute.name?.split(separator: ":").last.map(String.init) else { return false }
            return KeyHints.fieldNameKeys.contains(KeyHints.words(key).joined()) && KeyHints.header(attribute.stringValue ?? "") != nil
        }
        if named || labelledField(element) != nil { return true }
        if phrasing.contains(name.lowercased()) { return false }
        // A bare <name> in a sentence ("Ms <name>Brisa V…</name> called") names a product as
        // often as a person, so it is read with the words around it, which tell which; under
        // a record of a person ("<customer>Active<name>…") it is that person's, as it is anywhere.
        if KeyHints.isBareName(name) {
            guard let parent = element.parent as? XMLElement, let parentName = parent.name?.split(separator: ":").last.map(String.init) else { return false }
            let siblings = ((parent.attributes ?? []) + (parent.children ?? []).filter { $0 is XMLElement && $0 !== element }).compactMap { $0.name?.split(separator: ":").last.map(String.init) }
            return KeyHints.isPersonsRecord(siblings: siblings, parent: parentName)
        }
        return KeyHints.hint(name) != nil || RecordIDs.isPersonKey(name) || KeyHints.isRole(name)
    }
    /// The field a value element stands for when an element beside it names
    /// it (<name>ssn</name><value>…</value>, <value>…</value><key>password</key>),
    /// read the same whether or not the record holds text of its own.
    static func labelledField(_ element: XMLElement) -> String? {
        func local(_ name: String?) -> String? { name?.split(separator: ":").last.map(String.init) }
        guard let name = local(element.name), KeyHints.fieldValueKeys.contains(KeyHints.words(name).joined()) else { return nil }
        let siblings: [(String, String)] = ((element.parent as? XMLElement)?.children ?? []).prefix(64).compactMap { node in
            guard let sibling = node as? XMLElement, sibling !== element, sibling.childCount <= 1, let name = local(sibling.name) else { return nil }
            return (name, sibling.stringValue ?? "")
        }
        return KeyHints.namedField(name, siblings: siblings)
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
