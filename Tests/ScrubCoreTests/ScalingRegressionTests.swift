import Foundation
import Synchronization
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
    /// A name taken for someone once is that person for good.
    private var resolved: [String: Entry] = [:]
    func register(_ first: String?, _ last: String?) -> Entry {
        let f = first.map(fold), l = last.map(fold)
        let key = (f ?? "\u{0}") + "\u{1}" + (l ?? "\u{0}")
        if let found = resolved[key] { return found }
        let entry = resolve(f, l)
        resolved[key] = entry
        return entry
    }
    private func resolve(_ f: String?, _ l: String?) -> Entry {
        if let exact = entries.first(where: { $0.first == f && $0.last == l }) { return exact }
        var candidates = entries.filter { (f == nil || $0.first == nil || $0.first == f) && (l == nil || $0.last == nil || $0.last == l) }
        // One part alone is someone who has it, before anyone who lacks it.
        if f == nil || l == nil, (f != nil || l != nil) {
            let having = candidates.filter { f != nil ? $0.first == f : $0.last == l }
            if !having.isEmpty { candidates = having }
        }
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
    // Other suites run in parallel and their load changes between two runs, so
    // the sizes alternate and the fastest run of each is compared.
    var half = Duration.seconds(3600), full = Duration.seconds(3600)
    for _ in 0..<2 {
        half = min(half, try measure(10_000))
        full = min(full, try measure(20_000))
    }
    print("person CSV debug: 10000=\(half), 20000=\(full)")
    #expect(full < half * 3)
}

/// Scrubs `data`, letting `cancelWhen` decide from the progress reports when
/// to cancel, and returns how long the scrub ran on after being cancelled with
/// how long a small uncancelled scrub took just after it. Both are timed inside
/// the scrub's own task: with other tests running, this task can resume long
/// after the scrub has stopped.
private func timeToStop(_ data: Data, name: String = "people.csv", cancelWhen: @escaping @Sendable (Stage, Int, Int, @escaping @Sendable () -> Void) -> Void) async throws -> (stopped: Duration, reference: Duration) {
    let work = Mutex<Task<(stopped: Duration, reference: Duration), any Error>?>(nil)
    let cancelledAt = Mutex<ContinuousClock.Instant?>(nil)
    let cancel: @Sendable () -> Void = {
        cancelledAt.withLock { $0 = .now }
        work.withLock { $0?.cancel() }
    }
    let reference = personCSV(500)
    let task = Task.detached { () throws -> (stopped: Duration, reference: Duration) in
        do {
            _ = try Scrubber.scrub(data, name: name) { stage, done, total in cancelWhen(stage, done, total, cancel) }
            Issue.record("Cancelled scrub completed")
            return (.zero, .zero)
        } catch ScrubError.cancelled {
            let stoppedAt = ContinuousClock.now
            let stopped = try #require(cancelledAt.withLock { $0 }).duration(to: stoppedAt)
            // The task is cancelled, so the reference runs on a fresh one.
            let measured = try await Task.detached {
                let start = ContinuousClock.now
                _ = try Scrubber.scrub(reference, name: "people.csv")
                return start.duration(to: .now)
            }.value
            return (stopped, measured)
        }
    }
    work.withLock { $0 = task }
    return try await task.value
}

/// Within a second unloaded; under load, no slower than a small scrub run under
/// the same load. Other suites run in parallel, so an absolute budget alone
/// measures machine load, and the load can still change between the two
/// timings: a miss is tried once more. A scrub that ignores cancelling misses
/// every time.
private func expectPrompt(_ measure: () async throws -> (stopped: Duration, reference: Duration)) async throws {
    var timing = (stopped: Duration.zero, reference: Duration.zero)
    for _ in 0..<2 {
        timing = try await measure()
        print("cancel debug: stopped=\(timing.stopped), reference=\(timing.reference)")
        if timing.stopped < max(.seconds(1), timing.reference) { return }
    }
    #expect(timing.stopped < max(.seconds(1), timing.reference))
}

@Test func cancellingDuringParallelDetectionStopsPromptly() async throws {
    try await expectPrompt {
        let started = Atomic(false)
        return try await timeToStop(personCSV(40_000)) { stage, _, _, cancel in
            // 300 ms into detection, on a thread of its own: a sleeping test
            // task, or a timer on the queues detection fills, can wake long
            // after detection has ended.
            guard stage == .finding, started.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.3)
                cancel()
            }
        }
    }
}

