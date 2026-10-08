import Foundation
import Synchronization
@testable import ScrubCore
import Testing

/// A model that is missing or fails its checksum leaves the scrub without
/// it. The result names what didn't load, on every input path, and the scrub
/// really ran without it.
@Test(arguments: ["note.txt", "note.json", "note.csv", "note.xml"])
func aModelThatDoesNotLoadIsNamedInTheResult(_ name: String) throws {
    let note = "Please ask 王秀英 to call the front desk before Friday."
    let input: String
    switch name {
    case "note.json": input = #"{"note": "\#(note)"}"#
    case "note.csv": input = "id,note\n7,\(note)\n"
    case "note.xml": input = "<ticket><note>\(note)</note></ticket>"
    default: input = note
    }
    let full = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 5)
    #expect(full.coverage == .full)
    // Only the context model reads a name in another script inside English text.
    #expect(!String(decoding: full.output, as: UTF8.self).contains("王秀英"))

    for withheld in [[Coverage.Part.contextModel], [.nameModel, .addressModel], [.nameModel, .addressModel, .contextModel]] {
        let reduced = try Coverage.$withheld.withValue(Set(withheld)) {
            try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 5)
        }
        #expect(reduced.coverage.missing == withheld && reduced.coverage.isReduced)
        let output = String(decoding: reduced.output, as: UTF8.self)
        #expect(output.contains("王秀英") == withheld.contains(.contextModel), "\(withheld): \(output)")
        // Taking findings back keeps the status.
        #expect(try reduced.skipping(Set(reduced.findings.map(\.id))).coverage == reduced.coverage)
    }
}

/// More scrubs at once than there are cores all finish. Each waits on its
/// own thread for work it starts; started on the global queues, whose threads
/// it shares with Swift concurrency, that work never began once every one of
/// those threads was waiting.
///
/// Each is timed from when it starts. A task waits behind every job queued on
/// Swift concurrency's threads before it, whatever its priority, and the test
/// runner queues the rest of the suite there: timed from the test's start, a
/// full run measured its own queue, not the scrubs.
@Test func moreScrubsAtOnceThanCoresAllFinish() {
    let count = ProcessInfo.processInfo.activeProcessorCount + 2
    // For each scrub, when it started and whether it finished with a result.
    let runs = Mutex([(started: ContinuousClock.Instant?, scrubbed: Bool?, took: Duration)](repeating: (nil, nil, .zero), count: count))
    let launched = ContinuousClock.now
    for index in 0..<count {
        Task.detached {
            let start = ContinuousClock.now
            runs.withLock { $0[index].started = start }
            let text = "Odalys Ferriter (odalys@kestrel.example) asked Teodoro Quillan to call her on 415-867-2290, ticket \(index)."
            let scrubbed = (try? Scrubber.scrub(Data(text.utf8), name: "note.txt", forceFullDetection: false, seed: UInt64(index))) != nil
            runs.withLock { $0[index].scrubbed = scrubbed; $0[index].took = start.duration(to: .now) }
        }
    }
    defer {
        let current = runs.withLock { $0 }
        let waited = current.compactMap { $0.started.map { launched.duration(to: $0) } }
        print("scrubs at once debug: longest wait to start \(waited.max() ?? .zero), longest scrub \(current.map(\.took).max() ?? .zero)")
    }
    while true {
        let now = ContinuousClock.now, current = runs.withLock { $0 }
        if current.allSatisfy({ $0.scrubbed != nil }) { break }
        // Generous: the machine may be busy.
        if let stuck = current.indices.first(where: { current[$0].scrubbed == nil && current[$0].started.map { $0.duration(to: now) > .seconds(900) } == true }) {
            Issue.record("scrub \(stuck) still running fifteen minutes after it started")
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(runs.withLock { $0 }.allSatisfy { $0.scrubbed == true })
}
