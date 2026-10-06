import Foundation

/// The values a JSON document gives the pipeline, and the document written
/// again from what the pipeline made of them. A .json file is one; so is each
/// body written inside other text (a curl command's, a log line's), and a
/// string that holds a document of its own ("body": "{\"password\": …}") is
/// read as one inside the document around it, a few levels deep at most. Only
/// the tokens whose value changed are written again (see `JSONSource`).
final class JSONDocument {
    let source: JSONSource
    /// The leaf each string or number value went to, and each key, by path.
    private var valueIDs: [String: Int] = [:]
    private var keyIDs: [String: Int] = [:]
    /// Keys that name a field ("password"): a value written into one is
    /// replaced, but the name is never replaced whole for being the same word.
    private var fieldKeys: Set<String> = []
    /// Strings that hold a document of their own, by path, and those that hold one in base64.
    private var nested: [String: JSONDocument] = [:]
    private var encoded: Set<String> = []
    private static let deepest = 3

    private init(_ source: JSONSource) { self.source = source }

    /// What every document of one scrub shares: the leaves they add, the
    /// records they number, and the keys they write.
    final class Collector {
        private var items: [DocumentLeaf] = []
        /// Every value collected, each field's identifier decided across all its values (see `identifyColumns`).
        var leaves: [DocumentLeaf] {
            identifyColumns()
            return items
        }
        var names: [String] = []
        var nextRecord = 0

        /// `key`: what the text around a body calls it (`credentials = {…}`).
        func add(_ source: JSONSource, records: [Int] = [], key: String? = nil) -> JSONDocument {
            let document = JSONDocument(source)
            collect(document, source.root, key: key, path: "", records: records, keys: key.map { [$0] } ?? [], depth: 0)
            return document
        }
        /// A number no key names, kept until its whole field is read.
        private struct BareNumber {
            let document: JSONDocument
            let path: String
            let number: String
            let key: String?
            let records: [Int]
            let field: String
        }
        private var bareNumbers: [BareNumber] = []
        /// Every value each field writes, strings and numbers alike, and the strings' leaves.
        private var population: [String: [String]] = [:]
        private var fieldStrings: [String: [Int]] = [:]
        /// Each field's identifier, decided once across every value it writes, strings and numbers
        /// alike (see `Fields.column`): its strings take the decision, and its numbers no key named
        /// that pass the identifier's check become values to replace, written as numbers.
        private func identifyColumns() {
            guard !population.isEmpty else { return }
            defer { population = [:]; fieldStrings = [:]; bareNumbers = [] }
            let numbers = Dictionary(grouping: bareNumbers, by: \.field)
            for (field, values) in population {
                let recognizer = Fields.column(values)
                for index in fieldStrings[field] ?? [] { items[index].column = recognizer?.name ?? "" }
                guard let recognizer else { continue }
                for item in numbers[field] ?? [] where Recognizers.candidates(item.number).contains(where: { $0.name == recognizer.name }) {
                    item.document.valueIDs[item.path] = items.count
                    var leaf = DocumentLeaf(item.number, key: item.key, records: item.records, numericEntity: recognizer.entity)
                    leaf.field = item.field
                    items.append(leaf)
                }
            }
        }

