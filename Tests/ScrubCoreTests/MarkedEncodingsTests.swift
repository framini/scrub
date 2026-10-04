import Foundation
@testable import ScrubCore
import Testing

/// A value marked by hand is replaced wherever it reads so, not only where it
/// is written plainly: percent-encoded in a link ("?depot=%51uillmere") and
/// split by markup or a hidden character ("Quill<em>mere</em>", "Quill**mere**").
@Suite struct MarkedEncodingsTests {
    enum Shape: String, CaseIterable, Sendable { case text, json, csv, xml }

    /// A depot's notes in each shape: the depot's name written plainly, inside
    /// a link percent-encoded (and in a query with "+" for a space), and split.
    static func notes(_ shape: Shape) -> (name: String, data: Data) {
        let link = "https://maps.corvane.test/find?depot=%51uillmere&near=Quillmere+North"
        let path = "https://corvane.test/depots/%51uillmere/hours"
        let text: String
        switch shape {
        case .text:
            text = """
            Parcel for Odalys Ferriter waits at the Quillmere depot.
            Map: \(link)
            Hours: \(path)
            The driver wrote Quill**mere** on the slip, and Quill\u{200B}mere on the label.
            """
        case .json:
            text = #"{"customer":"Odalys Ferriter","depot":"Quillmere","map":"\#(link)","hours":"\#(path)","slip":"Driver wrote Quill<b>mere</b> on the slip, and Quill​mere on the label."}"#
        case .csv:
            text = "customer,depot,map,hours,slip\nOdalys Ferriter,Quillmere,\(link),\(path),Driver wrote Quill\u{200B}mere on the label\n"
        case .xml:
            text = "<parcel><customer>Odalys Ferriter</customer><depot>Quillmere</depot><map>\(link.replacingOccurrences(of: "&", with: "&amp;"))</map><hours>\(path)</hours><slip>Driver wrote Quill<em>mere</em> on the slip.</slip></parcel>"
        }
        return ("notes." + (shape == .text ? "txt" : shape.rawValue), Data(text.utf8))
    }

    static func output(_ result: ScrubResult) -> String { String(decoding: result.output, as: UTF8.self) }

