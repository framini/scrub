import Foundation
@testable import ScrubCore
import Testing

extension ScrubberProperties {
    @Test func hostileInput() throws {
        let run = PropertyRun("hostileInput")
        defer { run.finish() }
        for index in 0..<run.count {
            var gen = Gen(seed: run.seed(index))
            let format = ["json", "csv", "xml", "txt"][index % 4]
            let source = try gen.document(format: format)
            var bytes = Array(source.data)
            let offset = gen.int(0...(bytes.count - 1))
            switch index % 7 {
            case 0: bytes = Array(bytes.prefix(offset))
            case 1: bytes.insert(UInt8(gen.int(0...255)), at: offset)
            case 2: bytes.remove(at: offset)
            case 3: bytes[offset] ^= UInt8(gen.int(1...255))
            case 4: bytes.insert(contentsOf: [0xFF, 0xC0, 0xAF], at: offset)
            case 5: bytes.insert(contentsOf: Array("\"[<broken>".utf8), at: offset)
            default: bytes.insert(contentsOf: Array(String(repeating: "quiet ", count: gen.int(12000...14000)).utf8), at: offset)
            }
            checkHostile(Data(bytes), format: format, run: run, index: index)
            let depth = index == 0 ? 5_000 : gen.choose([1, 20, 128, 256, 512, 1_000, 5_000])
            for (format, input) in [("json", String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)),
                                    ("xml", String(repeating: "<r>", count: depth) + "quiet" + String(repeating: "</r>", count: depth))] {
                checkHostile(Data(input.utf8), format: format, run: run, index: index)
            }
            let declaration = "<!DOCTYPE root [<!ENTITY x 'EXPANSION_&#88;&#89;&#90;_SENTINEL'>]>"
            let wrapper = gen.choose(["<root>&x;</root>", "<!-- placeholder --><root>&x;</root>", "<?audit placeholder?><root>&x;</root>", "<root><![CDATA[placeholder]]>&x;</root>", "<?audit <!-- ?><root>&x;</root><!-- -->"])
            var entity = Array(wrapper.utf8)
            entity.insert(contentsOf: declaration.utf8, at: gen.int(0...entity.count))
            checkHostile(Data(entity), format: "xml", run: run, index: index)
        }
    }

    private func checkHostile(_ data: Data, format: String, run: PropertyRun, index: Int) {
        let doc = GeneratedDocument(text: String(decoding: data, as: UTF8.self), format: format, planted: [], delimiter: ",", quote: "\"", newline: "\n")
        let diagnostic = Comment(rawValue: "\(run.diagnostic(index, doc))\nEXACT BYTES(base64):\(data.base64EncodedString())")
        do {
            let result = try Scrubber.scrub(data, name: doc.filename, forceFullDetection: false, seed: run.seed(index))
            #expect(!String(decoding: result.output, as: UTF8.self).contains("EXPANSION_XYZ_SENTINEL"), diagnostic)
        } catch {
            #expect(error is ScrubError, "Non-ScrubError \(error). \(diagnostic)")
        }
    }
}
