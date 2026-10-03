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
@Test func moreScrubsAtOnceThanCoresAllFinish() {
    let count = ProcessInfo.processInfo.activeProcessorCount + 2
    let group = DispatchGroup()
    let finished = Mutex(0)
    for index in 0..<count {
        group.enter()
        Task.detached {
            defer { group.leave() }
            let text = "Odalys Ferriter (odalys@kestrel.example) asked Teodoro Quillan to call her on 415-867-2290, ticket \(index)."
            if (try? Scrubber.scrub(Data(text.utf8), name: "note.txt", forceFullDetection: false, seed: UInt64(index))) != nil { finished.withLock { $0 += 1 } }
        }
    }
    // Generous: the rest of the suite shares these threads, and the machine may be busy.
    #expect(group.wait(timeout: .now() + 900) == .success, "scrubs still waiting after fifteen minutes")
    #expect(finished.withLock { $0 } == count)
}
