import Foundation
import ScrubCore
import Testing

@Test func inputRefusals() {
    #expect(throws: ScrubError.unsupported("empty_file")) { try Scrubber.scrub(Data("   ".utf8), name: "a.txt") }
    #expect(throws: ScrubError.unsupported("images_not_supported_yet")) { try Scrubber.scrub(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), name: "a.png") }
    #expect(throws: ScrubError.unsupported("unsupported_type")) { try Scrubber.scrub(Data("%PDF-1.7".utf8), name: "a.pdf") }
    #expect(throws: ScrubError.unsupported("not_utf8")) { try Scrubber.scrub(Data([0xFF, 0xFE]), name: "a.txt") }
}

@Test(arguments: ["a.txt", "a.md", "a.log", "Pasted text"])
func chunkOneRoutesTextLikeInput(_ name: String) throws {
    let result = try Scrubber.scrub(Data("alice@example.com".utf8), name: name)
    #expect(result.format == "text")
    #expect(result.counts["EMAIL_ADDRESS"] == 1)
}

@Test func digitsKeepShapeAndNeverEqualOriginal() {
    for _ in 0..<200 {
        let job = Job()
        let fake = job.digits("7")
        #expect(fake.count == 1 && fake != "7" && fake.first != "0")
        #expect(job.digits("7") == fake)
    }
}
