import Foundation
@testable import ScrubCore
import Testing

/// One person, one stand-in: a name and every part of it read the same way
/// wherever the document writes it, whatever order it names the person in;
/// and one value read as two kinds in two places still has one stand-in.
struct ConsistencyTests {
    static func isName(_ word: Substring) -> Bool { word.wholeMatch(of: /[A-Z][a-z'-]+/) != nil }
    static func folded(_ value: Substring) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter(\.isLetter)
    }

    /// A greeting names her first, a title her surname, and the address she
    /// is reached at both; another person is named between them.
    static let note = """
    Hi Odalys,

    Ms Ferriter moved to Boise last spring and now works at Tallowmere Freight. Odalys said the Boise office needs her badge.
    can you ask oluwaseun to resend the form? Reach her at odalys.ferriter@corvane.test or 208-555-0143.

    Thanks,
    Tamsin
    """

    @Test func aLoneFirstNameIsOnePersonThroughANote() throws {
        for seed in UInt64(0)..<4 {
            for path in PIIGaps.InputPath.allCases {
                let (output, result) = try SpreadTests.scrub(Self.note, path, seed: seed)
                #expect(SpreadTests.gone(["Odalys", "Ferriter", "oluwaseun", "Tamsin"], from: output).isEmpty, "[\(path)] \(output)")
                let greeted = try #require(output.firstMatch(of: /^Hi ([^,\s]+),/)?.1, "[\(path)] \(output)")
                let said = try #require(output.firstMatch(of: /\. (\S+) said the/)?.1, "[\(path)] \(output)")
                let surname = try #require(output.firstMatch(of: /Ms (\S+) moved/)?.1, "[\(path)] \(output)")
                let email = try #require(output.firstMatch(of: /at ([^@\s]+)@([a-z0-9.-]+\.[a-z]+) or/), "[\(path)] \(output)")
                #expect(Self.isName(greeted) && Self.isName(surname), "[\(path)] \(output)")
                #expect(greeted == said, "one first name, one stand-in: [\(path) seed \(seed)] \(output)")
                // Her address is built from her stand-in name as the original is from hers.
                #expect(email.1 == Self.folded(greeted) + "." + Self.folded(surname), "[\(path) seed \(seed)] \(output)")
                let finding = try #require(result.findings.first { $0.original == "Odalys" })
                #expect(finding.standIn == String(greeted) && finding.occurrences == 2, "[\(path)] \(result.findings)")
            }
        }
    }

    /// The parts before the full name and after it, with another person known
    /// only by title and surname between them, in every input path: one note,
    /// a CSV whose rows name her in different cells, and JSON objects.
    @Test func everyPartFollowsTheFullName() throws {
        let text = "Ferriter called twice about the refund.\nUpdate from Odalys Ferriter: she paid by transfer.\nMr Okonjo approved the refund on Monday.\nHi Odalys, the card was declined again.\nOdalys said the receipt is attached, and Ferriter's account is clear."
        let csv = "ticket,contact,remark\n4471,,Ferriter called twice about the refund.\n4472,Odalys Ferriter,she paid by transfer\n4473,,Mr Okonjo approved the refund on Monday.\n4474,,\"Hi Odalys, the card was declined again.\"\n4475,,\"Odalys said the receipt is attached, and Ferriter's account is clear.\"\n"
        let json = #"{"tickets": [{"id": 4471, "remark": "Ferriter called twice about the refund."}, {"id": 4472, "contact": {"first_name": "Odalys", "last_name": "Ferriter"}, "remark": "she paid by transfer"}, {"id": 4473, "remark": "Mr Okonjo approved the refund on Monday."}, {"id": 4474, "remark": "Hi Odalys, the card was declined again."}, {"id": 4475, "remark": "Odalys said the receipt is attached, and Ferriter's account is clear."}]}"#
        for seed in UInt64(0)..<4 {
            for path in PIIGaps.InputPath.allCases {
                let (output, _) = try SpreadTests.scrub(text, path, seed: seed)
                let full = try #require(output.firstMatch(of: /from (\S+) (\S+): she/), "[\(path)] \(output)")
                try Self.expectParts(of: (full.1, full.2), in: output, "[\(path) seed \(seed)]")
            }
            let table = try Scrubber.scrub(Data(csv.utf8), name: "tickets.csv", forceFullDetection: false, seed: seed)
            let rows = try CSVFile.parse(String(decoding: table.output, as: UTF8.self), delimiter: ",")
            #expect(rows.count == 6 && rows.allSatisfy { $0.count == 3 } && rows.dropFirst().map { $0[0] } == ["4471", "4472", "4473", "4474", "4475"], "\(rows)")
            let contact = try #require(rows[2][1].firstMatch(of: /^(\S+) (\S+)$/), "\(rows)")
            try Self.expectParts(of: (contact.1, contact.2), in: rows.dropFirst().map { $0[2] }.joined(separator: "\n"), "[csv rows, seed \(seed)]")
            let object = try Scrubber.scrub(Data(json.utf8), name: "tickets.json", forceFullDetection: false, seed: seed)
            let tickets = try #require((JSONSerialization.jsonObject(with: object.output) as? [String: Any])?["tickets"] as? [[String: Any]])
            #expect(tickets.map { $0["id"] as? Int } == [4471, 4472, 4473, 4474, 4475], "\(tickets)")
            let name = try #require(tickets[1]["contact"] as? [String: String])
            let first = try #require(name["first_name"]), last = try #require(name["last_name"])
            try Self.expectParts(of: (Substring(first), Substring(last)), in: tickets.compactMap { $0["remark"] as? String }.joined(separator: "\n"), "[json objects, seed \(seed)]")
        }
    }

    static func expectParts(of full: (Substring, Substring), in output: String, _ label: String) throws {
        #expect(isName(full.0) && isName(full.1), "\(label) \(output)")
        #expect(SpreadTests.gone(["Odalys", "Ferriter", "Okonjo"], from: output).isEmpty, "\(label) \(output)")
        let other = try #require(output.firstMatch(of: /Mr (\S+) approved/)?.1, "\(label) \(output)")
        #expect(isName(other) && other != full.1, "another person, another surname: \(label) \(output)")
        #expect(output.hasPrefix("\(full.1) called twice"), "the surname alone is hers: \(label) \(output)")
        #expect(output.contains("Hi \(full.0), the card"), "the greeting is hers: \(label) \(output)")
        #expect(output.contains("\n\(full.0) said") && output.contains("and \(full.1)'s account"), "\(label) \(output)")
    }

    /// A value under a username key, written again in a note where a rule
    /// reads it as a password: one stand-in, which still reads as a username.
    @Test func oneValueReadAsTwoKindsHasOneStandIn() throws {
        let original = "mfarrow1987"
        let note = "Temp password=\(original) set at the customer's request, same as the login; ask them to rotate it."
        let inputs: [(String, Data)] = [
            ("account.json", Data(#"{"account": {"username": "\#(original)", "plan": "basic"}, "note": "\#(note)"}"#.utf8)),
            ("accounts.csv", Data("username,plan,note\n\(original),basic,\"\(note)\"\n".utf8)),
            ("account.xml", Data("<account><username>\(original)</username><plan>basic</plan><note>\(note)</note></account>".utf8)),
            ("account.txt", Data("username: \(original)\nplan: basic\nnote: \(note)\n".utf8)),
        ]
        for seed in UInt64(0)..<4 {
            for (name, data) in inputs {
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let output = String(decoding: result.output, as: UTF8.self)
                #expect(!output.contains(original), "\(name): \(output)")
                let (username, written): (String?, String?)
                switch name {
                case "account.json":
                    let object = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
                    let account = object["account"] as? [String: String]
                    #expect(account?["plan"] == "basic", "\(output)")
                    (username, written) = (account?["username"], object["note"] as? String)
                case "accounts.csv":
                    let rows = try CSVFile.parse(output, delimiter: ",")
                    #expect(rows.count == 2 && rows[1].count == 3 && rows[1][1] == "basic", "\(output)")
                    (username, written) = (rows[1][0], rows[1][2])
                case "account.xml":
                    let root = try #require(XMLDocument(data: result.output, options: []).rootElement())
                    #expect(root.elements(forName: "plan").first?.stringValue == "basic", "\(output)")
                    (username, written) = (root.elements(forName: "username").first?.stringValue, root.elements(forName: "note").first?.stringValue)
                default:
                    (username, written) = (output.firstMatch(of: /username: (\S+)\n/).map { String($0.1) }, output.firstMatch(of: /note: ([^\n]+)\n/).map { String($0.1) })
                }
                // A username stays one: a short run of letters, digits and joiners.
                let fake = try #require(username, "\(name): \(output)")
                #expect(fake.contains(/^[A-Za-z0-9._-]{3,32}$/) && fake != original, "\(name): \(fake)")
                #expect(written == note.replacingOccurrences(of: original, with: fake), "\(name) seed \(seed): \(output)")
                #expect(result.findings.filter { $0.original == original }.count == 1, "\(name): \(result.findings)")
            }
        }
    }

    /// The property case that found it (seed 1823212342, case 12), reduced: a
    /// login and a note the context model reads as holding a secret.
    @Test func generatedLoginInANoteKeepsItsStandIn() throws {
        let token = "Qz7rbjzzjqqgud46"
        let data = Data(#"{"login": "\#(token)", "note": "item \#(token) complete; repeat \#(token) summary"}"#.utf8)
        let result = try Scrubber.scrub(data, name: "input.json", forceFullDetection: false, seed: 1823212354)
        let object = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: String])
        let login = try #require(object["login"])
        #expect(login != token && object["note"] == "item \(login) complete; repeat \(login) summary", "\(object)")
    }

    /// The same, without the detectors: whatever reads the value as what, the
    /// surest reading names its kind everywhere.
    @Test func theSurestReadingNamesTheKind() throws {
        let job = Job(seed: 5)
        let field = "rv8kq2mzt0x4", note = "item rv8kq2mzt0x4 complete"
        job.observeSpans([(field, [Span(range: 0..<12, entity: "USERNAME", score: 1)]), (note, [Span(range: 5..<17, entity: "SECRET", score: 0.5)])])
        let inNote = job.replacement(for: "SECRET", original: field, persona: nil)
        #expect(job.replacement(for: "USERNAME", original: field, persona: nil) == inNote)
        #expect(job.kind(of: field, read: "SECRET") == "USERNAME")
        // A name or a place keeps its own kind: its stand-in comes from a person or an address.
        #expect(job.kind(of: field, read: "PERSON") == "PERSON")
    }

    /// A name keeps the person it was first taken for, however the document's
    /// later names change whom its parts could be: "Odalys" stays Odalys
    /// Ferriter's once her full name fills her in, though a second Odalys follows.
    @Test func aResolvedNameKeepsItsPerson() {
        for seed in UInt64(0)..<8 {
            let people = People(rng: SeededGenerator(seed: seed))
            let lone = people.register("Odalys", nil)
            let full = people.registerFull("Odalys Ferriter").0
            #expect(full === lone, "her full name fills her in")
            _ = people.registerFull("Odalys Brennan")
            #expect(people.register("Odalys", nil) === lone, "seed \(seed)")
            #expect(people.register(nil, "Ferriter") === lone, "seed \(seed)")
        }
    }

    /// A name written the same way reads the same each time: "Ferriter" alone
    /// is Odalys Ferriter's surname, and stays so after an Ama Ferriter is named.
    @Test func aWrittenNameReadsTheSameEachTime() {
        for seed in UInt64(0)..<8 {
            let people = People(rng: SeededGenerator(seed: seed))
            let odalys = people.registerFull("Odalys Ferriter").0
            let surname = people.name(for: "Ferriter")
            #expect(surname == odalys.last)
            _ = people.registerFull("Ama Ferriter")
            #expect(people.name(for: "Ferriter") == surname, "seed \(seed)")
        }
    }

    /// A known person's name read as a place is replaced as the person, and
    /// marked as one, so the review lists one finding and Leave counts it back.
    @Test func aPlaceThatIsAKnownPersonIsMarkedAsThePerson() throws {
        let job = Job(seed: 3)
        let name = "Odalys Ferriter"
        job.observeSpans([(name, [Span(range: 0..<15, entity: "PERSON", score: 0.85)])])
        let text = "Parcel for Odalys Ferriter left the depot."
        let (output, marks) = try job.apply(text, spans: [Span(range: 11..<26, entity: "LOCATION", score: 0.6)])
        #expect(marks.map(\.entity) == ["PERSON"], "\(output)")
        #expect(job.counts == ["PERSON": 1])
        #expect(job.replacement(for: "PERSON", original: name) == TextRanges.substring(output, marks[0].range))
    }

    /// An extension written beside two places is one line: too short for an
    /// area code, it has no place to follow, so it keeps one stand-in.
    @Test func anExtensionNearTwoPlacesKeepsOneStandIn() throws {
        let text = """
        The applicant was represented by Ms E. Gravenor, a lawyer practising in Leeds. Please call Rhys Brennan at x81656 with any questions.
        The box is marked fragile on two sides. Reset your password from the settings page. Hope the charge clears soon. The key is to keep the steps small.
        We grew up in Szeged but left after school. Please call Rhys Brennan at x81656 with any questions.
        The desk number is ext. 7-6434 for Leeds, and the old desk in Szeged was ext. 7-6434 too.
        """
        for seed in UInt64(0)..<4 {
            for path in PIIGaps.InputPath.allCases {
                let (output, result) = try SpreadTests.scrub(text, path, seed: seed)
                #expect(!output.contains("81656") && !output.contains("7-6434"), "[\(path)] \(output)")
                let extensions = output.matches(of: /at x([0-9]+) with/).map { String($0.1) }
                let desks = output.matches(of: /ext\. ([0-9]-[0-9]{4})\b/).map { String($0.1) }
                // Same shape as written: five digits after "x", one and four around the hyphen.
                #expect(extensions.count == 2 && extensions.allSatisfy { $0.count == 5 } && Set(extensions).count == 1, "[\(path) seed \(seed)] \(output)")
                #expect(desks.count == 2 && Set(desks).count == 1, "[\(path) seed \(seed)] \(output)")
                #expect(result.findings.first { $0.original == "81656" }.map { $0.standIn == extensions.first && $0.occurrences == 2 } == true, "[\(path)] \(result.findings)")
            }
        }
    }

    /// A city named inside a whole address ("Denver, Colorado 80205") is a
    /// real place in the document, so no other place's stand-in becomes it.
    @Test func noPlaceBecomesACityAnAddressNames() {
        var drawn: Set<String> = []
        for seed in UInt64(0)..<400 {
            let standIns = StandIns(rng: SeededGenerator(seed: seed))
            standIns.avoid("394 Wexcombe Drive, Denver, Colorado 80205")
            standIns.avoid("Fresno")
            let city = standIns.replace("LOCATION", "Fresno")
            drawn.insert(city)
            #expect(city != "Denver", "seed \(seed)")
        }
        #expect(drawn.count > 20, "the draw still ranges over many places: \(drawn.count)")
    }

    /// The recheck reads the text with its stand-ins in: a stand-in surname
    /// that is also a street word ("Lane") makes "retry 3 for Theresa Lane" an
    /// address to the system detector. That address was read off the stand-in,
    /// so the name stays the name its email beside it is built from. A real
    /// street after a stand-in name is still caught.
    @Test func aStandInSurnameIsNoStreet() throws {
        func marked(_ text: String, _ values: [(String, String)]) -> [Mark] {
            values.map { value, entity in
                let range = (text as NSString).range(of: value)
                return Mark(range: range.location..<NSMaxRange(range), entity: entity)
            }
        }
        let line = "2025-04-25T00:48:36.528Z WARN  payment retry 3 for Theresa Lane <theresa.lane@example.com> card ending 1528\n"
        let (output, _, _) = try Correction.run(line, marks: marked(line, [("Theresa Lane", "PERSON"), ("theresa.lane@example.com", "EMAIL_ADDRESS")]), job: Job(seed: 1))
        // The card's last four are the holder's own and go; the name and its address stay as marked.
        let kept = "2025-04-25T00:48:36.528Z WARN  payment retry 3 for Theresa Lane <theresa.lane@example.com> card ending "
        #expect(output.hasPrefix(kept) && !output.contains("1528") && output.dropFirst(kept.count).prefix(4).allSatisfy(\.isNumber), "\(output)")
        let label = "Ship to Theresa Lane, 4821 Juniper Hollow Rd, Boise, ID 83702 by Friday.\n"
        let (shipped, _, _) = try Correction.run(label, marks: marked(label, [("Theresa Lane", "PERSON")]), job: Job(seed: 1))
        #expect(shipped.hasPrefix("Ship to Theresa Lane, ") && !shipped.contains("Juniper Hollow"), "\(shipped)")
    }
}
