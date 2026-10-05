import Foundation
@testable import ScrubCore
import Testing

/// The address model and what it adds: postal addresses in signatures, in
/// other countries' formats and in prose, each replaced as one unit by a
/// stand-in of the same shape, on every input path; and nothing at all in
/// text that only looks like one. Every person, street and number here is invented.
@Suite(.serialized)
struct AddressModelTests {
    private struct ParityCase: Decodable {
        let text: String
        let tokens: [[Int]]
        let logits: [[Float]]
        let addresses: [[Int]]
    }

    @Test func loads() {
        #expect(AddressModel.shared != nil)
        #expect(AddressModel.wide != nil)
    }

    /// The Swift port splits, scores and decodes text exactly as each trained
    /// model does, including a long text that spans several windows.
    @Test(arguments: [false, true]) func matchesTraining(wide: Bool) throws {
        let model = try #require(wide ? AddressModel.wide : AddressModel.shared)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(wide ? "Fixtures/address-model-wide-parity.json" : "Fixtures/address-model-parity.json")
        let cases = try JSONDecoder().decode([ParityCase].self, from: Data(contentsOf: url))
        for sample in cases {
            let tokens = NameModel.tokens(sample.text)
            #expect(tokens.map { [$0.range.lowerBound, $0.range.upperBound] } == sample.tokens, "\(sample.text.prefix(60))")
            let logits = tokens.isEmpty ? [] : model.logits(tokens)
            #expect(logits.count == sample.logits.count)
            for (index, (swift, python)) in zip(logits, sample.logits).enumerated() {
                for label in 0..<3 {
                    #expect(abs(swift[label] - python[label]) < 1e-3 * max(1, abs(python[label])), "\(sample.text.prefix(60)) token \(index): \(swift) vs \(python)")
                }
            }
            let decoded = tokens.isEmpty ? [] : AddressModel.decode(tokens, model.probabilities(tokens), numberless: model.numberless)
            #expect(decoded.map { [$0.lowerBound, $0.upperBound] } == sample.addresses, "\(sample.text.prefix(60))")
        }
    }

    @Test func rejectsDamagedWeights() {
        #expect(AddressModel(Data("SAM1".utf8)) == nil)
        #expect(AddressModel(Data()) == nil)
    }

    /// Weights altered on disk are refused, even ones that still parse as a
    /// model, and Scrub then runs without it.
    @Test(arguments: [AddressModel.Weights.first, .wide]) func loadsOnlyWithItsChecksum(weights: AddressModel.Weights) throws {
        let url = try #require(ModelResources.bundle?.url(forResource: weights.name, withExtension: "bin"))
        var data = try Data(contentsOf: url)
        #expect(AddressModel.verified(data, weights: weights) != nil)
        data[data.count - 1] ^= 0x01
        #expect(AddressModel(data) != nil)
        #expect(AddressModel.verified(data, weights: weights) == nil, "an altered file is refused")
        #expect(AddressModel.verified(try Data(contentsOf: url), weights: weights, checksum: String(repeating: "0", count: 64)) == nil)
        // Each file is only itself.
        #expect(AddressModel.verified(try Data(contentsOf: url), weights: weights.name == "AddressModel" ? .wide : .first) == nil)
    }

    // MARK: Addresses on every path

    enum Path: CaseIterable { case text, json, csv, xml }

    struct Case {
        /// The text, with the address marked ⟦…⟧. What shares a line with the address is no one's.
        let marked: String
        /// Words of the real address that must all be gone.
        let words: [String]
        /// The country the stand-in's locality must be in.
        let country: String?
        /// Lines around the address that hold nothing personal, so stay as written.
        var kept: [String] = []

        var prose: String { marked.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "") }
        var address: String { String(marked.split(separator: "⟦")[1].split(separator: "⟧")[0]) }
        var before: String { String(marked.split(separator: "⟦", omittingEmptySubsequences: false)[0]) }
        var after: String { String(marked.split(separator: "⟧", omittingEmptySubsequences: false)[1]) }

