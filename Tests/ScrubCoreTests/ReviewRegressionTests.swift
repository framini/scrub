import Foundation
@testable import ScrubCore
import Testing

private func cleaned(_ input: String) throws -> String {
    let result = try Scrubber.scrub(Data(input.utf8), name: "notes.txt")
    return String(decoding: result.output, as: UTF8.self)
}

@Test func enclosingSecretWinsOverlap() throws {
    let output = try cleaned("credit card Bearer 4111111111111111.abcdEFGH")
    #expect(!output.contains("4111111111111111.abcdEFGH"))
    #expect(!output.contains(".abcdEFGH"))
}

@Test func lowercaseFullNameWithReportingVerb() throws {
    let output = try cleaned("robert mitchell asked for a refund.")
    #expect(!output.lowercased().contains("robert"))
    #expect(!output.lowercased().contains("mitchell"))
    #expect(try cleaned("please mark the customer record") == "please mark the customer record")
}

@Test(arguments: ["driver license A12345678", "account 000123456789", "passport 912803456"])
func contextBoostReachesThreshold(_ input: String) throws {
    let output = try cleaned(input)
    let secret = String(input.split(separator: " ").last ?? "")
    #expect(!output.contains(secret))
}

@Test(arguments: ["GB82WEST12345698765432 IS ACTIVE", "GB82-WEST-1234-5698-7654-32"])
func ibanCandidatesTrimAndSeparate(_ input: String) throws {
    let output = try cleaned(input)
    #expect(!output.contains("GB82WEST12345698765432"))
    #expect(!output.contains("GB82-WEST-1234-5698-7654-32"))
}

@Test(arguments: ["::ffff:192.0.2.1", "2001:db8::ff00:42:8329", "198.51.100.23"])
func fullIPAddressIsReplaced(_ input: String) throws {
    #expect(!(try cleaned(input)).contains(input))
}

@Test(arguments: ["SSN 219.09.9998", "passport A12345678"])
func recognizerVariants(_ input: String) throws {
    let secret = String(input.split(separator: " ").last ?? "")
    #expect(!(try cleaned(input)).contains(secret))
}

@Test func fieldOrderSharesPersona() {
    let job = Job()
    _ = job.observe([("ana.pereira@acme.com", "email"), ("Ana", "firstName"), ("Pereira", "lastName")])
    let email = job.replacement(for: "EMAIL_ADDRESS", original: "ana.pereira@acme.com")
    let first = job.replacement(for: "FIRST_NAME", original: "Ana")
    let last = job.replacement(for: "LAST_NAME", original: "Pereira")
    #expect(email.hasPrefix("\(first.lowercased()).\(last.lowercased())@example."))
}

@Test func explicitRecordAssociation() {
    let job = Job()
    job.associate(first: "Ana", last: "Pereira", email: "ana.pereira@acme.com")
    let email = job.replacement(for: "EMAIL_ADDRESS", original: "ana.pereira@acme.com")
    let first = job.replacement(for: "FIRST_NAME", original: "Ana")
    let last = job.replacement(for: "LAST_NAME", original: "Pereira")
    #expect(email.hasPrefix("\(first.lowercased()).\(last.lowercased())@example."))
}

@Test func titleCaseLargeInputIsLinear() {
    let input = String(repeating: "robert mitchell asked for a refund. ", count: 6_500)
    let start = ContinuousClock.now
    let result = NameTagger.titleCaseLowercaseWords(input)
    #expect(result.utf16.count == input.utf16.count)
    #expect(start.duration(to: .now) < .seconds(1))
}

