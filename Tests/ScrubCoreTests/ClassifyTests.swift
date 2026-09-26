import Foundation
import ScrubCore
import Testing

@Test(arguments: [
    ("a.json", "{}", "json"),
    ("a.CSV", "a,b", "csv"),
    ("notes.md", "# hi", "text"),
    ("Pasted text", #"{"user":{"email":"a@b.com"}}"#, "json"),
    ("Pasted text", "id,name,email\n1,Ana,a@b.com\n2,Bo,b@c.com\n", "csv"),
    ("Pasted text", "id\tname\n1\tAna\n2\tBo\n", "csv"),
    ("Pasted text", #"[{"id":1},{"id":2}]"#, "json"),
    ("Pasted text", #"{"truncated":"response"#, "text"),
    ("Pasted text", "[INFO] 2026-09-24 user robert@acme.com logged in\n[INFO] done\n", "text"),
    ("Pasted text", "Hi Ana, thanks for the call.\nBest, Bo\n", "text"),
    ("Pasted text", "  \n<?xml version=\"1.0\"?><r/>", "xml"),
    ("Pasted text", "<p>Hi <b>there</p>", "text")
])
func classifiesInput(_ name: String, _ text: String, _ expected: String) throws {
    #expect(try Scrubber.classify(Data(text.utf8), name: name) == expected)
}

@Test func textExtensionDoesNotSniff() throws {
    #expect(try Scrubber.classify(Data(#"{"email":"a@b.com"}"#.utf8), name: "a.txt") == "text")
}

@Test func classifyUsesStableRefusalCodes() {
    #expect(throws: ScrubError.unsupported("empty_file")) { try Scrubber.classify(Data("   ".utf8), name: "a.json") }
    #expect(throws: ScrubError.unsupported("images_not_supported_yet")) { try Scrubber.classify(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), name: "a.png") }
    #expect(throws: ScrubError.unsupported("unsupported_type")) { try Scrubber.classify(Data("%PDF-1.7".utf8), name: "a.pdf") }
}
