import Foundation
import NaturalLanguage
@testable import ScrubCore
import Testing

/// Failures the random property and payload seeds found, each reduced to its
/// cause and checked on every input path it can reach, plus the generated
/// case itself pinned to its seed.
@Suite struct SeedRegressionTests {
    // MARK: A number whose last four digits a "last4" field repeats

    /// realisticPayloads, seed 13396540874208249897 (case 6, a webhook): the
    /// tax ID's stand-in ended in "1973", the applicant's real birth year. The
    /// "last4_ssn" beside it must repeat those digits, every draw of it was
    /// refused as a value the document holds, and it came out as "[LAST_DIGITS]".
    @Test func aNumberNeverEndsInAnotherValueTheDocumentHolds() {
        for seed in UInt64(0)..<300 {
            let standIns = StandIns(rng: SeededGenerator(seed: seed))
            // Birth years, PINs and the like found elsewhere in the document.
            var gen = Gen(seed: seed &+ 1_000)
            var held = Set<String>()
            for _ in 0..<2_500 { held.insert(String(gen.int(1000...9999))) }
            for value in held { standIns.avoid(value) }
            standIns.noteEnding("3820")
            let taxID = standIns.replace("ID_NUMBER", "183293820")
            let last4 = standIns.replace("LAST_DIGITS", "3820")
            // Type oracle: nine digits, a four-digit ending that is no other value, and the "last4" is that ending.
            #expect(taxID.count == 9 && taxID.allSatisfy(\.isNumber), "seed \(seed): \(taxID)")
            #expect(!held.contains(String(taxID.suffix(4))), "seed \(seed): \(taxID) ends in a held value")
            #expect(last4 == String(taxID.suffix(4)), "seed \(seed): \(last4) vs \(taxID)")
        }
    }

    /// One generated payload, in every way it arrives, judged field by field
    /// (the payload properties' own oracle: types, relations, kept values).
    static func judgeEveryRendering(seed: UInt64, shape: String) throws {
        var payloads = PayloadGen(seed: seed)
        let payload = payloads.payload(shape)
        var judged = 0
        for rendering in Rendering.allCases {
            guard let rendered = Render.render(payload, as: rendering, gen: &payloads.gen) else { continue }
            let result = try Scrubber.scrub(Data(rendered.text.utf8), name: rendering.filename, forceFullDetection: false, seed: seed)
            let hard = Judge.judge(payload, rendered, output: result.output).filter { $0.problem != "softChanged" }
            #expect(hard.isEmpty, "\(shape) \(rendering): \(hard.map(\.detail))")
            #expect(!String(decoding: result.output, as: UTF8.self).contains("[LAST_DIGITS]"), "\(rendering)")
            judged += 1
        }
        #expect(judged >= 8)
    }

    @Test func theWebhookKeepsItsLastFourOnEveryPath() throws {
        try Self.judgeEveryRendering(seed: 13_396_540_874_208_249_903, shape: "webhook")
    }

    // MARK: Found by the 20 new random seeds

    /// realisticPayloads, seed 116783992733670778 (case 61): a webhook's own
    /// "ID": "evt_xNptjX29KGaePinQ" sat beside "DATA", and a value key's
    /// naming sibling says what it holds ({"name": "ssn", "value": …}). Read
    /// as words, the ID spelled "pin", so everything under DATA without a key
    /// of its own (status, locale, created_at, title, time zone) became a secret.
    @Test func aRecordsOwnIDNamesNoField() throws {
        #expect(KeyHints.isToken("evt_xNptjX29KGaePinQ") && KeyHints.isToken("usr_CkceZ2w8JWBEbeDpPdq"))
        for name in ["ssn", "date_of_birth", "Applicant Name First", "address_line1", "http://hl7.org/fhir/sid/us-ssn", "phone"] { #expect(!KeyHints.isToken(name), "\(name)") }
        #expect(KeyHints.namedField("DATA", siblings: [("ID", "evt_xNptjX29KGaePinQ"), ("TYPE", "customer.updated")]) == nil)
        #expect(KeyHints.namedField("value", siblings: [("name", "ssn")]) != nil)
        try Self.judgeEveryRendering(seed: 116_783_992_733_670_839, shape: "webhook")
        // The same envelope with other IDs on every path.
        let event = #"{"id": "evt_Qm7bX29KGaePinWz", "type": "customer.updated", "data": {"object": {"status": "APPROVED", "locale": "es-MX", "created_at": "2026-11-08 18:33:25", "first_name": "Ifeoma", "last_name": "Castellane"}}}"#
        let xml = "<event><id>evt_Qm7bX29KGaePinWz</id><type>customer.updated</type><data><object><status>APPROVED</status><locale>es-MX</locale><created_at>2026-11-08 18:33:25</created_at><first_name>Ifeoma</first_name><last_name>Castellane</last_name></object></data></event>"
        for (input, name) in [(event, "event.json"), (xml, "event.xml"), ("curl -X POST https://api.example.com/hooks -d '\(event)'", "event.txt")] {
            let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 61).output, as: UTF8.self)
            for kept in ["APPROVED", "es-MX", "2026-11-08 18:33:25", "evt_Qm7bX29KGaePinWz", "customer.updated"] { #expect(output.contains(kept), "\(name): \(kept) changed in \(output)") }
            #expect(!output.contains("Ifeoma") && !output.contains("Castellane"), "\(name): \(output)")
        }
    }