    /// The output as a reader reads it: links decoded, hidden characters and markup gone, XML read as text.
    static func read(_ result: ScrubResult, _ shape: Shape) -> String {
        var text = output(result)
        if shape == .xml, let document = try? XMLDocument(data: result.output, options: []) { text = document.rootElement()?.stringValue ?? text }
        if shape == .json, let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] {
            text = object.values.compactMap { $0 as? String }.joined(separator: "\n")
        }
        let decoded = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
        return Visible.plain(decoded).replacingOccurrences(of: "*", with: "").replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression).lowercased()
    }

    static func parses(_ result: ScrubResult, _ shape: Shape) -> Bool {
        switch shape {
        case .json: return (try? JSONSerialization.jsonObject(with: result.output)) != nil
        case .xml: return XMLParser(data: result.output).parse()
        case .csv:
            let widths = output(result).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).count }
            return Set(widths).count == 1
        case .text: return true
        }
    }

    /// The query value under `key` in the first link that has one, as written.
    static func query(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: #"[?&;]"# + key + #"=[^&\s"<,]*"#, options: .regularExpression) else { return nil }
        return String(text[range].drop { $0 != "=" }.dropFirst())
    }

    @Test(arguments: Shape.allCases)
    func aMarkedValueLeavesNoEncodedOrSplitForm(_ shape: Shape) throws {
        let input = Self.notes(shape)
        let result = try Scrubber.scrub(input.data, name: input.name, forceFullDetection: false, seed: 31)
        // Scrub may read some of its forms itself, the encoded one too when it reads the plain one as a name.
        let left = Self.output(result).contains("%51uillmere")
        // As the app marks: a value Scrub only suspected and left as written is replaced too.
        let (choices, marks) = result.marking(["Quillmere"], as: "LOCATION", choices: result.choices, marks: Marks())
        let marked = try result.applying(choices, marks: marks)
        let after = Self.output(marked)
        // No form of it is left, as written or as read.
        #expect(!after.lowercased().contains("quillmere") && !after.contains("%51uillmere"), "\(shape): \(after)")
        #expect(!Self.read(marked, shape).contains("quillmere"), "\(shape): \(Self.read(marked, shape))")
        #expect(Self.parses(marked, shape), "\(shape): \(after)")
        // Type oracle: a place's name, written into the link as the link needs.
        let finding = try #require(marked.byHand.first)
        #expect(!finding.standIn.isEmpty && finding.standIn.allSatisfy { $0.isLetter || " .'-".contains($0) }, "\(finding.standIn)")
        // Each encoded place takes the stand-in its value takes: the mark's, or the one Scrub gave it.
        let standIns = Set(([finding.standIn] + result.findings.filter { $0.original.lowercased() == "quillmere" }.map(\.standIn)).map { $0.lowercased() })
        let depot = try #require(Self.query("depot", in: after), "\(after)")
        #expect(standIns.contains(URLs.decode(depot, .query).lowercased()), "\(depot) vs \(standIns)")
        let near = try #require(Self.query("near", in: after), "\(after)")
        for part in [depot, near] { #expect(part.allSatisfy { $0.isLetter || $0.isNumber || "%+-._~".contains($0) }, "\(part)") }
        #expect(URLs.decode(near, .query).hasSuffix(" North"), "\(near)")
        let hours = try #require(after.range(of: #"/depots/[^/]+/hours"#, options: .regularExpression).map { String(after[$0].dropFirst(8).dropLast(6)) })
        #expect(URLs.decode(hours, .path).lowercased() == URLs.decode(depot, .query).lowercased() && !hours.contains(" "), "\(hours)")
        // The encoded places are counted among the places it reached.
        if left { #expect(finding.places.count >= 2, "\(shape): \(finding.places.count)") }
    }

    /// A word no detector reads, written plainly, split by a hidden character
    /// and by markup, and encoded in a link: one mark reaches every form.
    @Test(arguments: Shape.allCases)
    func aMarkedWordReachesItsSplitForms(_ shape: Shape) throws {
        let link = "https://wiki.corvane.test/search?tag=%71uorvelline"
        let text: String
        switch shape {
        case .text: text = "The rotation word this week is quorvelline; also logged as quor\u{200B}velline and quor**velline**.\nSee \(link)\n"
        case .json: text = #"{"note": "The rotation word this week is quorvelline", "log": "logged as quor​velline and quor<b>velline</b>", "wiki": "\#(link)"}"#
        case .csv: text = "note,log,wiki\nThe rotation word this week is quorvelline,logged as quor\u{200B}velline and quor<b>velline</b>,\(link)\n"
        case .xml: text = "<ops><note>The rotation word this week is quorvelline</note><log>logged as quor<em>velline</em> and quor\u{200B}velline</log><wiki>\(link)</wiki></ops>"
        }
        let result = try Scrubber.scrub(Data(text.utf8), name: "ops." + (shape == .text ? "txt" : shape.rawValue), forceFullDetection: false, seed: 12)
        try #require(Self.read(result, shape).components(separatedBy: "quorvelline").count >= 4, "\(shape): every form must be left to mark: \(Self.output(result))")
        let (choices, marks) = result.marking(["quorvelline"], as: "USERNAME", choices: result.choices, marks: Marks())
        let marked = try result.applying(choices, marks: marks)
        let after = Self.output(marked)
        #expect(!Self.read(marked, shape).contains("quorvelline") && !after.contains("velline"), "\(shape): \(after)")
        #expect(Self.parses(marked, shape), "\(shape): \(after)")
        // Type oracle: one handle, written the same in every place, the link's included.
        let finding = try #require(marked.byHand.first)
        #expect(!finding.standIn.isEmpty && !finding.standIn.contains(where: \.isWhitespace) && !finding.standIn.contains("@"), "\(finding.standIn)")
        #expect(finding.places.count >= 4, "\(shape): \(finding.places.count)")
        #expect(Self.read(marked, shape).components(separatedBy: finding.standIn.lowercased()).count >= 5, "\(shape): \(Self.read(marked, shape))")
    }

    /// A marked name's surname alone, percent-encoded in a link, and a marked
    /// place encoded with a hidden character inside it, are read as plain text
    /// is: the mark reaches both, and writes each stand-in encoded as the place was.
    @Test(arguments: Shape.allCases)
    func aMarkedValueReachesItsPartsEncodedAndHidden(_ shape: Shape) throws {
        let lookup = "https://desk.corvane.test/find?q=%6Cisk&page=2", depot = "https://maps.corvane.test/find?depot=%51uill%E2%80%8Bmere"
        let rota = "night desk: harrowgate lisk then lisk again on sunday", note = "the quillmere depot opens at six"
        let text: String
        switch shape {
        case .text: text = "\(rota).\nLookup: \(lookup)\nDepot: \(depot)\nNote: \(note).\n"
        case .json: text = #"{"rota": "\#(rota)", "lookup": "\#(lookup)", "depot": "\#(depot)", "note": "\#(note)"}"#
        case .csv: text = "rota,lookup,depot,note\n\(rota),\(lookup),\(depot),\(note)\n"
        case .xml: text = "<desk><rota>\(rota)</rota><lookup>\(lookup.replacingOccurrences(of: "&", with: "&amp;"))</lookup><depot>\(depot)</depot><note>\(note)</note></desk>"
        }
        let result = try Scrubber.scrub(Data(text.utf8), name: "desk." + (shape == .text ? "txt" : shape.rawValue), forceFullDetection: false, seed: 17)
        try #require(Self.output(result).contains("%6Cisk") && Self.output(result).contains("%51uill%E2%80%8Bmere"), "\(shape): the encoded forms must be left to mark: \(Self.output(result))")
        var (choices, marks) = result.marking(["harrowgate lisk"], as: "PERSON", choices: result.choices, marks: Marks())
        (choices, marks) = result.marking(["quillmere"], as: "LOCATION", choices: choices, marks: marks)
        let marked = try result.applying(choices, marks: marks)
        let after = Self.output(marked), read = Self.read(marked, shape)
        for gone in ["harrowgate", "lisk", "quillmere"] { #expect(!read.contains(gone), "\(shape) \(gone): \(after)") }
        #expect(!after.contains("%E2%80%8B") && !after.contains("\u{200B}"), "\(shape): \(after)")
        #expect(Self.parses(marked, shape), "\(shape): \(after)")
        // Type oracle: the surname's stand-in is the name's, and the place's a place's, each written as its link needs.
        let person = try #require(marked.byHand.first { $0.entity == "PERSON" }), place = try #require(marked.byHand.first { $0.entity == "LOCATION" })
        let surname = try #require(person.standIn.split(separator: " ").last.map(String.init))
        #expect(person.standIn.split(separator: " ").count == 2 && person.standIn.allSatisfy { $0.isLetter || " '-".contains($0) }, "\(person.standIn)")
        let q = try #require(Self.query("q", in: after), "\(after)")
        #expect(URLs.decode(q, .query).lowercased() == surname.lowercased(), "\(q) vs \(person.standIn)")
        let written = try #require(Self.query("depot", in: after), "\(after)")
        #expect(URLs.decode(written, .query).lowercased() == place.standIn.lowercased() && place.standIn.allSatisfy { $0.isLetter || " .'-".contains($0) }, "\(written) vs \(place.standIn)")
        for part in [q, written] { #expect(part.allSatisfy { $0.isLetter || $0.isNumber || "%+-._~".contains($0) }, "\(part)") }
    }

    @Test(arguments: Shape.allCases)
    func theSameMarksWriteTheSameBytes(_ shape: Shape) throws {
        let input = Self.notes(shape)
        let first = try Scrubber.scrub(input.data, name: input.name, forceFullDetection: false, seed: 31)
        let second = try Scrubber.scrub(input.data, name: input.name, forceFullDetection: false, seed: 31)
        var marks = Marks()
        marks.add("Quillmere", as: "LOCATION")
        let one = try first.applying(first.choices, marks: marks), two = try second.applying(second.choices, marks: marks)
        #expect(one.output == two.output)
        // Taken back, the scrub is as made.
        #expect(try one.applying(one.choices, marks: Marks()).output == first.output)
    }

    /// The XML joint parts the stand-in where the value was split: the pieces
    /// still parse, and the first holds the stand-in.
    @Test func aSplitValueInXMLIsWrittenBackInItsPieces() throws {
        let input = "<log><entry>Driver wrote Quill<em>mere</em> twice; Quillmere confirmed.</entry></log>"
        let result = try Scrubber.scrub(Data(input.utf8), name: "log.xml", forceFullDetection: false, seed: 2)
        var marks = Marks()
        marks.add("Quillmere", as: "LOCATION")
        let marked = try result.applying(result.choices, marks: marks)
        let standIn = try #require(marked.byHand.first?.standIn)
        let after = Self.output(marked)
        #expect(XMLParser(data: marked.output).parse(), "\(after)")
        #expect(after.contains("wrote " + standIn + "<em"), "\(after)")
        #expect(after.components(separatedBy: standIn).count == 3, "\(after)")
        #expect(!after.lowercased().contains("quill") && !after.contains("<em>mere"), "\(after)")
    }

    /// Each unit of a decoded link part points back at what it was read from.
    @Test func aDecodedLinkPartMapsBackToItsEscapes() throws {
        let read = try #require(URLs.decoded("%51uill+m%C3%A9re", .query))
        #expect(read.text == "Quill mére")
        #expect(read.sources[0] == 0..<3 && read.sources[1] == 3..<4 && read.sources[5] == 7..<8)
        #expect(read.sources[7] == 9..<15)
        #expect(URLs.decoded("Quillmere", .path) == nil)
        #expect(URLs.decoded("a+b", .path) == nil)
        #expect(URLs.decoded("%E2%28%A1", .query) == nil)
    }
}
