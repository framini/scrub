import Foundation
@testable import ScrubCore
import Testing

/// One person keeps one stand-in however their name is written, and two
/// people never share one: a middle name is no first name, a clipped first
/// name is its person's, the words a reader takes in before a name are none
/// of it, and a family shares a stand-in surname.
struct NameConsistencyTests {
    static func scrub(_ text: String, _ file: String, seed: UInt64 = 5) throws -> (ScrubResult, String) {
        let result = try Scrubber.scrub(Data(text.utf8), name: file, forceFullDetection: false, seed: seed)
        return (result, String(decoding: result.output, as: UTF8.self))
    }
    static func standIn(_ result: ScrubResult, _ original: String) -> String? {
        result.findings.first { $0.original == original && !$0.suspected }?.standIn
    }

    /// A middle name takes a first name of its own, never the one the first name took.
    @Test(arguments: [FieldLayout.json, .csv, .xml])
    func aMiddleNameIsNoFirstName(_ layout: FieldLayout) throws {
        for seed: UInt64 in 1...6 {
            let fields = [("applicant_id", "A-2291"), ("first_name", "Cordelia"), ("middle_name", "Rose"), ("last_name", "Fairweather"), ("dob", "1984-02-19")]
            let (data, file) = PersonFields.written(fields, layout, record: "applicant")
            let result = try Scrubber.scrub(data, name: file, forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            let first = try #require(Self.standIn(result, "Cordelia"), "[\(layout)] \(output)")
            let middle = try #require(Self.standIn(result, "Rose"), "[\(layout)] \(output)")
            #expect(first != middle && middle != "Rose" && first != "Cordelia", "[\(layout) seed \(seed)] Cordelia → \(first), Rose → \(middle)")
        }
        // A short form of the first name in the same record is that name, not another.
        let (result, output) = try Self.scrub(#"{"first_name": "Robert", "preferred_name": "Bob", "last_name": "Lindqvist"}"#, "member.json")
        #expect(Self.standIn(result, "Bob") == Self.standIn(result, "Robert"), "\(output)")
    }

    /// "Bart" signing a message Bartholomew Ng opened is him.
    @Test func aClippedFirstNameIsItsPersons() throws {
        let text = "Hi, I'm Bartholomew Ng.\n\nI've been locked out since Friday.\n\nThanks,\nBart\n"
        let (result, output) = try Self.scrub(text, "ticket.txt")
        let full = try #require(Self.standIn(result, "Bartholomew Ng"), "\(output)\n\(result.findings.map(\.original))")
        let short = try #require(Self.standIn(result, "Bart"), "\(output)")
        #expect(full.split(separator: " ").first.map(String.init) == short, "Bartholomew Ng → \(full), Bart → \(short)")
        #expect(output.contains(", I'm ") && !output.contains("I'm Bart"), "\(output)")
    }

    /// A short surname after a first name a cue is sure of goes with it: "I'm Bartholomew Ng." leaves no "Ng".
    @Test func aSelfIntroductionsSurnameGoesWithItsFirstName() throws {
        for text in ["I'm Bartholomew Ng. My account is locked.\n", "Hi, I'm Bartholomew Ng.\n\nI've been locked out since Friday.\n", "Spoke with Imani Oyelaran-Wu about the refund.\n"] {
            let (_, output) = try Self.scrub(text, "ticket.txt")
            #expect(!output.contains("Bartholomew") && !output.contains(" Ng") && !output.contains("Oyelaran"), "\(output)")
        }
    }

    /// A time's "PM" before a name is no part of it: the sender keeps one stand-in through the thread.
    @Test func aNameAfterATimeKeepsOneStandIn() throws {
        let text = """
        Thanks, will do.

        On Wed, Oct 1, 2026 at 4:12 PM Jasper Thornquist <jasper.thornquist@example.org> wrote:
        > Hi Wilhelmina,
        > Can you send the signed copy?
        >
        > Jasper Thornquist

        """
        let (result, output) = try Self.scrub(text, "thread.txt")
        let names = result.findings.filter { $0.original.contains("Thornquist") && !$0.original.contains("@") }
        #expect(names.map(\.original) == ["Jasper Thornquist"], "\(names.map(\.original))\n\(output)")
        #expect(output.contains("4:12 PM "), "\(output)")
    }

    /// A chat's speaker is read whole: "Wren" is Cassius Wren's surname, and takes a surname.
    @Test func aChatSpeakerIsReadWhole() throws {
        let text = "[09:02] Cassius Wren: morning! anyone seen the deploy logs?\n[09:04] Ines Okoro: on it\n[09:05] Cassius Wren: thx.\n"
        let (result, output) = try Self.scrub(text, "chat.txt")
        let standIn = try #require(Self.standIn(result, "Cassius Wren"), "\(result.findings.map(\.original))\n\(output)")
        #expect(output.components(separatedBy: standIn + ":").count == 3, "\(output)")
        #expect(!output.contains("Wren") && !output.contains("Cassius"), "\(output)")
    }

    /// A patient and their contact share a surname, so their stand-ins do; the patient's
    /// email, written with a short form of her first name, follows her own stand-in.
    @Test func aFamilySharesItsStandInSurname() throws {
        let text = """
        {"resourceType": "Patient", "id": "pt-1", "name": [{"family": "Abernathy", "given": ["Clementine"]}],
         "telecom": [{"system": "email", "value": "clem.abernathy@example.com"}],
         "contact": [{"relationship": [{"text": "Brother"}], "name": {"family": "Abernathy", "given": ["Ezra"]}}]}
        """
        for seed: UInt64 in 1...4 {
            let (result, output) = try Self.scrub(text, "patient.json", seed: seed)
            let surnames = result.findings.filter { $0.original == "Abernathy" }.map(\.standIn)
            #expect(Set(surnames).count == 1 && surnames.count >= 1, "seed \(seed): \(surnames)\n\(output)")
            let first = try #require(Self.standIn(result, "Clementine")), brother = try #require(Self.standIn(result, "Ezra"))
            #expect(first != brother, "seed \(seed)")
            let email = try #require(Self.standIn(result, "clem.abernathy@example.com"))
            let local = email.lowercased().split(separator: "@").first.map(String.init) ?? ""
            #expect(local.contains(surnames.first?.lowercased() ?? "?") && !local.contains(brother.lowercased()), "seed \(seed): \(email) for \(first) \(surnames)")
        }
    }

    /// A first name that gives no sex takes the one a pronoun after it in its sentence gives.
    @Test func aPronounAfterANameGivesItsStandInsSex() throws {
        let text = """
        My former manager, Dr. Benedikt Sauer, can speak to my work; he is reachable at benedikt.sauer@example.de.
        Also ask Dr. Ioana Brancusi; she supervised the audit.

        """
        for seed: UInt64 in 1...8 {
            let (result, output) = try Self.scrub(text, "letter.txt", seed: seed)
            for (name, sex) in [("Dr. Benedikt Sauer", "male"), ("Dr. Ioana Brancusi", "female")] {
                let standIn = try #require(Self.standIn(result, name), "\(output)")
                let first = standIn.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                // The stand-in's first name is drawn from that sex's names.
                #expect((sex == "male" ? Names.male : Names.female).contains(first.lowercased()), "seed \(seed): \(name) → \(standIn)")
            }
        }
    }

    /// A holder's first name in their record's notes takes the record's stand-in, and their
    /// spouse, of the same surname, shares the stand-in surname but not the first name.
    @Test func aHoldersFirstNameInNotesIsTheirs() throws {
        let text = #"<?xml version="1.0"?>\#n<Holder><FirstName>Percival</FirstName><LastName>Underhill-Graves</LastName><Notes>Spoke with Percival on 2026-09-01; spouse Marguerite Underhill-Graves is joint holder.</Notes></Holder>\#n"#
        for seed: UInt64 in 1...4 {
            let (result, output) = try Self.scrub(text, "holder.xml", seed: seed)
            let first = try #require(Self.standIn(result, "Percival"), "\(output)")
            let spouse = try #require(Self.standIn(result, "Marguerite Underhill-Graves"), "\(output)")
            #expect(result.findings.filter { $0.original == "Percival" }.count == 1, "seed \(seed): \(output)")
            #expect(!spouse.hasPrefix(first + " "), "seed \(seed): \(first) / \(spouse)")
            #expect(spouse.hasSuffix(" " + (Self.standIn(result, "Underhill-Graves") ?? "?")), "seed \(seed): \(output)")
        }
    }

    /// A full name closing a file's name before its extension is replaced whole, as the
    /// home folder spelling the same person is; a file named with ordinary words stays.
    @Test func aNameInAFilesNameIsReplacedWhole() throws {
        let report = "Process:  Ledgerly [4412]\nLast file: /Users/genevieve.oduya/Documents/2025 return - Genevieve Oduya.ledger\nAlso open: Annual Report.pdf\n"
        let json = #"{"recent": ["/Users/genevieve.oduya/Documents/2025 return - Genevieve Oduya.ledger", "/Users/genevieve.oduya/Documents/Annual Report.pdf"]}"#
        for (text, file) in [(report, "crash.txt"), (json, "recent.json")] {
            let (result, output) = try Self.scrub(text, file)
            #expect(!output.contains("Oduya") && !output.lowercased().contains("genevieve"), "\(output)")
            #expect(output.contains("Annual Report.pdf"), "\(output)")
            let full = try #require(Self.standIn(result, "Genevieve Oduya"), "\(result.findings.map(\.original))")
            #expect(output.contains(" - \(full).ledger"), "\(output)")
        }
    }

    /// A name written with and without its accents, apostrophe or ß, in capitals or not, is one person's:
    /// a card's embossed "EABHA ODWYER" is the "Éabha O'Dwyer" of the account.
    @Test func aNameKeepsItsStandInWithoutItsAccentsOrApostrophe() throws {
        for seed: UInt64 in 1...6 {
            let text = #"{"account": {"full_name": "Éabha O'Dwyer", "card": {"cardholder": "EABHA ODWYER", "last4": "4417"}}, "payee": {"name": "Lukas Großmann", "reference": "LUKAS GROSSMANN"}}"#
            let (result, output) = try Self.scrub(text, "account.json", seed: seed)
            let account = try #require(Self.standIn(result, "Éabha O'Dwyer"), "\(output)")
            let card = try #require(Self.standIn(result, "EABHA ODWYER"), "\(output)")
            #expect(card == account.uppercased(), "[seed \(seed)] \(output)")
            let payee = try #require(Self.standIn(result, "Lukas Großmann"), "\(output)")
            #expect(Self.standIn(result, "LUKAS GROSSMANN") == payee.uppercased(), "[seed \(seed)] \(output)")
        }
    }

    /// One person under compound given names and a double surname keeps one stand-in in each of the ways
    /// a record writes them: in parts, in capitals, by one given name and one surname, and surname first.
    @Test func aCompoundNameKeepsOneStandInHoweverWritten() throws {
        for seed: UInt64 in 1...6 {
            let text = #"{"first_name": "Ana Lucía", "last_name": "Ferreira Halvorsen", "names": [{"first": "ANA", "middle": "LUCIA", "last": "FERREIRA HALVORSEN"}, {"first": "Ana", "last": "Halvorsen", "type": "aka"}, {"full": "Ferreira Halvorsen, Ana Lucía", "type": "reported"}, {"full": "Ana Lucía Ferreira Halvorsen"}]}"#
            let (result, output) = try Self.scrub(text, "identity.json", seed: seed)
            let first = try #require(Self.standIn(result, "Ana Lucía"), "\(output)")
            let last = try #require(Self.standIn(result, "Ferreira Halvorsen"), "\(output)")
            #expect(Self.standIn(result, "ANA") == first.uppercased(), "[seed \(seed)] \(output)")
            #expect(output.contains(#"{"first": "\#(first)", "last": "\#(last)", "type": "aka"}"#), "[seed \(seed)] \(output)")
            #expect(Self.standIn(result, "Ferreira Halvorsen, Ana Lucía") == last + ", " + first, "[seed \(seed)] \(output)")
            #expect(Self.standIn(result, "Ana Lucía Ferreira Halvorsen") == first + " " + last, "[seed \(seed)] \(output)")
        }
        // In a message, her given names alone and her surname alone are hers too.
        let text = "Customer: Ana Lucía Ferreira Halvorsen\nHi Ana Lucía,\nAlso: Ferreira Halvorsen, Ana Lucía has a duplicate account.\nAna Halvorsen called back.\n"
        let (result, output) = try Self.scrub(text, "ticket.txt")
        let full = try #require(Self.standIn(result, "Ana Lucía Ferreira Halvorsen"), "\(output)")
        let parts = full.split(separator: " ").map(String.init)
        #expect(output.contains("Hi \(parts[0]),") && output.contains("Also: \(parts[1]), \(parts[0]) has") && output.contains("\(full) called back"), "\(output)")
    }

    /// A middle initial and the middle name it stands for, or a short form of the first name,
    /// are one person in a credit header's aliases, and a spouse of the surname shares its stand-in.
    @Test func aMiddleInitialAndItsNameAreOnePerson() throws {
        for seed: UInt64 in 1...6 {
            let text = #"{"subject": {"name": {"first": "WILLIAM", "middle": "K", "last": "BRANNIGAN", "suffix": ""}, "aka": ["BILL BRANNIGAN", "WILLIAM KEITH BRANNIGAN"], "ssn": "123-45-6789"}, "spouse": {"first": "MARGARET", "last": "BRANNIGAN"}}"#
            let (result, output) = try Self.scrub(text, "header.json", seed: seed)
            let first = try #require(Self.standIn(result, "WILLIAM"), "\(output)")
            let last = try #require(Self.standIn(result, "BRANNIGAN"), "\(output)")
            #expect(Self.standIn(result, "BILL BRANNIGAN") == first + " " + last, "[seed \(seed)] \(output)")
            #expect(Self.standIn(result, "WILLIAM KEITH BRANNIGAN") == first + " " + last, "[seed \(seed)] \(output)")
            #expect(!output.contains("BRANNIGAN") && output.components(separatedBy: last).count == 5, "[seed \(seed)] \(output)")
        }
    }

    /// Two account holders joined by "&" are two people, each the one named elsewhere, and a surname
    /// they share stays shared; a match input's double surname written apart is the holder's.
    @Test func jointHoldersAreEachTheirOwn() throws {
        for seed: UInt64 in 1...6 {
            let text = #"{"accounts": [{"holder_name": "Ngozi Adeyemi-Eze", "name_match": {"input": "N Adeyemi Eze", "score": 0.91}}, {"holder_name": "NGOZI ADEYEMI-EZE & TUNDE EZE", "type": "joint"}, {"holder_name": "Tunde Eze"}, {"holder_name": "KEMI & DAYO OKONJO-BALOGUN"}]}"#
            let (result, output) = try Self.scrub(text, "accounts.json", seed: seed)
            let ngozi = try #require(Self.standIn(result, "Ngozi Adeyemi-Eze"), "\(output)")
            let tunde = try #require(Self.standIn(result, "Tunde Eze"), "\(output)")
            #expect(ngozi != tunde, "\(output)")
            #expect(Self.standIn(result, "NGOZI ADEYEMI-EZE & TUNDE EZE") == ngozi.uppercased() + " & " + tunde.uppercased(), "[seed \(seed)] \(output)")
            #expect(tunde.split(separator: " ").last == ngozi.split(separator: " ").last, "[seed \(seed)] a shared surname: \(output)")
            #expect(output.contains(#""input": "N \#(ngozi.split(separator: " ")[1])""#), "[seed \(seed)] \(output)")
            let pair = try #require(Self.standIn(result, "KEMI & DAYO OKONJO-BALOGUN"), "\(output)")
            let words = pair.split(separator: " ")
            #expect(words.count == 4 && words[1] == "&" && words[0] != words[2] && !pair.contains("KEMI") && !pair.contains("DAYO"), "[seed \(seed)] \(output)")
        }
    }

    /// Two people of one first name, each in a record with an email of their own (an applicant and
    /// a co-applicant), take first names of their own, so each one's first name alone is theirs; one
    /// person's first name written again with a prior surname still keeps one stand-in.
    @Test func twoPeopleOfOneFirstNameTakeTheirOwn() throws {
        let check = """
        {"application_id": "APP-30417", "applicant": {"first_name": "Marisol", "last_name": "Thornbury", "full_name": "Marisol Thornbury", "email": "marisol.thornbury@example.com", "dob": "1986-04-12"},
         "co_applicant": {"first_name": "Marisol", "last_name": "Achterberg", "full_name": "Marisol Achterberg", "email": "m.achterberg@example.org", "dob": "1990-11-03"}}
        """
        let rows = "role,full_name,first_name,email\napplicant,Marisol Thornbury,Marisol,marisol.thornbury@example.com\nco_applicant,Marisol Achterberg,Marisol,m.achterberg@example.org\n"
        for (text, file) in [(check, "application.json"), (rows, "applicants.csv")] {
            for seed: UInt64 in 1...4 {
                let (result, output) = try Self.scrub(text, file, seed: seed)
                let one = try #require(Self.standIn(result, "Marisol Thornbury"), "\(output)"), other = try #require(Self.standIn(result, "Marisol Achterberg"), "\(output)")
                #expect(one.split(separator: " ").first != other.split(separator: " ").first, "[\(file) seed \(seed)] \(one) / \(other)")
                let firsts = result.findings.filter { $0.original == "Marisol" }.map(\.standIn)
                #expect(Set(firsts).count == 2 && !output.contains("Marisol"), "[\(file) seed \(seed)] \(firsts)\n\(output)")
            }
        }
        let graph = #"{"person_id": "P-7", "names": [{"first": "Marisol", "last": "Thornbury", "type": "PRIMARY"}, {"first": "Marisol", "last": "Achterberg", "type": "PRIOR_NAME"}], "emails": [{"address": "marisol.thornbury@example.com"}]}"#
        for seed: UInt64 in 1...4 {
            let (result, output) = try Self.scrub(graph, "person.json", seed: seed)
            #expect(Set(result.findings.filter { $0.original == "Marisol" }.map(\.standIn)).count == 1, "[seed \(seed)] \(output)")
        }
    }
}

/// A screening batch of many people: those of different surnames never share a stand-in surname,
/// and two of one surname share theirs, whatever the seed.
@Test func differentSurnamesNeverShareAStandInSurname() throws {
    let firsts = ["Odalys", "Tamsin", "Benedikt", "Imogen", "Caspian", "Rosalind", "Ignatius", "Philippa", "Lorcan", "Annika", "Evander", "Marisol",
                  "Thaddeus", "Ottilie", "Leopold", "Clementine", "Barnaby", "Henrietta", "Ambrose", "Wilhelmina", "Cosimo", "Delphine", "Florian", "Josephine"]
    let lasts = ["Quillfeather", "Ashcombe", "Marlowe", "Penhallow", "Thornbury", "Wexley", "Brackenridge", "Halloran", "Ferriter", "Ravensworth", "Ellery", "Pendergast",
                 "Kingsmill", "Ostrander", "Fairweather", "Lockhart", "Dunmore", "Whitcombe", "Achterberg", "Merriweather", "Gallagher", "Haverford", "Stanhope", "Vandermeer"]
    var subjects = zip(firsts, lasts).map { #"{"first_name": "\#($0)", "last_name": "\#($1)", "status": "clear"}"# }
    // Two of one family.
    subjects.append(#"{"first_name": "Winifred", "last_name": "Quillfeather", "status": "review"}"#)
    let json = "{\"batch\": \"B-2207\", \"subjects\": [\n" + subjects.joined(separator: ",\n") + "\n]}\n"
    for seed: UInt64 in 1...6 {
        let result = try Scrubber.scrub(Data(json.utf8), name: "screening.json", forceFullDetection: false, seed: seed)
        let object = try JSONSerialization.jsonObject(with: result.output) as? [String: Any]
        let rows = try #require(object?["subjects"] as? [[String: Any]])
        let drawn = rows.compactMap { $0["last_name"] as? String }
        #expect(drawn.count == lasts.count + 1)
        for last in lasts { #expect(!drawn.contains(last), "\(last) left as written") }
        // Rows 0 and the last are one family; every other row is a family of its own.
        #expect(drawn.first == drawn.last, "seed \(seed): \(drawn)")
        #expect(Set(drawn.dropLast()).count == lasts.count, "seed \(seed): \(drawn)")
    }
}
