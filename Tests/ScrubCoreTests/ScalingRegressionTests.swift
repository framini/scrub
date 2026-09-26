import Foundation
@testable import ScrubCore
import Testing

private final class LinearPeople {
    final class Entry {
        var first: String?
        var last: String?
        init(_ first: String?, _ last: String?) { self.first = first; self.last = last }
        func matches(_ local: String) -> Bool {
            let parts = Set(local.lowercased().split { !$0.isLetter }.map(String.init))
            let joined = local.lowercased().filter(\.isLetter)
            if let first, let last {
                return (parts.contains(first) && parts.contains(last)) || [first + last, last + first, String(first.prefix(1)) + last, last + String(first.prefix(1))].contains(joined)
            }
            return (last.map { parts.contains($0) } ?? false) || (first.map { parts == [$0] } ?? false)
        }
    }
    var entries: [Entry] = []
    private let locale = Locale(identifier: "en_US_POSIX")
    private func fold(_ value: String) -> String { value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale).trimmingCharacters(in: .whitespacesAndNewlines) }
    func register(_ first: String?, _ last: String?) -> Entry {
        let f = first.map(fold), l = last.map(fold)
        if let exact = entries.first(where: { $0.first == f && $0.last == l }) { return exact }
        let candidates = entries.filter { (f == nil || $0.first == nil || $0.first == f) && (l == nil || $0.last == nil || $0.last == l) }
        if candidates.count == 1, let found = candidates.first {
            found.first = found.first ?? f; found.last = found.last ?? l
            return found
        }
        let entry = Entry(f, l)
        entries.append(entry)
        return entry
    }
    func find(_ email: String) -> Entry? {
        let local = String(email.split(separator: "@", maxSplits: 1).first ?? "")
        let matches = entries.filter { $0.matches(local) }
        return matches.count == 1 ? matches.first : nil
    }
}

@Test func indexedPeopleMatchLinearReference() {
    let people = People(), linear = LinearPeople()
    var actual: [ObjectIdentifier: Int] = [:]
    var expected: [ObjectIdentifier: Int] = [:]
    var seed: UInt64 = 0x1459a6c38b
    func next() -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 33) }
    let names = (0..<180).map { "n\($0)" }
    for _ in 0..<2_000 {
        let f: String? = next() % 5 == 0 ? nil : names[next() % names.count]
        let l: String? = next() % 5 == 0 ? nil : names[next() % names.count]
        let a = people.register(f, l), b = linear.register(f, l)
        let ai = ObjectIdentifier(a), bi = ObjectIdentifier(b)
        if actual[ai] == nil { actual[ai] = actual.count }
        if expected[bi] == nil { expected[bi] = expected.count }
        #expect(actual[ai] == expected[bi])
        let first = names[next() % names.count], last = names[next() % names.count]
        for local in ["\(first).\(last)", first + last, String(first.prefix(1)) + last, last + String(first.prefix(1)), first, last] {
            let foundA = people.find(email: local + "@example.test").map { actual[ObjectIdentifier($0)] }
            let foundB = linear.find(local + "@example.test").map { expected[ObjectIdentifier($0)] }
            #expect(foundA == foundB)
        }
    }
}

@Test func matcherUsesUnicodeCaseFoldingAndOriginalRanges() {
    let pairs = [("Straße", "STRASSE"), ("Σ", "ς"), ("İ", "i\u{0307}"), ("ﬃ", "FFI")]
    for (a, b) in pairs {
        for (pattern, source) in [(a, b), (b, a)] {
            let matches = Matcher([pattern]).matches(in: "(\(source))")
            #expect(matches.count == 1)
            for match in matches {
                let slice = TextRanges.substring("(\(source))", match.range)
                #expect(Matcher.fold(slice) == Matcher.fold(pattern))
            }
        }
    }
    #expect(Matcher(["😀"]).matches(in: "🚀").isEmpty)
    #expect(Matcher.fold("😀") != Matcher.fold("🚀"))
    #expect(Matcher(["Straße", "STRASSE"]).matches(in: "straße").count == 1)
    let job = Job()
    job.recordOriginals([("ab😀", [Span(range: 0..<4, entity: "PERSON", score: 1)]),
                         ("ab🚀", [Span(range: 0..<4, entity: "PERSON", score: 1)])])
    #expect(OriginalMatcher(job).matcher.literals.count == 2)
}

@Test func gazetteerChecksSupplementaryWordBoundary() {
    #expect(Detector().find("𐐀ann", gazetteer: ["PERSON": ["ann"]]).allSatisfy { $0.range != 2..<5 })
}