    /// realisticPayloads, seeds 3240910474 (case 94) and 63515175 (case
    /// 171): a webhook flattened to CSV ("data.object.name.first",
    /// "data.object.email") read its name object as a sibling of the object
    /// around it, so the person's email and initials no longer followed the
    /// stand-in name. An object in a row sits inside the one around it.
    @Test func aFlattenedObjectSitsInsideTheOneAroundIt() throws {
        try Self.judgeEveryRendering(seed: 3_240_910_568, shape: "webhook")
        try Self.judgeEveryRendering(seed: 63_515_346, shape: "webhook")
    }

    /// realisticPayloads, seed 6165913227236476311 (case 138): a birth year
    /// of 2001 was found "still there" in every rendering, but the 2001 the
    /// judge saw opened the IPv6 address's stand-in ("2001:db8::…", the
    /// documentation prefix every IPv6 stand-in uses). The birth year itself
    /// had moved. The judge's mistake, fixed there; Scrub was right.
    @Test func aBirthYearOf2001IsNoIPv6Prefix() throws {
        #expect(Judge.leaked("2001", kind: .dobYear, in: #"{"ip": "2001:db8::4f2a", "birth_year": "2003"}"#) == nil)
        #expect(Judge.leaked("2001", kind: .dobYear, in: #"{"ip": "2001:db8::4f2a", "birth_year": "2001"}"#) == "2001")
        try Self.judgeEveryRendering(seed: 6_165_913_227_236_476_449, shape: "webhook")
    }

    /// realisticPayloads, seed 4722731081897907372 (case 189): the context
    /// model read a score, "RISK_SCORE: 0.874" in pasted YAML, as an ID.
    @Test func aScoreIsNoID() throws {
        try Self.judgeEveryRendering(seed: 4_722_731_081_897_907_561, shape: "verification")
    }

    // MARK: A name is a word of its own