/// A long text is one value, so its patterns are stopped partway through.
@Test func cancellingLongTextStopsPromptly() async throws {
    let text = Data(String(repeating: "robert mitchell asked for a refund on order 4471.\n", count: 60_000).utf8)
    try await expectPrompt {
        try await timeToStop(text, name: "notes.txt") { stage, _, _, cancel in
            if stage == .finding { cancel() }
        }
    }
}

/// Cancelled while the context model reads, between its windows.
@Test func cancellingWhileReadingStopsPromptly() async throws {
    let text = Data((0..<3000).map { "Kofi Mensah moved to Tromsø in \(2001 + $0 % 12) and works at Orrinvale Freight." }.joined(separator: "\n").utf8)
    try await expectPrompt {
        try await timeToStop(text, name: "notes.txt") { stage, done, _, cancel in
            if stage == .reading, done > 0 { cancel() }
        }
    }
}

/// Cancelled as the context model finishes, while its findings join the
/// others' in one long text.
@Test func cancellingAfterReadingStopsPromptly() async throws {
    let text = Data((0..<3000).map { "Kofi Mensah moved to Tromsø in \(2001 + $0 % 12) and works at Orrinvale Freight." }.joined(separator: "\n").utf8)
    try await expectPrompt {
        try await timeToStop(text, name: "notes.txt") { stage, done, total, cancel in
            if stage == .reading, done == total, total > 0 { cancel() }
        }
    }
}

/// Cancelled once every value is found, while the table is put back together.
@Test func cancellingWhileAssemblingTableStopsPromptly() async throws {
    try await expectPrompt {
        try await timeToStop(personCSV(40_000)) { stage, done, total, cancel in
            if stage == .finding, done == total, total > 0 { cancel() }
        }
    }
}

@Test func plainTextScalingBudget() throws {
    func measure(_ lines: Int) throws -> Duration {
        let text = (0..<lines).map { "robert mitchell asked for a refund on order \($0 * 37 + 1000)." }.joined(separator: "\n")
        let start = ContinuousClock.now
        let result = try Scrubber.scrub(Data(text.utf8), name: "notes.txt")
        #expect(result.counts["PERSON", default: 0] >= lines)
        return start.duration(to: .now)
    }
    // Other suites run in parallel, so an absolute budget measures machine
    // load; the ratio between two runs under the same load measures scaling.
    // That load changes between two runs, so the sizes alternate and the
    // fastest run of each is compared.
    var half = Duration.seconds(3600), full = Duration.seconds(3600)
    for _ in 0..<2 {
        half = min(half, try measure(4_000))
        full = min(full, try measure(8_000))
    }
    print("plain text debug: 4000=\(half), 8000=\(full)")
    #expect(full < half * 3)
}

/// `fastest`, measured again up to three times until `holds` does: a machine busy with other
/// tests can slow one run of a pair, but a cost that grows faster than it should fails every time.
private func settled(_ a: () throws -> Void, _ b: () throws -> Void, until holds: (Duration, Duration) -> Bool) rethrows -> (Duration, Duration) {
    var times = try fastest(a, b)
    for _ in 0..<2 where !holds(times.0, times.1) { times = try fastest(a, b) }
    return times
}

/// The fastest of two runs of each, alternated: other suites run in
/// parallel, and their load changes between two timings.
private func fastest(_ a: () throws -> Void, _ b: () throws -> Void) rethrows -> (Duration, Duration) {
    var first = Duration.seconds(3600), second = Duration.seconds(3600)
    for _ in 0..<2 {
        var start = ContinuousClock.now
        try a()
        first = min(first, start.duration(to: .now))
        start = .now
        try b()
        second = min(second, start.duration(to: .now))
    }
    return (first, second)
}

/// A customer export: an ID, a name, an email, a phone and a city on every row.
private func customerCSV(_ count: Int) -> Data {
    let firsts = ["Odalys", "Teodoro", "Marisol", "Kwabena", "Ingrid", "Tobiah", "Saoirse", "Leocadia"]
    let lasts = ["Ferriter", "Quillan", "Abernathy", "Oduya", "Brackenridge", "Thornquist", "Castellanos", "Venkataraman"]
    let cities = ["Albany", "Tacoma", "Dayton", "Fresno", "Provo"]
    let rows = (0..<count).map { index -> String in
        let first = firsts[index % firsts.count], last = lasts[index / firsts.count % lasts.count]
        return "C-\(10_000 + index),\(first),\(last),\(first.lowercased()).\(last.lowercased())\(index)@example.com,(212) 555-01\(String(format: "%02d", index % 100)),\(cities[index % cities.count]),2024-\(String(format: "%02d", index % 12 + 1))-\(String(format: "%02d", index % 28 + 1)),\(index * 7 % 1000).\(index % 100)"
    }
    return Data(("customer_id,first_name,last_name,email,phone,city,signup_date,ltv\n" + rows.joined(separator: "\n") + "\n").utf8)
}

