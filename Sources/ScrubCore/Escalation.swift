import Foundation
import os
import Synchronization

/// How the span tagger reads a value the rules left as written.
enum TaggerReading: Sendable, Equatable {
    /// Free text, read whole.
    case prose
    /// A field, read on one line with its key and the keys beside it.
    case line(key: String, siblings: [String])
}

/// After the rules have run, the span tagger reads what they left as written
/// and sends what it suspects to review. It only ever adds suspects: it never
/// replaces a value, and never drops or weakens what a rule found.
enum Escalation {
    /// The layer's one switch, off until hand marking and its suspects agree (see EscalationTests).
    /// Off, or without the tagger's weights, Scrub runs as it would without it.
    static let enabled = Atomic(false)
    private static let log = Logger(subsystem: "Scrub", category: "Escalation")
    /// Turns the layer on or off for one task whatever the switch says, as tests do.
    @TaskLocal static var active: Bool?
    static var tagger: SpanTagger? { active ?? enabled.load(ordering: .relaxed) ? SpanTagger.shared : nil }

    /// The labels the tagger is asked for. The last five only soak up what is
    /// no one's (a company, a date, a ticket); their hits are dropped.
    static let labels = ["person", "email", "phone_number", "address", "postal_code", "date_of_birth", "passport_number", "national_id_number",
                         "drivers_license_number", "tax_id", "bank_account", "iban", "card_number", "ip_address", "username", "account_id",
                         "medical_record_number", "organization", "date", "request_id", "ticket_id", "software_version"]
    static let sinks: Set = ["organization", "date", "request_id", "ticket_id", "software_version"]
    /// Labels a field's whole value is never sent for: they fire on every system's own keys.
    static let notForFields: Set = ["username", "ip_address", "account_id"]
    static let numeric: Set = ["phone_number", "postal_code", "passport_number", "national_id_number", "drivers_license_number", "tax_id", "bank_account",
                               "iban", "card_number", "ip_address", "username", "account_id", "medical_record_number"]
    static let identifiers: Set = ["passport_number", "national_id_number", "drivers_license_number", "tax_id", "medical_record_number"]
    static let accounts: Set = ["bank_account", "iban", "card_number", "account_id"]
    static let threshold: Float = 0.7
    /// A field's value is read up to this many characters.
    static let fieldLength = 400
    /// How many texts the tagger reads in one document, at most: a wide export
    /// would otherwise take minutes. Counted, never timed, so the same input
    /// always gets the same review.
    @TaskLocal static var readsPerDocument = 200
    /// Told, once a document is read, how many texts the tagger read and how many values the limit left unread.
    @TaskLocal static var counted: (@Sendable (_ reads: Int, _ unread: Int) -> Void)?

    static let entities = ["person": "PERSON", "email": "EMAIL_ADDRESS", "phone_number": "PHONE_NUMBER", "address": "ADDRESS", "postal_code": "POSTAL_CODE",
                           "date_of_birth": "DATE_OF_BIRTH", "iban": "IBAN_CODE", "card_number": "CREDIT_CARD", "ip_address": "IP_ADDRESS", "username": "USERNAME"]

