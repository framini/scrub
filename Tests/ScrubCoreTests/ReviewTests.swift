import Foundation
@testable import ScrubCore
import Testing

/// Each finding carries how sure its surest detector was, and a person can
/// take uncertain ones back: a skipped value is left as written everywhere,
/// and every other stand-in stays exactly as it was, in every format.
struct ReviewTests {
    /// The same note in a text file, nested JSON, two CSV rows and XML: a
    /// titled person (sure), an email (sure), and a place only the system
    /// tagger reads, twice (unsure).
    static let note = "Ms Odalys Ferriter called about the refund; write to odalys.ferriter@corvane.test. Brightwater from billing called back, and Brightwater wants the invoice."
    static let inputs: [(Data, String)] = [
        (Data(note.utf8), "note.txt"),
        (Data(#"{"ticket": {"id": 4471, "notes": [{"body": "\#(note)"}, {"body": "Ms Odalys Ferriter again. Brightwater approved it."}]}}"#.utf8), "ticket.json"),
        (Data("ticket,remark\n4471,\"\(note)\"\n4472,Ms Odalys Ferriter again. Brightwater approved it.\n".utf8), "tickets.csv"),
        (Data("<tickets><ticket id=\"4471\"><remark>\(note)</remark></ticket><ticket><remark>Ms Odalys Ferriter again. Brightwater approved it.</remark></ticket></tickets>".utf8), "tickets.xml"),
    ]

    static func occurrences(_ word: String, in text: String) -> Int { text.components(separatedBy: word).count - 1 }

    @Test func eachFindingCarriesTheConfidenceOfItsSurestDetector() throws {
        for (data, name) in Self.inputs {
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 3)
            let findings = result.findings
            let email = try #require(findings.first { $0.entity == "EMAIL_ADDRESS" }, "\(name): \(findings)")
            #expect(email.confidence == 1 && !email.needsReview)
            let titled = try #require(findings.first { $0.original == "Ms Odalys Ferriter" }, "\(name): \(findings)")
            #expect(titled.confidence >= 0.9 && !titled.needsReview, "\(name): \(titled)")
            let place = try #require(findings.first { $0.original == "Brightwater" }, "\(name): \(findings)")
            #expect(place.needsReview && place.confidence <= 0.6, "\(name): \(place)")
            #expect(place.occurrences >= 2 && result.uncertain.contains(place), "\(name): \(place)")
            // Excerpts show the stand-in where it stands, and no original.
            let excerpt = try #require(place.excerpts.first)
            #expect(excerpt.standIn == place.standIn && !(excerpt.before + excerpt.after).contains("Brightwater") && !(excerpt.before + excerpt.after).contains("Ferriter"), "\(excerpt)")
        }
    }

    @Test func aPartLearnedFromASureNameIsAsSure() throws {
        // "Kellowan" alone would be the name model's guess; the titled name made it sure.
        let text = "Mr Dariusz Kellowan signed on Monday. On Tuesday Kellowan asked for a copy, and the copy went to Kellowan's office."
        let result = try Scrubber.scrub(Data(text.utf8), name: "n.txt", forceFullDetection: false, seed: 1)
        let part = try #require(result.findings.first { $0.original == "Kellowan" }, "\(result.findings)")
        #expect(part.confidence >= 0.9 && part.occurrences == 2, "\(part)")
    }

    @Test func skippingLeavesAValueAsWrittenEverywhereAndTheRestAsItWas() throws {
        for (data, name) in Self.inputs {
            for seed in UInt64(0)..<3 {
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let output = String(decoding: result.output, as: UTF8.self)
                let place = try #require(result.findings.first { $0.original == "Brightwater" })
                let person = try #require(result.findings.first { $0.original == "Ms Odalys Ferriter" })
                let input = String(decoding: data, as: UTF8.self)

                // Keeping everything is the scrub as made.
                #expect(try result.skipping([]).output == result.output)

                let skipped = try result.skipping([place.id])
                let revised = String(decoding: skipped.output, as: UTF8.self)
                // Left as written, every time, and only the place changed back.
                #expect(Self.occurrences("Brightwater", in: revised) == Self.occurrences("Brightwater", in: input), "\(name): \(revised)")
                #expect(Self.occurrences(place.standIn, in: revised) == Self.occurrences(place.standIn, in: output) - place.occurrences, "\(name): \(revised)")
                #expect(revised.replacingOccurrences(of: "Brightwater", with: place.standIn) == output, "\(name): \(revised)")
                // The person keeps the same stand-in everywhere, and is still gone.
                #expect(Self.occurrences(person.standIn, in: revised) == Self.occurrences(person.standIn, in: output) && !revised.contains("Ferriter"), "\(name): \(revised)")
                #expect(skipped.counts["LOCATION", default: 0] == max(0, result.counts["LOCATION", default: 0] - place.occurrences), "\(skipped.counts) vs \(result.counts)")
                // The same findings stay on offer, and choices apply to the scrub as first made.
                #expect(skipped.findings == result.findings)
                #expect(try skipped.skipping([place.id]).output == skipped.output)
                #expect(try skipped.skipping([person.id]).output != skipped.output)
                let both = String(decoding: try result.skipping([place.id, person.id]).output, as: UTF8.self)
                #expect(both.contains("Ms Odalys Ferriter") && both.contains("Brightwater") && !both.contains(person.standIn), "\(name): \(both)")
                // A revised file still reads in its format.
                if name.hasSuffix(".json") { #expect((try? JSONSerialization.jsonObject(with: skipped.output)) != nil) }
                if name.hasSuffix(".xml") { #expect(try XMLFile.parses(skipped.output)) }
                if name.hasSuffix(".csv") { #expect(try CSVFile.parse(revised, delimiter: ",").count == 3) }
            }
        }
    }
}
