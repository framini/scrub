import Foundation
@testable import ScrubCore
import Testing

/// Personal data inside links: query values, path segments under a
/// person's collection, fragments, user names, percent-encoding, tokens and
/// signatures. The personal part is replaced with the stand-in the same
/// value takes elsewhere in the document, the link still parses, and plain
/// public links stay as written. The oracle reads links with Foundation's
/// URLComponents, never with ScrubCore.
struct URLTests {
    static let email = "odalys.ferriter@kestrel.example"
    static let accessKey = "AKIAQ7XW2MLR8ZTPVB3D"
    static let signature = "9c4be1f07a2d3e5b8f61c0a4d7e29b3f5a8c1e6d0b4f7a2c9e3d5b1f8a0c6e4d"
    static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c3JfNDQ3MSJ9.Zm9yZ2VkLXNpZ25hdHVyZS12YWx1ZQ"

    /// Links that hold someone, and one plain mention of each value to agree with.
    static let personal = [
        "https://portal.example/verify?email=odalys.ferriter%40kestrel.example&name=Odalys+Ferriter&phone=%2B14158672290&ref=newsletter",
        "https://forum.example/users/odalys.ferriter/posts?page=2",
        "https://app.example/u/48213177/settings",
        "ftp://oferriter:Quillfen7Harbor@files.example/exports/",
        "https://files.example/q3/report.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=\(accessKey)%2F20240101%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Expires=3600&X-Amz-Signature=\(signature)",
        "https://api.example/callback?access_token=\(jwt)&lang=en",
        "https://app.example/#/users/odalys.ferriter",
        "https://app.example/welcome#email=odalys.ferriter%40kestrel.example&tab=billing",
    ]
    /// Links that name no one, which stay byte for byte.
    static let public_ = ["https://t.co/PngvVZic", "https://www.example.org/about?lang=en&page=2", "https://docs.example.com/guide/install#step-3", "https://status.example.net/incidents/2024-01-07"]

    static let note = "Odalys Ferriter wrote from \(email) and asked us to call +1 415 867 2290; her handle is odalys.ferriter."

    enum Path: String, CaseIterable { case text, json, csv, xml }