        /// Keys whose value says what kind of thing a record's other values are ("type": "CPR").
        private static let kindKeys: Set<String> = ["type", "kind", "idtype", "idkind", "documenttype", "doctype", "documentkind", "identifiertype", "identificationtype", "identitytype", "scheme", "idscheme", "typecode", "category", "system"]
        /// `typed`: the words a record's own kind field writes, which name its other values as a key would.
        private func collect(_ document: JSONDocument, _ value: JSONValue, key: String?, path: String, records: [Int], keys: [String], depth: Int, listed: Bool = false, typed: Set<String> = []) {
            // Each kind of value read in its own frame: a document nested sixty levels deep recurses
            // through these, and only an object's reading needs a large one.
            switch value {
            case .object(let pairs): collectObject(document, pairs, key: key, path: path, records: records, keys: keys, depth: depth, listed: listed, typed: typed)
            case .array(let values): collectArray(document, values, key: key, path: path, records: records, keys: keys, depth: depth, typed: typed)
            case .string(let string): collectString(document, string, key: key, path: path, records: records, keys: keys, depth: depth, typed: typed)
            case .number(let number): collectNumber(document, number, key: key, path: path, records: records, keys: keys, typed: typed)
            default: break
            }
        }
        @inline(never)
        private func collectObject(_ document: JSONDocument, _ pairs: [(String, JSONValue)], key: String?, path: String, records: [Int], keys: [String], depth: Int, listed: Bool, typed: Set<String>) {
            names += pairs.map(\.0)
            // A record that says what its number is ({"type": "CPR", "number": "…"}) names it there.
            let kind = Set(pairs.flatMap { pair -> [String] in
                guard Self.kindKeys.contains(KeyHints.words(pair.0).joined()), let text = pair.1.stringValue, text.utf16.count <= 40 else { return [] }
                return KeyHints.words(text)
            })
            nextRecord += 1
            let ancestry = KeyHints.isWrapper(pairs.map(\.0)) && !records.isEmpty ? records : records + [nextRecord]
            let named = pairs.compactMap { pair in pair.1.stringValue.map { (pair.0, $0) } }
            for (index, pair) in pairs.enumerated() {
                let childPath = path + "/" + String(index)
                // A field's plain name ("password") is read for what a pattern or a value
                // found elsewhere writes in it ("quillharbor_token"); any other key as a value.
                let fieldName = KeyHints.isFieldName(pair.0) && !KeyHints.holdsData(pair.0)
                document.keyIDs[childPath] = items.count
                if fieldName { document.fieldKeys.insert(childPath) }
                items.append(DocumentLeaf(pair.0, fieldName: fieldName))
                var inherited: String?
                switch pair.1 {
                case .object, .array: inherited = KeyHints.namedField(pair.0, siblings: named) ?? KeyHints.resolveContainer(pair.0, parent: key, listed: listed)
                default: inherited = KeyHints.namedField(pair.0, siblings: named) ?? KeyHints.resolve(pair.0, parent: key, listed: listed, value: pair.1.stringValue)
                }
                if KeyHints.isBareName(pair.0), case .string(let name) = pair.1,
                   !KeyHints.bareNameIsPerson(name, siblings: pairs.map(\.0), parent: key) { inherited = nil }
                // The kind a record says reaches its own values, and through a slot ("number": {"value": …}, "number": […]) the values it wraps.
                let reaches: Bool
                switch pair.1 {
                case .object, .array: reaches = Self.isSlot(pair.0)
                default: reaches = true
                }
                collect(document, pair.1, key: inherited, path: childPath, records: ancestry, keys: keys + [pair.0], depth: depth,
                        typed: Self.kindKeys.contains(KeyHints.words(pair.0).joined()) || !reaches ? [] : kind.union(typed))
            }
        }
        @inline(never)
        private func collectArray(_ document: JSONDocument, _ values: [JSONValue], key: String?, path: String, records: [Int], keys: [String], depth: Int, typed: Set<String>) {
            let pair = JSONFile.coordinateKeys(key, values)
            for (index, child) in values.enumerated() {
                // Several names or emails in one list may be several people's; one is the record's own.
                collect(document, child, key: pair?[index] ?? key, path: path + "/" + String(index), records: values.count > 1 && KeyHints.hint(key).map({ ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME"].contains($0) }) == true ? [] : records, keys: keys, depth: depth, listed: true, typed: typed)
            }
        }
        @inline(never)
        private func collectString(_ document: JSONDocument, _ string: String, key: String?, path: String, records: [Int], keys: [String], depth: Int, typed: Set<String>) {
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // A body sent as a string, or as base64: its own document, read under the key that holds it.
            if depth < JSONDocument.deepest, let (text, base64) = Self.document(in: string), let inner = try? JSONSource.read(text), Self.holds(inner.root) {
                let child = JSONDocument(inner)
                document.nested[path] = child
                if base64 { document.encoded.insert(path) }
                collect(child, inner.root, key: key, path: "", records: records, keys: keys, depth: depth + 1,
                        typed: keys.last.map(Self.isSlot) ?? false ? typed : [])
                return
            }
            document.valueIDs[path] = items.count
            var leaf = DocumentLeaf(string, key: key, records: records, contextWords: Set(keys.flatMap { KeyHints.words($0) }))
            leaf.namingWords = Self.naming(keys, typed)
            leaf.field = keys.joined(separator: ".")
            population[leaf.field ?? "", default: []].append(leaf.seen)
            fieldStrings[leaf.field ?? "", default: []].append(items.count)
            items.append(leaf)
        }
        @inline(never)
        private func collectNumber(_ document: JSONDocument, _ number: String, key: String?, path: String, records: [Int], keys: [String], typed: Set<String>) {
            population[keys.joined(separator: "."), default: []].append(number)
            guard let entity = JSONFile.numericEntity(key: key, number: number, context: Self.naming(keys, typed)) else {
                if (7...20).contains(number.count), number.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    bareNumbers.append(BareNumber(document: document, path: path, number: number, key: key, records: records, field: keys.joined(separator: ".")))
                }
                return
            }
            document.valueIDs[path] = items.count
            var leaf = DocumentLeaf(number, key: key, records: records, numericEntity: entity)
            leaf.field = keys.joined(separator: ".")
            items.append(leaf)
        }
        /// Keys that only hold a value, naming nothing of their own ("number", "id_value").
        private static let slots: Set<String> = ["number", "num", "no", "nr", "value", "val", "id", "identifier", "ident", "code", "digits", "text", "data", "document", "doc"]
        /// The words that may name an identifier under `keys`: the innermost key's, and where it
        /// is only a slot, those of the keys around it and of its record's kind field. A batch
        /// number under "medicare" is a batch's; "medicare": {"number": …} is the card's.
        /// Outward from the innermost key, through slots, up to and with the nearest key that names something:
        /// "medicare": {"batch": {"number": …}} is the batch's number.
        /// The record's kind field names a value whose own key is a slot.
        static func naming(_ keys: [String], _ typed: Set<String>) -> Set<String> {
            var words: Set<String> = keys.last.map(isSlot) ?? true ? typed : []
            for key in keys.reversed() {
                words.formUnion(KeyHints.words(key))
                if !isSlot(key) { break }
            }
            return words
        }
        static func isSlot(_ key: String) -> Bool {
            let words = KeyHints.words(key)
            return !words.isEmpty && words.allSatisfy(slots.contains)
        }
        /// The document a string writes: itself when it opens as one, or what its base64 decodes to.
        private static func document(in string: String) -> (String, Bool)? {
            guard let first = string.first(where: { !$0.isWhitespace }) else { return nil }
            if first == "{" || first == "[" { return (string, false) }
            guard string.utf16.count >= 16, string.utf16.count % 4 == 0,
                  string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }),
                  let data = Data(base64Encoded: string), let text = String(data: data, encoding: .utf8) else { return nil }
            let opening = text.first(where: { !$0.isWhitespace })
            return opening == "{" || opening == "[" ? (text, true) : nil
        }
        private static func holds(_ value: JSONValue) -> Bool {
            switch value {
            case .object(let pairs): return !pairs.isEmpty
            case .array(let members): return !members.isEmpty
            default: return false
            }
        }
    }

