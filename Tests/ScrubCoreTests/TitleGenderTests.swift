import Foundation
@testable import ScrubCore
import Testing

/// A title beside a surname ("Ms. Okafor") never joins a first name that is
/// clearly of the other sex ("Mateus Okafor"): they are two people of one
/// family, with one stand-in surname. A first name given to either sex
/// ("Jordan"), a short form of names of both ("Alex"), or a name the lists
/// don't know still joins, as before.
@Suite struct TitleGenderTests {
    @Test func firstNamesClearlyOfOneSex() {
        for name in ["Mateus", "Siobhan", "Declan", "Ifeoma", "Aurelio"] { #expect(NameLists.gender(ofFirst: name) != nil, "\(name)") }
        #expect(NameLists.gender(ofFirst: "Mateus") == "male" && NameLists.gender(ofFirst: "Siobhan") == "female")
        for name in ["Jordan", "Quinn", "Alex", "Sam", "Chris", "Oluwaseun", "Corentin", "J", "J."] { #expect(NameLists.gender(ofFirst: name) == nil, "\(name)") }
    }

    @Test func aTitleKeepsApartAFirstNameOfTheOtherSex() {
        for seed in UInt64(0)..<20 {
            for order in [["Mateus Okafor", "Ms. Okafor"], ["Ms. Okafor", "Mateus Okafor"]] {
                let people = People(rng: SeededGenerator(seed: seed))
                let (first, _) = people.registerFull(order[0])
                let (second, _) = people.registerFull(order[1])
                #expect(first !== second, "\(order) seed \(seed)")
                #expect(first.last == second.last, "\(order) seed \(seed): one family, one stand-in surname")
                let mateus = order[0].hasPrefix("Mateus") ? first : second
                // Mateus no longer takes the title's sex; his own first name says he is a man.
                #expect(Names.male.contains(mateus.first.lowercased()), "\(order) seed \(seed): \(mateus.first)")
                // "Mr. Okafor" is Mateus; "Okafor" alone reads as the family's surname.
                #expect(people.registerFull("Mr. Okafor").0 === mateus)
                #expect(people.name(for: "Okafor") == mateus.last)
            }
        }
    }

    @Test func aFirstNameForEitherSexStillJoins() {
        for seed in UInt64(0)..<20 {
            for name in ["Jordan Okafor", "Oluwaseun Okafor", "Siobhan Okafor"] {
                let people = People(rng: SeededGenerator(seed: seed))
                let (person, _) = people.registerFull(name)
                #expect(people.registerFull("Ms. Okafor").0 === person, "\(name) seed \(seed)")
            }
        }
    }

    /// The same note in a text file, a JSON field, a CSV cell and an XML element.
    @Test func twoPeopleOfOneFamilyOnEveryPath() throws {
        let notes = ["Mateus Okafor called about the lease renewal. Ms. Okafor will sign it on Friday, and Mateus will drop off the keys.",
                     "Ms. Okafor asked for a copy of the lease. Her son Mateus Okafor will collect it on Friday."]
        for note in notes {
            var inputs = PIIGaps.InputPath.allCases.map { PIIGaps.wrap(note, $0) }
            inputs.append((Data("<tickets><ticket><id>4471</id><note>\(note)</note></ticket></tickets>".utf8), "tickets.xml"))
            for (data, name) in inputs {
                for seed in UInt64(1)...4 {
                    let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                    let output = String(decoding: result.output, as: UTF8.self)
                    #expect(!output.contains("Okafor") && !output.contains("Mateus"), "\(name): \(output)")
                    // Type oracle: "Ms. <surname>" keeps its title; the man's full name shares that surname and has a man's first name.
                    let titled = try #require(output.firstMatch(of: /Ms\. (\p{Lu}[\p{L}'-]+)/), "\(name): \(output)")
                    let surname = String(titled.output.1)
                    let full = try #require(output.firstMatch(of: try Regex("(\\p{Lu}\\p{Ll}+) \(surname)(?! will sign| asked)")), "\(name): \(output)")
                    let first = String(full.output[1].substring ?? "")
                    #expect(Names.male.contains(first.lowercased()), "\(name) seed \(seed): \(first) \(surname) in \(output)")
                    if note.contains("Mateus will") { #expect(output.contains(" \(first) will drop off"), "\(name): \(output)") }
                }
            }
        }
    }
}
