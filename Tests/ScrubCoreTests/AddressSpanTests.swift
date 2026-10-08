import Foundation
@testable import ScrubCore
import Testing

/// An address ends where a message's greeting or sign-off starts, and a number
/// filed under an order or a case is no house number or postcode. Real
/// addresses written over several lines, beside a greeting, are still replaced
/// whole.
struct AddressSpanTests {
    struct Kept {
        let prose: String
        /// What must read exactly as written.
        let kept: [String]
        /// Names that must be gone.
        let gone: [String]
    }

    static let notAddresses = [
        // A support ticket's subject, then the greeting on the next line.
        Kept(prose: "Brannagh Kesterton <> support | re: order 77120\nHi Saoirse,\n\nYour replacement card has shipped.",
             kept: ["support | re: order 77120\nHi ", ",\n\nYour replacement card has shipped."], gone: ["Saoirse"]),
        // The greeting's title and name would read as a street ("77120 Dear Ms Ottoline Way").
        Kept(prose: "re: order 77120\nDear Ms Ottoline Way,\nthe parcel is late.",
             kept: ["re: order 77120\nDear Ms ", ",\nthe parcel is late."], gone: ["Ottoline"]),
        // One line: the greeting would read as Hawaii after a ZIP.
        Kept(prose: "Update on order 77120 Hi Saoirse, the courier has it now.",
             kept: ["Update on order 77120 Hi ", ", the courier has it now."], gone: ["Saoirse"]),
        // No label, one line: a number, then a greeting read as Hawaii.
        Kept(prose: "We shipped 77120 Hi Saoirse, the courier has it now.",
             kept: ["We shipped 77120 Hi ", ", the courier has it now."], gone: []),
        // A word before the number the system takes for a city, and the greeting for a state.
        Kept(prose: "Code 77120\nHi Saoirse,\nyour parcel is on its way.",
             kept: ["Code 77120\nHi ", ",\nyour parcel is on its way."], gone: ["Saoirse"]),
        // An order number before a building's name is no house number.
        Kept(prose: "Support | re: order 77120 The Elm Dr Apartments open next week.",
             kept: ["Support | re: order 77120 The Elm Dr Apartments open next week."], gone: []),
        // An order number before a state's code is still an order number, not a postcode.
        Kept(prose: "Hi Saoirse, your order 77120 TX shipped today.",
             kept: ["Hi ", ", your order 77120 TX shipped today."], gone: ["Saoirse"]),
    ]

