import Foundation
@testable import ScrubCore
import ScrubTestSupport
import Testing

/// A record ID that names a person or their account takes a stand-in of the
/// same shape, the same wherever it is written (another record, a field that
/// refers to it, a link, prose), and technical IDs stay as written.
struct RecordIDTests {
    static let spelled = "cus_odalys_ferriter"
    static let opaque = "cus_4TUvJhQkMeNW"
    static let patient = "pat_7Hq2Lm9XwR"
    /// IDs that name no one.
    static let technical = ["req_8KfP2qLmZx", "3fa85f64-5717-4562-b3fc-2c963f66afa6", "9f2c1e7b4a6d", "SKU-48213", "ord_55120893"]

    enum Path: String, CaseIterable { case json, csv, xml, text }

    static func document(_ path: Path) -> String {
        let link = "https://billing.example/customers/\(opaque)/invoices"
        switch path {
        case .json:
            return #"""
            {"customers": [{"id": "\#(spelled)", "name": "Odalys Ferriter", "email": "odalys.ferriter@kestrel.example"},
                           {"customer_id": "\#(opaque)", "patient_id": "\#(patient)", "full_name": "Teodoro Quillan"}],
             "charges": [{"id": "\#(technical[4])", "customer": "\#(opaque)", "amount": 1200, "sku": "\#(technical[3])"}],
             "request_id": "\#(technical[0])", "trace": "\#(technical[1])", "build": "\#(technical[2])",
             "note": "Refund \#(opaque) via \#(link); see \#(spelled)."}
            """#
        case .csv:
            return "customer_id,name,patient_id,referred_by,request_id,order_id,note\n\(spelled),Odalys Ferriter,\(patient),\(opaque),\(technical[0]),\(technical[4]),Refund via \(link)\n\(opaque),Teodoro Quillan,,\(spelled),\(technical[1]),\(technical[3]),build \(technical[2])\n"
        case .xml:
            return "<file><customer><customer_id>\(spelled)</customer_id><name>Odalys Ferriter</name></customer><customer><customer_id>\(opaque)</customer_id><patient_id>\(patient)</patient_id><name>Teodoro Quillan</name></customer><charge><order_id>\(technical[4])</order_id><customer>\(opaque)</customer><sku>\(technical[3])</sku></charge><request_id>\(technical[0])</request_id><trace>\(technical[1])</trace><build>\(technical[2])</build><note>Refund via \(link.replacingOccurrences(of: "&", with: "&amp;")); see \(spelled).</note></file>"
        case .text:
            return "Customer \(opaque) (Teodoro Quillan, patient \(patient)) asked about order \(technical[4]) and SKU \(technical[3]). Odalys Ferriter's account is \(spelled). Refund via \(link). Request \(technical[0]), trace \(technical[1]), build \(technical[2])."
        }
    }

    /// A stand-in in the original's shape: the prefix, the length and each character's kind.
    static func shaped(_ standIn: String, like original: String) -> Bool {
        guard standIn != original, standIn.count == original.count else { return false }
        let prefix = String(original.prefix { $0 != "_" }) + "_"
        guard standIn.hasPrefix(prefix) else { return false }
        return zip(standIn, original).allSatisfy { a, b in
            a.isNumber == b.isNumber && a.isLowercase == b.isLowercase && a.isUppercase == b.isUppercase && (a.isLetter || a.isNumber || a == b)
        }
    }

    @Test(arguments: Path.allCases)
    func personalIDsTakeOneStandInOfTheirShapeEverywhere(_ path: Path) throws {
        for seed in UInt64(0)..<3 {
            let input = Self.document(path)
            let result = try Scrubber.scrub(Data(input.utf8), name: "ids.\(path == .text ? "txt" : path.rawValue)", forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            let label = "[\(path) \(seed)]"
            for original in [Self.spelled, Self.opaque, Self.patient] where input.contains(original) {
                #expect(!output.contains(original), "\(label) \(original) left: \(output)")
                let finding = try #require(result.findings.first { $0.original == original && $0.entity == "RECORD_ID" }, "\(label) \(original): \(result.findings.map(\.original))")
                #expect(Self.shaped(finding.standIn, like: original), "\(label) \(original) → \(finding.standIn)")
                // One stand-in, written as often as the original was.
                #expect(output.components(separatedBy: finding.standIn).count == input.components(separatedBy: original).count, "\(label) \(finding.standIn): \(output)")
                #expect(result.findings.filter { $0.original == original }.count == 1, "\(label) \(result.findings.filter { $0.original == original })")
            }
            for kept in Self.technical { #expect(output.contains(kept), "\(label) \(kept) changed: \(output)") }
            // The link still reads, around the customer's stand-in.
            #expect(output.contains("https://billing.example/customers/cus_") && output.contains("/invoices"), "\(label) \(output)")
            let leaked = ComponentLeaks.leaks([.init(Self.spelled, kind: .other), .init(Self.opaque, kind: .other), .init(Self.patient, kind: .other), .init("Odalys Ferriter", kind: .name)], input: input, output: output)
            #expect(leaked.isEmpty, "\(label) leaked \(leaked)")
            if path == .json { #expect((try? JSONSerialization.jsonObject(with: result.output)) != nil) }
            if path == .xml { #expect((try? XMLDocument(data: result.output)) != nil) }
        }
    }

    /// A key or column named like a prefixed ID ("user_street1") is a field's name, kept as written.
    @Test func numberedFieldNamesAreNoIDs() throws {
        let json = #"{"applicant": {"name": "Ingrid Vasquez-Ono", "user_street1": "3997 Heron Point Rd", "user_line2": "Unit 4"}}"#
        let csv = "name,user_street1,user_line2\nIngrid Vasquez-Ono,3997 Heron Point Rd,Unit 4\n"
        for (input, name) in [(json, "a.json"), (csv, "a.csv"), ("Set user_street1 and user_line2 for Ingrid Vasquez-Ono.", "a.txt")] {
            let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: 3).output, as: UTF8.self)
            #expect(output.contains("user_street1") && output.contains("user_line2"), "\(name): \(output)")
        }
    }
}