    /// The suspects the tagger adds to each value it reads, by value.
    static func suspects(_ leaves: [DocumentLeaf], _ values: [DocumentValue], tagger: SpanTagger) throws -> [Int: [Mark]] {
        var out: [Int: [Mark]] = [:]
        var lines: [String: [SpanTagger.Hit]] = [:]
        var reads = 0, unread = 0
        for index in values.indices {
            guard let reading = leaves[index].reading, !leaves[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard reads < readsPerDocument else { unread += 1; continue }
            try Scrubber.checkCancellation()
            let value = values[index]
            let untouched = value.marks.isEmpty && value.unresolved.isEmpty && value.held.isEmpty && value.text == leaves[index].text
            switch reading {
            // Free text reads as prose, so review points at the words, not the whole field.
            case .line(let key, let siblings) where untouched && !isFreeText(value.text):
                let text = String(String.UnicodeScalarView(value.text.unicodeScalars.prefix(fieldLength)))
                let prefix = key + ": "
                let line = prefix + text + " (record also has: " + siblings.prefix(10).joined(separator: ", ") + ")"
                let hits: [SpanTagger.Hit]
                if let known = lines[line] {
                    hits = known
                } else {
                    reads += 1
                    hits = tagger.hits(Array(line.unicodeScalars), labels: labels, threshold: threshold)
                    lines[line] = hits
                }
                let start = prefix.unicodeScalars.count, range = start..<(start + text.unicodeScalars.count)
                let best = hits.filter { !sinks.contains($0.label) && !notForFields.contains($0.label) && $0.score >= threshold && $0.range.overlaps(range) }
                    .max { $0.score < $1.score }
                guard let best, !dropped(value.text, key: key, label: best.label) else { continue }
                out[index] = [mark(0..<(value.text as NSString).length, in: value.text, label: best.label)]
            case .line where !isFreeText(leaves[index].text):
                continue
            default:
                reads += 1
                let marks = prose(value, tagger: tagger)
                if !marks.isEmpty { out[index] = marks }
            }
        }
        if unread > 0 { log.info("Span tagger stopped after \(reads) reads, \(unread) values unread") }
        counted?(reads, unread)
        return out
    }

    /// The tagger's suspects in free text, outside every place a rule already marked.
    private static func prose(_ value: DocumentValue, tagger: SpanTagger) -> [Mark] {
        let scalars = Array(value.text.unicodeScalars)
        // Scalar offsets to UTF-16 ones.
        var utf16 = [0]
        for scalar in scalars { utf16.append(utf16.last! + UTF16.width(scalar)) }
        let blocked = (value.marks + value.unresolved + value.held).map(\.range)
        var out: [Mark] = []
        let hits = tagger.hits(scalars, labels: labels, threshold: threshold).enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
        for hit in hits.map(\.element) where !sinks.contains(hit.label) {
            let lower = min(hit.range.lowerBound, scalars.count), upper = min(hit.range.upperBound, scalars.count)
            let text = String(String.UnicodeScalarView(scalars[lower..<upper]))
            if numeric.contains(hit.label), !text.contains(where: \.isNumber) { continue }
            let range = utf16[lower]..<utf16[upper]
            guard !blocked.contains(where: { $0.overlaps(range) }), !out.contains(where: { $0.range.overlaps(range) }) else { continue }
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2, !dropped(text, key: "", label: hit.label) else { continue }
            out.append(mark(range, in: value.text, label: hit.label))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func mark(_ range: Range<Int>, in text: String, label: String) -> Mark {
        Mark(range: range, entity: entities[label] ?? "ID_NUMBER", original: TextRanges.substring(text, range), confidence: LeakGate.suspectConfidence)
    }

    /// Four or more words, one of three letters or more: a field written as prose.
    static func isFreeText(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 4 && text.range(of: #"[^\W\d_]{3,}"#, options: .regularExpression) != nil
    }

    private static let identifierKey = TextPattern(#"ssn|tin\b|passport|licen[cs]e|national|nat_?id|document|doc_?(no|num)|tax|nino|\bnin\b|mrn|member|personal_?(no|num|id)|citizen|aadhaar|cpf|curp|dni|pesel|id_?(no|num)|idnumber|social"#, options: [.caseInsensitive])

    /// Whether a hit's shape rules it out: a bare hex run, a UUID or a run of
    /// digits with no valid checksum, unless its key or label says it is an
    /// identifier; an email that has no email's shape; an account with too few digits.
    static func dropped(_ raw: String, key: String, label: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexLike = RecordIDs.isUUID(value) || value.count >= 8 && value.allSatisfy(\.isHexDigit) && value.contains(where: \.isLetter) && value.contains(where: \.isNumber)
        let digits = !value.isEmpty && value.allSatisfy { $0.wholeNumberValue != nil && $0.isNumber }
        let checksum = digits && (13...19).contains(value.count) && luhn(value)
        let saysIdentifier = !TextRanges.matches(identifierKey, in: key).isEmpty || identifiers.contains(label)
        if hexLike || digits && !checksum, !saysIdentifier { return true }
        // A handle or a code ("agent_marta", "user42") is no one's written name.
        if label == "person", value.contains(where: { $0 == "_" || $0 == "@" || $0.isNumber }) { return true }
        if label == "email", value.range(of: #"\S@\S+\.\w"#, options: .regularExpression) == nil { return true }
        if accounts.contains(label), value.filter(\.isNumber).count < 4, value.range(of: #"^[A-Za-z]{2}\d{2}[A-Za-z0-9 ]{10,}$"#, options: .regularExpression) == nil { return true }
        return false
    }

    private static func luhn(_ digits: String) -> Bool {
        var total = 0
        for (index, character) in digits.reversed().enumerated() {
            var n = character.wholeNumberValue ?? 0
            if index % 2 == 1 { n = n * 2 > 9 ? n * 2 - 9 : n * 2 }
            total += n
        }
        return total % 10 == 0
    }
}
