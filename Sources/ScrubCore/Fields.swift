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
        for members in groups.values where members.count >= 3 {
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
    /// identifier, though no key or word names it: four values passing even a
    /// one-in-ten check by chance is one field in ten thousand, as a
    /// structured analysis reads a column by what its cells are.
    private static func identify(_ members: [Int], _ leaves: [DocumentLeaf], _ founds: inout [[Span]]) {
        let values = members.filter { !leaves[$0].seen.trimmingCharacters(in: .whitespaces).isEmpty }
        guard values.count >= 4 else { return }
        var passing: [String: [Int]] = [:]
        for index in values {
            guard let recognizer = Recognizers.recognizing(leaves[index].seen), recognizer.verifies else { continue }
            passing[recognizer.name, default: []].append(index)
        }
        guard let (name, indices) = passing.max(by: { $0.value.count < $1.value.count }), indices.count * 10 >= values.count * 9,
              let recognizer = Recognizers.all.first(where: { $0.name == name }) else { return }
        for index in indices {
            let length = (leaves[index].seen as NSString).length
            if founds[index].contains(where: { $0.range.count * 5 >= length * 4 && $0.score >= 0.85 }) { continue }
            founds[index] = [Span(range: 0..<length, entity: recognizer.entity, score: 0.9)]
        }
    }

    /// The kind most of a field's values were read as, given to those read as nothing that could be one too.
    private static func carry(_ members: [Int], _ leaves: [DocumentLeaf], _ founds: inout [[Span]]) {
        var counts: [String: Int] = [:]
        var bare: [Int] = []
        for index in members {
            let length = (leaves[index].seen as NSString).length
            guard length > 0 else { continue }
            if let whole = founds[index].first(where: { $0.range.count * 5 >= length * 4 }) { counts[whole.entity, default: 0] += 1 }
            else if founds[index].isEmpty { bare.append(index) }
        }
        let read = counts.values.reduce(0, +)
        guard !bare.isEmpty, let (entity, count) = counts.max(by: { $0.value < $1.value }), carried.contains(entity),
              count >= 2, count * 5 >= (read + bare.count) * 3 else { return }
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
