import Foundation
@testable import ScrubCore
import Testing

// Technical text as staff paste it: an application's log, a stack trace, an
// environment file, an application's XML settings, a crash report and a
// verbose HTTP transcript, as a file, pasted, and as a string inside a JSON
// log line. Only the personal parts change; every key, path, separator and
// technical value stays as written. Every name, path and secret is invented.

private func scrub(_ text: String, as name: String) throws -> String {
    String(decoding: try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 7).output, as: UTF8.self)
}

/// The same text as a log file, as pasted text, and as the message of a JSON log line, read back out.
private let renderings: [(String, @Sendable (String) throws -> String)] = [
    ("log", { try scrub($0, as: "app.log") }),
    ("pasted", { try scrub($0, as: "Pasted text") }),
    ("jsonl", { text in
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            "{\"level\":\"info\",\"msg\":" + String(decoding: try! JSONEncoder().encode(String(line)), as: UTF8.self) + "}"
        }
        let output = try scrub(lines.joined(separator: "\n"), as: "events.jsonl")
        return try output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String], "no longer parses: \(line)")
            return try #require(object["msg"])
        }.joined(separator: "\n")
    }),
]

private let loginLog = """
2026-10-03 14:22:05,118 INFO  [http-nio-8080-exec-7] c.e.api.AuthController - Login attempt user=ofelia.brandvold@example.com ip=10.4.1.20
2026-10-03 14:22:05,402 ERROR [http-nio-8080-exec-7] c.e.api.ProfileService - Failed to load avatar for user ofelia.brandvold@example.com
2026-10-03 14:22:06,007 INFO  [http-nio-8080-exec-8] c.e.api.ResetController - GET /reset?email=ofelia.brandvold@example.com&lang=en 302 12ms
2026-10-03 14:22:06,310 INFO  [mailer-2] c.e.mail.Outbox - queued to=ofelia.brandvold@example.com from=noreply@example.org template=reset_v2
"""

/// A value after a key ("user=…", "to=…", "?email=…") is replaced and the key stays; one address
/// takes one stand-in whatever word or mark is written before it.
@Test(arguments: renderings.map(\.0))
private func aKeyBeforeAnAddressStaysAndTheAddressTakesOneStandIn(_ name: String) throws {
    let rendering = try #require(renderings.first { $0.0 == name })
    let output = try rendering.1(loginLog)
    #expect(!output.contains("ofelia") && !output.contains("brandvold"), "[\(name)] \(output)")
    for kept in ["Login attempt user=", " ip=", "avatar for user ", "GET /reset?email=", "&lang=en 302 12ms", "queued to=", " from=noreply@", " template=reset_v2"] {
        #expect(output.contains(kept), "[\(name)] \(kept) lost in \(output)")
    }
    let address = /[a-z]+(?:\.[a-z]+)?@example\.(?:com|org|net)/
    let lines = output.split(separator: "\n").map(String.init)
    #expect(lines.count == 4, "[\(name)] \(output)")
    let standIns = [("user=", lines[0]), ("for user ", lines[1]), ("?email=", lines[2]), ("to=", lines[3])].compactMap { cue, line in
        line.firstRange(of: cue).flatMap { line[$0.upperBound...].prefixMatch(of: address).map { String($0.output) } }
    }
    #expect(standIns.count == 4 && Set(standIns).count == 1, "[\(name)] \(standIns) in \(output)")
}

private let thread = """
From: Wilhelmina Castellanos <w.castellanos@example.com>
To: Jasper Thornquist <jasper.thornquist@example.org>
Subject: Re: Q4 freight rates

Hi Jasper,

Rates attached.

Wilhelmina

On Wed, Oct 1, 2026 at 4:12 PM Jasper Thornquist <jasper.thornquist@example.org> wrote:
> Sent 09:30 AM UTC Jasper Thornquist <jasper.thornquist@example.org>
> Hi Wilhelmina,
"""

/// A time's half of the day and its zone stay with the time: "4:12 PM" before a name and its address
/// keeps its "PM", and the name is the same person's as everywhere else in the thread.
@Test(arguments: ["thread.txt", "Pasted text"])
private func aTimeBeforeANameKeepsItsHalfOfTheDay(_ name: String) throws {
    let output = try scrub(thread, as: name)
    for word in ["Jasper", "Thornquist", "Wilhelmina", "Castellanos"] { #expect(!output.contains(word), "[\(name)] \(word) left in \(output)") }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let to = try #require(lines[1].firstMatch(of: /^To: ([A-Z][a-z]+ [A-Z][a-z]+) </)).output.1
    #expect(lines[10].hasPrefix("On Wed, Oct 1, 2026 at 4:12 PM \(to) <"), "[\(name)] \(lines[10])")
    #expect(lines[11].hasPrefix("> Sent 09:30 AM UTC \(to) <"), "[\(name)] \(lines[11])")
}
