import Foundation
import ScrubCore
import Testing

@Test(arguments: [
    "sk_live_51Hx9aQ2eZvKYlo2CabcdEF",
    "ghp_a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8",
    "AKIAIOSFODNN7EXAMPLE",
    "xoxb-123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx",
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
])
func secretsInFreeText(_ secret: String) throws {
    let result = try Scrubber.scrub(Data("Use this key: \(secret) for the import.\n".utf8), name: "notes.txt")
    let text = try #require(String(data: result.output, encoding: .utf8))
    #expect(!text.contains(secret))
    if case let .text(_, marks, _) = result.preview { #expect(marks.contains { $0.entity == "SECRET" }) }
    #expect(result.unresolved.isEmpty)
}

@Test func bearerTokenIsReplaced() throws {
    let token = "9f8e7d6c5b4a39281706f5e4d3c2b1a0"
    let result = try Scrubber.scrub(Data("Authorization: Bearer \(token)\n".utf8), name: "notes.txt")
    #expect(!String(decoding: result.output, as: UTF8.self).contains(token))
    #expect(result.unresolved.isEmpty)
}

@Test func symbolSecretAndBarePrefix() {
    let job = Job()
    let a = job.replacement(for: "SECRET", original: "!!!@@@###")
    let b = job.replacement(for: "SECRET", original: "sk_live_")
    #expect(a.count == 24 && a.allSatisfy({ $0.isLetter || $0.isNumber }))
    #expect(b.count == 24 && b.allSatisfy({ $0.isLetter || $0.isNumber }))
    #expect(job.counts["SECRET"] == 2)
}

@Test func secretsKeepNoShape() {
    let job = Job()
    let a = job.replacement(for: "SECRET", original: "Tr0ub4dor&3")
    let b = job.replacement(for: "SECRET", original: "sk_live_51Hx9aQ2eZvKYlo2C")
    #expect(a.count == 24 && a.allSatisfy({ $0.isLetter || $0.isNumber }))
    #expect(b.hasPrefix("sk_live_") && b.count == "sk_live_".count + 24)
}
