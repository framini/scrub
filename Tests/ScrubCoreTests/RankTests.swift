import Foundation
@testable import ScrubCore
import Testing

/// A military or police rank is a title: it stays as written before the
/// stand-in, and the name after it is the person, on every input path. A
/// rank that is also a word ("private", "major", "general") is one only
/// with its capital before a name.
@Suite struct RankTests {
    typealias Path = PersonScorerTests.Path

    static let ranked: [(text: String, ranks: [String], gone: [String])] = [
        ("Corporal Haddleton reported to Sergeant Pryce and Lieutenant Varga.", ["Corporal ", "Sergeant ", "Lieutenant "], ["Haddleton", "Pryce", "Varga"]),
        ("Constable Brightmore took the statement; Detective Inspector Quayle signed it.", ["Constable ", "Detective Inspector "], ["Brightmore", "Quayle"]),
        ("Sgt. Okonkwo and Capt. Ravensworth met Private Ellery at the gate.", ["Sgt. ", "Capt. ", "Private "], ["Okonkwo", "Ravensworth", "Ellery"]),
    ]

    @Test(arguments: Path.allCases) func aRankStaysAndTheNameAfterItGoes(path: Path) throws {
        for sample in Self.ranked {
            for seed in UInt64(1)...2 {
                let (output, result) = try PersonScorerTests.scrub(sample.text, path, seed: seed)
                let label = "[\(path) seed \(seed)] \(output.debugDescription)"
                #expect(SpreadTests.gone(sample.gone, from: output).isEmpty, "\(SpreadTests.gone(sample.gone, from: output)) left: \(label)")
                for rank in sample.ranks {
                    // The rank is followed by a stand-in name with its capital, never replaced itself.
                    let pattern = NSRegularExpression.escapedPattern(for: rank) + #"\p{Lu}\p{Ll}+"#
                    #expect(output.range(of: pattern, options: .regularExpression) != nil, "\(rank) lost: \(label)")
                }
                // Every one replaced is a person, and no rank is a finding's whole original.
                #expect(result.findings.allSatisfy { $0.entity == "PERSON" }, "\(result.findings.map { "\($0.entity):\($0.original)" }) \(label)")
                #expect(!result.findings.contains { WrittenNames.ranks.contains($0.original.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))) }, "\(label)")
            }
        }
    }

    static let words = [
        "It is a private matter for the board.",
        "There is a major issue with the general ledger.",
        "In general the corporal punishment debate is over.",
        "The detective novels and the captain's log are on the shelf.",
    ]

    @Test(arguments: Path.allCases) func ranksWrittenAsWordsStay(path: Path) throws {
        for text in Self.words {
            let (output, result) = try PersonScorerTests.scrub(text, path, seed: 1)
            #expect(output == text, "[\(path)] \(output.debugDescription)")
            #expect(result.findings.isEmpty, "[\(path)] \(result.findings.map(\.original))")
        }
    }

    @Test func ranksAreRolesAndTitles() {
        for rank in ["Corporal", "Constable", "Detective", "Sgt", "Lt.", "Superintendent", "Trooper"] {
            #expect(NameShape.isRole(rank), "\(rank)")
            #expect(People.isTitle(rank), "\(rank)")
        }
        #expect(NameShape.isRole("Private") && NameShape.isRole("Major") && NameShape.isRole("General"))
        #expect(!NameShape.isRole("private") && !NameShape.isRole("major") && !NameShape.isRole("general"))
    }
}

/// A word a dictionary holds and no list of names does ("Refund") is a word
/// when one detector reads it as a surname: it is not found everywhere else
/// it is written, in lowercase or opening a sentence.
@Suite struct WordsReadAsNamesTests {
    typealias Path = PersonScorerTests.Path

    static let note = "Thanks,\nSaoirse Refund approved for Alice Murray after review. The refund went out Friday.\nRefund forms are attached, and the refund desk has a copy."

    @Test(arguments: Path.allCases) func aWordReadAsASurnameStaysAWordElsewhere(path: Path) throws {
        for seed in UInt64(1)...3 {
            let (output, _) = try PersonScorerTests.scrub(Self.note, path, seed: seed)
            let label = "[\(path) seed \(seed)] \(output.debugDescription)"
            #expect(output.contains("The refund went out Friday."), "\(label)")
            #expect(output.contains("\nRefund forms are attached, and the refund desk has a copy."), "\(label)")
            #expect(!output.contains("Alice Murray"), "\(label)")
        }
    }

    @Test func dictionaryWordsNoListHoldsAreUnlisted() {
        #expect(NameLists.isUnlistedWord("Refund") && NameLists.isUnlistedWord("refunds"))
        // A listed name is never one, even where a dictionary holds it.
        #expect(!NameLists.isUnlistedWord("Odalys") && !NameLists.isUnlistedWord("Ferriter") && !NameLists.isUnlistedWord("Will"))
        #expect(NameLists.isWord("refund") && NameLists.isWord("will"))
    }
}

/// A rank written after a first name is that person's surname.
@Suite struct RankSurnameTests {
    @Test(arguments: PersonScorerTests.Path.allCases) func aRankAfterAFirstNameIsASurname(path: PersonScorerTests.Path) throws {
        let text = "Tickets for Evan Ensign and Marisol Major were sent to the box office."
        for seed in UInt64(1)...2 {
            let (output, _) = try PersonScorerTests.scrub(text, path, seed: seed)
            #expect(SpreadTests.gone(["Evan", "Ensign", "Marisol", "Major"], from: output).isEmpty, "[\(path) seed \(seed)] \(output.debugDescription)")
        }
    }
}
