import Foundation

/// The last word on a person's record: a value beside a person Scrub found
/// (in the same object, row or element), that no rule read and that is
/// written like an identifier ("4382-1957-6034-2018", "BE123456"), is never
/// kept unseen. It stays as written and is asked about, whatever its key
/// calls it. A field is judged across the person records it writes: one whose
/// values there are mostly identifiers is surfaced, one of words or of codes
/// is not. Keys a rule reads as no one's (a status, an amount, a time, a
/// request's or a case's reference) and values already decided are left alone.
enum PersonIdentifiers {
    private static let names: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME"]
    /// The key a value is read under when its record's type field writes a code no table knows
    /// ({"type": "ZQX", "value": …}, see `KeyHints.pairedFields`): written as an identifier, it is asked about on its own.
    static let typedKey = "typed_identifier"

    static func run(_ values: inout [DocumentValue], leaves: [DocumentLeaf]) {
        var records = Set<Int>()
        for (value, leaf) in zip(values, leaves) where !leaf.isKey && value.marks.contains(where: { names.contains($0.entity) }) {
            if let record = leaf.lastRecord { records.insert(record) }
        }
        guard !records.isEmpty else { return }
        // Each field's untouched values in a person's record, and those written as identifiers.
        var fields: [String: (all: Int, shaped: [Int])] = [:]
        var typed: [Int] = []
        for index in values.indices {
            let value = values[index], leaf = leaves[index]
            // A typed pair's value in a list of the person's documents is theirs too: its own object is a record of its own.
            guard let record = leaf.lastRecord, records.contains(record) || leaf.key == typedKey && leaf.enclosing.contains(where: records.contains), value.marks.isEmpty, value.unresolved.isEmpty, value.held.isEmpty,
                  value.text == leaf.text, !value.text.trimmingCharacters(in: .whitespaces).isEmpty, !Self.excluded(leaf) else { continue }
            if leaf.key == typedKey {
                if Self.shaped(value.text) { typed.append(index) }
                continue
            }
            let field = leaf.field ?? leaf.key ?? leaf.rawKey ?? ""
            fields[field, default: (0, [])].all += 1
            if Self.shaped(value.text) { fields[field]!.shaped.append(index) }
        }
        let surfaced = fields.values.filter { !$0.shaped.isEmpty && $0.shaped.count * 2 >= $0.all }.flatMap(\.shaped) + typed
        for index in surfaced {
            let value = values[index]
            let text = value.text, range = 0..<(text as NSString).length
            let mark = Mark(range: range, entity: Recognizers.entity, original: text, confidence: LeakGate.suspectConfidence, doubt: .personIdentifier)
            values[index] = DocumentValue(text: text, marks: value.marks, unresolved: [mark], proposals: value.proposals, held: value.held)
        }
    }

    /// Whether the value's key or shape says it is no one's: a reference of the request, the case or the
    /// transaction, a time, a count, a code, a structure's own key.
    private static func excluded(_ leaf: DocumentLeaf) -> Bool {
        if leaf.isKey || leaf.fieldName || leaf.nonPersonal || leaf.isCode || leaf.machineAddress || leaf.datePart != nil { return true }
        let words = KeyHints.words(leaf.rawKey ?? leaf.key ?? leaf.field)
        guard let last = words.last else { return false }
        if technical.contains(last) { return true }
        return ["id", "ref", "reference", "number", "no", "nr", "num", "key", "uuid", "guid"].contains(last) && words.dropLast().contains(where: owners.contains)
    }
    /// What a reference may belong to that is no person: "request_id", "case_ref", "transaction_number".
    private static let owners: Set<String> = ["request", "req", "case", "transaction", "txn", "trace", "correlation", "session", "event", "message", "msg", "batch", "job", "run",
                                              "report", "rule", "error", "idempotency", "order", "invoice", "payment", "ticket", "tracking", "product", "plan", "sku", "api",
                                              "app", "build", "check", "verification", "inquiry", "workflow", "template", "webhook", "span", "parent", "query", "search", "decision",
                                              "screening", "alert", "match", "list", "source", "vendor", "provider", "model", "config", "policy", "audit", "log", "entry", "record", "result"]
    /// Last words of keys whose values are a machine's or an issuer's, never a person's.
    private static let technical: Set<String> = ["hash", "checksum", "digest", "signature", "nonce", "etag", "index", "seq", "sequence", "page", "offset", "limit", "port", "pid",
                                                 "latency", "duration", "ms", "ttl", "size", "length", "lat", "lng", "lon", "latitude", "longitude", "ip", "build", "revision", "rev", "sha", "bin", "iin", "mcc"]

    private static let shape = TextPattern(#"^[A-Za-z0-9]+(?:[-. ][A-Za-z0-9]+)*$"#)
    private static let notIdentifiers = [
        // Dates, written with separators or as eight digits, and a year's month as six.
        #"^\d{4}[-./ ]\d{1,2}[-./ ]\d{1,2}$"#, #"^\d{1,2}[-./ ]\d{1,2}[-./ ]\d{2,4}$"#, #"^(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])?$"#,
        // An amount with its cents, a version or a machine's address, a time in milliseconds (one in seconds is ten digits any number may be).
        #"^\d{1,3}(?:[., ]\d{3})*[.,]\d{1,2}$"#, #"^\d+[.,]\d{1,2}$"#, #"^[vV]?\d{1,2}(?:\.\d{1,3}){1,3}$"#, #"^1[5-9]\d{11}$"#,
        // A hash or a UUID in hexadecimal.
        #"^(?=[0-9a-f-]*[a-f])(?=[0-9a-f-]*\d)[0-9a-f]{8,}$"#, #"^(?=[0-9A-F]*[A-F])[0-9A-F]{32,}$"#, #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
    ].map { TextPattern($0) }

    /// Whether a value is written as an identifier: six characters or more, digits or letters and digits,
    /// possibly in groups split by "-", "." or a space, and no date, amount, time, version, hash or UUID.
    static func shaped(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard (6...40).contains(text.count), text.allSatisfy(\.isASCII), !TextRanges.matches(shape, in: text).isEmpty else { return false }
        let digits = text.filter(\.isNumber).count
        guard digits >= 4 else { return false }
        // Every group carries a digit but a short lead of letters ("AB 123456"), or of codes in capitals before a long run
        // of digits, as an account's country and bank are ("UY-BROU-001827364500"): never words beside a number ("Room 1234").
        let groups = text.split { "-. ".contains($0) }
        let codes = groups.prefix { group in (2...6).contains(group.count) && group.allSatisfy(\.isUppercase) }.count
        let account = (1...3).contains(codes) && groups.dropFirst(codes).contains { $0.filter(\.isNumber).count >= 8 }
        guard groups.enumerated().allSatisfy({ at, group in group.contains(where: \.isNumber) || at == 0 && group.count <= 3 && groups.count > 1 || account && at < codes }) else { return false }
        return !notIdentifiers.contains { !TextRanges.matches($0, in: text).isEmpty }
    }
}
