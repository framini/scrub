import Foundation
import ScrubCore
import Testing

@Test func keyHints() {
    #expect(KeyHints.hint("firstName") == "FIRST_NAME")
    #expect(KeyHints.hint("last_name") == "LAST_NAME")
    #expect(KeyHints.hint("Email") == "EMAIL_ADDRESS")
    #expect(KeyHints.hint("phone-number") == "PHONE_NUMBER")
    #expect(KeyHints.hint("plan") == nil)
    #expect(KeyHints.hint("username") == "USERNAME")
    #expect(KeyHints.hint("national_id") == "ID_NUMBER")
    #expect(KeyHints.hint("api_key") == "SECRET")
}

@Test func validatedPatterns() {
    let detector = Detector()
    let text = "Email alice@example.com, card 4111111111111111, invalid 4111111111111112, IP 192.0.2.1, IBAN GB82WEST12345698765432."
    let found = detector.find(text)
    #expect(found.contains { $0.entity == "EMAIL_ADDRESS" })
    #expect(found.contains { $0.entity == "CREDIT_CARD" && (text as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) == "4111111111111111" })
    #expect(!found.contains { $0.entity == "CREDIT_CARD" && (text as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) == "4111111111111112" })
    #expect(found.contains { $0.entity == "IP_ADDRESS" })
    #expect(found.contains { $0.entity == "IBAN_CODE" })
}

@Test func titleCaseSecondPass() {
    let detector = Detector()
    #expect(detector.find("maria called about her account").contains { $0.entity == "PERSON" })
    #expect(!detector.find("The enterprise plan renews in March for the Finance team").contains { $0.entity == "PERSON" })
}

@Test(arguments: [
    "please mark the date in the calendar",
    "we had a frank discussion about pricing",
    "they will jack up the price next year",
    "the invoice has a grace period of ten days",
    "an amber warning light and a crystal clear screen",
    "the heather and hazel hedges were trimmed",
])
func ordinaryWordsThatAreAlsoFirstNamesStayText(_ sentence: String) throws {
    let result = try Scrubber.scrub(Data(sentence.utf8), name: "note.txt")
    #expect(String(data: result.output, encoding: .utf8) == sentence)
    #expect(result.counts["PERSON", default: 0] == 0)
}

@Test func documentConsistency() throws {
    let result = try Scrubber.scrub(Data("Robert Mitchell called. Later, robert mitchell replied.".utf8), name: "note.txt")
    let text = try #require(String(data: result.output, encoding: .utf8))
    #expect(!text.lowercased().contains("robert mitchell"))
    #expect(result.counts["PERSON"] == 2)
    #expect(result.unresolved.isEmpty)
}

@Test func utf16MarksPointIntoPreview() throws {
    let result = try Scrubber.scrub(Data("😀 Call alice@example.com now.".utf8), name: "note.txt")
    if case let .text(preview, marks, _) = result.preview {
        let email = try #require(marks.first { $0.entity == "EMAIL_ADDRESS" })
        let marked = (preview as NSString).substring(with: NSRange(location: email.range.lowerBound, length: email.range.count))
        #expect(marked.contains("@example."))
        #expect(email.range.lowerBound >= 2)
    }
}

@Test func standInNumbersValidate() {
    let job = Job()
    let card = job.replacement(for: "CREDIT_CARD", original: "5555555555554444")
    let iban = job.replacement(for: "IBAN_CODE", original: "GB82WEST12345698765432")
    #expect(Detector().find(card).contains { $0.entity == "CREDIT_CARD" })
    #expect(Detector().find(iban).contains { $0.entity == "IBAN_CODE" })
}
