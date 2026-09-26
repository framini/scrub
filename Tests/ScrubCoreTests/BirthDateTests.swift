import Foundation
import ScrubCore
import Testing

@Test(arguments: [
    ("She was born on 1990-01-01 in Ohio.", "1990-01-01", #"\d{4}-\d{2}-\d{2}"#),
    ("maria called about her account, dob 03/14/1985.", "03/14/1985", #"\d{2}/\d{2}/\d{4}"#),
    ("Date of birth: 14.03.1985", "14.03.1985", #"\d{2}\.\d{2}\.\d{4}"#)
])
func birthDatesInFreeText(_ sentence: String, _ original: String, _ shape: String) throws {
    let result = try Scrubber.scrub(Data(sentence.utf8), name: "notes.txt")
    let text = String(decoding: result.output, as: UTF8.self)
    #expect(!text.contains(original))
    if case let .text(preview, marks, _) = result.preview {
        let dates = marks.filter { $0.entity == "DATE_OF_BIRTH" }.map { (preview as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(dates.count == 1)
        #expect(dates.first?.range(of: "^\(shape)$", options: .regularExpression) != nil)
    }
    #expect(result.unresolved.isEmpty)
}

@Test func otherDatesAreKept() throws {
    let result = try Scrubber.scrub(Data("The invoice was issued on 2024-05-01 and paid 05/03/2024.\n".utf8), name: "notes.txt")
    let text = String(decoding: result.output, as: UTF8.self)
    #expect(text.contains("2024-05-01"))
    #expect(text.contains("05/03/2024"))
}

@Test func birthDateFieldsKeepFormat() {
    let job = Job()
    let a = job.replacement(for: "DATE_OF_BIRTH", original: "03/14/1985")
    let b = job.replacement(for: "DATE_OF_BIRTH", original: "1985-03-14")
    #expect(a.range(of: #"^\d{2}/\d{2}/\d{4}$"#, options: .regularExpression) != nil && a != "03/14/1985")
    #expect(b.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil && b != "1985-03-14")
}