        /// The stand-in in `output`, read off the address's lines, and whether the lines around it that hold nothing personal stayed.
        func standIn(in output: String) -> (String, Bool)? {
            let lines = output.components(separatedBy: "\n")
            guard lines.count == prose.components(separatedBy: "\n").count else { return nil }
            let first = before.components(separatedBy: "\n").count - 1, last = first + address.components(separatedBy: "\n").count - 1
            let lead = before.components(separatedBy: "\n").last ?? "", tail = after.components(separatedBy: "\n").first ?? ""
            let block = lines[first...last].joined(separator: "\n")
            guard block.hasPrefix(lead), block.hasSuffix(tail), block.count >= lead.count + tail.count else { return nil }
            return (String(block.dropFirst(lead.count).dropLast(tail.count)), kept.allSatisfy(lines.contains))
        }
    }

    static let cases: [Case] = [
        Case(marked: "Thanks,\nOrla Penhallow\n⟦Suite 1400, 88 Quarrendon Street\nLeeds LS1 4DX⟧\nT: +44 113 496 0821",
             words: ["1400", "Quarrendon", "Leeds", "LS1", "4DX"], country: "GB", kept: ["Thanks,"]),
        Case(marked: "Best regards,\nMateus Ferreira-Lind\n⟦Rua das Amendoeiras 214, 3º Esq.\n1170-023 Lisboa\nPortugal⟧",
             words: ["Amendoeiras", "214", "1170-023", "Lisboa"], country: "PT", kept: ["Best regards,"]),
        Case(marked: "Mit freundlichen Grüßen\nJannik Oberreuter\nBrandtwerk GmbH\n⟦Lindenhofer Straße 48a\n70178 Stuttgart⟧\nTel. +49 711 555 0144",
             words: ["Lindenhofer", "48a", "70178", "Stuttgart"], country: "DE", kept: ["Mit freundlichen Grüßen", "Brandtwerk GmbH"]),
        Case(marked: "Please send the replacement to ⟦Flat 3, 27 Pellow Gardens, Bristol BS6 5QR⟧ — I moved last month.",
             words: ["Pellow", "Bristol", "BS6", "5QR"], country: "GB"),
        Case(marked: "We've moved! Our new office is at ⟦Keizersgracht 418-2, 1016 GC Amsterdam⟧.",
             words: ["Keizersgracht", "418-2", "1016", "Amsterdam"], country: "NL"),
        Case(marked: "She moved last month. Her new flat is ⟦ul. Kwiatowa 7 m. 12, 30-389 Kraków⟧.",
             words: ["Kwiatowa", "30-389", "Kraków"], country: "PL"),
        Case(marked: "Cheers,\nBram\n--\nKestrelwood Studio\n⟦Unit 6, 41 Tamsin Road\nCollingwood VIC 3066⟧\n0412 555 019",
             words: ["Tamsin", "Collingwood", "3066"], country: "AU", kept: ["Cheers,", "--"]),
        Case(marked: "she lives at ⟦1414 Rookery Lane⟧ now, with her sister",
             words: ["1414", "Rookery"], country: nil),
        Case(marked: "Return address:\n⟦Via dei Tessitori 9, 50122 Firenze (FI)⟧",
             words: ["Tessitori", "50122", "Firenze"], country: "IT", kept: ["Return address:"]),
        Case(marked: "Sincerely,\nDr. Kwabena Asante-Moreau\n⟦Room 4.12, Harrowgate Building\n200 University Avenue West\nWaterloo, ON N2L 3G5\nCanada⟧",
             words: ["Harrowgate", "University", "Waterloo", "N2L", "3G5"], country: "CA", kept: ["Sincerely,"]),
        Case(marked: "Faktura skickas till ⟦Box 3318, 103 66 Stockholm⟧.",
             words: ["3318", "103 66", "Stockholm"], country: "SE"),
        Case(marked: "Ship to:\nPriyanka Raghavan\n⟦Flat 702, Lakeshore Residency, 5th Cross Road\nIndiranagar\nBengaluru, Karnataka 560038⟧",
             words: ["702", "Lakeshore", "Indiranagar", "Bengaluru", "Karnataka", "560038"], country: "IN", kept: ["Ship to:"]),
    ]

    @Test(arguments: Path.allCases) func addressesAreReplacedWhole(path: Path) throws {
        for sample in Self.cases {
            for seed in UInt64(0)..<3 {
                let (output, counts) = try Self.scrub(sample.prose, path, seed: seed)
                let label = "[\(path) seed \(seed)] \(output.debugDescription)"
                let found = try #require(sample.standIn(in: output), "lines and context kept: \(label)")
                #expect(found.1, "lines around it as written: \(label)")
                #expect(SpreadTests.gone(sample.words, from: found.0).isEmpty, "\(SpreadTests.gone(sample.words, from: found.0)) left: \(label)")
                #expect(counts["ADDRESS", default: 0] >= 1, "\(counts) \(label)")
                #expect(Self.sameShape(sample.address, found.0, country: sample.country), "shape: \(found.0.debugDescription) for \(sample.address.debugDescription)")
            }
        }
    }

    /// The stand-in keeps the address's lines and pieces, a number where the
    /// street had one, and a locality of the same country whose postcode is
    /// written alike; in Scrub's four countries, its city, region and postcode are one real place.
    static func sameShape(_ original: String, _ standIn: String, country: String?) -> Bool {
        guard standIn.components(separatedBy: "\n").count == original.components(separatedBy: "\n").count else { return false }
        if let line = AddressParts.line(original) {
            guard let made = AddressParts.line(standIn), made.pieces.count == line.pieces.count, let city = made.parts.city else { return false }
            return Places.all.contains { place in
                place.city == city && (made.parts.region.map { Places.region($0, in: place.country)?.code == Places.region(place.region, in: place.country)?.code } ?? true)
            }
        }
        guard let block = AddressBlock.read(original) else { return standIn.first?.isNumber == original.first?.isNumber && standIn != original }
        guard let made = AddressBlock.read(standIn), made.roles == block.roles, made.separators == block.separators else { return false }
        for (index, locality) in block.localities {
            guard let other = made.localities.first(where: { $0.index == index })?.locality else { return false }
            if let postal = locality.postal, other.postal.map({ shape($0) == shape(postal) }) != true { return false }
            if let country, let city = other.city, locality.city != nil {
                if ["US", "CA", "GB", "AU"].contains(country) {
                    guard let place = Places.all.first(where: { $0.city.caseInsensitiveCompare(city) == .orderedSame && $0.country == country }) else { return false }
                    if let postal = other.postal, !place.postal.contains(where: { postal.uppercased().hasPrefix($0) }) { return false }
                } else if !Places.abroad.contains(where: { $0.country == country && $0.city.caseInsensitiveCompare(city) == .orderedSame }) {
                    return false
                }
            }
        }
        return true
    }

    private static func shape(_ text: String) -> String { String(text.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 }) }

    // MARK: What is not an address

    /// Text with numbers beside capitalised words and nothing personal in it.
    static let notAddresses = [
        "v2.14.1 released on 12 March 2024 — see CHANGELOG for details.",
        "Ticket #55120 Priority High\nAssigned to: Platform Team",
        "Meeting moved to 14:30 in Room 4B, Building 2.",
        "We ordered 12 Queen Beds and 40 King Size Pillows for the lodge.",
        "Python 3.12.11 (main, Aug 18 2025, 19:02:39) [Clang 20.1.4]",
        "for (int i = 0; i < 4096; i++) {\n    street[i] = parse_line(buf, 12);\n}",
        "| Item        | Qty | Price  |\n| Main Course | 12  | 340.00 |\n| Park Pass   | 4   | 60.00  |",
        "Options:\n  -n count  Stop after count packets. With -c 10 the program exits after ten replies.",
        "Seats 12A and 12B, Row 14, Stand C.",
        "Version 11.6 Street Edition supports 4 Players.",
        "Sprint 14 Planning: 3 Main Goals, 12 Story Points each.",
        "Season 4 Episode 12 airs on Channel 5 at 21:00.",
        "Item 4, Lot 212: Edwardian Oak Bookcase, 3 Shelves.",
        "Q4 2025: 18 New Stores, 4 Regions, 2 Distribution Centres.",
    ]
    /// Look-alikes beside a name or a place that other detectors replace: the model adds nothing to them.
    static let besideOthers = [
        "re: order 77120\nHi Saoirse,\n\nYour replacement card has shipped.",
        "Flight BA 117 to London departs from Gate B12 at 18:40.",
        "Hi team,\n\nOrder 55120 shipped today; tracking AB1234567GB.\n\nThanks,\nRafael",
        "The 2 Way Splitter and 3 Lane Highway models ship in May.",
    ]

    @Test(arguments: Path.allCases) func lookAlikesStayAsWritten(path: Path) throws {
        for text in Self.notAddresses {
            let (output, counts) = try Self.scrub(text, path, seed: 1)
            #expect(counts["ADDRESS", default: 0] == 0, "[\(path)] \(counts) \(output.debugDescription)")
            #expect(output == text, "[\(path)] \(output.debugDescription)")
        }
        for text in Self.notAddresses + Self.besideOthers {
            let with = try Self.scrub(text, path, seed: 1)
            let without = try AddressModel.$active.withValue(false) { try Self.scrub(text, path, seed: 1) }
            #expect(with.0 == without.0 && with.1 == without.1, "[\(path)] the model changed \(text.debugDescription): \(with.0.debugDescription) against \(without.0.debugDescription)")
        }
    }

    /// Addresses the rules and the system's detector read only in part, or not at all.
    static let modelOnly: [(text: String, words: [String])] = [
        ("Could you post the forms to 47 Harlow Mead, Chelmsford CM2 7QP? Ta.", ["Harlow", "Chelmsford", "CM2", "7QP"]),
        ("Kontakt: Mühlenkamp 9, 22303 Hamburg · 040 555 0181", ["Mühlenkamp", "22303", "Hamburg"]),
        ("Hälsningar\nSigne Bergqvist\nKvarnbacken 4 B\n722 14 Västerås", ["Kvarnbacken", "Västerås"]),
        ("Witness gave her address as Bramblecote Farm, Wexley Lane, Little Ousebridge, YO61 4RT.", ["Bramblecote", "Wexley", "Ousebridge", "YO61"]),
        ("Postal address:\nPostfach 12 03 44\n53045 Bonn", ["53045", "Bonn"]),
        ("Customer relocated to Brändströmsgatan 6, SE-582 23 Linköping.", ["Brändströmsgatan", "Linköping"]),
        ("Could you forward any post to PO Box 7712, Halifax NS B3K 5M2 until June?", ["7712", "Halifax", "B3K"]),
        ("Ship to:\nPriyanka Raghavan\nFlat 702, Lakeshore Residency, 5th Cross Road\nIndiranagar\nBengaluru, Karnataka 560038", ["Lakeshore", "Indiranagar", "Bengaluru", "560038"]),
    ]

    /// The model is what finds these: with it every word of each address is
    /// gone; without it, most of them keep some (the system's detector reads
    /// a few, and may read more in later releases of macOS).
    @Test func theModelIsWhatFindsThem() throws {
        var partly = 0
        for (text, words) in Self.modelOnly {
            let (with, _) = try Self.scrub(text, .text, seed: 2)
            let (without, _) = try AddressModel.$active.withValue(false) { try Self.scrub(text, .text, seed: 2) }
            #expect(SpreadTests.gone(words, from: with).isEmpty, "with the model: \(with.debugDescription)")
            if !SpreadTests.gone(words, from: without).isEmpty { partly += 1 }
        }
        #expect(partly * 2 >= Self.modelOnly.count, "only \(partly) of \(Self.modelOnly.count) need the model")
    }

    // MARK: Helpers

    static func scrub(_ text: String, _ path: Path, seed: UInt64) throws -> (String, [String: Int]) {
        switch path {
        case .text, .json, .csv:
            let inner: PIIGaps.InputPath = path == .text ? .text : path == .json ? .json : .csv
            let (output, result) = try SpreadTests.scrub(text, inner, seed: seed)
            return (output, result.counts)
        case .xml:
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let data = Data("<ticket><id>4471</id><status>open</status><remark>\(escaped)</remark></ticket>".utf8)
            let result = try Scrubber.scrub(data, name: "ticket.xml", forceFullDetection: false, seed: seed)
            let document = try XMLDocument(data: result.output)
            let remark = try document.nodes(forXPath: "/ticket/remark").first?.stringValue ?? ""
            return (remark, result.counts)
        }
    }
}