    /// Property seed 9171640990125283514, case 130 (XML): the system tagger
    /// split a login like "Qz7m9rx5l1ba2ms6" at its digits and called "Qz" a
    /// name. "Qz" then spread into every token that starts with it, so a
    /// login's note read "Frank7m9rx5l1ba2ms6" while its field read "angela224".
    @Test func theHeadOfATokenIsNoName() throws {
        let note = "item Qz7m9rx5l1ba2ms6 complete; repeat Qz7m9rx5l1ba2ms6 summary"
        var organisations: [Range<Int>] = []
        let tagged = NameTagger.find(note, using: NLTagger(tagSchemes: [.nameType]), organisations: &organisations, isCancelled: { false })
        #expect(!tagged.contains { $0.entity == "PERSON" }, "\(tagged.map { TextRanges.substring(note, $0.range) })")
        #expect(NameTagger.glued(5..<7, in: note) && !NameTagger.glued(0..<4, in: note))

        // The same accounts as a file of each kind and as pasted text.
        let logins = ["Qz7m9rx5l1ba2ms6", "Qz7d54l385vghjij"]
        let notes = logins.map { "item \($0) complete; repeat \($0) summary" }
        let json = "{\"accounts\": [" + zip(logins, notes).map { "{\"login\": \"\($0)\", \"note\": \"\($1)\"}" }.joined(separator: ", ") + "]}"
        let csv = "login,note\n" + zip(logins, notes).map { "\($0),\($1)" }.joined(separator: "\n") + "\n"
        let xml = "<accounts>" + zip(logins, notes).map { "<account><login>\($0)</login><note>\($1)</note></account>" }.joined() + "</accounts>"
        let text = zip(logins, notes).map { "login: \($0)\nnote: \($1)" }.joined(separator: "\n\n")
        for (input, name) in [(json, "accounts.json"), (csv, "accounts.csv"), (xml, "accounts.xml"), (text, "accounts.txt")] {
            let result = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 9_171_640_990_125_283_644)
            let output = String(decoding: result.output, as: UTF8.self)
            #expect(result.counts["PERSON"] == nil, "\(name): \(result.counts)")
            for (login, note) in zip(logins, notes) {
                // Type oracle: each login has one stand-in, a whole token, and its note reads the same with it.
                let escaped = NSRegularExpression.escapedPattern(for: note).replacingOccurrences(of: NSRegularExpression.escapedPattern(for: login), with: "(\\S+)")
                let match = try #require(output.firstMatch(of: try Regex(escaped)), "\(name): \(output)")
                let standIns = (1..<match.count).compactMap { match[$0].substring.map(String.init) }
                #expect(Set(standIns).count == 1 && standIns.first != login && !standIns[0].hasPrefix("Qz"), "\(name): \(standIns)")
                // The login's own field holds it too.
                #expect(output.components(separatedBy: standIns[0]).count - 1 >= 3, "\(name): \(output)")
            }
        }
    }

    /// The generated case, pinned.
    @Test func propertyCase9171640990125283514Pinned() throws {
        let seed: UInt64 = 9_171_640_990_125_283_514 &+ 130
        var gen = Gen(seed: seed)
        let doc = try gen.document(format: "xml")
        let result = try doc.scrub(seed: seed)
        #expect(try doc.surroundingTextKept(in: result.output))
        #expect(try doc.model().shape == DocumentModel(data: result.output, format: doc.format, delimiter: doc.delimiter, quote: doc.quote).shape)
        #expect(result.counts["PERSON"] == nil, "\(result.counts)")
    }

    // MARK: An address read off a stand-in

    /// plainCapitalized, seed 45114708, case 167: "Table" in filler was read
    /// as a name and got the stand-in "Estrada", which the system detector
    /// then read, with the filler after it, as a road: "Estrada Quiet Weekly
    /// Summary 403". The recheck took that for an address the first pass missed.
    @Test func anAddressThatOpensWithAStandInWasReadOffIt() throws {
        let text = "Estrada Quiet Weekly Summary 403, useful table"
        // The detector does read an address there.
        #expect(Detector().find(text).contains { $0.entity == "ADDRESS" && $0.range.lowerBound == 0 })
        let marks = [Mark(range: 0..<7, entity: "PERSON", original: "Table", confidence: 0.85)]
        let (output, after, _) = try Correction.run(text, marks: marks, job: Job(seed: 3))
        #expect(output == text && after == marks, "\(output)")
        // A real street after a stand-in name is still replaced, whole.
        let moved = "Estrada moved to 4821 Juniper Hollow Rd, Tacoma, WA 98402 last spring."
        let (replaced, found, _) = try Correction.run(moved, marks: marks, job: Job(seed: 3))
        #expect(replaced.hasPrefix("Estrada moved to ") && replaced.hasSuffix(" last spring.") && !replaced.contains("Juniper"), "\(replaced)")
        #expect(found.contains { $0.entity == "ADDRESS" || $0.entity == "LOCATION" })
    }

    /// The generated case, pinned, and the same filler on every path.
    @Test func propertyCase45114708Pinned() throws {
        let seed: UInt64 = 45_114_708 + 167
        var gen = Gen(seed: seed)
        let doc = try gen.document(format: "txt", plain: true, capitalized: true, large: true)
        let result = try doc.scrub(seed: seed)
        #expect(Set(result.counts.keys).isSubset(of: ["PERSON", "LOCATION"]), "\(result.counts)")
        #expect(try doc.model().shape == DocumentModel(data: result.output, format: doc.format, delimiter: doc.delimiter, quote: doc.quote).shape)
        for path in PIIGaps.InputPath.allCases {
            let (data, name) = PIIGaps.wrap(doc.text, path)
            let counts = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed).counts
            #expect(Set(counts.keys).isSubset(of: ["PERSON", "LOCATION"]), "\(path): \(counts)")
        }
    }

    // MARK: Pinned without a cause found

    /// Seed 15170946639243693585, case 165 (CSV of passwords with quotes,
    /// backslashes and line breaks, IBANs and IPv6), failed once on an earlier
    /// tree. It passes on the tree this work started from, every run; it is
    /// pinned so a change that brings it back shows.
    @Test func propertyCase15170946639243693585Pinned() throws {
        let seed: UInt64 = 15_170_946_639_243_693_585 &+ 165
        var gen = Gen(seed: seed)
        let doc = try gen.document(format: "csv")
        let result = try doc.scrub(seed: seed)
        #expect(try doc.surroundingTextKept(in: result.output))
        #expect(try doc.model().shape == DocumentModel(data: result.output, format: doc.format, delimiter: doc.delimiter, quote: doc.quote).shape)
        #expect(try doc.leaks(in: result.output).isEmpty)
    }
}
