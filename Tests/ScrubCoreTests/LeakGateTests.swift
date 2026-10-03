import Foundation
@testable import ScrubCore
import Testing

/// The leak gate: a value already replaced, written another way in a note,
/// is replaced too, with the stand-in its original got and in the variant's
/// own shape. Each case puts a record (a name, a phone, an email) in fields
/// and a variant in a free-text note, on every input path: text, JSON, CSV
/// and XML. A type oracle reads the stand-ins from the output's fields and
/// checks the variant's stand-in against them; the rest of the note stays.
@Suite struct LeakGateTests {
    enum Path: CaseIterable { case text, json, csv, xml }

    struct Record: Sendable {
        var name = "Odalys Ferriter"
        var phone = "(415) 867-2290"
        var email = "quillpen77@marrowmail.example"
    }
    /// What a scrubbed document's fields and note read.
    struct Read: Sendable {
        let name: String
        let phone: String
        let email: String
        let note: String
        var first: String { String(name.split(separator: " ").first ?? "") }
        var last: String { String(name.split(separator: " ").last ?? "") }
        var phoneDigits: String { phone.filter(\.isNumber) }
    }

    static func document(_ record: Record, note: String, _ path: Path) -> (Data, String) {
        switch path {
        case .text:
            return (Data("Customer: \(record.name)\nPhone: \(record.phone)\nEmail: \(record.email)\nNote: \(note)".utf8), "ticket.txt")
        case .json:
            let object: [String: Any] = ["ticket": 5528, "customer": ["full_name": record.name, "phone": record.phone, "email": record.email], "note": note]
            return (try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), "ticket.json")
        case .csv:
            func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return (Data("ticket,customer_name,phone,email,note\n5528,\(quoted(record.name)),\(quoted(record.phone)),\(quoted(record.email)),\(quoted(note))\n".utf8), "tickets.csv")
        case .xml:
            func escaped(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
            return (Data("<ticket><id>5528</id><customer><fullName>\(escaped(record.name))</fullName><phone>\(escaped(record.phone))</phone><email>\(escaped(record.email))</email></customer><note>\(escaped(note))</note></ticket>".utf8), "ticket.xml")
        }
    }

    static func read(_ data: Data, _ path: Path) throws -> Read {
        switch path {
        case .text:
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.components(separatedBy: "\n")
            func field(_ label: String) -> String { lines.first { $0.hasPrefix(label + ": ") }.map { String($0.dropFirst(label.count + 2)) } ?? "" }
            let note = text.range(of: "\nNote: ").map { String(text[$0.upperBound...]) } ?? ""
            return Read(name: field("Customer"), phone: field("Phone"), email: field("Email"), note: note)
        case .json:
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let customer = object["customer"] as? [String: Any] ?? [:]
            return Read(name: customer["full_name"] as? String ?? "", phone: customer["phone"] as? String ?? "", email: customer["email"] as? String ?? "", note: object["note"] as? String ?? "")
        case .csv:
            let rows = try CSVFile.parse(String(decoding: data, as: UTF8.self), delimiter: ",")
            let row = try #require(rows.dropFirst().first)
            return Read(name: row[1], phone: row[2], email: row[3], note: row[4])
        case .xml:
            let document = try XMLDocument(data: data)
            func value(_ path: String) throws -> String { try document.nodes(forXPath: path).first?.stringValue ?? "" }
            return Read(name: try value("/ticket/customer/fullName"), phone: try value("/ticket/customer/phone"), email: try value("/ticket/customer/email"), note: try value("/ticket/note"))
        }
    }

