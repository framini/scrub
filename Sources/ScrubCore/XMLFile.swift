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
        /// A value's element or attribute name and those beside it, for the span tagger.
        func reading(_ node: XMLNode) -> TaggerReading {
            let element = node.kind == .text ? node.parent : node
            let siblings = (element?.parent?.children ?? []).compactMap { local($0.name) }
            return .line(key: local(element?.name) ?? "", siblings: Array(siblings.prefix(15)))
        }
        /// `unsure`: a bare name written as a person's that nothing says is one (see `KeyHints.writtenAsName`).
        func add(_ node: XMLNode, key: String?, records: [Int], words: Set<String>, unsure: Bool = false) {
            guard let value = node.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            nodes.append([node])
            valueIDs.append(leaves.count)
            var leaf = DocumentLeaf(value, key: key, records: records, contextWords: words)
            leaf.unsureName = unsure
            leaf.reading = reading(node)
            leaves.append(leaf)
        }
        /// Text split by inline elements ("<i>Odal</i>ys Ferriter wrote…") read as one value: its
        /// pieces joined by `Visible.joint`, which detection reads through and stand-ins keep.
        func addJoined(_ texts: [XMLNode], key: String?, records: [Int], words: Set<String>, unsure: Bool = false) {
            let values = texts.map { $0.stringValue ?? "" }
            guard values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
            nodes.append(texts)
            valueIDs.append(leaves.count)
            var leaf = DocumentLeaf(values.joined(separator: Visible.joint), key: key, records: records, contextWords: words)
            leaf.unsureName = unsure
            leaf.reading = texts.first.map(reading)
            leaves.append(leaf)
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
                   let container = keys.last.map({ KeyHints.words($0).joined() }), name == container || container.hasPrefix(name) && container.count <= name.count + 2 || ["item", "entry", "element", "value", "li"].contains(name) {
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
                if KeyHints.hint(elementKey) == nil, let part = Self.namePart(element) { elementKey = part }
                // A card's or a document's expiry, and a birth's date or year, by the record around them (see `KeyHints.expiry`, `KeyHints.birthField`).
                if KeyHints.hint(elementKey) == nil, let name = local(element.name), let parent = element.parent as? XMLElement {
                    let siblings = (parent.children ?? []).compactMap { $0 as? XMLElement }.filter { $0 !== element }
                        .compactMap { sibling in local(sibling.name).map { ($0, (sibling.children ?? []).contains { $0 is XMLElement } ? "" : (sibling.stringValue ?? "")) } }
                    let kind = Set(siblings.filter { ["type", "kind", "object"].contains(KeyHints.words($0.0).joined()) }.flatMap { KeyHints.words($0.1) })
                    let text = (element.children ?? []).contains { $0 is XMLElement } ? nil : element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let expiry = KeyHints.expiry(name, siblings: siblings.map(\.0), parent: local(parent.name), kind: kind) { elementKey = expiry }
                    else if let born = KeyHints.birthField(name, value: text, siblings: siblings, kind: kind) { elementKey = born }
                }
                func key(_ name: String?, resolved: String?, parent: String?, value: String?, siblings: @autoclosure () -> [String], values: @autoclosure () -> [String] = []) -> String? {
                    if KeyHints.isBareName(name), KeyHints.isBareName(resolved), let value, !KeyHints.bareNameIsPerson(value, siblings: siblings(), parent: parent, values: values()) { return nil }
                    return resolved
                }
                // A bare name `key` found no one's, still written as a person's.
                func unsure(_ name: String?, key: String?, parent: String?, value: String?) -> Bool {
                    KeyHints.isBareName(name) && key == nil && value.map { KeyHints.writtenAsName($0.trimmingCharacters(in: .whitespacesAndNewlines), parent: parent) } == true
                }
                // The texts of an element's fields, beside its attributes' values: an email among them may spell a name there.
                func fieldTexts(_ element: XMLElement?) -> [String] {
                    ((element?.attributes ?? []).compactMap(\.stringValue)) + (element?.children ?? []).compactMap { child in
                        guard let child = child as? XMLElement, !(child.children ?? []).contains(where: { $0 is XMLElement }) else { return nil }
                        return child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
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
                    var resolved = local(attribute.name).flatMap { KeyHints.namedField($0, siblings: attributeTexts) } ?? KeyHints.resolve(local(attribute.name), parent: elementKey)
                    // A name's parts side by side as attributes (<subject fn="…" ln="…"/>).
                    if KeyHints.hint(resolved) == nil, let name = local(attribute.name), let part = KeyHints.nameParts(attributeTexts)[name] { resolved = part }
                    let attributeKey = key(local(attribute.name), resolved: resolved, parent: local(element.name), value: attribute.stringValue, siblings: names(element), values: fieldTexts(element))
                    add(attribute, key: attributeKey, records: ancestry, words: words, unsure: unsure(local(attribute.name), key: attributeKey, parent: local(element.name), value: attribute.stringValue))
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
                    let runKey = key(local(element.name), resolved: textKey, parent: keys.last, value: joined, siblings: names(element.parent as? XMLElement), values: fieldTexts(element.parent as? XMLElement))
                    addJoined(texts, key: runKey, records: textRecords, words: words, unsure: unsure(local(element.name), key: runKey, parent: keys.last, value: joined))
                }
                if let texts = Self.inline(element) {
                    readNames(within: element)
                    addRun(texts)
                    return
                }
                func read(_ child: XMLNode) throws {
                    if child is XMLElement { return try walk(child, records: ancestry, keys: currentKeys, parentKey: elementKey) }
                    if child.kind == .processingInstruction { addName(child, records: ancestry) }
                    let childKey = child.kind == .text ? key(local(element.name), resolved: textKey, parent: keys.last, value: child.stringValue, siblings: names(element.parent as? XMLElement), values: fieldTexts(element.parent as? XMLElement)) : nil
                    add(child, key: childKey, records: textRecords, words: words, unsure: child.kind == .text && unsure(local(element.name), key: childKey, parent: keys.last, value: child.stringValue))
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
        // A name's own long digits ("order_48213907") are drawn first, namespaces
        // first, as any value's: the same number written in a value is then theirs.
        let order = namedNodes.indices.filter { namedNodes[$0].kind == .namespace } + namedNodes.indices.filter { namedNodes[$0].kind != .namespace }
        let drawn = JSONFile.drawDigits(order.map { leaves[nameIDs[$0]].text }, job: job)
        var values = try DocumentPipeline.run(leaves, job: job, forceFullDetection: forceFullDetection, progress: progress)
        let records = leaves.map(\.lastRecord)
        progress(.finding, leaves.count, leaves.count)
        progress(.checking, 0, 1)
        // An element's or an attribute's name, read as a value: its own long digits,
        // as drawn above, and a person's name written into it ("OdalysFerriter",
        // "odalys_ferriter") are replaced here, once, namespaces first; each writing of the file then
        // names the node from the value as edits and choices leave it. A name so
        // written is a handle of its person's, so their edits and a person keeping
        // it as written reach it.
        var rewritten: [String: (String, [Mark])] = [:]
        func rewrite(_ own: String) -> (String, [Mark]) {
            if let known = rewritten[own] { return known }
            let (digits, numbers) = JSONFile.replaceDigits(own, drawn: drawn)
            var candidate = digits as NSString
            var marks = numbers
            // In a fixed order: a stand-in drawn here, or one name's replacement
            // reaching into another's, must not follow a set's hash order.
            for person in (job.gazetteer["PERSON"] ?? []).sorted() {
                let parts = person.split(separator: " ")
                guard parts.count == 2 else { continue }
                let camel = String(parts[0]) + String(parts[1])
                let snake = parts.joined(separator: "_").lowercased()
                guard (candidate as String).localizedCaseInsensitiveContains(camel) || (candidate as String).localizedCaseInsensitiveContains(snake) else { continue }
                let fake = job.replacement(for: "PERSON", original: person).split(separator: " ").map { $0.filter { $0.isASCII && $0.isLetter } }
                guard fake.count == 2 else { continue }
                for (form, written) in [(camel, fake.joined()), (snake, fake.joined(separator: "_").lowercased())] {
                    var from = 0
                    while from < candidate.length {
                        let found = candidate.range(of: form, options: .caseInsensitive, range: NSRange(location: from, length: candidate.length - from))
                        guard found.location != NSNotFound else { break }
                        let original = candidate.substring(with: found)
                        _ = job.variant(original, fake: written, entity: "USERNAME", source: person)
                        candidate = candidate.replacingCharacters(in: found, with: written) as NSString
                        let range = found.location..<(found.location + (written as NSString).length)
                        // Earlier marks after it move with it.
                        marks = marks.map { $0.range.lowerBound >= found.location + found.length ? $0.moved(to: ($0.range.lowerBound + range.count - found.length)..<($0.range.upperBound + range.count - found.length)) : $0 }
                        marks.append(Mark(range: range, entity: "USERNAME", original: original))
                        from = range.upperBound
                    }
                }
            }
            let made = (candidate as String, marks.sorted { $0.range.lowerBound < $1.range.lowerBound })
            rewritten[own] = made
            return made
        }
        for index in order { values[nameIDs[index]] = JSONFile.rewritingOwnText(values[nameIDs[index]], with: rewrite) }
        let originalNames = namedNodes.map(\.name)
        let takenNames = Set(originalNames.compactMap { $0 })
        /// Each node named from its value as `values` write it: a valid XML name
        /// no other node holds, or its own name where the value is as written.
        func name(_ values: [DocumentValue]) -> [(String, String, Bool)] {
            var marked: [(String, String, Bool)] = []
            var usedNames = takenNames
            // The local names of the nodes renamed: what a repaired name may never become.
            let renamedOriginals = Set(order.compactMap { index in
                originalNames[index].flatMap { name in values[nameIDs[index]].text == name ? nil : (name.split(separator: ":").last.map(String.init) ?? name).lowercased() }
            })
            var renamedNames: [String: String] = [:]
            var prefixes: [String: String] = [:]
            func safeName(_ local: String, original: String, prefix: String? = nil) -> String {
                let candidate = prefix.map { $0 + ":" + local } ?? local
                guard candidate != original else { return original }
                let squeezed = Review.squeezed(local)
                let own = (original.split(separator: ":").last.map(String.init) ?? original).lowercased()
                // What a name is made valid or told apart with never spells an original:
                // "123" for <n123> is not written <n123>, nor "n12" beside an <n12> as <n123>.
                func safe(_ value: String) -> Bool {
                    let folded = value.lowercased()
                    return !(folded.contains(own) && !squeezed.lowercased().contains(own)) && !renamedOriginals.contains(folded)
                }
                let starts = squeezed.first.map({ !$0.isLetter && $0 != "_" }) ?? true ? ["n", "x", "v", "k", "q"].map { $0 + squeezed } : [squeezed]
                var counter = 1
                while true {
                    for base in starts {
                        let value = counter == 1 ? base : base + String(counter)
                        let qualified = prefix.map { $0 + ":" + value } ?? value
                        guard !usedNames.contains(qualified), safe(value) else { continue }
                        usedNames.insert(qualified)
                        return qualified
                    }
                    counter += 1
                }
            }
            for index in order {
                let node = namedNodes[index], value = values[nameIDs[index]]
                guard let name = originalNames[index] else { continue }
                // One name written the same way is one name, wherever it stands.
                let seen = name + "\u{0}" + value.text
                let replacement: String
                if let known = renamedNames[seen] {
                    replacement = known
                } else if node.kind == .namespace {
                    replacement = safeName(value.text, original: name)
                } else if let colon = name.firstIndex(of: ":") {
                    let prefix = String(name[..<colon])
                    let local = value.text.split(separator: ":").last.map(String.init) ?? value.text
                    replacement = safeName(local, original: name, prefix: prefixes[prefix] ?? prefix)
                } else {
                    replacement = safeName(value.text, original: name)
                }
                renamedNames[seen] = replacement
                if replacement != name {
                    if node.kind == .namespace { prefixes[name] = replacement }
                    // Each stand-in as the name writes it, so a click on one reaches its finding.
                    let pieces = value.marks.map { (Review.squeezed(TextRanges.substring(value.text, $0.range)), $0.entity, $0.byHand) }
                        .filter { !$0.0.isEmpty && replacement.contains($0.0) }
                    let mark = value.marks.first
                    marked += pieces.isEmpty ? [(replacement, mark?.entity ?? "PERSON", mark?.byHand ?? false)] : pieces
                }
                if node.name != replacement { node.name = replacement }
            }
            return marked
        }
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
            markedValues += name(values)
            let unresolved = values.flatMap(\.unresolved)
            let output = counts.isEmpty ? text : keepingLayout(of: text, in: XMLSerialization.render(document))
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
        result.review = Review(values: values, counts: job.counts, records: records, people: job.personLinks(), squeezed: Set(nameIDs), render: render)
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
    /// What a <first>, <last>, <given>, <middle> or <family> element is read as
    /// when it holds part of a name ("<person><first>Odalys</first><last>Ferriter</last>"):
    /// its value is written as a name, and its record is a person's, it sits
    /// beside the other part written as a name, or the value is a known name.
    /// Elsewhere (`<first>true</first>`, `<first>2024-01-01</first>`) it is no name.
    static func namePart(_ element: XMLElement) -> String? {
        func local(_ name: String?) -> String? { name?.split(separator: ":").last.map(String.init) }
        func part(_ element: XMLElement) -> String? {
            local(element.name).flatMap { KeyHints.hint($0) == nil ? KeyHints.namePartKey($0) : nil }
        }
        func value(_ element: XMLElement) -> String? {
            guard element.childCount == 1, element.children?.first?.kind == .text else { return nil }
            let value = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let words = value.split(separator: " ")
            guard (1...3).contains(words.count), words.allSatisfy({ word in
                word.first?.isUppercase == true && word.allSatisfy { $0.isLetter || "'’.-".contains($0) }
                    && !NameShape.months.contains(word.lowercased()) && !NameShape.weekdays.contains(word.lowercased())
            }), KeyHints.fits("first_name", value) else { return nil }
            return value
        }
        guard let own = part(element), let written = value(element), let parent = element.parent as? XMLElement else { return nil }
        let siblings = (parent.children ?? []).compactMap { $0 as? XMLElement }.filter { $0 !== element }
        if KeyHints.isPersonsRecord(siblings: siblings.compactMap { local($0.name) }, parent: local(parent.name)) { return own }
        if siblings.contains(where: { sibling in part(sibling).map { $0 != own } == true && value(sibling) != nil }) { return own }
        let known = written.lowercased().split { !$0.isLetter }.contains { Names.firstFolded.contains(String($0)) || Names.lastFolded.contains(String($0)) }
        return known ? own : nil
    }
    static func parses(_ data: Data) throws -> Bool {
        guard let source = try? decodeXML(data) else { return false }
        let text = normalizedDeclaration(source)
        guard !unsafeDeclaration(in: text) else { return false }
        try XMLDepth.check(Data(text.utf8))
        guard let document = try? XMLDocument(data: Data(text.utf8), options: XMLSerialization.parseOptions) else { return false }
        return document.dtd == nil && document.rootElement() != nil
    }
    /// The rendered document with the source's own text around its root: the
    /// declaration as written, the space, line breaks and final newline
    /// between the comments and instructions before and after the root, which
    /// rendering drops, and CR LF line ends. Those comments and instructions are the rendered ones,
    /// replaced as any value is. Rendered as is when the two don't line up.
    static func keepingLayout(of source: String, in rendered: String) -> String {
        guard let original = outside(source), let made = outside(rendered) else { return rendered }
        let declared = { (token: Substring) in token.hasPrefix("<?xml") && token.dropFirst(5).first.map { $0.isWhitespace } == true }
        func nodes(_ tokens: [Substring]) -> [Substring] { tokens.filter { !$0.first!.isWhitespace && !declared($0) } }
        guard nodes(original.before).count == nodes(made.before).count, nodes(original.after).count == nodes(made.after).count else { return rendered }
        func rebuild(_ tokens: [Substring], from rendered: [Substring]) -> String {
            var next = nodes(rendered).makeIterator()
            return tokens.map { $0.first!.isWhitespace || declared($0) ? String($0) : String(next.next()!) }.joined()
        }
        // A parser reads every line break as a line feed: a file that ends its lines with CR LF gets them back.
        let feeds = source.utf8.lazy.filter { $0 == 10 }.count
        let crlf = feeds > 0 && source.components(separatedBy: "\r\n").count - 1 == feeds
        let root = crlf ? rendered[made.root].replacingOccurrences(of: "(?<!\r)\n", with: "\r\n", options: .regularExpression) : String(rendered[made.root])
        return rebuild(original.before, from: made.before) + root + rebuild(original.after, from: made.after)
    }
    /// A document's text before and after its root element, as runs of space,
    /// comments and instructions, and the root's own range; nil if anything else is there.
    private static func outside(_ text: String) -> (before: [Substring], root: Range<String.Index>, after: [Substring])? {
        var start = text.startIndex, end = text.endIndex
        var before: [Substring] = [], after: [Substring] = []
        while start < end, text[start] != "<" || text[start...].hasPrefix("<!--") || text[start...].hasPrefix("<?") {
            let tail = text[start...]
            let stop: String.Index?
            if tail.first!.isWhitespace { stop = tail.firstIndex { !$0.isWhitespace } ?? end }
            else if tail.hasPrefix("<!--") { stop = tail.range(of: "-->")?.upperBound }
            else if tail.hasPrefix("<?") { stop = tail.range(of: "?>")?.upperBound }
            else { return nil }
            guard let stop else { return nil }
            before.append(text[start..<stop])
            start = stop
        }
        while end > start {
            let head = text[start..<end]
            let from: String.Index?
            if head.last!.isWhitespace { from = head.lastIndex { !$0.isWhitespace }.map { text.index(after: $0) } ?? start }
            else if head.hasSuffix("-->") { from = head.range(of: "<!--", options: .backwards)?.lowerBound }
            else if head.hasSuffix("?>") { from = head.range(of: "<?", options: .backwards)?.lowerBound }
            else { break }
            guard let from, from > start else { return nil }
            after.insert(text[from..<end], at: 0)
            end = from
        }
        guard start < end, text[start] == "<", text[text.index(before: end)] == ">" else { return nil }
        return (before, start..<end, after)
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
