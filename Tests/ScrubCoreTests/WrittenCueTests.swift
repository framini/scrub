import Foundation
@testable import ScrubCore
import Testing

/// What the words around a value say it is, through a text file, a JSON
/// field, a CSV cell and an XML element alike: a verb that opens an
/// instruction is no part of the name after it, a name in capitals beside a
/// first name, a title or a greeting is a name, an age said after a birth date
/// moves with it, a page's file name in a link is no one, a team's mailbox
/// is no one's, and an address in lowercase or named alone is read with
/// care. Every person, address and number here is invented.
@Suite(.serialized)
struct WrittenCueTests {
    enum Path: CaseIterable { case text, json, csv, xml }

    /// The prose as it reads after scrubbing, whatever held it, and the result.
    static func scrub(_ text: String, _ path: Path, seed: UInt64 = 1) throws -> (String, ScrubResult) {
        let data: Data, name: String
        switch path {
        case .text: (data, name) = (Data(text.utf8), "note.txt")
        case .json: (data, name) = (try JSONSerialization.data(withJSONObject: ["case_ref": "QX-2290", "state": "open", "body": text], options: [.sortedKeys]), "case.json")
        case .csv: (data, name) = (Data("case_ref,state,body\nQX-2290,open,\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"\n".utf8), "cases.csv")
        case .xml:
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            (data, name) = (Data("<case><ref>QX-2290</ref><state>open</state><body>\(escaped)</body></case>".utf8), "case.xml")
        }
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
        let output: String
        switch path {
        case .text: output = String(decoding: result.output, as: UTF8.self)
        case .json: output = ((try JSONSerialization.jsonObject(with: result.output)) as? [String: Any])?["body"] as? String ?? ""
        case .csv: output = try CSVFile.parse(String(decoding: result.output, as: UTF8.self), delimiter: ",").dropFirst().first?.last ?? ""
        case .xml: output = try XMLDocument(data: result.output).nodes(forXPath: "/case/body").first?.stringValue ?? ""
        }
        return (output, result)
    }

    // MARK: A verb before a name

    @Test(arguments: Path.allCases) func aVerbOpeningAnInstructionStaysAVerb(path: Path) throws {
        let text = "Call Odalys on +1 415 555 0182 about the renewal. Ping Teodoro Quillan when it ships.\nAsk Brisa for the signed copy."
        for seed in UInt64(0)..<3 {
            let (output, _) = try Self.scrub(text, path, seed: seed)
            #expect(SpreadTests.gone(["Odalys", "Teodoro", "Quillan", "Brisa"], from: output).isEmpty, "[\(path)] \(output)")
            // Each verb stays, followed by one stand-in name in capitals and lowercase: no "Hudson Hudson".
            let called = try #require(output.firstMatch(of: #/^Call ([A-Z][a-z]+) on \+1 /#)?.1, "[\(path)] \(output)")
            #expect(!["Call", "Odalys"].contains(String(called)), "[\(path)] \(output)")
            #expect(output.contains("Ping ") && output.contains("\nAsk ") && output.contains(" when it ships."), "[\(path)] \(output)")
            #expect(output.firstMatch(of: #/\b([A-Z][a-z]+) \1\b/#) == nil, "a stand-in repeats a word: [\(path)] \(output)")
        }
    }

    @Test func aStandInNameNeverRepeatsItsFirstNameAsItsSurname() {
        for seed in UInt64(0)..<40 {
            let people = People(rng: SeededGenerator(seed: seed))
            for index in 0..<300 {
                let person = people.register("Quorvan\(index)", "Teslin\(index)", gender: index.isMultiple(of: 3) ? "female" : nil)
                #expect(person.drawn.lowercased() != person.last.lowercased(), "seed \(seed): \(person.drawn) \(person.last)")
            }
        }
    }

    // MARK: Names in capitals

    @Test(arguments: Path.allCases) func aNameInCapitalsBesideACueIsAName(path: Path) throws {
        let text = "Hi JINX,\n\nThe deck looks good. Julie BEET will send the API notes to the CEO by Friday, and Ms BEET has the NASA contract ID.\n\nThanks,\nMarta"
        for seed in UInt64(0)..<3 {
            let (output, _) = try Self.scrub(text, path, seed: seed)
            #expect(SpreadTests.gone(["JINX", "BEET", "Julie"], from: output).isEmpty, "[\(path)] \(output)")
            // Acronyms stay; the stand-ins keep their capitals, and one person keeps one surname.
            for word in ["API", "CEO", "NASA", "ID"] { #expect(output.contains(" \(word)"), "[\(path)] \(word): \(output)") }
            #expect(output.firstMatch(of: #/^Hi [A-Z]{2,}[A-Z'-]*,/#) != nil, "[\(path)] \(output)")
            let surname = try #require(output.firstMatch(of: #/[A-Z][a-z]+ ([A-Z]{2,}[A-Z'-]*) will send/#)?.1, "[\(path)] \(output)")
            #expect(output.contains("Ms \(surname) has"), "[\(path)] \(output)")
        }
    }

    @Test(arguments: Path.allCases) func acronymsAndShoutedWordsStay(path: Path) throws {
        let text = "Hi TEAM,\n\nThe API is down again. ASAP please ask the CEO and the USA office for the NDA. FYI the ID badge is URGENT, NOT optional.\nDr NASA review is TBD.\n\nThanks"
        let (output, result) = try Self.scrub(text, path)
        #expect(output == text, "[\(path)] \(output)")
        #expect(result.counts["PERSON", default: 0] == 0, "[\(path)] \(result.counts)")
    }

    // MARK: An age after a birth date

    @Test(arguments: Path.allCases) func anAgeSaidAfterABirthDateMovesWithIt(path: Path) throws {
        let cases = [("She was born on 14 March 1987 and is ", 1987, 38, #/born on \d{1,2} [A-Z][a-z]+ (\d{4}) and is (\d{1,3})\./#),
                     ("He was born in 1990 and is now ", 1990, 35, #/born in (\d{4}) and is now (\d{1,3})\./#)]
        for (opening, year, age, pattern) in cases {
            for seed in UInt64(0)..<3 {
                let (output, _) = try Self.scrub(opening + "\(age).", path, seed: seed)
                let match = try #require(output.firstMatch(of: pattern), "[\(path)] \(output)")
                let (madeYear, madeAge) = (Int(match.1)!, Int(match.2)!)
                #expect(madeYear != year, "[\(path)] \(output)")
                #expect(madeAge == age + year - madeYear, "the age follows the date: [\(path)] \(output)")
            }
        }
        // With no birth date beside it, a bare number is no age.
        let (alone, _) = try Self.scrub("The invoice is 38. Her score is 41.", path)
        #expect(alone == "The invoice is 38. Her score is 41.", "[\(path)] \(alone)")
    }

    // MARK: Pages in links

    @Test(arguments: Path.allCases) func aPagesFileNameInALinkIsNoOne(path: Path) throws {
        let text = "The old login page lived at https://intranet.example.org/user/default.asp, the staff list at https://portal.example.org/users/index.html and the form at https://forms.example.org/members/login.php before the move."
        let (output, result) = try Self.scrub(text, path)
        #expect(output == text, "[\(path)] \(output)")
        #expect(result.counts["USERNAME", default: 0] == 0, "[\(path)] \(result.counts)")
        // A person's segment under the same collection is still someone's.
        let (profile, _) = try Self.scrub("Her profile moved to https://portal.example.org/users/odalys.ferriter last week.", path)
        #expect(!profile.contains("odalys") && profile.contains("https://portal.example.org/users/"), "[\(path)] \(profile)")
    }

    // MARK: Mailboxes of teams and lists

    @Test(arguments: Path.allCases) func aTeamsMailboxKeepsItsName(path: Path) throws {
        let text = "From: Ops Team <ops-team@kestrel.example>\nTo: Teodoro Quillan <teodoro.quillan@kestrel.example>\nCc: Billing <billing@kestrel.example>, Platform Announcements <announce-list@kestrel.example>\n\nThe rota is attached."
        for seed in UInt64(0)..<3 {
            let (output, _) = try Self.scrub(text, path, seed: seed)
            #expect(SpreadTests.gone(["Teodoro", "Quillan", "teodoro.quillan"], from: output).isEmpty, "[\(path)] \(output)")
            // The lists keep their names and mailboxes; their domain is the one the person's address takes.
            let person = try #require(output.firstMatch(of: #/To: [A-Z][a-z]+ [A-Z][a-z'-]+ <[a-z.]+@([a-z0-9.-]+)>/#)?.1, "[\(path)] \(output)")
            for list in ["Ops Team <ops-team@", "Billing <billing@", "Platform Announcements <announce-list@"] {
                #expect(output.contains(list + person + ">"), "[\(path)] \(list): \(output)")
            }
        }
        #expect(People.isRoleMailbox("no-reply@kestrel.example") && People.isRoleMailbox("support.emea@kestrel.example"))
        #expect(!People.isRoleMailbox("odalys.ferriter@kestrel.example") && !People.isRoleMailbox("teamlead.quillan@kestrel.example"))
    }

    // MARK: Addresses in lowercase, and named alone

    @Test(arguments: Path.allCases) func aLowercaseAddressAfterAnAddressCueIsReplacedInLowercase(path: Path) throws {
        let text = "we finally moved to 12 rue des lilas last month, come visit"
        for seed in UInt64(0)..<3 {
            let (output, result) = try Self.scrub(text, path, seed: seed)
            #expect(SpreadTests.gone(["lilas"], from: output).isEmpty, "[\(path)] \(output)")
            let address = try #require(output.firstMatch(of: #/^we finally moved to (\d+ [a-zà-ÿ' -]+) last month, come visit$/#)?.1, "[\(path)] \(output)")
            #expect(String(address) == address.lowercased() && address.hasPrefix(String(address.prefix { $0.isNumber })), "[\(path)] \(output)")
            #expect(result.counts["ADDRESS", default: 0] >= 1, "[\(path)] \(result.counts)")
        }
        // Without such words, a number before a street is directions.
        for directions in ["take bus 14 and get off at market street", "we sold 40 park benches on station road"] {
            let (output, result) = try Self.scrub(directions, path)
            #expect(output == directions && result.counts["ADDRESS", default: 0] == 0, "[\(path)] \(output)")
        }
    }

    @Test(arguments: Path.allCases) func aStreetNamedAloneIsAskedAboutNotGuessed(path: Path) throws {
        for (text, street) in [("Please send the parcel to Lindenhofweg instead.", "Lindenhofweg"), ("She lives at Mill Lane these days.", "Mill Lane")] {
            let (output, result) = try Self.scrub(text, path)
            // Left as written, never given a town's stand-in, and put to a person as an address.
            #expect(output == text, "[\(path)] \(output)")
            let finding = try #require(result.uncertain.first { $0.original == street }, "[\(path)] \(result.uncertain.map(\.original))")
            #expect(finding.entity == "ADDRESS" && finding.doubt == .unconfirmed, "[\(path)] \(finding.entity) \(String(describing: finding.doubt))")
        }
        #expect(AddressModel.streetAlone("Mill Lane") && AddressModel.streetAlone("Ahornweg") && AddressModel.streetAlone("Pear Tree Cottage"))
        #expect(!AddressModel.streetAlone("Mountain View") && !AddressModel.streetAlone("Notting Hill") && !AddressModel.streetAlone("Leeds") && !AddressModel.streetAlone("14 Mill Lane"))
    }

    // A lowercase title still leaves no surname behind; a word spelled like a title never makes the next word a person.
    @Test(arguments: Path.allCases) func lowercaseTitlesAndTitleWords(path: Path) throws {
        for title in ["sgt", "SGT", "capt", "cpl", "insp"] {
            let text = "Please speak to \(title) Baker at the front desk."
            let (output, _) = try Self.scrub(text, path, seed: 7)
            #expect(!output.contains("Baker") && output.hasPrefix("Please speak to \(title) "), "[\(path)] \(output)")
        }
        for text in ["We will miss Christmas with the family.", "Readings col Temperature were high.", "Sorry, we miss Tuesday standups again."] {
            let (output, _) = try Self.scrub(text, path, seed: 7)
            #expect(output == text, "[\(path)] \(output)")
        }
    }

    // A name learned elsewhere in the text is no person after "a" or "an".
    @Test(arguments: Path.allCases) func aNameAfterAnArticleIsAThing(path: Path) throws {
        for (text, kept) in [("Mason Treloar hired a Mason.", " hired a Mason."), ("Amber Lindqvist wore an Amber ring.", " wore an Amber ring.")] {
            let (output, _) = try Self.scrub(text, path, seed: 7)
            #expect(!output.hasPrefix(String(text.prefix(12))) && output.hasSuffix(kept), "[\(path)] \(output)")
        }
    }

    @Test(arguments: Path.allCases) func ordinaryClinicalPhrasesStay(path: Path) throws {
        for text in ["he may want to be there", "Referred onto the Cardiac REHAB Service.", "We might need to revisit the plan."] {
            let (output, _) = try Self.scrub(text, path, seed: 7)
            #expect(output == text, "[\(path)] \(output)")
        }
    }
}
