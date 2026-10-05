import Foundation
@testable import ScrubCore
import Testing

/// A name only a model read, which nothing else in the text agrees with, is
/// not sure enough to replace but too likely to ignore. It is kept with its
/// reason and left as written, and review asks about it starting on "Leave";
/// choosing to replace it writes the stand-in it was offered.
struct DoubtTests {
    static let notes = [
        ("sorry for the delay, hendrika was out sick so the report slipped to Friday.", "hendrika"),
        ("The deploy broke again. Rhosyn fixed it before lunch and pushed the patch.", "Rhosyn"),
        ("Thanks for the update. Marisela will take over the account from Monday.", "Marisela"),
    ]

    enum Path: String, CaseIterable { case text, json, csv, xml }

    static func wrap(_ note: String, _ path: Path) -> (Data, String) {
        switch path {
        case .text: return (Data(note.utf8), "note.txt")
        case .json: return (Data(#"{"ticket": 4471, "note": "\#(note)"}"#.utf8), "note.json")
        case .csv: return (Data("ticket,note\n4471,\"\(note)\"\n".utf8), "note.csv")
        case .xml: return (Data("<ticket id=\"4471\"><note>\(note)</note></ticket>".utf8), "note.xml")
        }
    }

    @Test(arguments: Path.allCases)
    func aNameNothingAgreesWithIsLeftAsWrittenAndAskedAbout(_ path: Path) throws {
        for (note, name) in Self.notes {
            let (data, file) = Self.wrap(note, path)
            let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 3)
            let output = String(decoding: result.output, as: UTF8.self)
            let label = "[\(path)] \(note)"
            #expect(output.contains(note), "\(label): \(output)")
            let doubt = try #require(result.findings.first { $0.original == name }, "\(label): \(result.findings.map(\.original))")
            #expect(doubt.doubt == .unconfirmed && doubt.suspected && doubt.needsReview && doubt.entity == "PERSON", "\(label): \(doubt)")
            #expect(result.uncertain.contains(doubt) && result.leftAsWritten.contains(doubt.id), "\(label)")
            // The stand-in it would take is a name, written as the original is.
            #expect(doubt.standIn != name && doubt.standIn.allSatisfy(\.isLetter) && (doubt.standIn.first?.isUppercase == name.first?.isUppercase), "\(label): \(doubt.standIn)")
            #expect(doubt.excerpts.first?.standIn == doubt.standIn)
            // Replacing it writes that stand-in there and changes nothing else.
            let replaced = String(decoding: try result.applying(Choices()).output, as: UTF8.self)
            let expected = output.replacingOccurrences(of: name, with: doubt.standIn)
            if path == .json {
                // JSON is laid out again once anything in it is replaced; its values are what count.
                let note = { (text: String) in (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["note"] as? String }
                #expect(note(replaced) != nil && note(replaced) == note(expected), "\(label): \(replaced)")
            } else {
                #expect(replaced == expected, "\(label): \(replaced)")
            }
        }
    }

    /// Something that says a word is no one (a company's, a town's, after "the")
    /// leaves no doubt to ask about.
    @Test func aWordSaidToBeNoOneIsNotAskedAbout() throws {
        for note in ["We moved to Szeged last spring and the office followed.", "the Jenkins build failed twice overnight.", "Darwin 25.6.0 ships with the patch."] {
            let result = try Scrubber.scrub(Data(note.utf8), name: "n.txt", forceFullDetection: false, seed: 3)
            #expect(!result.findings.contains { $0.doubt == .unconfirmed }, "\(note): \(result.findings)")
        }
    }

    /// A surname the tagger stops short of ("Tomasz O'Sullivan", cut at the
    /// apostrophe) is part of the first name found beside it: the whole name
    /// is replaced, with nothing of it left and nothing asked.
    @Test(arguments: Path.allCases)
    func aDoubtedWordBesideAFoundNameIsPartOfIt(_ path: Path) throws {
        for (note, name) in [("Customer: Tomasz O'Sullivan", "Tomasz O'Sullivan"), ("Spoke to Tomasz O'Sullivan.", "Tomasz O'Sullivan"),
                             ("Contact: Tavish O'Quillmere", "Tavish O'Quillmere")] {
            let (data, file) = Self.wrap(note, path)
            let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 3)
            let output = String(decoding: result.output, as: UTF8.self)
            let label = "[\(path)] \(note)"
            let surname = String(name.split(separator: " ").last!)
            #expect(!output.contains(surname) && !output.contains(String(surname.dropFirst(2))), "\(label): \(output)")
            let people = result.findings.filter { name.contains($0.original) }
            #expect(!people.isEmpty && people.allSatisfy { $0.entity == "PERSON" && !$0.suspected }, "\(label): \(result.findings)")
            #expect(!result.findings.contains { $0.doubt == .unconfirmed }, "\(label): \(result.findings)")
        }
    }
}
