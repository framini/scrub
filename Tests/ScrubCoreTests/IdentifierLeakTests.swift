import Foundation
@testable import ScrubCore
import Testing

/// Identifiers and links that hold someone with nothing else in the document
/// to give them away: an ID made of a name ("odalys-ferriter"), a root handle
/// ("/@odalysferriter"), a collection written encoded ("/%75sers/…"), a route
/// in a fragment with its own query ("#/search?email=…"). Each is replaced,
/// with no piece of the name left, as a value of its own kind, and a link
/// stays a link. Real type prefixes ("cus_", "E-") are kept, with the shape.
struct IdentifierLeakTests {
    enum Path: String, CaseIterable { case text, json, csv, xml }

    /// IDs a system made from someone's name.
    static let named = ["odalys-ferriter", "Quillmere_Tavish", "pat-ferriter", "ferriter-4821", "odalys_ferriter_7", "QUILLMERE-0042"]
    /// IDs with a type prefix, which stays.
    static let typed = [("cus_4TUvJhQkMeNW", "cus_"), ("E-48211", "E-"), ("usr-19f3a8b2", "usr-"), ("INV-2024-0042", "INV-"), ("pat_ZqybnpAzukkun", "pat_")]

    static func render(_ rows: [(key: String, value: String)], _ path: Path) -> (Data, String) {
        switch path {
        case .text: return (Data(rows.map { "\($0.key): \($0.value)" }.joined(separator: "\n").utf8), "ids.txt")
        case .json:
            let fields = rows.map { #"{"\#($0.key)": "\#($0.value)", "status": "active"}"# }
            return (Data(#"{"records": [\#(fields.joined(separator: ", "))]}"#.utf8), "ids.json")
        // Each ID under its own column, as an export writes it.
        case .csv: return (Data(((rows.map(\.key) + ["status"]).joined(separator: ",") + "\n" + (rows.map(\.value) + ["active"]).joined(separator: ",") + "\n").utf8), "ids.csv")
        case .xml:
            let body = rows.map { "<record><\($0.key)>\($0.value.replacingOccurrences(of: "&", with: "&amp;"))</\($0.key)><status>active</status></record>" }
            return (Data("<records>\(body.joined())</records>".utf8), "ids.xml")
        }
    }

    /// The words of a name an ID is made of, three letters or more.
    static func pieces(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
    }
    /// The tokens of letters in the output, decoded as a reader of a link would.
    static func words(_ output: String) -> Set<String> {
        let decoded = output.removingPercentEncoding ?? output
        return Set(decoded.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    /// The same length and kinds of character, with every joiner where it was.
    static func shaped(_ standIn: String, like original: String) -> Bool {
        standIn != original && standIn.count == original.count && zip(standIn, original).allSatisfy { a, b in
            a.isNumber == b.isNumber && a.isLowercase == b.isLowercase && a.isUppercase == b.isUppercase && (a.isLetter || a.isNumber || a == b)
        }
    }

    @Test(arguments: Path.allCases)
    func idsMadeOfANameLeaveNoPieceOfIt(_ path: Path) throws {
        let keys = ["customer_id", "user_id", "member_ref", "patient_id", "employee_id", "account_id"]
        let rows = zip(keys, Self.named).map { (key: $0, value: $1) }
        for seed in UInt64(0)..<3 {
            let (data, name) = Self.render(rows, path)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            let label = "[\(path) \(seed)]"
            let left = Self.words(output)
            for id in Self.named {
                for piece in Self.pieces(id) { #expect(!left.contains(piece), "\(label) \(id): \(piece) left in \(output)") }
                let finding = try #require(result.findings.first { $0.original == id }, "\(label) \(id) not found: \(result.findings.map(\.original))")
                #expect(finding.entity == "RECORD_ID" && Self.shaped(finding.standIn, like: id), "\(label) \(id) → \(finding.entity) \(finding.standIn)")
            }
            if path == .json { #expect((try? JSONSerialization.jsonObject(with: result.output)) != nil) }
            if path == .xml { #expect((try? XMLDocument(data: result.output)) != nil) }
        }
    }

    /// The same IDs written in sentences, after the word for whose they are but with no key.
    @Test func idsMadeOfANameInProseLeaveNoPieceOfIt() throws {
        let prose = """
        Ticket from customer odalys-ferriter about the refund. Account Quillmere_Tavish was merged into pat-ferriter last week.
        Please reopen user ferriter-4821 and member odalys_ferriter_7, then close account QUILLMERE-0042.
        """
        for seed in UInt64(0)..<3 {
            let output = String(decoding: try Scrubber.scrub(Data(prose.utf8), name: "note.txt", forceFullDetection: false, seed: seed).output, as: UTF8.self)
            let left = Self.words(output)
            for piece in Self.named.flatMap(Self.pieces) { #expect(!left.contains(piece), "[\(seed)] \(piece) left in \(output)") }
            #expect(output.hasPrefix("Ticket from customer ") && output.contains(" about the refund."), "[\(seed)] \(output)")
        }
    }

    @Test(arguments: Path.allCases)
    func typePrefixesStayWithTheShape(_ path: Path) throws {
        let keys = ["customer_id", "employee_id", "user_id", "customer_ref", "patient_id"]
        let rows = zip(keys, Self.typed).map { (key: $0, value: $1.0) }
        let (data, name) = Self.render(rows, path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 2)
        for (id, prefix) in Self.typed {
            guard let finding = result.findings.first(where: { $0.original == id }) else { continue }
            #expect(finding.standIn.hasPrefix(prefix) && Self.shaped(finding.standIn, like: id), "[\(path)] \(id) → \(finding.standIn)")
        }
        // A person's own IDs are always found.
        // A random body may lack a digit: after a listed type, turns of case inside it are enough.
        for id in ["cus_4TUvJhQkMeNW", "E-48211", "usr-19f3a8b2", "pat_ZqybnpAzukkun"] { #expect(result.findings.contains { $0.original == id }, "[\(path)] \(id) not found") }
    }

    /// The prefix a stand-in keeps, read straight off the value.
    @Test func keptPrefixIsATypeNeverAName() {
        for (id, prefix) in Self.typed + [("u_1234", "u_"), ("tenant_8812", "tenant_"), ("cus_odalys_ferriter", "cus_"), ("acc-77Fq2", "acc-"), ("ord_55120893", "ord_")] {
            #expect(RecordIDs.keptPrefix(id) == prefix, "\(id) → \(RecordIDs.keptPrefix(id))")
        }
        for id in Self.named + ["Odalys-Ferriter", "jdoe-1234", "quillmere-north", "ana_4821", "pat_Ferriterson"] {
            #expect(RecordIDs.keptPrefix(id).isEmpty, "\(id) kept \(RecordIDs.keptPrefix(id))")
        }
    }

    /// Slugs under people's collections in links: replaced as handles or IDs, with no piece of the name left.
    @Test(arguments: Path.allCases)
    func slugsInLinksLeaveNoPieceOfTheName(_ path: Path) throws {
        let links = ["https://crm.corvane.test/people/odalys-ferriter", "https://crm.corvane.test/customers/Quillmere_Tavish/orders", "https://crm.corvane.test/#/users/pat-ferriter"]
        for seed in UInt64(0)..<3 {
            let (data, name) = Self.renderLinks(links, path)
            let output = String(decoding: try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed).output, as: UTF8.self)
            let left = Self.words(output)
            for piece in ["odalys", "ferriter", "quillmere", "tavish", "pat"] { #expect(!left.contains(piece), "[\(path) \(seed)] \(piece) left in \(output)") }
            for link in Self.links(in: output) { #expect(URLComponents(string: link)?.host != nil, "[\(path) \(seed)] not a link: \(link)") }
        }
    }

    // MARK: Link layouts

    static func renderLinks(_ links: [String], _ path: Path) -> (Data, String) {
        func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;") }
        switch path {
        case .text: return (Data(("See the links below.\n\n" + links.joined(separator: "\n")).utf8), "links.txt")
        case .json: return (Data(#"{"events": [\#(links.map { #"{"kind": "visit", "url": "\#($0)"}"# }.joined(separator: ", "))]}"#.utf8), "links.json")
        case .csv: return (Data(("kind,url\n" + links.map { "visit,\($0)" }.joined(separator: "\n") + "\n").utf8), "links.csv")
        case .xml: return (Data("<events>\(links.map { "<event><kind>visit</kind><url>\(xml($0))</url></event>" }.joined())</events>".utf8), "links.xml")
        }
    }

    static func links(in output: String) -> [String] {
        output.replacingOccurrences(of: "&amp;", with: "&").matches(of: /https?:\/\/[^\s"<>,]+/).map { String($0.output) }
    }

    /// A handle: letters first, then letters, digits and joiners.
    static func isHandle(_ value: String) -> Bool { value.wholeMatch(of: /[A-Za-z][A-Za-z0-9._-]{1,63}/) != nil }
    static func isEmail(_ value: String) -> Bool { value.wholeMatch(of: /[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil }

    /// Each layout, its personal value, and how the value's stand-in is read back from the scrubbed link.
    struct Layout: Sendable {
        let link: String
        let original: String
        let read: @Sendable (URLComponents) -> String?
        let kind: @Sendable (String) -> Bool
    }

    static func segment(_ index: Int) -> @Sendable (URLComponents) -> String? {
        { components in components.path.split(separator: "/").map(String.init).dropFirst(index).first }
    }
    static func fragmentQuery(_ key: String) -> @Sendable (URLComponents) -> String? {
        { components in
            guard let fragment = components.percentEncodedFragment, let question = fragment.firstIndex(of: "?") else { return nil }
            var query = URLComponents()
            query.percentEncodedQuery = String(fragment[fragment.index(after: question)...])
            return query.queryItems?.first { $0.name == key }?.value?.replacingOccurrences(of: "+", with: " ")
        }
    }

    static let layouts: [Layout] = [
        // A root handle, alone and with a page after it.
        Layout(link: "https://social.corvane.test/@odalysferriter", original: "odalysferriter", read: segment(0), kind: { $0.hasPrefix("@") && isHandle(String($0.dropFirst())) }),
        Layout(link: "https://social.corvane.test/@quillmere.tavish/posts/4821", original: "quillmere.tavish", read: segment(0), kind: { $0.hasPrefix("@") && isHandle(String($0.dropFirst())) }),
        Layout(link: "https://home.corvane.test/~tavishq/notes.html", original: "tavishq", read: segment(0), kind: { $0.hasPrefix("~") && isHandle(String($0.dropFirst())) }),
        // A collection written encoded.
        Layout(link: "https://app.corvane.test/%75sers/odalys.ferriter", original: "odalys.ferriter", read: segment(1), kind: isHandle),
        Layout(link: "https://app.corvane.test/%70%72%6F%66%69%6C%65/quillmere_tavish/settings", original: "quillmere_tavish", read: segment(1), kind: isHandle),
        // A route in a fragment with its own query.
        Layout(link: "https://app.corvane.test/#/search?email=odalys%40corvane.test", original: "odalys@corvane.test", read: fragmentQuery("email"), kind: isEmail),
        Layout(link: "https://app.corvane.test/inbox#!/compose?to=quillmere.tavish%40corvane.test&draft=1", original: "quillmere.tavish@corvane.test", read: fragmentQuery("to"), kind: isEmail),
        Layout(link: "https://app.corvane.test/#/people?name=Odalys+Ferriter&tab=2", original: "Odalys Ferriter", read: fragmentQuery("name"),
               kind: { $0.split(separator: " ").count == 2 && $0.split(separator: " ").allSatisfy { $0.first?.isUppercase == true && $0.allSatisfy(\.isLetter) } }),
    ]

    @Test(arguments: Path.allCases)
    func linkLayoutsAreReplacedAndStayLinks(_ path: Path) throws {
        for seed in UInt64(0)..<3 {
            let (data, name) = Self.renderLinks(Self.layouts.map(\.link), path)
            let output = String(decoding: try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed).output, as: UTF8.self)
            let label = "[\(path) \(seed)]"
            let found = Self.links(in: output)
            try #require(found.count == Self.layouts.count, "\(label) \(output)")
            let left = Self.words(output)
            for (layout, link) in zip(Self.layouts, found) {
                let components = try #require(URLComponents(string: link), "\(label) not a link: \(link)")
                #expect(components.host != nil, "\(label) no host: \(link)")
                let standIn = try #require(layout.read(components), "\(label) \(layout.link) → \(link)")
                #expect(!standIn.lowercased().contains(layout.original.lowercased()) && layout.kind(standIn), "\(label) \(layout.original) → \(standIn) in \(link)")
                for piece in Self.pieces(layout.original) where !["corvane", "test"].contains(piece) {
                    #expect(!left.contains(piece), "\(label) \(piece) left in \(link)")
                }
            }
            // An email written back into a link is encoded as the original was: "%40", no "@".
            #expect(found[5].contains("%40") && !found[5].contains("@"), "\(label) \(found[5])")
        }
    }

    /// Each value alone in its document, the smallest a leak can hide in.
    @Test func eachValueAloneIsReplaced() throws {
        let documents = [
            (#"{"customer_id":"odalys-ferriter"}"#, "a.json", ["odalys", "ferriter"]),
            ("https://crm.corvane.test/people/odalys-ferriter", "a.txt", ["odalys", "ferriter"]),
            ("https://social.corvane.test/@odalysferriter", "b.txt", ["odalysferriter"]),
            ("https://app.corvane.test/%75sers/odalys.ferriter", "c.txt", ["odalys", "ferriter"]),
            ("https://app.corvane.test/#/search?email=odalys%40corvane.test", "d.txt", ["odalys"]),
            (#"{"url":"https://app.corvane.test/#/search?email=odalys%40corvane.test"}"#, "b.json", ["odalys"]),
        ]
        for (input, name, pieces) in documents {
            let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 4).output, as: UTF8.self)
            let left = Self.words(output)
            for piece in pieces { #expect(!left.contains(piece), "\(name): \(piece) left in \(output)") }
            for link in Self.links(in: output) { #expect(URLComponents(string: link)?.host != nil, "\(name): not a link: \(link)") }
        }
    }

    /// The parts read off a fragment's route and its query, keyed by what they decode to.
    @Test func componentsOfRoutesAndEncodedSegments() {
        func parts(_ link: String) -> [(String, URLPart, String?)] {
            URLs.components(in: link).map { (TextRanges.substring(link, $0.range), $0.part, $0.key) }
        }
        let route = parts("https://a.test/#/search?email=odalys%40corvane.test&page=2")
        #expect(route.contains { $0.0 == "search" && $0.1 == .path } && route.contains { $0.0 == "odalys%40corvane.test" && $0.1 == .query && $0.2 == "email" }, "\(route)")
        let bang = parts("https://a.test/#!/users/odalys")
        #expect(bang.contains { $0.0 == "odalys" && $0.1 == .path && $0.2 == "users" }, "\(bang)")
        let encoded = parts("https://a.test/%75sers/odalys?%65mail=x%40y.test")
        #expect(encoded.contains { $0.0 == "odalys" && $0.2 == "users" } && encoded.contains { $0.2 == "email" }, "\(encoded)")
    }

    /// Links that name no one stay as written: a route to a page, a route's query of plain words, an encoded page.
    @Test func plainLinksStay() throws {
        let plain = ["https://docs.corvane.test/guide/install#/getting-started", "https://app.corvane.test/#/search?q=invoices&page=2", "https://app.corvane.test/%61bout/team"]
        let output = String(decoding: try Scrubber.scrub(Data(plain.joined(separator: "\n").utf8), name: "a.txt", forceFullDetection: false, seed: 1).output, as: UTF8.self)
        for link in plain { #expect(output.contains(link), "\(link) changed: \(output)") }
    }

    /// A device-intelligence lookup as each route carries it: a vendor's JSON response, a service's log line, an export's
    /// row and an XML feed. A phone's identifiers and the ones its advertisers know it by are the person's who holds it.
    static func renderDevice(_ path: Path) -> (Data, String) {
        let ids = [("device", "d3f1c9a2-7b44-4e0e-9a1f-5c2b8e6d4a10"), ("idfa", "EA7583CD-A667-48BC-B806-42ECB2B48606"), ("idfv", "6F9619FF-8B86-D011-B42D-00C04FC964FF"),
                   ("gaid", "38400000-8cf0-11bd-b23e-10b96e40000d"), ("android_id", "9774d56d682e549c"), ("device_fingerprint", "8c1f2e9ab07d4c63")]
        switch path {
        case .text:
            let pairs = ids.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            return (Data("2026-09-14T10:22:32.007Z INFO [risk] lookup \(pairs) os=iOS-19.0.1 model=iPhone16,2 score=0.83\n2026-09-14T10:22:32.110Z INFO [risk] decision=review\n".utf8), "risk.log")
        case .json:
            let fields = ids.map { #""\#($0.0)": "\#($0.1)""# }.joined(separator: ", ")
            return (Data(#"{"event_id": "evt_5c1f0a77e2", "account": {"email": "ottoline.w@example.com"}, "device": {\#(fields), "os": "iOS 19.0.1", "model": "iPhone16,2"}, "risk_score": 23}"#.utf8), "device.json")
        case .csv:
            return (Data((["event_id"] + ids.map(\.0) + ["model"]).joined(separator: ",").appending("\n").appending((["evt_5c1f0a77e2"] + ids.map(\.1) + ["iPhone16"]).joined(separator: ",")).appending("\n").utf8), "devices.csv")
        case .xml:
            let fields = ids.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
            return (Data("<lookup><event_id>evt_5c1f0a77e2</event_id><signals>\(fields)<model>iPhone16,2</model></signals></lookup>".utf8), "lookup.xml")
        }
    }

    @Test(arguments: Path.allCases)
    func aPhonesIdentifiersAreReplacedInEveryRoute(_ path: Path) throws {
        let originals = ["d3f1c9a2-7b44-4e0e-9a1f-5c2b8e6d4a10", "EA7583CD-A667-48BC-B806-42ECB2B48606", "6F9619FF-8B86-D011-B42D-00C04FC964FF",
                         "38400000-8cf0-11bd-b23e-10b96e40000d", "9774d56d682e549c", "8c1f2e9ab07d4c63"]
        let (data, name) = Self.renderDevice(path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 3)
        let output = String(decoding: result.output, as: UTF8.self)
        for id in originals {
            #expect(!output.contains(id), "[\(path)] \(id) left: \(output)")
            // Each takes a stand-in of its own shape: a UUID stays a UUID in its case, sixteen hex digits stay sixteen.
            let finding = try #require(result.findings.first { $0.original == id }, "[\(path)] \(id) not found")
            #expect(IdentifierLeakTests.shaped(finding.standIn, like: id), "[\(path)] \(id) -> \(finding.standIn)")
        }
        // The event, the model and the score name no one.
        #expect(output.contains("iPhone16"), "[\(path)] \(output)")
        #expect(path == .text || output.contains("evt_5c1f0a77e2"), "[\(path)] \(output)")
    }

    @Test func aDeviceModelOrARequestBesideADeviceStays() throws {
        let log = "2026-09-14 10:31:02,118 INFO device-intel - lookup request=4b9e2a1c-55d0-4f7e-8c3a-2e1f0d9b7a66 device: iPhone16,2 os: 19.0.1 took 41ms\n"
        let result = try Scrubber.scrub(Data(log.utf8), name: "service.log", forceFullDetection: false, seed: 1)
        #expect(String(decoding: result.output, as: UTF8.self) == log)
    }

    @Test func aBiometricEnrolmentsIDIsReplaced() throws {
        // "Biometric ID: BIO-5048597196" stayed as written beside a replaced name and birth date.
        let card = "**Ottoline Wexcombe, DOB: 1984-03-07, Biometric ID: QX-5048597196**\nBiometric template for Tobiah Quennell, DOB: 1961-06-10, Biometric ID: B7716204953.\n"
        let check = #"{"result": {"status": "match", "score": 0.97, "subject": {"name": "Ottoline Wexcombe", "biometric_id": "FP-88203117", "biometricTemplateId": "T4410982751"}}}"#
        for seed in UInt64(0)..<3 {
            for (document, name) in [(card, "card.txt"), (check, "check.json")] {
                let output = String(decoding: try Scrubber.scrub(Data(document.utf8), name: name, forceFullDetection: false, seed: seed).output, as: UTF8.self)
                for gone in ["5048597196", "B7716204953", "88203117", "T4410982751", "Wexcombe"] { #expect(!output.contains(gone), "\(gone) in \(name): \(output)") }
                #expect(!name.hasSuffix(".json") || output.contains(#""status": "match", "score": 0.97"#), "\(output)")
            }
        }
    }
}

/// IDs made of a word and a number, written in a sentence with nothing to
/// say whose they are, and no other mention of the person in the document.
/// One built on a name the lists hold is replaced whole; one built on a
/// word no dictionary holds may be a surname, and waits for the review,
/// left as written until then. Words, short codes and versions stay.
struct UnlabelledIdentifierTests {
    typealias Path = IdentifierLeakTests.Path

    static func render(_ note: String, _ path: Path) -> (Data, String) {
        switch path {
        case .text: return (Data(note.utf8), "note.txt")
        case .json: return (Data(#"{"ticket": {"status": "open", "note": "\#(note)"}}"#.utf8), "ticket.json")
        case .csv: return (Data("status,note\nopen,\"\(note)\"\n".utf8), "tickets.csv")
        case .xml: return (Data("<ticket><status>open</status><note>\(note)</note></ticket>".utf8), "ticket.xml")
        }
    }

    @Test(arguments: Path.allCases)
    func anIDBuiltOnANameIsReplacedWhole(_ path: Path) throws {
        for (id, piece) in [("0042_odalys", "odalys"), ("MARGUERITE-0042", "marguerite"), ("okonkwo-tavern-17", "okonkwo")] {
            for seed in UInt64(0)..<3 {
                let (data, name) = Self.render("Please close \(id) before Friday, then reply.", path)
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let output = String(decoding: result.output, as: UTF8.self)
                let label = "[\(path) \(seed) \(id)]"
                #expect(!IdentifierLeakTests.words(output).contains(piece), "\(label) \(output)")
                let finding = try #require(result.findings.first { $0.original == id }, "\(label) not found: \(result.findings.map(\.original))")
                #expect(["RECORD_ID", "ID_NUMBER"].contains(finding.entity) && IdentifierLeakTests.shaped(finding.standIn, like: id), "\(label) → \(finding.entity) \(finding.standIn)")
                #expect(output.contains("Please close ") && output.contains(" before Friday, then reply."), "\(label) \(output)")
            }
        }
    }

    /// An ID built from the name of someone the same note names is theirs,
    /// however short the name or missing from the name lists: "pat-1987"
    /// beside Pat Ferriter. The same shapes with no one named stay as written.
    @Test(arguments: Path.allCases)
    func anIDBuiltOnANamedPersonIsTheirs(_ path: Path) throws {
        for (id, piece) in [("pat-1987", "pat"), ("pat1987", "pat"), ("ferriter_07", "ferriter"), ("1987-pat", "pat")] {
            for seed in UInt64(0)..<3 {
                let (data, name) = Self.render("Pat Ferriter asked us to close \(id) before Friday.", path)
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let output = String(decoding: result.output, as: UTF8.self)
                let label = "[\(path) \(seed) \(id)]"
                #expect(!IdentifierLeakTests.words(output).contains(piece) && !output.lowercased().contains(id), "\(label) \(output)")
                let finding = try #require(result.findings.first { $0.original == id }, "\(label) not found: \(result.findings.map(\.original))")
                // Replaced either way; one read as a handle may still be shown for a look.
                #expect(["RECORD_ID", "ID_NUMBER", "USERNAME"].contains(finding.entity), "\(label) → \(finding.entity) \(finding.standIn)")
                #expect(IdentifierLeakTests.shaped(finding.standIn, like: id) || finding.entity == "USERNAME", "\(label) → \(finding.standIn)")
            }
        }
        // A host beside a named person is still no one's.
        let (data, name) = Self.render("Odalys Ferriter asked us to restart router-0042 before Friday.", path)
        let output = String(decoding: try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 1).output, as: UTF8.self)
        #expect(output.contains("router-0042") && !output.contains("Ferriter"), "[\(path)] \(output)")
    }

    /// realisticPayloads, seed 603824321: an applicant's own "ID":
    /// "app_wvyxnNnadrziFb", with a prefix no list holds and only two capitals,
    /// stayed. In a person's own record it is theirs; a build tag beside no one stays.
    @Test func aPersonsOwnIDNeedsNoPersonsPrefix() throws {
        let id = "app_wvyxnNnadrziFb"
        let shapes = [
            (#"{"applicant": {"ID": "\#(id)", "name": "Odalys Ferriter", "status": "pending"}}"#, "a.json"),
            ("<applicant><ID>\(id)</ID><name>Odalys Ferriter</name><status>pending</status></applicant>", "a.xml"),
            ("applicant.ID,applicant.name,applicant.status\n\(id),Odalys Ferriter,pending\n", "a.csv"),
        ]
        for (input, name) in shapes {
            for seed in UInt64(0)..<3 {
                let result = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: seed)
                let output = String(decoding: result.output, as: UTF8.self)
                #expect(!output.contains("wvyxnNnadrziFb") && !output.contains("Ferriter") && output.contains("pending"), "[\(name) \(seed)] \(output)")
                let finding = try #require(result.findings.first { $0.original == id }, "[\(name)] \(result.findings.map(\.original))")
                #expect(IdentifierLeakTests.shaped(finding.standIn, like: id), "[\(name)] \(finding.standIn)")
            }
        }
        let build = #"{"release": {"id": "app_wvyxnNnadrziFb", "channel": "beta"}}"#
        let output = String(decoding: try Scrubber.scrub(Data(build.utf8), name: "r.json", forceFullDetection: false, seed: 1).output, as: UTF8.self)
        #expect(output.contains("app_wvyxnNnadrziFb"), "\(output)")
    }

    @Test func aPersonsTypedIDNeedsNoMixedCase() throws {
        // A user's ID beside their own name and email, its body almost all lowercase.
        for id in ["usr_qmtrvzkapwHns", "cus_hbqxwtrnelzd", "usr-7kq2mwzx"] {
            let shapes = [
                (#"{"actor": {"id": "\#(id)", "email": "oferriter12@corvane.test", "name": "Odalys Ferriter"}, "action": "user.login"}"#, "a.json"),
                ("<event><actor><id>\(id)</id><email>oferriter12@corvane.test</email><name>Odalys Ferriter</name></actor><action>user.login</action></event>", "a.xml"),
                ("actor.id,actor.email,actor.name,action\n\(id),oferriter12@corvane.test,Odalys Ferriter,user.login\n", "a.csv"),
                ("Saw this in the audit log:\n{\"actor\": {\"id\": \"\(id)\", \"email\": \"oferriter12@corvane.test\", \"name\": \"Odalys Ferriter\"}, \"action\": \"user.login\"}\n", "a.txt"),
                ("actor:\n  id: \(id)\n  email: oferriter12@corvane.test\n  name: Odalys Ferriter\naction: user.login\n", "a.txt"),
            ]
            for (input, name) in shapes {
                let result = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 4)
                let output = String(decoding: result.output, as: UTF8.self)
                #expect(!output.contains(id) && output.contains("user.login"), "[\(name) \(id)] \(output)")
                let finding = try #require(result.findings.first { $0.original == id }, "[\(name) \(id)] \(result.findings.map(\.original))")
                #expect(IdentifierLeakTests.shaped(finding.standIn, like: id), "[\(name)] \(finding.standIn)")
            }
        }
        // Away from a person, a thing's ID stays.
        let build = #"{"build": {"id": "usr_qmtrvzkapwHns", "channel": "beta"}}"#
        let output = String(decoding: try Scrubber.scrub(Data(build.utf8), name: "r.json", forceFullDetection: false, seed: 1).output, as: UTF8.self)
        #expect(output.contains("usr_qmtrvzkapwHns"), "\(output)")
    }

    @Test(arguments: Path.allCases)
    func anIDBuiltOnAnUnknownWordWaitsForTheReview(_ path: Path) throws {
        for id in ["QUILLMERE-0042", "ferriter-4821", "4821_tavish_brightwater"] {
            let (data, name) = Self.render("Please close \(id) before Friday, then reply.", path)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 1)
            let label = "[\(path) \(id)]"
            // Left as written only until it is checked: Copy and Save ask first.
            let held = try #require(result.findings.first { $0.original == id }, "\(label) not asked about: \(result.findings.map(\.original))")
            #expect(["RECORD_ID", "ID_NUMBER"].contains(held.entity) && held.needsReview && result.uncertain.contains(held), "\(label) \(held.entity) \(held.standIn)")
        }
    }

    @Test(arguments: Path.allCases)
    func wordsCodesAndVersionsStay(_ path: Path) throws {
        let note = "Router-0042 runs build 2024 with SHA-256 per RFC-2616, page-42 of chapter_12, UTF-8 on x86_64 and kubernetes-1.28."
        let (data, name) = Self.render(note, path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 1)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(output.contains(note), "[\(path)] \(output)")
        #expect(result.findings.isEmpty, "[\(path)] \(result.findings.map(\.original))")
    }
}

/// An identifier beside a person found, under a key no rule knows, is never kept
/// unseen: it is replaced, or asked about as an identifier in that person's record.
struct PersonRecordIdentifierTests {
    struct Out {
        let output: String
        let result: ScrubResult
        var findings: [(original: String, suspected: Bool, doubt: Doubt?)] { (result.review?.findings ?? []).map { ($0.original, $0.suspected, $0.doubt) } }
    }
    static func scrub(_ text: String, name: String, seed: UInt64 = 5) throws -> Out {
        let result = try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: seed)
        return Out(output: String(decoding: result.output, as: UTF8.self), result: result)
    }
    static func seen(_ value: String, _ out: Out) -> Bool {
        !out.output.contains(value) || out.findings.contains { $0.original == value && $0.suspected && $0.doubt == .personIdentifier }
    }

    @Test func anIdentifierUnderAnUnknownKeyBesideAPersonIsAskedAbout() throws {
        let json = #"{"request_id": "8812734455", "case_id": "77120034", "created_at": "2026-03-01T10:00:00Z", "amount": "1250.00", "version": "2.4.1", "subject": {"firstName": "Liesel", "lastName": "Okafor", "birthDate": "1987-06-21", "natRegNo": "4382-1957-6034-2018", "status": "VERIFIED", "score": "98"}}"#
        let out = try Self.scrub(json, name: "response.json")
        #expect(Self.seen("4382-1957-6034-2018", out), "\(out.output)")
        for kept in [#""request_id": "8812734455""#, #""case_id": "77120034""#, #""amount": "1250.00""#, #""version": "2.4.1""#, #""status": "VERIFIED""#, #""score": "98""#] {
            #expect(out.output.contains(kept), "\(kept): \(out.output)")
        }
        #expect(!out.findings.contains { $0.doubt == .personIdentifier && $0.original != "4382-1957-6034-2018" }, "\(out.findings.map(\.original))")
        // With no person in its record, it is no one's to ask about.
        let alone = try Self.scrub(#"{"batch": {"label": "nightly", "natRegNo": "4382-1957-6034-2018"}}"#, name: "response.json")
        #expect(!alone.findings.contains { $0.doubt == .personIdentifier }, "\(alone.output)")
    }

    @Test func aCSVColumnOfIdentifiersInPeoplesRowsIsAskedAbout() throws {
        let csv = "row,surname,given,birth,carte_ref,branch\n1,Benmoussa,Youssef,1990-05-12,BE123456,Centre\n2,Alaoui,Samira,1985-11-02,J987654,Agdal\n3,Tazi,Karim,1979-01-30,AB34567,Medina\n"
        let out = try Self.scrub(csv, name: "people.csv")
        for value in ["BE123456", "J987654", "AB34567"] { #expect(Self.seen(value, out), "\(value): \(out.output)") }
        #expect(out.output.hasPrefix("row,surname,given,birth,carte_ref,branch\n1,") && out.output.contains(",Centre\n2,"), "\(out.output)")
    }

    /// For generated records under keys no rule knows, every identifier beside a
    /// person is replaced or asked about, and every non-personal value stays unasked.
    @Test func generatedRecordsLeaveNoIdentifierUnseen() throws {
        let run = PropertyRun("personRecordIDs")
        defer { run.finish() }
        let keys = ["xrefNo", "regNumber", "holder_ident", "bureauKey", "cardRef", "fileNo", "docNum", "member_tag", "kennung", "numeroRegistro"]
        let given = ["Liesel", "Tomasz", "Ines", "Kwame", "Mirela", "Haruto", "Oona", "Dario"], family = ["Okafor", "Brandvold", "Szekely", "Achterberg", "Marangoni", "Quispe"]
        for index in 0..<run.count {
            var gen = Gen(seed: run.seed(index))
            let key = gen.choose(keys)
            let value: String = {
                switch gen.int(0...3) {
                case 0: return gen.string("0123456789", count: 4) + "-" + gen.string("0123456789", count: 4) + "-" + gen.string("0123456789", count: 4)
                case 1: return gen.string("ABCDEFGHJKLMNPRSTUVWXYZ", count: gen.int(1...2)) + String(gen.int(1...9)) + gen.string("0123456789", count: 5)
                case 2: return String(gen.int(1...9)) + gen.string("0123456789", count: gen.int(7...11))
                default: return gen.string("0123456789", count: 3) + " " + gen.string("0123456789", count: 3) + " " + gen.string("0123456789", count: 3)
                }
            }()
            let first = gen.choose(given), last = gen.choose(family)
            let format = ["json", "csv", "xml"][index % 3]
            let text: String
            switch format {
            case "json": text = #"{"request_id": "req_\#(gen.int(1000...9999))", "status": "complete", "subject": {"first_name": "\#(first)", "last_name": "\#(last)", "\#(key)": "\#(value)", "updated_at": "2026-04-0\#(gen.int(1...9))"}}"#
            case "csv": text = "first_name,last_name,\(key),status\n\(first),\(last),\(value),complete\n"
            default: text = "<records><subject><firstName>\(first)</firstName><lastName>\(last)</lastName><\(key)>\(value)</\(key)><status>complete</status></subject></records>"
            }
            let out = try Self.scrub(text, name: "record." + format, seed: run.seed(index))
            #expect(Self.seen(value, out), "\(key)=\(value) left unseen in \(format): \(out.output)\nseed \(run.seed(index))")
            #expect(out.output.contains("complete"), "\(out.output)")
            #expect(!out.findings.contains { finding in finding.doubt == .personIdentifier && ["complete", "2026", "req_"].contains { finding.original.hasPrefix($0) } }, "\(out.findings.map(\.original))")
        }
    }
}