@Test func cancelledScrubThrows() async {
    let input = Data(String(repeating: "robert mitchell asked for a refund.\n", count: 80_000).utf8)
    let task = Task {
        try Scrubber.scrub(input, name: "notes.txt") { stage, _, _ in
            if stage == .finding { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    do {
        _ = try await task.value
        Issue.record("Cancelled scrub completed")
    } catch {
        #expect(error as? ScrubError == .cancelled)
    }
}

@Test func privateFileWriteIsOwnerOnly() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("result.txt")
    let data = Data("private content".utf8)
    try PrivateFile.write(data, to: destination)
    #expect(try Data(contentsOf: destination) == data)
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "actual mode: \(String(describing: attributes[.posixPermissions]))")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["result.txt"])
    let locked = directory.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
    let invalid = locked.appendingPathComponent("result.txt")
    #expect(throws: (any Error).self) { try PrivateFile.write(data, to: invalid) }
    #expect(!FileManager.default.fileExists(atPath: invalid.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).isEmpty)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["result.txt", "locked"])
}

/// A stand-in card ending as the real one did showed its last four digits,
/// and left "last4" beside it nothing to take but a placeholder.
@Test func standInNumbersNeverKeepTheRealEnding() {
    // Seeds that drew a stand-in card ending in 9119 before the fix.
    for seed in [49_799, 78_379, 94_800] + Array(UInt64(0)..<2_000) {
        let job = Job(seed: seed)
        let card = job.replacement(for: "CREDIT_CARD", original: "4831860760789119")
        let last4 = job.replacement(for: "LAST_DIGITS", original: "9119")
        #expect(!card.hasSuffix("9119"), "seed \(seed): \(card)")
        #expect(last4.count == 4 && last4.allSatisfy(\.isNumber) && last4 != "9119", "seed \(seed): \(last4)")
    }
}

@Test func lastDigitsFollowTheCardNotAPhoneEndingAlike() {
    // The phone is replaced first and ends as the card does.
    for seed in UInt64(0)..<200 {
        let job = Job(seed: seed)
        _ = job.replacement(for: "PHONE_NUMBER", original: "(646) 380-5792")
        let card = job.replacement(for: "CREDIT_CARD", original: "4937337937055792")
        let last4 = job.replacement(for: "LAST_DIGITS", original: "5792")
        #expect(card.hasSuffix(last4), "seed \(seed): \(card) \(last4)")
    }
}

@Test func anchoredPatternsMatchAFullScan() {
    // The secret patterns are tried only where a match can start; any text
    // must give the matches a scan of every position gives. The pieces include
    // a key name split by a value's end, a Kelvin sign and a long s (which
    // fold to "k" and "s"), non-ASCII spaces, backticks and quotes.
    let pieces = ["password", "PassWord", "token", "to\u{212A}en", "\u{017F}ecret", "api_key", "session-id", "my", ":", "=", "::", " ", "  ", "    ", "\u{00A0}", "\"", "'", "`", ",", ";", "\n",
                  "abcd", "x9Kq2", "hunter2hunter2", "mytoken", "Bearer ", "bearer ", "sk_live_", "pk_test_", "ghp_", "github_pat_", "AKIA", "IOSFODNN7EXAMPLE1234", "xoxb-", "eyJ", ".", "-",
                  "-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----", "Zq81mN0pLs7Tt3Rw9vYx", "é", "日本"]
    var gen = Gen(seed: 2_026)
    var texts = ["password=mytoken :wxyz", "token:   'abcd", "private_key\"   =   \"wxyz", "session_id=   \"", "Passphrase   :abcd", "secret: \"abcd`\" token=abcdefgh`", "Authorization: Bearer abcdefghijklmnop0123", "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"]
    texts += (0..<3_000).map { _ in (0..<gen.int(1...40)).map { _ in gen.choose(pieces) }.joined() }
    for regex in Patterns.compiled.map(\.1) where Patterns.starts.keys.contains(where: regex.pattern.hasPrefix) {
        for text in texts {
            let units = Array(text.utf16), ns = text as NSString
            let anchored = Patterns.matches(regex, in: ns, units: units, isCancelled: { false }).map(\.range)
            let scanned = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            #expect(anchored == scanned, "\(regex.pattern.prefix(20)) on \(text.debugDescription)")
        }
    }
}
