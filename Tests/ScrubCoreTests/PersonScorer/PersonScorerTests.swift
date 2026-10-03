import Foundation
@testable import ScrubCore
import Testing

/// People only a model reads, judged by what else agrees (PersonScorer):
/// names in casual writing are replaced as people on every input path, and
/// tools, companies, job titles and departments named like people stay.
@Suite struct PersonScorerTests {
    enum Path: CaseIterable { case text, json, csv, xml }

    /// The text a reader sees after scrubbing `text` through `path`, and the result.
    static func scrub(_ text: String, _ path: Path, seed: UInt64) throws -> (String, ScrubResult) {
        switch path {
        case .text, .json, .csv:
            let inner: PIIGaps.InputPath = path == .text ? .text : path == .json ? .json : .csv
            let (data, name) = PIIGaps.wrap(text, inner)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            return (PIIGaps.readable(result.output, inner), result)
        case .xml:
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let data = Data("<ticket><id>4471</id><status>open</status><remark>\(escaped)</remark></ticket>".utf8)
            let result = try Scrubber.scrub(data, name: "ticket.xml", forceFullDetection: false, seed: seed)
            let remark = try XMLDocument(data: result.output).nodes(forXPath: "/ticket/remark").first?.stringValue ?? ""
            return (remark, result)
        }
    }

    /// Casual messages whose people (marked ⟦…⟧) only the context model reads,
    /// with a second signal beside it: a listed name, a cue, the name model.
    static let casual = [
        "ok so ⟦marguerite⟧ says the parcel never arrived",
        "lol ⟦tatiana⟧ sent the wrong invoice again",
        "Thanks for the update, I will forward it to ⟦Ignatius⟧ tomorrow.",
        "meeting with ⟦dagny⟧ and ⟦rolf⟧ moved to 3pm",
    ]

    /// The text with every ⟦name⟧ read as a pattern: the words around stay, each name becomes one.
    static func pattern(_ marked: String) -> (NSRegularExpression, [String]) {
        var regex = "^", names: [String] = []
        for (index, piece) in marked.components(separatedBy: "⟦").enumerated() {
            guard index > 0 else { regex += NSRegularExpression.escapedPattern(for: piece); continue }
            let parts = piece.components(separatedBy: "⟧")
            names.append(parts[0])
            regex += #"(\p{L}[\p{L}'’.-]*(?: \p{L}[\p{L}'’.-]*)*)"# + NSRegularExpression.escapedPattern(for: parts[1])
        }
        return (try! NSRegularExpression(pattern: regex + "$"), names)
    }

    @Test(arguments: Path.allCases) func casualNamesAreReplacedAsPeople(path: Path) throws {
        for marked in Self.casual {
            let text = marked.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
            let (regex, names) = Self.pattern(marked)
            for seed in UInt64(1)...3 {
                let (output, result) = try Self.scrub(text, path, seed: seed)
                let label = "[\(path) seed \(seed)] \(output.debugDescription)"
                let match = try #require(regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)), "only the name changes: \(label)")
                for (index, name) in names.enumerated() {
                    let standIn = (output as NSString).substring(with: match.range(at: index + 1))
                    #expect(standIn.lowercased() != name.lowercased(), "\(name) kept: \(label)")
                    // The stand-in is a person's name written as the original was.
                    #expect((standIn.first?.isUppercase == true) == (name.first?.isUppercase == true), "\(standIn) for \(name): \(label)")
                    #expect(NameLists.isFirst(standIn) || NameLists.isSurname(standIn), "\(standIn) is no name: \(label)")
                    let finding = try #require(result.findings.first { $0.original == name }, "no finding for \(name): \(label)")
                    #expect(finding.entity == "PERSON", "\(finding.entity): \(label)")
                    #expect(finding.confidence >= ContextStage.score && finding.confidence <= 0.85, "confidence \(finding.confidence): \(label)")
                }
                #expect(result.counts.keys.allSatisfy { $0 == "PERSON" }, "\(result.counts) \(label)")
            }
        }
    }

    /// Words the context model may read as people that something says are not.
    static let things = [
        "Brindlewick was acquired by a larger chain last spring.",
        "Grafton was founded in 1902 in a rented barn.",
        "Tallowmere shipped the update overnight.",
        "The Thornfield build failed on main again.",
        "The build agent reports Marlowe 14.2.1 on every host.",
    ]

    @Test(arguments: Path.allCases) func thingsNamedLikePeopleStay(path: Path) throws {
        for text in Self.things {
            for seed in UInt64(1)...2 {
                let (output, result) = try Self.scrub(text, path, seed: seed)
                #expect(output == text, "[\(path) seed \(seed)] \(output.debugDescription)")
                #expect(result.counts["PERSON", default: 0] == 0, "[\(path)] \(result.counts)")
            }
        }
    }

    /// A town someone lives in or moves to is a place, whatever the context model reads.
    static let places = ["Moved to Veszprem last spring, update the address on file.", "She still lives in Kessingland with her sister.", "He is flying into Tarnowo on Thursday."]

    @Test(arguments: Path.allCases) func placesAreNoPeople(path: Path) throws {
        for text in Self.places {
            let (output, result) = try Self.scrub(text, path, seed: 1)
            #expect(result.counts["PERSON", default: 0] == 0, "[\(path)] \(result.counts) \(output.debugDescription)")
            #expect(result.findings.allSatisfy { $0.entity == "LOCATION" }, "[\(path)] \(result.findings.map(\.entity)) \(output.debugDescription)")
        }
    }