    @Test func aNumberBeforeAGreetingIsNoAddress() throws {
        for sample in Self.notAddresses {
            for seed in UInt64(0)..<3 {
                for path in PIIGaps.InputPath.allCases {
                    let (output, result) = try SpreadTests.scrub(sample.prose, path, seed: seed)
                    let label = "[\(path) seed \(seed)] \(output)"
                    for part in sample.kept { #expect(output.contains(part), "kept \(part.debugDescription): \(label)") }
                    #expect(SpreadTests.gone(sample.gone, from: output).isEmpty, "\(label)")
                    #expect(result.counts["ADDRESS", default: 0] == 0 && result.counts["LOCATION", default: 0] == 0, "\(result.counts) \(label)")
                    #expect(output.components(separatedBy: "\n").count == sample.prose.components(separatedBy: "\n").count, "\(label)")
                }
            }
        }
    }

    struct Placed {
        let prose: String
        /// Words of the real address, all gone after scrubbing.
        let address: [String]
        /// What must read exactly as written: the greeting or sign-off and the message.
        let kept: [String]
        /// The street and city lines' indices in the output.
        let street: Int
        let city: Int?
    }

    static let addresses = [
        // A signature stacks name, street, unit and city.
        Placed(prose: "Thanks,\nBram Oyelaran\n3277 Wexcombe Drive\nSuite 882\nBoise, ID 83702",
               address: ["Wexcombe", "83702", "Boise", "Oyelaran"], kept: ["Thanks,\n"], street: 2, city: 4),
        // An envelope's address, then the letter's greeting.
        Placed(prose: "Ifeoma Castellane\n58 Rookery Lane\nTacoma, WA 98402\n\nDear Ifeoma,\nyour card has shipped.",
               address: ["Rookery", "Tacoma", "98402", "Castellane", "Ifeoma"], kept: ["\n\nDear ", ",\nyour card has shipped."], street: 1, city: 2),
        // A street at the end of a line, the greeting on the next.
        Placed(prose: "Please send it to 4821 Juniper Hollow Rd\nHi Bram, the parcel is late.",
               address: ["Juniper", "4821", "Bram"], kept: ["Please send it to ", "\nHi ", ", the parcel is late."], street: 0, city: nil),
        // A label before a street's number leaves it a house number.
        Placed(prose: "Return item 981 Pellow Street\nThanks, Bram",
               address: ["Pellow", "981", "Bram"], kept: ["Return item ", "\nThanks, "], street: 0, city: nil),
        // A street and city, then a sign-off.
        Placed(prose: "New address: 912 Pellow Avenue\nSpokane, WA 99201\nThanks, Bram",
               address: ["Pellow", "Spokane", "99201", "Bram"], kept: ["New address: ", "\nThanks, "], street: 0, city: 1),
    ]

    @Test func realAddressesBesideAGreetingAreReplacedWhole() throws {
        for sample in Self.addresses {
            for seed in UInt64(0)..<3 {
                for path in PIIGaps.InputPath.allCases {
                    let (output, result) = try SpreadTests.scrub(sample.prose, path, seed: seed)
                    let label = "[\(path) seed \(seed)] \(output)"
                    #expect(SpreadTests.gone(sample.address, from: output).isEmpty, "\(label)")
                    for part in sample.kept { #expect(output.contains(part), "kept \(part.debugDescription): \(label)") }
                    #expect(result.counts["ADDRESS", default: 0] + result.counts["LOCATION", default: 0] > 0, "\(result.counts) \(label)")
                    let lines = output.components(separatedBy: "\n")
                    #expect(lines.count == sample.prose.components(separatedBy: "\n").count, "\(label)")
                    // The stand-in reads as a street and a city line where the originals stood.
                    guard lines.count == sample.prose.components(separatedBy: "\n").count else { continue }
                    #expect(lines[sample.street].contains(/\d{1,6} \p{Lu}\p{Ll}+( \p{Lu}\p{Ll}+)*( (Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Lane|Ln|Way|Court|Ct|Place|Pl|Boulevard|Blvd))\.?$/), "street: \(label)")
                    if let city = sample.city {
                        #expect(lines[city].wholeMatch(of: /\p{Lu}[\p{L} .'-]+, [A-Z]{2} \d{5}/) != nil, "city: \(label)")
                    }
                }
            }
        }
    }

    /// A town, a state written in lower case and a ZIP is still a place:
    /// only a postcode with no town before a word read as a state is dropped.
    @Test func aTownWithALowercaseStateIsStillAPlace() throws {
        let prose = "Mail goes to Fernhollow, Ca 94110 now."
        for seed in UInt64(0)..<3 {
            for path in PIIGaps.InputPath.allCases {
                let (output, result) = try SpreadTests.scrub(prose, path, seed: seed)
                #expect(SpreadTests.gone(["Fernhollow", "94110"], from: output).isEmpty, "[\(path) seed \(seed)] \(output)")
                #expect(output.hasPrefix("Mail goes to ") && output.hasSuffix(" now."), "\(output)")
                #expect(result.counts["ADDRESS", default: 0] + result.counts["LOCATION", default: 0] > 0, "\(result.counts)")
            }
        }
    }

    /// The rule on the system detector's own readings, without the rest of the pipeline.
    @Test func theSystemReadingIsCut() throws {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)
        func cut(_ text: String) -> [String] {
            let ns = text as NSString
            return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
                Detector.addressRange(match.range.location..<NSMaxRange(match.range), in: ns).map { TextRanges.substring(text, $0) }
            }
        }
        #expect(cut("77120\nHi Saoirse,").isEmpty)
        // A reading with no street keeps nothing once cut: "Code 77120" is a word and a number.
        let code = "Code 77120\nHi Saoirse," as NSString
        #expect(Detector.addressRange(0..<15, in: code, street: false) == nil && Detector.addressRange(0..<15, in: code) == 0..<10)
        // A number filed under an order is no postcode; one before a street is a house number.
        #expect(Detector.filed(10, in: "re: order 77120 TX" as NSString) && Detector.filed(9, in: "Invoice #4412" as NSString))
        #expect(cut("Send it to 4821 Juniper Hollow Rd\nHi Bram,") == ["4821 Juniper Hollow Rd"])
        #expect(cut("3277 Wexcombe Drive\nSuite 882\nBoise, ID 83702\nThanks, Bram") == ["3277 Wexcombe Drive\nSuite 882\nBoise, ID 83702"])
    }
}

/// An address never runs on into the phone number, the email or the link written after it: each is
/// replaced as what it is, its label kept, however the address's reading ends, in several languages.
struct ContactBesideAddressTests {
    static let notes: [(String, [String], [String])] = [
        ("Note de dossier : Mme Albane Rivière a appelé.\nAdresse : 8 allée des Tilleuls, 35000 Rennes. Tél. 02 99 55 01 42 — albane.riviere@example.fr\nMerci.",
         ["albane.riviere@example.fr", "02 99 55 01 42", "allée des Tilleuls", "Rivière"], ["Tél. ", " — "]),
        ("Kundennotiz: Herr Henrik Lorenz, Anschrift: Lindenstraße 14, 50674 Köln, Tel. 0221 5550123, E-Mail henrik.lorenz@example.de\nRückruf erbeten.",
         ["henrik.lorenz@example.de", "0221 5550123", "Lindenstraße", "Lorenz"], [", Tel. ", ", E-Mail "]),
        ("Domicilio: Calle del Pez 7, 3º B, 28004 Madrid; teléfono 655 501 234; correo marta.ibanez@example.es",
         ["marta.ibanez@example.es", "655 501 234", "Calle del Pez"], ["; teléfono ", "; correo "]),
        ("Morada: Rua das Flores 21, 4050-262 Porto, telefone 912 555 038, email rui.tavares@example.pt",
         ["rui.tavares@example.pt", "912 555 038", "Rua das Flores"], [", telefone ", ", email "]),
        ("Mailing address: 4821 Juniper Hollow Rd, Boise, ID 83702 phone (208) 555-0147 email dana.whitlock@example.com",
         ["dana.whitlock@example.com", "555-0147", "Juniper Hollow"], [" phone (", " email "]),
    ]

