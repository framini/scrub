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
}