    /// Each key's own long digits written as drawn (see `JSONFile.drawDigits`), in this document and those it holds.
    func writeKeyDigits(_ values: inout [DocumentValue], drawn: [String: String]) {
        guard !drawn.isEmpty else { return }
        for id in keyIDs.values { values[id] = JSONFile.rewritingOwnText(values[id]) { JSONFile.replaceDigits($0, drawn: drawn) } }
        for child in nested.values { child.writeKeyDigits(&values, drawn: drawn) }
    }

    /// `number` with each digit drawn again from `seed`, the first never a zero:
    /// its sign, point and exponent stay, so it is still a JSON number.
    static func numberShaped(like number: String, from seed: String) -> String {
        var state = seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        var output = "", first = true
        for character in number {
            guard character.isASCII, character.isNumber else { output.append(character); continue }
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var digit = Int(state >> 33) % 10
            if first, digit == 0, character != "0" { digit = 1 + Int(state >> 40) % 9 }
            if first, character == "0" { digit = 0 }
            output += String(digit)
            first = false
        }
        return output == number ? String(number.dropLast()) + String(((Int(String(number.last!)) ?? 0) + 1) % 10) : output
    }
    /// The document written with each changed token's new value, and the marks over them.
    func render(_ values: [DocumentValue]) -> (String, [Mark]) {
        var edits: [(range: Range<Int>, value: String, marks: [Mark])] = []
        func written(_ text: String, _ marks: [Mark], original: String) -> (String, [Mark])? {
            text == original && marks.isEmpty ? nil : OrderedJSON.quoted(text, marks: marks)
        }
        func walk(_ value: JSONValue, path: String) {
            switch value {
            case .object(let pairs):
                // A key written again as another's is set apart; two keys the input writes alike stay as written.
                let given = Set(pairs.map(\.0))
                var outputs: [String] = []
                for (index, pair) in pairs.enumerated() {
                    let childPath = path + "/" + String(index)
                    var key = pair.0, marks: [Mark] = []
                    if let id = keyIDs[childPath] {
                        let scrubbed = values[id]
                        let whole = scrubbed.marks.count == 1 && scrubbed.marks[0].range == 0..<(scrubbed.text as NSString).length
                        if !(fieldKeys.contains(childPath) && whole) { key = scrubbed.text; marks = scrubbed.marks }
                    }
                    var unique = key
                    if unique != pair.0 { while outputs.contains(unique) || given.contains(unique) { unique += "_" } }
                    outputs.append(unique)
                    if unique != key { marks = [] }
                    if let range = source.keys[childPath], let (text, placed) = written(unique, marks, original: pair.0) { edits.append((range, text, placed)) }
                    walk(pair.1, path: childPath)
                }
            case .array(let members):
                for (index, member) in members.enumerated() { walk(member, path: path + "/" + String(index)) }
            case .string(let string):
                guard let range = source.values[path] else { return }
                if let child = nested[path] {
                    let (inner, marks) = child.render(values)
                    if encoded.contains(path), inner != child.source.text {
                        // Written in base64 again: one mark over the whole, as what it holds can't be shown.
                        let text = OrderedJSON.quote(Data(inner.utf8).base64EncodedString())
                        edits.append((range, text, marks.first.map { [$0.moved(to: 1..<((text as NSString).length - 1))] } ?? []))
                    } else if !encoded.contains(path), inner != child.source.text || !marks.isEmpty {
                        let (text, placed) = OrderedJSON.quoted(inner, marks: marks); edits.append((range, text, placed))
                    }
                } else if let id = valueIDs[path], let (text, placed) = written(values[id].text, values[id].marks, original: string) {
                    edits.append((range, text, placed))
                }
            case .number(let number):
                guard let range = source.values[path], let id = valueIDs[path], values[id].text != number || !values[id].marks.isEmpty else { return }
                let text = values[id].text
                if TextRanges.matches(OrderedJSON.numberGrammar, in: text).isEmpty {
                    // A stand-in that is no number (a secret's) is written in the number's own shape instead.
                    let shaped = Self.numberShaped(like: number, from: text)
                    edits.append((range, shaped, values[id].marks.isEmpty ? [] : [values[id].marks[0].moved(to: 0..<(shaped as NSString).length)]))
                } else {
                    edits.append((range, text, values[id].marks))
                }
            default: break
            }
        }
        walk(source.root, path: "")
        guard !edits.isEmpty else { return (source.text, []) }
        // Inside a shell's quotes an apostrophe is written as the shell writes it; each mark's ends move by the apostrophes before them.
        if source.shell {
            edits = edits.map { edit in
                guard edit.value.contains("'") else { return edit }
                let apostrophes = edit.value.utf16.enumerated().filter { $0.element == 39 }.map(\.offset)
                func moved(_ at: Int) -> Int { at + 3 * apostrophes.filter { $0 < at }.count }
                let marks = edit.marks.map { $0.moved(to: moved($0.range.lowerBound)..<moved($0.range.upperBound)) }
                return (edit.range, edit.value.replacingOccurrences(of: "'", with: "'\\''"), marks)
            }
        }
        edits.sort { $0.range.lowerBound < $1.range.lowerBound }
        let (output, placed) = TextRanges.apply(edits.map { ($0.range, $0.value) }, to: source.text)
        let marks = zip(edits, placed).flatMap { edit, range in
            edit.marks.map { $0.moved(to: ($0.range.lowerBound + range.lowerBound)..<($0.range.upperBound + range.lowerBound)) }
        }
        return (output, marks)
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
}
