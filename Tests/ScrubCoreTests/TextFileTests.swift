import Foundation
@testable import ScrubCore
import Testing

private func scrubText(_ text: String) throws -> (String, ScrubResult) {
    let result = try Scrubber.scrub(Data(text.utf8), name: "notes.txt")
    return (try #require(String(data: result.output, encoding: .utf8)), result)
}

@Test func replacesInline() throws {
    let (text, result) = try scrubText("Hi team,\n\nRobert Mitchell (robert@acme-corp.com, 212-867-5309) asked for a refund.\n")
    #expect(!text.contains("Robert Mitchell"))
    #expect(!text.contains("robert@acme-corp.com"))
    #expect(text.contains("asked for a refund."))
    if case let .text(preview, marks, _) = result.preview {
        #expect(marks.allSatisfy { $0.range.count > 0 && $0.range.upperBound <= (preview as NSString).length })
    }
    #expect(result.unresolved.isEmpty)
}

@Test(arguments: ["078-05-1120", "123-45-6789", "900-12-3456", "666-12-3456", "219-09-9999"])
func ssnShapedNumbersBecomeFakeSSNs(_ ssn: String) throws {
    let (text, result) = try scrubText("Call back re: renewal, her SSN is \(ssn) and her phone is 212-867-5309.\n")
    #expect(!text.contains(ssn))
    if case let .text(preview, marks, _) = result.preview {
        let ssns = marks.filter { $0.entity == "US_SSN" }.map { (preview as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(ssns.count == 1)
        #expect(ssns.first?.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) != nil)
        #expect(marks.contains { $0.entity == "PHONE_NUMBER" })
    }
    #expect(result.unresolved.isEmpty)
}

@Test(arguments: ["42 Wallaby Way", "1600 Pennsylvania Avenue NW", "221B Baker Street", "350 Fifth Ave, Suite 3400"])
func streetAddressesInFreeText(_ address: String) throws {
    let (text, result) = try scrubText("Please ship it to \(address), as agreed.\n")
    #expect(!text.contains(address))
    #expect(text.contains("as agreed."))
    #expect(result.unresolved.isEmpty)
}

@Test func correctionCatchesSurvivingOriginal() throws {
    let job = Job()
    let fake = job.replacement(for: "PERSON", original: "Robert Mitchell")
    let initial = "\(fake) wrote to Robert Mitchell."
    let (text, _, unresolved) = Correction.run(initial, marks: [Mark(range: 0..<(fake as NSString).length, entity: "PERSON")], job: job)
    #expect(!text.contains("Robert Mitchell"))
    #expect(unresolved.isEmpty)
}