    @Test(arguments: [UInt64(1), 4, 11])
    func contactsBesideAnAddressAreTheirOwn(_ seed: UInt64) throws {
        for (note, gone, kept) in Self.notes {
            let result = try Scrubber.scrub(Data(note.utf8), name: "Pasted text", forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            for value in gone { #expect(!output.contains(value), "\(value) left: \(output)") }
            for value in kept { #expect(output.contains(value), "\(value) lost: \(output)") }
            // The email is replaced as an email, not inside an address's stand-in.
            let email = try #require(gone.first)
            #expect(result.findings.contains { $0.original == email && $0.entity == "EMAIL_ADDRESS" }, "\(result.findings.map { "\($0.entity) \($0.original)" })")
            #expect(!result.findings.contains { $0.entity == "ADDRESS" && $0.original.contains("@") }, "\(output)")
        }
    }

    /// The rule alone, on spans as any reading might leave them: one read past its end, one read from inside an email.
    @Test func anAddressGivesBackTheContactsItTookIn() {
        let text = "Adresse : 8 allée des Tilleuls, 35000 Rennes. Tél. 02 99 55 01 42 — a.r@example.fr"
        let ns = text as NSString
        func range(_ part: String) -> Range<Int> { let r = ns.range(of: part); return r.location..<NSMaxRange(r) }
        let address = range("8 allée des Tilleuls")
        let spans = [Span(range: address.lowerBound..<ns.length, entity: "ADDRESS", score: 1),
                     Span(range: range("02 99 55 01 42"), entity: "PHONE_NUMBER", score: 0.75),
                     Span(range: range("a.r@example.fr"), entity: "EMAIL_ADDRESS", score: 1)]
        let cut: [Span] = Detector.contactsOutOfAddresses(spans, in: text)
        let kept: String? = cut.first { $0.entity == "ADDRESS" }.map { TextRanges.substring(text, $0.range) }
        #expect(kept == "8 allée des Tilleuls, 35000 Rennes")
        // A house number and postcode a phone's pattern took stay the address's.
        let street = "Lieferung an Hauptstraße 12 50674 Köln bitte"
        let sns = street as NSString
        let whole = sns.range(of: "Hauptstraße 12 50674 Köln"), numbers = sns.range(of: "12 50674")
        let numbered: [Span] = Detector.contactsOutOfAddresses([Span(range: whole.location..<NSMaxRange(whole), entity: "ADDRESS", score: 0.9),
                                                    Span(range: numbers.location..<NSMaxRange(numbers), entity: "PHONE_NUMBER", score: 0.5)], in: street)
        let range: Range<Int>? = numbered.first { $0.entity == "ADDRESS" }?.range
        #expect(range == whole.location..<NSMaxRange(whole))
    }

    /// An address ends at its postcode's city, before the full stop and the sentence after it, in any language.
    @Test(arguments: [UInt64(2), 9])
    func anAddressEndsAtItsCityBeforeTheNextSentence(_ seed: UInt64) throws {
        let notes: [(String, String)] = [
            ("Bitte schicken Sie die Unterlagen an Hildegard Brenner, Lindenallee 14, 50674 Köln. Der Vogel im Garten singt jeden Morgen.", " Der Vogel im Garten singt jeden Morgen."),
            ("Er wohnt seit Mai in der Rosenstraße 3, 80331 München. Morgen fahre ich nach Hause.", " Morgen fahre ich nach Hause."),
            ("Elle habite 12 rue des Lilas, 75011 Paris. La semaine prochaine elle part en vacances.", " La semaine prochaine elle part en vacances."),
        ]
        for (note, sentence) in notes {
            let result = try Scrubber.scrub(Data(note.utf8), name: "note.txt", forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            #expect(output.hasSuffix(sentence), "\(output)")
            for part in ["Lindenallee 14", "Rosenstraße 3", "12 rue des Lilas", "50674", "80331", "75011"] where note.contains(part) { #expect(!output.contains(part), "\(part): \(output)") }
            #expect(!result.findings.contains { $0.entity == "ADDRESS" && $0.original.contains(". ") }, "\(result.findings.map { "\($0.entity) \($0.original)" })")
        }
    }
}