private func linearResolve(_ spans: [Span]) -> [Span] {
    let ordered = spans.sorted { a, b in
        if a.score != b.score { return a.score > b.score }
        if a.range.count != b.range.count { return a.range.count > b.range.count }
        return a.range.lowerBound < b.range.lowerBound
    }
    var kept: [Span] = []
    for span in ordered {
        let conflicts = kept.indices.filter { kept[$0].range.overlaps(span.range) }
        if conflicts.isEmpty { kept.append(span); continue }
        if conflicts.allSatisfy({ span.range.lowerBound <= kept[$0].range.lowerBound && span.range.upperBound >= kept[$0].range.upperBound && span.range != kept[$0].range && span.entity != kept[$0].entity }) {
            kept.removeAll { span.range.overlaps($0.range) }
            kept.append(span)
        }
    }
    return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
}

@Test func indexedResolveMatchesLinearReference() {
    var seed: UInt64 = 0x4152a09b
    func next() -> Int { seed = seed &* 2862933555777941757 &+ 3037000493; return Int(seed >> 33) }
    for _ in 0..<500 {
        let spans = (0..<(next() % 70)).map { _ in
            let start = next() % 100
            return Span(range: start..<(start + 1 + next() % 30), entity: next() % 2 == 0 ? "PERSON" : "SECRET", score: Double(next() % 4) / 4)
        }
        let a = Detector.resolve(spans), b = linearResolve(spans)
        #expect(a.map { "\($0.range):\($0.entity):\($0.score)" } == b.map { "\($0.range):\($0.entity):\($0.score)" })
    }
    let disjoint = (0..<10_000).map { Span(range: ($0 * 3)..<($0 * 3 + 2), entity: "PERSON", score: 0.5) }
    let start = ContinuousClock.now
    #expect(Detector.resolve(disjoint).count == disjoint.count)
    #expect(start.duration(to: .now) < .seconds(1))
}

private func personCSV(_ count: Int) -> Data {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    let notes = ["Called about order", "Customer asked for a refund on invoice", "Delivery to warehouse", "Spoke with support about ticket", "Renewal due next quarter, contract", "Payment failed twice for account", "Requested a copy of statement", "Escalated to billing, case"]
    let rows = (0..<count).map { index -> String in
        var number = index
        let code = String((0..<6).map { _ -> Character in defer { number /= 26 }; return alphabet[number % 26] })
        return "Priya K\(code),u\(index)@corp.test,\(code)abcd,\(notes[index % notes.count]) \(index * 23 + 1000) \(code)"
    }
    return Data(("name,email,password,note\n" + rows.joined(separator: "\n") + "\n").utf8)
}

@Test func personCSVScalingBudget() throws {
    func measure(_ count: Int) throws -> Duration {
        let data = personCSV(count)
        let start = ContinuousClock.now
        let result = try Scrubber.scrub(data, name: "people.csv")
        #expect(result.format == "csv")
        #expect(result.counts["EMAIL_ADDRESS"] == count)
        return start.duration(to: .now)
    }
    let half = try measure(10_000)
    let full = try measure(20_000)
    print("person CSV debug: 10000=\(half), 20000=\(full)")
    #expect(full < half * 3)
}

@Test func cancellingDuringParallelDetectionStopsPromptly() async throws {
    let data = personCSV(40_000)
    let work = Task.detached { try Scrubber.scrub(data, name: "people.csv") }
    try await Task.sleep(for: .milliseconds(300))
    let cancelledAt = ContinuousClock.now
    work.cancel()
    await #expect(throws: ScrubError.cancelled) { try await work.value }
    #expect(cancelledAt.duration(to: .now) < .seconds(1))
}

@Test func plainTextScalingBudget() throws {
    func measure(_ lines: Int) throws -> Duration {
        let text = (0..<lines).map { "robert mitchell asked for a refund on order \($0 * 37 + 1000)." }.joined(separator: "\n")
        let start = ContinuousClock.now
        let result = try Scrubber.scrub(Data(text.utf8), name: "notes.txt")
        #expect(result.counts["PERSON", default: 0] >= lines)
        return start.duration(to: .now)
    }
    let half = try measure(4_000)
    let full = try measure(8_000)
    print("plain text debug: 4000=\(half), 8000=\(full)")
    // Other suites run in parallel, so an absolute budget measures machine
    // load; the ratio between two runs under the same load measures scaling.
    #expect(full < half * 3)
}
