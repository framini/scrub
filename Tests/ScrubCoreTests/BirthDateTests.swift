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

/// A support ticket that quotes the birth date two ways round, and again in
/// words: each is the one day, its stand-in the same day in that spelling.
@Test func aBirthDateWrittenAnotherWayInATicketIsTheSameDay() throws {
    let ticket = """
    Ticket #48213 - Identity check stuck in review
    Priority: High   Assignee: support-tier2   Created: 2026-09-14 10:41 UTC

    Hi Ottoline,

    Your verification was flagged because the date of birth you entered, 03/07/1984, didn't match the bureau's 07/03/1984. \
    The old card on file reads 7 March 1984. Could you confirm which is right?

    Best,
    Verification Ops

    """
    let result = try Scrubber.scrub(Data(ticket.utf8), name: "Pasted text")
    let text = String(decoding: result.output, as: UTF8.self)
    for original in ["03/07/1984", "07/03/1984", "7 March 1984"] { #expect(!text.contains(original), "\(original) left: \(text)") }
    #expect(text.contains("Created: 2026-09-14 10:41 UTC"), "\(text)")
    let entered = try #require(text.firstMatch(of: /entered, (\d{2})\/(\d{2})\/(\d{4})/))
    let bureau = try #require(text.firstMatch(of: /bureau's (\d{2})\/(\d{2})\/(\d{4})/))
    #expect(entered.1 == bureau.2 && entered.2 == bureau.1 && entered.3 == bureau.3, "\(text)")
}

/// A chat where the agent asks for the birth date and the customer answers on
/// the next line, with a year of two digits: the answer is the birth date, in
/// its own spelling; a date the chat names otherwise stays.
@Test func aBirthDateGivenInAnswerToTheQuestionIsReplaced() throws {
    let chat = """
    [14:03:05] agent_lena: thanks for waiting. can you confirm your email and dob?
    [14:03:31] customer: ottoline.w@example.com and 12/9/95
    [14:04:10] agent_lena: got it. your parcel from 10/2/26 is still on hold
    [14:05:20] agent_lena: i'll pass this to the risk team

    """
    let result = try Scrubber.scrub(Data(chat.utf8), name: "Pasted text")
    let text = String(decoding: result.output, as: UTF8.self)
    #expect(!text.contains("12/9/95"), "\(text)")
    let answer = try #require(text.firstMatch(of: /example\.\w+ and (\d{1,2})\/(\d{1,2})\/(\d{2})\n/), "\(text)")
    #expect(Int(answer.1).map { (1...12).contains($0) } == true && Int(answer.2).map { (1...31).contains($0) } == true, "\(text)")
    #expect(text.contains("your parcel from 10/2/26 is still on hold"), "\(text)")
}
