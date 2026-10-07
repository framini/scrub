import Foundation

/// What a document's fields say about their values, read across all of them
/// rather than one at a time, as a table's column is: a field whose values are
/// mostly people's names holds names in the rest of its values too, and a
/// field whose values are a few codes written again and again ("FACE",
/// "SELFIE", "CUSTOMER") holds categories, not anyone's data. A field is a
/// value's keys from its document's root, a list's items being one field
/// (see `DocumentLeaf.field`).
enum Fields {
    /// Kinds a field's majority carries to the values detection missed.
    private static let carried: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION", "ID_NUMBER"]
    /// Kinds a key names that no category ever is.
    private static let personal: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "PHONE_NUMBER", "ADDRESS", "US_SSN", "ID_NUMBER", "CREDIT_CARD", "DATE_OF_BIRTH", "SECRET", "USERNAME", "MRZ", "IP_ADDRESS"]
    private static let code = TextPattern(#"^[A-Za-z][A-Za-z]{2,}(?:[_-][A-Za-z0-9]{1,12}){0,3}$"#)

    static func decide(_ leaves: [DocumentLeaf], _ founds: inout [[Span]]) {
        var groups: [String: [Int]] = [:]
        for index in leaves.indices where leaves[index].numericEntity == nil {
            guard let field = leaves[index].field, !field.isEmpty else { continue }
            groups[field, default: []].append(index)
        }
        for members in groups.values {
            // A field decided across its numbers too holds its identifier however few of its values are strings.
            guard members.count >= 3 else {
                if members.contains(where: { !(leaves[$0].column ?? "").isEmpty }) { identify(members, leaves, &founds) }
                continue
            }
            if categorical(members.map { leaves[$0] }) {
                for index in members { founds[index] = [] }
                continue
            }
            identify(members, leaves, &founds)
            carry(members, leaves, &founds)
        }
    }

    /// A few short codes, each written again and again, under a key that names nothing personal:
    /// a document's category, a check's result, a channel.
    static func categorical(_ leaves: [DocumentLeaf]) -> Bool {
        guard leaves.count >= 4, !leaves.contains(where: { personal.contains(KeyHints.hint($0.key) ?? "") || KeyHints.namesARole($0.key) || $0.addressKey != nil }) else { return false }
        let values = leaves.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard values.allSatisfy({ $0.utf16.count <= 32 && !TextRanges.matches(code, in: $0).isEmpty && $0.filter(\.isNumber).count <= 2 }) else { return false }
        // Codes are written in one case throughout: "FACE", "face"; a name list mixes them ("Rosalind", "Odile").
        guard values.allSatisfy({ $0 == $0.uppercased() }) || values.allSatisfy({ $0 == $0.lowercased() }) else { return false }
        // Written again and again: half of them repeats, or any repeat among capitals' codes.
        let distinct = Set(values)
        return distinct.count <= 12 && (distinct.count * 2 <= values.count || distinct.count < values.count && values.allSatisfy { $0 == $0.uppercased() })
    }

    /// A field whose values nearly all pass one identifier's check holds that
    /// identifier, though no key or word names it: four distinct values passing even a
    /// one-in-ten check by chance is one field in ten thousand, so a column is read
    /// by what its cells are.
    private static func identify(_ members: [Int], _ leaves: [DocumentLeaf], _ founds: inout [[Span]]) {
        let values = members.filter { !leaves[$0].seen.trimmingCharacters(in: .whitespaces).isEmpty }
        // A reader that saw the field's numbers too decided it already.
        let decided = members.lazy.compactMap { leaves[$0].column }.first
        let chosen = decided.map { name in Recognizers.all.first { $0.name == name } } ?? column(values.map { leaves[$0].seen })
        guard let recognizer = chosen else { return }
        for index in values where Recognizers.candidates(leaves[index].seen).contains(where: { $0.name == recognizer.name }) {
            let length = (leaves[index].seen as NSString).length
            if founds[index].contains(where: { $0.range.count * 5 >= length * 4 && $0.score >= 0.85 }) { continue }
            founds[index] = [Span(range: 0..<length, entity: recognizer.entity, score: 0.9)]
        }
    }
    /// The identifier a column of values holds: at least four of them, nine in ten passing
    /// one kind's verifying check, and four of those distinct (one order number on four line
    /// items is one chance passing, not four). Strings and JSON numbers are read alike.
    static func column(_ values: [String]) -> Recognizer? {
        // Distinct values, each counted once: a value repeated on many rows is one chance, however often it is written.
        var distinct: [String: String] = [:]
        for value in values {
            let canonical = value.uppercased().filter { $0.isLetter || $0.isNumber }
            if !canonical.isEmpty, distinct[canonical] == nil { distinct[canonical] = value }
        }
        guard distinct.count >= 4 else { return nil }
        var passing: [String: Int] = [:]
        for value in distinct.values {
            for recognizer in Recognizers.candidates(value) where recognizer.verifies { passing[recognizer.name, default: 0] += 1 }
        }
        // Two kinds every value passes (a CPF is a Guatemalan NIT too): the registry's earlier, longer-known one.
        let order = Dictionary(uniqueKeysWithValues: Recognizers.all.enumerated().map { ($1.name, $0) })
        guard let (name, passed) = passing.max(by: { ($0.value, order[$1.key] ?? 0) < ($1.value, order[$0.key] ?? 0) }), passed >= 4, passed * 10 >= distinct.count * 9 else { return nil }
        return Recognizers.all.first { $0.name == name }
    }

    /// The kind most of a field's values were read as, given to those read as nothing that could be one too.
    private static func carry(_ members: [Int], _ leaves: [DocumentLeaf], _ founds: inout [[Span]]) {
        // Distinct values, each counted once: one name repeated on every row is one reading, not many.
        var read: [String: Set<String>] = [:]
        var bare: [Int] = []
        var unread: Set<String> = []
        for index in members {
            let seen = leaves[index].seen, length = (seen as NSString).length
            guard length > 0 else { continue }
            if let whole = founds[index].first(where: { $0.range.count * 5 >= length * 4 }) { read[whole.entity, default: []].insert(seen) }
            else if founds[index].isEmpty { bare.append(index); unread.insert(seen) }
        }
        let total = read.values.reduce(0) { $0 + $1.count }
        guard !bare.isEmpty, let (entity, values) = read.max(by: { $0.value.count < $1.value.count }), carried.contains(entity),
              values.count >= 2, values.count * 5 >= (total + unread.count) * 3 else { return }
        for index in bare where fits(leaves[index].seen, entity) {
            founds[index] = [Span(range: 0..<(leaves[index].seen as NSString).length, entity: entity, score: 0.8)]
        }
    }
    /// Whether a value can be one of `entity` at all: a name is words of letters, an ID has a digit.
    private static func fits(_ value: String, _ entity: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 80, KeyHints.fits("name", trimmed) || entity == "ID_NUMBER" else { return false }
        switch entity {
        case "ID_NUMBER": return trimmed.contains(where: \.isNumber) && !trimmed.contains(" ")
        default:
            return trimmed.allSatisfy { $0.isLetter || " .'’-".contains($0) } && trimmed.split(separator: " ").count <= 5
                && !KeyHints.isCommonValue(trimmed) && trimmed.first?.isUppercase == true
        }
    }
}
