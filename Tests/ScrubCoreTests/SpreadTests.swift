import Foundation
@testable import ScrubCore
import Testing

/// A name confirmed once is found again in every other form it is written:
/// its parts, possessive, capitals, lowercase, initials, short forms and
/// "Last, First", in greetings and sign-offs, in a text file, a JSON field or
/// a CSV cell, and across rows. Parts that are ordinary words stay words
/// outside a name's position.
struct SpreadTests {
    static func scrub(_ text: String, _ path: PIIGaps.InputPath, seed: UInt64) throws -> (String, ScrubResult) {
        let (data, name) = PIIGaps.wrap(text, path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
        return (PIIGaps.readable(result.output, path), result)
    }

    static func gone(_ words: [String], from output: String) -> [String] {
        words.filter { output.range(of: "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: $0) + "(?![\\p{L}])", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    @Test func everyFormOfAConfirmedNameGoes() throws {
        let text = """
        Ms Odalys Ferriter called about the refund. Ferriter's account shows two charges.
        FERRITER, O. - REFUND APPROVED
        thanks odalys, will do
        """
        for seed in UInt64(0)..<3 {
            for path in PIIGaps.InputPath.allCases {
                let (output, result) = try Self.scrub(text, path, seed: seed)
                #expect(Self.gone(["Odalys", "Ferriter"], from: output).isEmpty, "[\(path)] \(output)")
                #expect(result.counts["PERSON", default: 0] > 0)
                // One person, one surname: the stand-in after "Ms" is the one before "'s" and in capitals.
                let surname = try #require(output.firstMatch(of: /Ms [A-Z][a-z]+ ([A-Z][a-z'-]+) called/)?.1, "[\(path)] \(output)")
                #expect(output.contains("\(surname)'s account"), "[\(path)] \(output)")
                #expect(output.contains(surname.uppercased() + ","), "[\(path)] \(output)")
                #expect(output.contains("REFUND APPROVED") && output.contains("will do"), "[\(path)] \(output)")
            }
        }
    }

    @Test func initialsAndShortFormsAreTheSamePerson() throws {
        let text = "Robert Kellowan approved the credit. R. Kellowan signed the form on Monday, and Bob Kellowan emailed the receipt.\n\nThanks,\nBob"
        for seed in UInt64(0)..<3 {
            for path in PIIGaps.InputPath.allCases {
                let (output, _) = try Self.scrub(text, path, seed: seed)
                #expect(Self.gone(["Robert", "Kellowan", "Bob"], from: output).isEmpty, "[\(path)] \(output)")
                let full = try #require(output.firstMatch(of: /^([A-Z][a-z]+) ([A-Z][a-z'-]+) approved/)?.output, "[\(path)] \(output)")
                // "R. Kellowan" keeps the form with the stand-in's initial; the short form and the sign-off are the stand-in's first name.
                #expect(output.contains("\(full.1.prefix(1)). \(full.2) signed"), "[\(path)] \(output)")
                #expect(output.hasSuffix("\n" + full.1) || output.hasSuffix("\n" + full.1 + "\n"), "[\(path)] \(output)")
            }
        }
    }

    @Test func lastFirstWithAMiddleNameOrSuffixIsOnePerson() throws {
        let text = "From: Bowman Jr., Raymond\nTo: Varga, Francisco Pinto; Lind, Per\nSubject: Q3 accruals\n\nPer, Raymond asked for the Q3 file."
        for path in PIIGaps.InputPath.allCases {
            let (output, _) = try Self.scrub(text, path, seed: 2)
            #expect(Self.gone(["Bowman", "Varga", "Francisco", "Pinto", "Raymond", "Lind"], from: output).isEmpty, "[\(path)] \(output)")
            #expect(output.contains(" Jr., "), "the suffix stays: [\(path)] \(output)")
            #expect(output.contains("Subject: Q3 accruals"), "[\(path)] \(output)")
        }
    }

    @Test func greetingsAndSignOffsNameSomeone() throws {
        // First names that are also words count where nothing but a name could stand.
        let texts = [("Holly,\n\nThe Q3 file is attached. Wade & Heidi have the originals.\n\nCheers,\nWade", ["Holly", "Wade", "Heidi"]),
                     ("hey rafael,\n\nThe Q3 file is attached.\n\nBest,\nTobias", ["rafael", "Tobias"])]
        for (text, names) in texts {
            for path in PIIGaps.InputPath.allCases {
                let (output, result) = try Self.scrub(text, path, seed: 1)
                #expect(Self.gone(names, from: output).isEmpty, "[\(path)] \(output)")
                #expect(result.counts["PERSON", default: 0] >= 2, "[\(path)] \(output)")
                #expect(output.contains("The Q3 file is attached.") && (output.contains("Cheers,") || output.contains("Best,")), "[\(path)] \(output)")
            }
        }
    }

    @Test func partsThatAreWordsStayWordsOutsideAName() throws {
        let text = "Ms Grace Long joined in May. I told Long that the grace period ends soon.\nLong delays are expected, and a long queue formed. May I ask why?"
        for path in PIIGaps.InputPath.allCases {
            let (output, _) = try Self.scrub(text, path, seed: 3)
            #expect(!output.contains("Ms Grace Long") && !output.contains("told Long"), "[\(path)] \(output)")
            for kept in ["grace period", "Long delays", "a long queue", "May I ask", "joined in May"] {
                #expect(output.contains(kept), "changed \(kept): [\(path)] \(output)")
            }
        }
    }

    @Test func aNameInOneRowIsFoundInEveryOther() throws {
        let csv = "id,contact,notes\n1,Odalys Ferriter,first call\n2,,ferriter called back about Ferriter's refund\n3,,\"Hi Odalys, sent\"\n"
        let result = try Scrubber.scrub(Data(csv.utf8), name: "calls.csv", forceFullDetection: false, seed: 6)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(Self.gone(["Odalys", "Ferriter"], from: output).isEmpty, "\(output)")
        let json = #"{"cases": [{"contact": {"first": "Odalys", "last": "Ferriter"}}, {"notes": "Spoke to O. Ferriter; ferriter wants a callback"}, {"notes": "Thanks, Odalys"}]}"#
        let scrubbed = String(decoding: try Scrubber.scrub(Data(json.utf8), name: "cases.json", forceFullDetection: false, seed: 6).output, as: UTF8.self)
        #expect(Self.gone(["Odalys", "Ferriter"], from: scrubbed).isEmpty, "\(scrubbed)")
    }
}