/// A service's log: a time, a level, a user's email, an address and a status on every line.
private func serviceLog(_ count: Int) -> Data {
    let lines = (0..<count).map { index in
        #"{"ts": "2026-10-01T\#(String(format: "%02d:%02d:%02d", 12 + index / 3600 % 12, index / 60 % 60, index % 60))Z", "level": "\#(index % 50 == 0 ? "warn" : "info")", "user_email": "user\#(index % 300)@example.com", "ip": "198.51.100.\#(index % 250)", "status": \#(index % 50 == 0 ? 503 : 200), "latency_ms": \#(index % 500)}"#
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

/// A table and a log four times as long take about four times as long, not sixteen.
@Test func customerExportAndServiceLogScaleLinearly() throws {
    for (name, make) in [("customers.csv", customerCSV), ("service.jsonl", serviceLog)] {
        let small = make(400), large = make(1_600)
        let (short, long) = try settled({ _ = try Scrubber.scrub(small, name: name, forceFullDetection: false, seed: 3) },
                                        { _ = try Scrubber.scrub(large, name: name, forceFullDetection: false, seed: 3) }, until: { $1 < $0 * 6 })
        print("\(name) debug: 400=\(short), 1600=\(long)")
        #expect(long < short * 6, "\(name): 400 rows \(short), 1600 rows \(long)")
    }
}

/// A value its key names (`"phone": "(212) 555-0142"`) is checked against the kinds the key
/// names, not read for every kind there is.
@Test func aKeyedValueIsReadOnlyForTheKindsItsKeyNames() {
    let values = (0..<300).map { "(212) 555-\(String(format: "%04d", $0 * 37 % 10_000))" }
    let words: Set<String> = ["phone"]
    let (named, read) = settled({ for value in values { _ = Recognizers.named(value, by: words) } },
                                { for value in values { _ = Recognizers.find(value, ns: value as NSString, units: Array(value.utf16), contextWords: words, isCancelled: { false }) } }, until: { $0 * 3 < $1 })
    print("keyed value debug: named=\(named), every kind=\(read)")
    #expect(named * 3 < read)
}

/// A column of values no kind passes (a log's times) is given up once nine in ten can no longer pass one.
@Test func aColumnNoKindHoldsIsGivenUpEarly() {
    let times = (0..<3_000).map { "2026-10-01T\(String(format: "%02d:%02d:%02d", $0 / 3600, $0 / 60 % 60, $0 % 60))Z" }
    let (column, every) = settled({ #expect(Fields.column(times) == nil) }, { for time in times { _ = Recognizers.candidates(time) } }, until: { $0 * 3 < $1 })
    print("column debug: column=\(column), every value=\(every)")
    #expect(column * 3 < every)
}

/// A document's records repeat their values ("level": "info"): one read once costs little where it is written again.
@Test func repeatedValuesAreReadOnce() throws {
    let lines = { (repeated: Bool) in
        Data((0..<600).map { index -> String in
            let tag = repeated ? "" : "-\(index)"
            return #"{"service": "checkout-api-eu-west-1-blue-canary\#(tag)", "path": "/api/v2/orders/search?status=open&sort=created_at&page=12\#(tag)", "build": "2026.10.01-rc3+arm64.release.9f8e7d\#(tag)", "route": "orders.search.v2.primary.read-replica\#(tag)", "trace": "svc=checkout;zone=eu-west-1b;pool=blue;tier=standard\#(tag)"}"#
        }.joined(separator: "\n").utf8)
    }
    let same = lines(true), distinct = lines(false)
    let (repeated, unique) = try settled({ _ = try Scrubber.scrub(same, name: "service.jsonl", forceFullDetection: false, seed: 3) },
                                         { _ = try Scrubber.scrub(distinct, name: "service.jsonl", forceFullDetection: false, seed: 3) }, until: { $0 * 9 < $1 * 5 })
    print("repeated values debug: repeated=\(repeated), distinct=\(unique)")
    // Read once, about half as long; read every time, about two thirds.
    #expect(repeated * 9 < unique * 5)
}