    /// A note with one ⟦slot⟧, read back as what now fills it; nil when anything else in the note changed.
    static func slot(_ template: String, in note: String) -> String? {
        let pieces = template.components(separatedBy: "⟦")
        guard pieces.count == 2 else { return nil }
        let rest = pieces[1].components(separatedBy: "⟧")
        let pattern = "^" + NSRegularExpression.escapedPattern(for: pieces[0]) + "(.+?)" + NSRegularExpression.escapedPattern(for: rest[1]) + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: note, range: NSRange(location: 0, length: (note as NSString).length)) else { return nil }
        return (note as NSString).substring(with: match.range(at: 1))
    }

    struct Variant: CustomStringConvertible, Sendable {
        let kind: String
        /// The note, with the variant between ⟦ and ⟧.
        let note: String
        var record = Record()
        /// What the variant's stand-in must be, from the stand-ins in the fields.
        let expect: @Sendable (Read) -> String
        /// Or, when the stand-in has a shape rather than one value, whether it fits.
        var fits: (@Sendable (String, Read) -> Bool)? = nil
        var description: String { kind }
        /// What fills the slot in the input.
        var variant: String {
            let start = note.range(of: "⟦")!, end = note.range(of: "⟧")!
            return String(note[start.upperBound..<end.lowerBound])
        }
    }

    static func lower(_ value: String) -> String { value.lowercased().filter(\.isLetter) }

    static let variants: [Variant] = [
        // Names written another way.
        Variant(kind: "capitals", note: "Later ⟦FERRITER⟧ called back about the charge.", expect: { $0.last.uppercased() }),
        Variant(kind: "lowercase possessive", note: "The spare laptop is ⟦ferriter⟧'s old one.", expect: { $0.last.lowercased() }),
        Variant(kind: "initial and surname", note: "Signed for by ⟦O. Ferriter⟧ at the desk.", expect: { "\($0.first.prefix(1)). \($0.last)" }),
        Variant(kind: "initial without a stop", note: "Signed for by ⟦O Ferriter⟧ at the desk.", expect: { "\($0.first.prefix(1)) \($0.last)" }),
        Variant(kind: "line break", note: "Please thank ⟦Odalys\nFerriter⟧ for the report.", expect: { "\($0.first)\n\($0.last)" }),
        Variant(kind: "hyphen at a line's end", note: "The long note from ⟦Fer-\nriter⟧ is attached.", expect: { $0.last }),
        Variant(kind: "soft hyphen", note: "Ask ⟦Fer\u{00AD}riter⟧ about the second charge.", expect: { $0.last }),
        // Names inside handles and logins.
        Variant(kind: "handle with an at sign", note: "She posts as @⟦odalysf⟧ on the forum.", expect: { lower($0.first) + lower($0.last).prefix(1) }),
        Variant(kind: "first name and initial", note: "Her login is ⟦odalys.f⟧ on the portal.", expect: { lower($0.first) + "." + lower($0.last).prefix(1) }),
        Variant(kind: "initial and surname joined", note: "The account ⟦oferriter⟧ was locked again.", expect: { String(lower($0.first).prefix(1)) + lower($0.last) }),
        Variant(kind: "surname and first name joined", note: "Her handle is ⟦ferriterodalys⟧ these days.", expect: { lower($0.last) + lower($0.first) }),
        Variant(kind: "underscore", note: "Her username is ⟦odalys_ferriter⟧ there.", expect: { lower($0.first) + "_" + lower($0.last) }),
        Variant(kind: "surname and digits", note: "Her gamer tag is ⟦ferriter99⟧ apparently.", expect: { _ in "" },
                fits: { standIn, read in standIn.hasPrefix(lower(read.last)) && standIn.dropFirst(lower(read.last).count).count == 2 && standIn.suffix(2).allSatisfy(\.isNumber) }),
        Variant(kind: "email built from the name", note: "She also writes from ⟦oferriter@kestrelmail.example⟧ sometimes.", expect: { _ in "" },
                fits: { standIn, read in
                    let parts = standIn.split(separator: "@")
                    return parts.count == 2 && String(parts[0]) == String(lower(read.first).prefix(1)) + lower(read.last) && parts[1].hasPrefix("example.")
                }),
        // Numbers written another way.
        Variant(kind: "phone without separators", note: "Backup number ⟦4158672290⟧ is in the old CRM.", expect: { $0.phoneDigits.suffix(10).description }),
        Variant(kind: "phone with dots", note: "Old format: ⟦415.867.2290⟧ in the export.", expect: { read in
            let digits = Array(read.phoneDigits.suffix(10))
            return String(digits[0..<3]) + "." + String(digits[3..<6]) + "." + String(digits[6...])
        }),
        Variant(kind: "phone's last four", note: "Her phone ending in ⟦2290⟧ is verified.", expect: { String($0.phoneDigits.suffix(4)) }),
        Variant(kind: "last four digits", note: "Verified the last four ⟦2290⟧ with her.", expect: { String($0.phoneDigits.suffix(4)) }),
        // Emails written another way.
        Variant(kind: "local part alone", note: "User ⟦quillpen77⟧ is locked out again.", expect: { String($0.email.split(separator: "@").first ?? "") }),
        Variant(kind: "email in capitals", note: "The copy to ⟦QUILLPEN77@MARROWMAIL.EXAMPLE⟧ bounced.", expect: { $0.email.uppercased() }),
    ]

    static func scrub(_ variant: Variant, _ path: Path, seed: UInt64) throws -> (Read, ScrubResult) {
        let note = variant.note.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
        let (data, name) = document(variant.record, note: note, path)
        let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
        return (try read(result.output, path), result)
    }

    @Test(arguments: Path.allCases) func aVariantTakesItsOriginalsStandIn(path: Path) throws {
        for variant in Self.variants {
            for seed in UInt64(1)...2 {
                let (read, result) = try Self.scrub(variant, path, seed: seed)
                let label = "[\(path) \(variant.kind) seed \(seed)] \(read.note.debugDescription) name \(read.name) phone \(read.phone) email \(read.email)"
                // The fields were replaced, so there is a stand-in to agree with.
                #expect(read.name != variant.record.name && read.phone != variant.record.phone && read.email != variant.record.email, "fields kept: \(label)")
                let standIn = try #require(Self.slot(variant.note, in: read.note), "the rest of the note changed: \(label)")
                #expect(standIn.lowercased() != variant.variant.lowercased(), "variant kept: \(label)")
                if let fits = variant.fits {
                    #expect(fits(standIn, read), "\(standIn.debugDescription) does not fit: \(label)")
                } else {
                    #expect(standIn == variant.expect(read), "\(standIn.debugDescription), expected \(variant.expect(read).debugDescription): \(label)")
                }
                // Nothing of the original is left anywhere, and nothing is left to ask about.
                let output = String(decoding: result.output, as: UTF8.self)
                for piece in ["Ferriter", "Odalys", "867-2290", "8672290", "quillpen77"] {
                    #expect(output.range(of: piece, options: .caseInsensitive) == nil, "\(piece) left: \(label)")
                }
                #expect(result.unresolved.isEmpty, "\(result.unresolved): \(label)")
            }
        }
    }

    /// Words that look like a name's part, numbers and dates beside the
    /// record stay as written: a name part that is an ordinary word, order
    /// numbers, versions, dates, and last digits no number replaced ends in.
    static let negatives = [
        "We will mark the order as shipped once the warehouse confirms.",
        "Order 77120893 shipped on 2024-03-14; invoice 4412-2290 is paid.",
        "Upgraded to version 4.15.2290 and build 2290 on 03/14/2024.",
        "The batch ending in 7731 shipped on Monday.",
        "Seats 2 to 22 on the ferris wheel are booked for Saturday.",
        "The rose garden opens at 9; bring the brown folder.",
    ]

    @Test(arguments: Path.allCases) func lookAlikesStay(path: Path) throws {
        let record = Record(name: "Will Rose Ferriter")
        for note in Self.negatives {
            for seed in UInt64(1)...2 {
                let (data, name) = Self.document(record, note: note, path)
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let read = try Self.read(result.output, path)
                #expect(read.note == note, "[\(path) seed \(seed)] \(read.note.debugDescription)")
                #expect(read.name != record.name, "[\(path)] name kept")
                #expect(result.uncertain.allSatisfy { !$0.suspected }, "[\(path)] \(result.uncertain.map(\.original)) \(read.note)")
            }
        }
    }

    /// A handle inside a link is not rewritten without a person's say: the
    /// link stays as written, review asks about it with the stand-in it
    /// would take, and choosing to replace it writes that stand-in and
    /// leaves every other one as it was.
    @Test(arguments: Path.allCases) func aVariantInALinkIsAskedAbout(path: Path) throws {
        let note = "Her profile is https://forum.example/u/odalysf for now."
        for seed in UInt64(1)...2 {
            let (data, name) = Self.document(Record(), note: note, path)
            let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
            let read = try Self.read(result.output, path)
            let label = "[\(path) seed \(seed)] \(read.note.debugDescription)"
            #expect(read.note == note, "the link changed: \(label)")
            let suspect = try #require(result.findings.first { $0.suspected && $0.original == "odalysf" }, "no suspect: \(label) \(result.findings.map(\.original))")
            #expect(suspect.needsReview && result.uncertain.contains(suspect), "\(label)")
            #expect(result.leftAsWritten == [suspect.id], "\(label)")
            #expect(suspect.standIn == Self.lower(read.first) + Self.lower(read.last).prefix(1), "\(suspect.standIn): \(label)")
            #expect(suspect.excerpts.first?.standIn == suspect.standIn, "\(label)")
            // Left as chosen, the result is the scrub as made.
            #expect(try result.skipping(result.leftAsWritten).output == result.output, "\(label)")
            let replaced = try result.skipping([])
            let after = try Self.read(replaced.output, path)
            #expect(after.note == "Her profile is https://forum.example/u/\(suspect.standIn) for now.", "\(after.note): \(label)")
            #expect(after.name == read.name && after.phone == read.phone && after.email == read.email, "\(label)")
            #expect(replaced.counts["USERNAME", default: 0] == result.counts["USERNAME", default: 0] + 1, "\(replaced.counts) \(result.counts): \(label)")
            #expect(replaced.unresolved.isEmpty && replaced.leftAsWritten.isEmpty, "\(label)")
            // Applied to the scrub as made each time: back to leaving it gives the original output.
            #expect(try replaced.skipping([suspect.id]).output == result.output, "\(label)")
        }
    }

    // MARK: The gate alone

    @Test func numbersThatCheckThemselvesAreSuspects() {
        let gate = LeakGate()
        let text = "Card 4539 1488 0343 6467 on file. IBAN DE89 3704 0044 0532 0130 00 too. SSN 536-21-7784."
        let found = gate.scan(text)
        let kinds = found.suspects.map { "\($0.entity):\(TextRanges.substring(text, $0.range))" }
        #expect(kinds == ["CREDIT_CARD:4539 1488 0343 6467", "US_SSN:536-21-7784", "IBAN_CODE:DE89 3704 0044 0532 0130 00"], "\(kinds)")
        #expect(found.suspects.allSatisfy { $0.score < 0.65 })
        #expect(found.leaks.isEmpty)
    }

    @Test func filedNumbersVersionsAndTimesAreNoSuspects() {
        let gate = LeakGate()
        for text in ["Invoice 4539148803436467 is paid.", "Order no. 4539 1488 0343 6467 shipped.", "Tracking 4539148803436467.",
                     "Released 4539148803436467.2 today.", "At 1710423045123 the job ran.", "Range 000-12-3456 and 666-12-3456 and 123-00-4567 are not.",
                     "Build v4539148803436467 passed.", "Card 4539 1488 0343 6468 fails its check."] {
            #expect(gate.scan(text).suspects.isEmpty, "\(text) \(gate.scan(text).suspects)")
        }
    }

    @Test func partsThatAreWordsAreNeverHunted() {
        var gate = LeakGate()
        gate.add([Replacement(original: "Will Rose", fake: "Ethan Cole", entity: "PERSON"), Replacement(original: "Ana Refund", fake: "Mia Holt", entity: "PERSON")])
        // "will", "rose" and "refund" are words, "ana" is too short, and two words joined are no handle.
        for text in ["we will rose it", "willrose", "the refund", "ana.r", "anarefund"] {
            #expect(gate.scan(text).leaks.isEmpty, "\(text) \(gate.scan(text).leaks.map(\.fake))")
        }
        #expect(LeakGate.usable("Ferriter") && !LeakGate.usable("Rose") && !LeakGate.usable("Will") && !LeakGate.usable("Refund") && !LeakGate.usable("Ana"))
    }

    @Test func casesFollowTheVariant() {
        #expect(LeakGate.cased("Garcia", like: "FERRITER") == "GARCIA")
        #expect(LeakGate.cased("Garcia", like: "ferriter") == "garcia")
        #expect(LeakGate.cased("garcia", like: "Ferriter") == "Garcia")
    }

    /// Past its budget a pass replaces no more variants; the rest are asked about, never dropped.
    @Test func pastItsBudgetTheRestAreSuspects() {
        var gate = LeakGate()
        gate.add([Replacement(original: "Odalys Ferriter", fake: "Joan Garcia", entity: "PERSON")])
        let text = (0..<10).map { _ in "ferriter" }.joined(separator: " ")
        let found = gate.scan(text, budget: 4)
        #expect(found.leaks.count == 4 && found.suspects.count == 6)
    }
}