    /// A job title, a studio or a department over an address is nobody; the person a parcel is for is someone.
    static let addressed: [(text: String, kept: [String], gone: [String])] = [
        ("Regards,\nMarisol Quintana\nSenior Paralegal\n4821 Juniper Hollow Rd\nTacoma, WA 98402", ["Regards,", "Senior Paralegal"], ["Marisol", "Quintana", "Juniper", "Tacoma"]),
        ("Cheers,\nBram\nKestrelwood Studio\n1414 Rookery Lane\nBoise, ID 83702", ["Cheers,", "Kestrelwood Studio"], ["Bram", "Rookery", "Boise"]),
        ("Accounts Payable\n77 Pellow Street\nDenver, CO 80205", ["Accounts Payable"], ["Pellow", "Denver"]),
        ("Please ship it to:\nOluwaseun Brightwater\n4821 Juniper Hollow Rd\nTacoma, WA 98402", ["Please ship it to:"], ["Oluwaseun", "Brightwater", "Juniper", "Tacoma"]),
    ]

    @Test(arguments: Path.allCases) func theLineOverAnAddressIsAPersonOnlyWhenItNamesOne(path: Path) throws {
        for sample in Self.addressed {
            for seed in UInt64(1)...3 {
                let (output, result) = try Self.scrub(sample.text, path, seed: seed)
                let label = "[\(path) seed \(seed)] \(output.debugDescription)"
                let lines = output.components(separatedBy: "\n")
                #expect(lines.count == sample.text.components(separatedBy: "\n").count, "lines kept: \(label)")
                for line in sample.kept { #expect(lines.contains(line), "\(line) changed: \(label)") }
                #expect(SpreadTests.gone(sample.gone, from: output).isEmpty, "\(SpreadTests.gone(sample.gone, from: output)) left: \(label)")
                #expect(result.counts["ADDRESS", default: 0] >= 1, "\(result.counts) \(label)")
                // The addressee, where there is one, is one person; a title or a business is none.
                let people = result.findings.filter { $0.entity == "PERSON" }.map(\.original)
                #expect(!people.contains { sample.kept.contains($0) }, "\(people) \(label)")
            }
        }
    }

    @Test func readsAsAddressee() {
        #expect(Detector.readsAsAddressee(["Oluwaseun", "Brightwater"]))
        #expect(Detector.readsAsAddressee(["Jane", "Price"]))
        for words in [["Senior", "Paralegal"], ["Kestrelwood", "Studio"], ["Accounts", "Payable"], ["Office", "Manager"], ["Brackenfold", "Dental"]] {
            #expect(!Detector.readsAsAddressee(words), "\(words)")
        }
    }

    // MARK: The rules and the scorer

    @Test func theWeightsAndTheSignalsAgree() {
        #expect(PersonScorer.weights.count == PersonScorer.Signals.names.count)
        #expect(PersonScorer.Signals().vector.count == PersonScorer.Signals.names.count)
        #expect(PersonScorer.keepFrom > 0 && PersonScorer.keepFrom < 1)
    }

    @Test func aContextGuessNeedsAnotherSignal() {
        var alone = PersonScorer.Signals()
        alone.context = 6
        alone.capitalised = true
        #expect(!PersonScorer.agrees(alone))
        for agreeing in [\PersonScorer.Signals.title, \.greeting, \.strong, \.nameModelFound, \.first, \.surname] {
            var signals = alone
            signals[keyPath: agreeing] = true
            #expect(PersonScorer.agrees(signals), "\(agreeing)")
        }
        // A listed name that is an ordinary word is no agreement on its own.
        var ordinary = alone
        (ordinary.first, ordinary.ordinary) = (true, true)
        #expect(!PersonScorer.agrees(ordinary))
        // A word opening a sentence before a verb ("Siri misheard") needs the name model.
        var opening = alone
        (opening.first, opening.opens, opening.subject, opening.position) = (true, true, true, true)
        #expect(!PersonScorer.agrees(opening))
        opening.nameModelFound = true
        #expect(PersonScorer.agrees(opening))
        // An organisation, a place, an acronym or a word after "the" never.
        for veto in [\PersonScorer.Signals.organisation, \.place, \.determiner, \.version, \.placeCue] {
            var signals = alone
            signals.title = true
            signals[keyPath: veto] = true
            #expect(!PersonScorer.agrees(signals), "\(veto)")
        }
    }

    @Test func theScorerWeighsWhatAgrees() {
        var weak = PersonScorer.Signals()
        (weak.nameModel, weak.context, weak.capitalised, weak.ordinary) = (-6, -2, true, true)
        var strong = PersonScorer.Signals()
        (strong.nameModel, strong.nameModelFound, strong.context, strong.first, strong.greeting) = (9, true, 7, true, true)
        #expect(PersonScorer.probability(weak) < PersonScorer.keepFrom)
        #expect(PersonScorer.probability(strong) > 0.9)
        #expect(PersonScorer.confidence(PersonScorer.probability(strong)) == 0.85)
        #expect(PersonScorer.confidence(PersonScorer.keepFrom) == ContextStage.score)
    }

    /// With the hand rules, a name the context model read beside a second
    /// signal is still replaced, and asked about before sharing.
    @Test(arguments: Path.allCases) func theHandRulesKeepAgreedNamesForReview(path: Path) throws {
        try PersonScorer.$learned.withValue(false) {
            for marked in Self.casual {
                let text = marked.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
                let (regex, names) = Self.pattern(marked)
                let (output, result) = try Self.scrub(text, path, seed: 1)
                #expect(regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)) != nil, "[\(path)] \(output.debugDescription)")
                for name in names {
                    let finding = try #require(result.findings.first { $0.original == name }, "[\(path)] \(name): \(output.debugDescription)")
                    #expect(finding.needsReview, "[\(path)] \(name) at \(finding.confidence)")
                }
            }
        }
    }
}
