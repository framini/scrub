import Foundation
@testable import ScrubCore
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

/// Pasted JSON Lines are read as JSON, one document a line: every separator stays as
/// written, every line still parses, and one value written on two lines takes one stand-in.
@Test func pastedJSONLinesAreReadAsJSON() throws {
    let input = "{\"email\":\"a@example.org\",\"count\":1}\n{\"email\":\"b@example.org\",\"count\":2}\r\n\n  \n{\"email\":\"a@example.org\",\"count\":3}\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: "Pasted text", forceFullDetection: false, seed: 7)
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(result.format == "jsonl")
    #expect(!output.contains("a@example.org") && !output.contains("b@example.org"), "\(output)")
    let separators = output.split(separator: "}", omittingEmptySubsequences: false).dropFirst().map { String($0.prefix { $0 != "{" }) }
    #expect(separators == ["\n", "\r\n\n  \n", "\n"], "\(output)")
    let lines = output.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let objects = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    #expect(objects.count == 3)
    #expect(objects.map { $0["count"] as? Int } == [1, 2, 3])
    #expect(objects[0]["email"] as? String == objects[2]["email"] as? String)
    #expect(objects[0]["email"] as? String != objects[1]["email"] as? String)
}

@Test(arguments: ["a.jsonl", "a.ndjson"])
func jsonLinesFilesAreReadAsJSON(_ name: String) throws {
    let input = "{\"email\":\"a@example.org\",\"count\":1}\n[{\"password\":\"quillharbor\"}]\n"
    let result = try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 7)
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(result.format == "jsonl")
    #expect(!output.contains("a@example.org") && !output.contains("quillharbor") && output.contains("\"count\":1}\n["), "\(output)")
    #expect(throws: ScrubError.unsupported("invalid_json")) { try Scrubber.scrub(Data("{\"email\":\"a@example.org\"}\nnot json\n".utf8), name: name) }
}

/// A stray NUL in text is a character like any other; a file that is mostly NULs is no text.
@Test(arguments: ["\"test\u{0}\"@iana.org reported", "(\u{0})test@example.com", "line one\u{0}\nwrite to test@example.com\n"])
func textWithAStrayNULIsScrubbed(_ text: String) throws {
    for name in ["doc.txt", "Pasted text"] {
        let result = try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 7)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(output.contains("\u{0}") && !output.contains("test@example.com"), "\(name): \(output)")
    }
}

@Test func mostlyNULFilesAreRefused() {
    let wide = Data("write to test@example.com".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    #expect(throws: ScrubError.unsupported("binary_file")) { try Scrubber.scrub(wide, name: "a.txt") }
    #expect(throws: ScrubError.unsupported("binary_file")) { try Scrubber.scrub(Data([0x41, 0, 0, 0, 0x42, 0, 0, 0]), name: "a.txt") }
}

@Test func digitsKeepShapeAndNeverEqualOriginal() {
    for _ in 0..<200 {
        let job = Job()
        let fake = job.digits("7")
        #expect(fake.count == 1 && fake != "7" && fake.first != "0")
        #expect(job.digits("7") == fake)
    }
}
