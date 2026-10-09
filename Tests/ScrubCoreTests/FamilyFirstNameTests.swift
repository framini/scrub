import Foundation
@testable import ScrubCore
import Testing

/// Korean, Japanese, Chinese, Vietnamese and Hungarian names written family name first: people of one
/// family share a stand-in family name and people of one given name a stand-in given name, in the
/// order and the capitals they were written in.
struct FamilyFirstNameTests {
    static func scrub(_ text: String, _ file: String) throws -> (ScrubResult, String) {
        let result = try Scrubber.scrub(Data(text.utf8), name: file, forceFullDetection: false, seed: 11)
        return (result, String(decoding: result.output, as: UTF8.self))
    }
    static func words(_ text: String) -> Set<String> { Set(text.lowercased().split { !$0.isLetter }.map(String.init)) }

    @Test func aRecordsNamesWrittenFamilyFirstKeepTheirFamilies() throws {
        let people = ["Park Ji-woo", "Kim Ji-woo", "Park Min-jun", "MORITA Kenji", "MORITA Haruka", "SATO Kenji", "Zhang Wei", "Wang Wei", "Zhang Xiuying",
                      "Nagy Eszter", "Kovács Eszter", "Nagy Péter", "Nguyễn Văn An", "Trần Văn An", "Nguyễn Thị Lan"]
        let records = people.enumerated().map { #"{"case_ref": "KV-\#(4100 + $0.offset)", "applicant": {"full_name": "\#($0.element)", "nationality": "XX"}, "status": "review"}"# }
        let document = #"{"batch": "2026-10", "checks": ["# + records.joined(separator: ",\n  ") + "]}"
        let (_, output) = try Self.scrub(document, "screening.json")
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], "\(output)")
        let checks = try #require(parsed["checks"] as? [[String: Any]])
        let written = checks.compactMap { ($0["applicant"] as? [String: String])?["full_name"] }
        #expect(written.count == people.count, "\(output)")
        var standIn: [String: [String]] = [:]
        for (real, fake) in zip(people, written) { standIn[real] = fake.split(separator: " ").map(String.init) }
        func family(_ name: String) -> String { standIn[name]?.first ?? "?" }
        func given(_ name: String) -> String { standIn[name]?.last ?? "?" }
        for name in people {
            for part in Self.words(name) where part.count > 2 { #expect(!Self.words(output).contains(part), "\(part) kept: \(output)") }
        }
        // One family's people share its stand-in; another family has its own.
        for (one, other) in [("Park Ji-woo", "Park Min-jun"), ("MORITA Kenji", "MORITA Haruka"), ("Zhang Wei", "Zhang Xiuying"), ("Nagy Eszter", "Nagy Péter"), ("Nguyễn Văn An", "Nguyễn Thị Lan")] {
            #expect(family(one) == family(other), "\(one) and \(other): \(output)")
        }
        for (one, other) in [("Park Ji-woo", "Kim Ji-woo"), ("MORITA Kenji", "SATO Kenji"), ("Zhang Wei", "Wang Wei"), ("Nagy Eszter", "Kovács Eszter"), ("Nguyễn Văn An", "Trần Văn An")] {
            #expect(family(one) != family(other), "\(one) and \(other): \(output)")
            // One given name, one stand-in given name.
            #expect(given(one) == given(other), "\(one) and \(other): \(output)")
        }
        // "MORITA Kenji" keeps the family name in capitals and the given name in none.
        #expect(family("MORITA Kenji") == family("MORITA Kenji").uppercased() && given("MORITA Kenji") != given("MORITA Kenji").uppercased(), "\(output)")
        // A Vietnamese middle name goes with the rest, as any full name's middle name does.
        #expect(!output.contains("Văn") && !output.contains("Thị"), "\(output)")
    }

    @Test func namesWrittenFamilyFirstInProseKeepTheirFamilies() throws {
        let text = """
        Branch visit, 3 October: Park Ji-woo opened the account and Kim Ji-woo co-signed as guarantor.
        The forms were witnessed by MORITA Kenji and MORITA Haruka; SATO Kenji countersigned.
        Later that day Park Ji-woo called back to confirm the transfer limit.
        """
        let (result, output) = try Self.scrub(text, "Pasted text")
        var standIn: [String: [String]] = [:]
        for finding in result.findings { standIn[finding.original] = finding.standIn.split(separator: " ").map(String.init) }
        for part in ["Park", "Kim", "Ji-woo", "MORITA", "Kenji", "Haruka", "SATO"] { #expect(!output.contains(part), "\(part) kept: \(output)") }
        let park = try #require(standIn["Park Ji-woo"], "\(result.findings.map(\.original))"), kim = try #require(standIn["Kim Ji-woo"], "\(result.findings.map(\.original))")
        #expect(park.first != kim.first && park.last == kim.last, "\(park) \(kim)")
        let kenji = try #require(standIn["MORITA Kenji"]), haruka = try #require(standIn["MORITA Haruka"]), sato = try #require(standIn["SATO Kenji"])
        #expect(kenji.first == haruka.first && kenji.first != sato.first && kenji.last == sato.last && kenji.last != haruka.last, "\(kenji) \(haruka) \(sato)")
        #expect(kenji.first == kenji.first?.uppercased() && kenji.last != kenji.last?.uppercased(), "\(kenji)")
    }

    /// A name in the usual order with such a family name last, or a given name like "Kim" first, stays in that order.
    @Test func namesInTheUsualOrderStayGivenNameFirst() throws {
        let document = #"""
        {"contacts": [{"name": "Wei Zhang"}, {"name": "Ming Zhang"}, {"name": "Kim Holloway"}, {"name": "Kim Pemberton"}, {"name": "Eszter Nagy"}, {"name": "Haruka Morita"}]}
        """#
        let (_, output) = try Self.scrub(document, "contacts.json")
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], "\(output)")
        let names = (parsed["contacts"] as? [[String: String]] ?? []).compactMap { $0["name"]?.split(separator: " ").map(String.init) }
        try #require(names.count == 6, "\(output)")
        #expect(names[0].last == names[1].last && names[0].first != names[1].first, "\(output)")
        #expect(names[2].first == names[3].first && names[2].last != names[3].last, "\(output)")
        for part in ["Zhang", "Holloway", "Pemberton", "Eszter", "Nagy", "Haruka", "Morita"] { #expect(!output.contains(part), "\(part) kept: \(output)") }
    }
}
