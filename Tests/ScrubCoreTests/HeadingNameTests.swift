import Foundation
@testable import ScrubCore
import Testing

/// A name alone on the line heading a contact card, a résumé or a quoted signature, in English text, is replaced
/// whole, whatever language its letters look like; a given name's middle initial is part of the name, never a title.
struct HeadingNameTests {
    static func scrubbed(_ text: String) throws -> String {
        let result = try Scrubber.scrub(Data(text.utf8), name: "Pasted text", forceFullDetection: false, seed: 3)
        return String(decoding: result.output, as: UTF8.self)
    }

    @Test(arguments: [
        ("Arvojuhani Kurkisalo\n\nSchool crossing guard\n\nPersonal Info:\nPhone:\n312-555-0142\n\nE-mail:\nArvojuhaniKurkisalo@example.com\n\nWebsite:\nhttps://example.org\n", ["Arvojuhani", "Kurkisalo"]),
        ("Thanks, see below.\n\n> \n> Tadeas K Mirovan\n> Brightwell Partners\n> Tadeas K Mirovan\n> 41 Harbour Terrace\n> Suite 12\n", ["Tadeas", "Mirovan"]),
    ])
    func aNameHeadingItsLineIsReplaced(_ text: String, _ parts: [String]) throws {
        let output = try Self.scrubbed(text)
        #expect(!parts.contains(where: output.contains), "kept: \(output)")
    }

    @Test(arguments: ["Lorenzo M. Haverstock Esq.", "Lorenzo M Van Dellen"])
    func aMiddleInitialKeepsTheNameWhole(_ name: String) throws {
        for text in ["\(name)\n", "Please forward the signed copy to \(name) by Friday.\n"] {
            let output = try Self.scrubbed(text)
            #expect(!output.contains("Lorenzo") && !output.contains("Haverstock") && !output.contains("Dellen"), "kept: \(output)")
        }
    }
}
