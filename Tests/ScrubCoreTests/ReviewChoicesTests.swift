import Foundation
@testable import ScrubCore
import Testing

/// Review keeps each place's own evidence. A finding is as sure as its least
/// sure place, findings split where places differ in kind, owner or doubt,
/// secrets are told apart by case and names are not, and a choice can cover
/// one place or one record as well as every place.
struct ReviewChoicesTests {
    /// Values as a scrub leaves them: "Brightwater" replaced in three records,
    /// surely in one and doubtfully in two; "1234" ending two people's numbers;
    /// a secret written in two cases; a name written in two cases.
    static func review() -> (Review, [DocumentValue]) {
        func value(_ text: String, _ marks: [(String, String, String, Double, Doubt?)]) -> DocumentValue {
            let ns = text as NSString
            return DocumentValue(text: text, marks: marks.map { standIn, entity, original, confidence, doubt in
                let range = ns.range(of: standIn)
                return Mark(range: range.location..<NSMaxRange(range), entity: entity, original: original, confidence: confidence, doubt: doubt)
            }, unresolved: [])
        }
        let values = [
            value("Lowmarsh called; key Kq7Zp2Wm9X", [("Lowmarsh", "LOCATION", "Brightwater", 1, nil), ("Kq7Zp2Wm9X", "SECRET", "AbC123xyzQ", 1, nil)]),
            value("Lowmarsh again, key Pd3Rr8Lm2T", [("Lowmarsh", "LOCATION", "Brightwater", 0.6, nil), ("Pd3Rr8Lm2T", "SECRET", "abc123XYZq", 1, nil)]),
            value("Lowmarsh wrote; ends 5521; MAREN HOLT", [("Lowmarsh", "LOCATION", "Brightwater", 0.9, nil), ("5521", "LAST_DIGITS", "1234", 1, nil), ("MAREN HOLT", "PERSON", "ODALYS FERRITER", 0.85, nil)]),
            value("ends 8830, then 8830 again; Maren Holt", [("8830", "LAST_DIGITS", "1234", 0.5, .unclearOwner), ("Maren Holt", "PERSON", "Odalys Ferriter", 0.85, nil)]),
        ]
        let render: ([DocumentValue], [String: Int]) throws -> ScrubResult = { values, counts in
            ScrubResult(format: "text", output: Data(values.map(\.text).joined(separator: "\n").utf8), preview: .text("", marks: [], truncated: false), counts: counts, unresolved: [])
        }
        return (Review(values: values, counts: [:], records: [0, 1, 2, 2], render: render), values)
    }

    @Test func aFindingIsAsSureAsItsLeastSurePlace() throws {
        let (review, _) = Self.review()
        let place = try #require(review.findings.first { $0.original == "Brightwater" })
        #expect(place.confidence == 0.6 && place.needsReview && place.occurrences == 3, "\(place)")
        #expect(place.places.map(\.confidence) == [1, 0.6, 0.9] && place.places.map(\.record) == [0, 1, 2])
        // Every place of a finding to look at keeps its line.
        #expect(place.places.allSatisfy { $0.excerpt != nil })
    }

    @Test func placesThatDifferInOwnerOrDoubtAreTwoFindings() throws {
        let (review, _) = Self.review()
        let endings = review.findings.filter { $0.original == "1234" }
        #expect(endings.count == 2 && Set(endings.map(\.standIn)) == ["5521", "8830"], "\(endings)")
        let unclear = try #require(endings.first { $0.doubt == .unclearOwner })
        #expect(unclear.needsReview && unclear.occurrences == 1)
    }

    @Test func secretsAreToldApartByCaseAndNamesAreNot() {
        let (review, _) = Self.review()
        #expect(review.findings.filter { $0.entity == "SECRET" }.count == 2)
        let names = review.findings.filter { $0.entity == "PERSON" }
        #expect(names.count == 1 && names[0].occurrences == 2, "\(names)")
    }

    @Test func aChoiceCoversEveryPlaceOneRecordOrOnePlace() throws {
        let (review, values) = Self.review()
        let place = try #require(review.findings.first { $0.original == "Brightwater" })
        func lines(_ choices: Choices) throws -> [String] { String(decoding: try review.applying(choices).output, as: UTF8.self).components(separatedBy: "\n") }
        let made = values.map(\.text)

        var everywhere = Choices()
        everywhere.set(place, leave: true)
        #expect(try lines(everywhere) == made.map { $0.replacingOccurrences(of: "Lowmarsh", with: "Brightwater") })

        var record = Choices()
        record.set(place, leave: true, inRecord: 1)
        #expect(try lines(record) == [made[0], made[1].replacingOccurrences(of: "Lowmarsh", with: "Brightwater"), made[2], made[3]])

        var one = Choices()
        one.set(place.places[2], leave: true)
        #expect(try lines(one) == [made[0], made[1], made[2].replacingOccurrences(of: "Lowmarsh", with: "Brightwater"), made[3]])
        #expect(one.leftCount(of: review.findings) == 1)

        // A place's own choice wins over its finding's.
        var mixed = everywhere
        mixed.set(place.places[0], leave: false)
        #expect(try lines(mixed) == [made[0], made[1].replacingOccurrences(of: "Lowmarsh", with: "Brightwater"), made[2].replacingOccurrences(of: "Lowmarsh", with: "Brightwater"), made[3]])
        // Setting the finding again clears the places' own choices.
        mixed.set(place, leave: false)
        let cleared = try lines(mixed)
        #expect(mixed.places.isEmpty && cleared == made)
    }

    /// The same, end to end: a place the tagger guessed in three CSV rows,
    /// left in one row only, and every other value as replaced.
    @Test func aRecordsChoiceStaysInItsRecord() throws {
        let csv = "ticket,remark\n1,Brightwater from billing called back.\n2,Brightwater wants the invoice.\n3,Brightwater paid on Friday.\n"
        let result = try Scrubber.scrub(Data(csv.utf8), name: "t.csv", forceFullDetection: false, seed: 4)
        let place = try #require(result.findings.first { $0.original == "Brightwater" }, "\(result.findings)")
        #expect(Set(place.places.compactMap(\.record)).count == 3, "\(place)")
        var choices = result.choices
        choices.set(place, leave: true, inRecord: try #require(place.places[1].record))
        let rows = String(decoding: try result.applying(choices).output, as: UTF8.self).components(separatedBy: "\n")
        #expect(!rows[1].contains("Brightwater") && rows[2].hasPrefix("2,Brightwater wants") && !rows[3].contains("Brightwater"), "\(rows)")
    }
}