    static func render(_ links: [String], _ path: Path) -> (Data, String) {
        func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;") }
        switch path {
        case .text: return (Data((note + "\n\n" + links.joined(separator: "\n")).utf8), "links.txt")
        case .json:
            let rows = links.map { #"{"note": "\#(note)", "link": "\#($0)"}"# }
            return (Data(#"{"messages": [\#(rows.joined(separator: ", "))]}"#.utf8), "links.json")
        case .csv: return (Data(("note,link\n" + links.map { "\"\(note)\",\($0)" }.joined(separator: "\n") + "\n").utf8), "links.csv")
        case .xml: return (Data("<messages>\(links.map { "<message><note>\(note)</note><link>\(xml($0))</link></message>" }.joined())</messages>".utf8), "links.xml")
        }
    }

    /// The links in the output, in order, as written.
    static func links(in output: String) -> [String] {
        let unescaped = output.replacingOccurrences(of: "&amp;", with: "&")
        return unescaped.matches(of: /(?:https?|ftp):\/\/[^\s"<>,]+/).map { String($0.output) }
    }

    static func items(_ link: String, fragment: Bool = false) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = fragment ? URLComponents(string: link)?.percentEncodedFragment : URLComponents(string: link)?.percentEncodedQuery
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value?.replacingOccurrences(of: "+", with: " ") }
        return result
    }

    @Test(arguments: Path.allCases)
    func personalPartsOfLinksAreReplacedAndTheLinksStillWork(_ path: Path) throws {
        for seed in UInt64(0)..<3 {
            let (data, name) = Self.render(Self.personal + Self.public_, path)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            let label = "[\(path) \(seed)]"
            let found = Self.links(in: output)
            try #require(found.count == Self.personal.count + Self.public_.count, "\(label) \(output)")
            for link in found { #expect(URLComponents(string: link)?.host != nil, "\(label) no longer a link: \(link)") }

            // The plain mentions' stand-ins, which the links must agree with.
            let plainEmail = try #require(output.firstMatch(of: /wrote from (\S+@\S+?) and/).map { String($0.output.1) }, "\(label) \(output)")
            let plainName = try #require(output.firstMatch(of: /([A-Z][a-z]+ [A-Z][a-z'-]+) wrote from/).map { String($0.output.1) }, "\(label) \(output)")
            #expect(plainEmail != Self.email && plainName != "Odalys Ferriter", "\(label) \(output)")

            let query = Self.items(found[0])
            #expect(query["email"] == plainEmail, "\(label) email \(query) vs \(plainEmail)")
            #expect(query["name"] == plainName, "\(label) name \(query) vs \(plainName)")
            #expect(query["phone"].map { $0.filter(\.isNumber).count >= 10 && !$0.contains("8672290") } == true, "\(label) phone \(query)")
            #expect(query["ref"] == "newsletter", "\(label) \(found[0])")

            let user = try #require(URLComponents(string: found[1])?.path.split(separator: "/").map(String.init))
            #expect(user.count == 3 && user[0] == "users" && user[2] == "posts" && user[1] != "odalys.ferriter" && !user[1].isEmpty, "\(label) \(found[1])")
            #expect(Self.items(found[1])["page"] == "2")
            let numeric = try #require(URLComponents(string: found[2])?.path.split(separator: "/").map(String.init))
            #expect(numeric.count == 3 && numeric[1].count == 8 && numeric[1].allSatisfy(\.isNumber) && numeric[1] != "48213177" && numeric[2] == "settings", "\(label) \(found[2])")

            let ftp = try #require(URLComponents(string: found[3]))
            #expect(ftp.user != nil && ftp.user != "oferriter" && ftp.password != "Quillfen7Harbor" && ftp.host == "files.example" && ftp.path == "/exports/", "\(label) \(found[3])")

            let signed = Self.items(found[4])
            #expect(signed["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256" && signed["X-Amz-Expires"] == "3600", "\(label) \(found[4])")
            #expect(signed["X-Amz-Signature"].map { $0 != Self.signature && !$0.isEmpty } == true, "\(label) \(found[4])")
            #expect(signed["X-Amz-Credential"].map { !$0.contains(Self.accessKey) && $0.hasSuffix("/20240101/us-east-1/s3/aws4_request") } == true, "\(label) \(found[4])")

            let callback = Self.items(found[5])
            #expect(callback["access_token"].map { $0 != Self.jwt && !$0.isEmpty } == true && callback["lang"] == "en", "\(label) \(found[5])")

            let fragmentPath = URLComponents(string: found[6])?.fragment ?? ""
            #expect(fragmentPath.hasPrefix("/users/") && !fragmentPath.contains("odalys") && fragmentPath.count > 7, "\(label) \(found[6])")
            // The same handle takes the same stand-in in the path, the fragment and the note.
            #expect(fragmentPath == "/users/" + user[1], "\(label) \(found[6]) vs \(found[1])")
            #expect(output.contains("her handle is \(user[1])."), "\(label) \(output)")

            let fragment = Self.items(found[7], fragment: true)
            #expect(fragment["email"] == plainEmail && fragment["tab"] == "billing", "\(label) \(found[7])")

            // Links naming no one are left exactly as written.
            #expect(Array(found.suffix(Self.public_.count)) == Self.public_, "\(label) \(found.suffix(Self.public_.count))")
            for original in ["odalys", "ferriter", "8672290", "48213177", "oferriter", "Quillfen7Harbor", Self.accessKey, Self.signature, Self.jwt] {
                #expect(!output.lowercased().contains(original.lowercased()), "\(label) \(original) left in \(output)")
            }
        }
    }

    /// A secret under a query key ends where its parameter does.
    @Test func aTokenInAQueryEndsAtTheNextParameter() throws {
        let text = "Retry with ?token=Kq7Zp2Wm9Xr4Lt6V&user_lang=en-GB&page=4 if it times out."
        let output = String(decoding: try Scrubber.scrub(Data(text.utf8), name: "t.txt", forceFullDetection: false, seed: 2).output, as: UTF8.self)
        #expect(!output.contains("Kq7Zp2Wm9Xr4Lt6V") && output.contains("&user_lang=en-GB&page=4 if it times out."), "\(output)")
    }

    /// A word that names a part of a site under a people collection ("/authors/id/…")
    /// is no one's handle, and the same word elsewhere in the text stays too.
    @Test func aStructuralSegmentUnderPeopleIsNoHandle() throws {
        let text = """
        Mirrors keep the scripts under http://www.mirror.example/authors/id/T/TO/TOMC/scripts/ and https://forum.example/users/id/edit.
        Field Bytes Description Token ID 1 byte Token ID. The user_id column holds each row's ID.
        """
        let output = String(decoding: try Scrubber.scrub(Data(text.utf8), name: "t.txt", forceFullDetection: false, seed: 4).output, as: UTF8.self)
        #expect(output == text, "\(output)")
    }

    /// A component's text is read decoded and written back encoded as it was.
    @Test func encodingRoundTrips() {
        #expect(URLs.decode("odalys.ferriter%40kestrel.example", .query) == Self.email)
        #expect(URLs.decode("Odalys+Ferriter", .query) == "Odalys Ferriter")
        #expect(URLs.encode("Maren Holt", like: "Odalys+Ferriter", .query) == "Maren+Holt")
        #expect(URLs.encode("maren.holt@example.com", like: "odalys.ferriter%40kestrel.example", .query) == "maren.holt%40example.com")
        #expect(URLs.encode("maren.holt@example.com", like: "odalys.ferriter@kestrel.example", .query) == "maren.holt@example.com")
        #expect(URLs.encode("+15555550123", like: "%2B14158672290", .query) == "%2B15555550123")
        #expect(URLs.encode("Maren Holt", like: "Odalys%20Ferriter", .path) == "Maren%20Holt")
    }
}
