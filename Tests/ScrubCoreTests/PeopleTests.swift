import Foundation
import ScrubCore
import Testing

@Test func textMentionsShareAPersona() throws {
    let result = try Scrubber.scrub(Data("Robert Mitchell asked for a refund. Please reply to robert.mitchell@acme-corp.com today.\n".utf8), name: "notes.txt")
    let text = String(decoding: result.output, as: UTF8.self)
    let name = String(text.components(separatedBy: " asked").first ?? "")
    let parts = name.lowercased().split(separator: " ")
    #expect(parts.count == 2)
    if parts.count == 2 { #expect(text.contains("\(parts[0]).\(parts[1])@example.")) }
    #expect(!text.contains("Robert Mitchell"))
    #expect(!text.contains("robert.mitchell@acme-corp.com"))
    #expect(result.unresolved.isEmpty)
}

@Test func onePersonaAcrossFields() {
    let job = Job()
    _ = job.observe([("Ana", "firstName"), ("Pereira", "lastName"), ("ana.pereira@acme.com", "email")])
    let first = job.replacement(for: "FIRST_NAME", original: "Ana")
    let last = job.replacement(for: "LAST_NAME", original: "Pereira")
    let email = job.replacement(for: "EMAIL_ADDRESS", original: "ana.pereira@acme.com")
    #expect(email.hasPrefix("\(first.lowercased()).\(last.lowercased())@example."))
}

@Test func distinctPeopleAndStableReplacements() {
    let job = Job()
    let a = job.replacement(for: "PERSON", original: "Robert Mitchell")
    let b = job.replacement(for: "PERSON", original: "Ana Pereira")
    #expect(a != b)
    #expect(job.replacement(for: "PERSON", original: "Robert Mitchell") == a)
}

@Test func noStandInEqualsOriginalAcrossRandomRuns() {
    for _ in 0..<200 {
        let job = Job()
        for (entity, original) in [("PERSON", "Robert Mitchell"), ("EMAIL_ADDRESS", "alice@example.com"), ("DATE_OF_BIRTH", "1985-03-14"), ("SECRET", "!!!@@@###"), ("ID_NUMBER", "SE-TEST-827364"), ("US_SSN", "078-05-1120")] {
            #expect(job.replacement(for: entity, original: original).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }
}

@Test func fakesDifferBetweenRuns() {
    let runs = Set((0..<8).map { _ in Job().replacement(for: "PERSON", original: "Robert Mitchell") })
    #expect(runs.count > 1)
}

@Test func idNumberKeepsShape() {
    let job = Job()
    let fake = job.replacement(for: "ID_NUMBER", original: "SE-TEST-827364")
    #expect(fake.range(of: #"^[A-Z]{2}-[A-Z]{4}-\d{6}$"#, options: .regularExpression) != nil)
    #expect(fake != "SE-TEST-827364")
}
