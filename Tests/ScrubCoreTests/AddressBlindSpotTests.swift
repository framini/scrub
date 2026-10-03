import Foundation
@testable import ScrubCore
import Testing

/// Addresses the first address model never read: typed all in lowercase,
/// written with no number at all, and in the languages of the countries
/// Scrub places addresses in. Each is replaced as one unit on every input
/// path, by a stand-in written the same way (lowercase stays lowercase, a
/// numberless address gets no number); and text that only names streets,
/// buildings or places stays as written. Every person, street and number here is invented.
@Suite(.serialized)
struct AddressBlindSpotTests {
    typealias Path = AddressModelTests.Path
    typealias Case = AddressModelTests.Case

    static let lowercase: [Case] = [
        Case(marked: "bitte schick das paket an ⟦lindenhofer straße 48a, 70178 stuttgart⟧, danke!", words: ["lindenhofer", "48a", "70178", "stuttgart"], country: "DE"),
        Case(marked: "wohne jetzt in der ⟦brunnenweg 12, 04109 leipzig⟧ seit märz", words: ["brunnenweg", "04109", "leipzig"], country: "DE"),
        Case(marked: "can you forward my post to ⟦14 rookery lane, leeds ls6 2ab⟧", words: ["rookery", "leeds", "ls6", "2ab"], country: "GB"),
        Case(marked: "ship it to ⟦apt 4b, 2271 quarry ridge dr, boise id 83702⟧ thx", words: ["2271", "quarry", "boise", "83702"], country: "US"),
        Case(marked: "à envoyer au ⟦12 rue des tisserands, 69002 lyon⟧", words: ["tisserands", "69002", "lyon"], country: "FR"),
        Case(marked: "ons nieuwe adres: ⟦kerkstraat 41, 3511 lx utrecht⟧", words: ["kerkstraat", "3511", "utrecht"], country: "NL"),
    ]

    static let numberless: [Case] = [
        Case(marked: "Please send the keys to ⟦Flat B, The Old Rectory, Little Hadham⟧ by Friday.", words: ["Old", "Little", "Hadham"], country: "GB"),
        Case(marked: "Unsere neue Adresse: ⟦Hauptstraße, Berlin-Mitte⟧", words: ["Hauptstraße", "Berlin"], country: "DE"),
        Case(marked: "Kind regards,\nRufus Penhale\n⟦Pear Tree Cottage, Sallow Lane, Long Compton, Warwickshire⟧", words: ["Pear", "Sallow", "Compton"], country: "GB", kept: ["Kind regards,"]),
        Case(marked: "Ci vediamo in ⟦Via Garibaldi, Torino⟧.", words: ["Garibaldi", "Torino"], country: "IT"),
    ]

    static let multilingual: [Case] = [
        Case(marked: "Bitte schicken Sie die Unterlagen an ⟦Mühlenweg 4b, 26135 Oldenburg⟧.", words: ["Mühlenweg", "26135", "Oldenburg"], country: "DE"),
        Case(marked: "Merci d'envoyer le colis au ⟦27 rue du Moulin, 35000 Rennes⟧.", words: ["Moulin", "35000", "Rennes"], country: "FR"),
        Case(marked: "Mi dirección nueva es ⟦Calle del Pez 31, 2º B, 28004 Madrid⟧.", words: ["Pez", "28004"], country: "ES"),
        Case(marked: "Il pacco va consegnato in ⟦Via Tessitori 18, 10123 Torino (TO)⟧.", words: ["Tessitori", "10123", "Torino"], country: "IT"),
        Case(marked: "Ons nieuwe adres: ⟦Prinsengracht 412-hs, 1016 JA Amsterdam⟧", words: ["Prinsengracht", "412-hs", "1016", "Amsterdam"], country: "NL"),
        Case(marked: "Ny adress från maj: ⟦Hornsgatan 52, 118 21 Stockholm⟧.", words: ["Hornsgatan", "118 21", "Stockholm"], country: "SE"),
    ]

    @Test(arguments: Path.allCases) func lowercaseAddressesAreReplacedInLowercase(path: Path) throws {
        for sample in Self.lowercase {
            for seed in UInt64(0)..<3 {
                let found = try Self.replaced(sample, path, seed: seed)
                // Written as the original was: in lowercase, its lines and pieces as they were.
                #expect(found == found.lowercased(), "lowercase kept: \(found.debugDescription)")
                let original = try #require(AddressBlock.cased(sample.address).flatMap(AddressBlock.read))
                let made = AddressBlock.cased(found).flatMap(AddressBlock.read)
                #expect(made?.roles == original.roles, "pieces: \(found.debugDescription) for \(sample.address.debugDescription)")
                #expect(Self.postcodeShapes(found) == Self.postcodeShapes(sample.address), "postcode shape: \(found.debugDescription)")
            }
        }
    }

    @Test(arguments: Path.allCases) func numberlessAddressesAreReplacedWhole(path: Path) throws {
        for sample in Self.numberless {
            for seed in UInt64(0)..<3 {
                let found = try Self.replaced(sample, path, seed: seed)
                // No number where the original had none, and as many pieces.
                let numbered = found.contains { $0.isNumber }
                #expect(!numbered, "no number: \(found.debugDescription)")
                #expect(AddressBlock.pieces(found).count == AddressBlock.pieces(sample.address).count, "pieces: \(found.debugDescription) for \(sample.address.debugDescription)")
            }
        }
    }

    @Test(arguments: Path.allCases) func addressesInOtherLanguagesKeepTheirCountry(path: Path) throws {
        for sample in Self.multilingual {
            for seed in UInt64(0)..<3 {
                let found = try Self.replaced(sample, path, seed: seed)
                #expect(AddressModelTests.sameShape(sample.address, found, country: sample.country), "shape: \(found.debugDescription) for \(sample.address.debugDescription)")
            }
        }
    }

    // MARK: What is not an address

    /// Text that names streets, buildings and places, or has numbers beside
    /// such words, in lowercase and as written: directions, board games,
    /// titles, citations, manuals, versions and firms.
    static let notAddresses = [
        "take the coast road for about 12 miles and turn left at the second roundabout",
        "schlossallee is the priciest square on the german board, 400 to buy",
        "the high street is busy on saturdays, so park on a side road",
        "we sold 40 park benches and 12 street lamps last quarter",
        "turn right after 200 m onto the b4017 towards the bypass",
        "Gemäß § 573 Abs. 2 BGB ist die Kündigung wirksam.",
        "Según el artículo 1902 del Código Civil, el daño debe repararse.",
        "Section 41 of the Highways Act 1980 sets the duty to maintain.",
        "see man 5 sudoers for the file format, then run visudo",
        "Version 4.2 Boulevard Edition ships on 14 May.",
        "Bridgewater Street Capital LLC raised its dividend by 3%.",
        "Kastanienstrasse AG reported 12% growth in 2024.",
        "We met on Bay Street for lunch and talked about bonds.",
        "Downing Street said the review would be published soon.",
        "Die Hauptstraße ist wegen eines Festes gesperrt.",
        "Abbey Road Studios reopened after the refit.",
        "The Old Vicarage Hotel has a lovely garden.",
        "Unsere Filiale in der Bahnhofstraße hat heute geschlossen.",
    ]

    @Test(arguments: Path.allCases) func lookAlikesStayAsWritten(path: Path) throws {
        for text in Self.notAddresses {
            let (output, counts) = try AddressModelTests.scrub(text, path, seed: 1)
            #expect(counts["ADDRESS", default: 0] == 0, "[\(path)] \(counts) \(output.debugDescription)")
            let without = try AddressModel.$active.withValue(false) { try AddressModelTests.scrub(text, path, seed: 1) }
            #expect(output == without.0, "[\(path)] the model changed \(text.debugDescription): \(output.debugDescription)")
        }
    }

    // MARK: The prefilter

    /// Lines with no number are read only when they hold something an address line has.
    @Test func numberlessLinesNeedACue() {
        for line in ["Hauptstraße, Berlin-Mitte", "Flat B, The Old Rectory", "Honeysuckle Cottage", "rue des Lilas, Nantes", "Strandvejen, Hellerup", "Sallow Lane", "Via Garibaldi, Torino"] {
            #expect(AddressModel.numberlessCue(line), "\(line)")
        }
        for line in ["The program reads its configuration in its place.", "DYLD_LIBRARY_PATH lists directories.", "Send it via email to the team.",
                     "The brigade arrived late.", "take the main road past the old mill"] {
            #expect(!AddressModel.numberlessCue(line), "\(line)")
        }
    }

    /// A long text of ordinary prose with no address gives the model almost nothing to read.
    @Test func proseWithoutNumbersIsSkipped() {
        let paragraph = "The daemon reads its settings at startup and again when it receives a hangup signal. Each option takes a value, and options that are not set keep their defaults. Errors are written to the system log, and the program exits when the configuration cannot be read."
        let text = Array(repeating: paragraph, count: 200).joined(separator: "\n")
        #expect(AddressModel.windows(text).isEmpty)
    }

    // MARK: Helpers

    /// The stand-in that replaced the case's address, with every one of its words gone and the lines around it kept.
    static func replaced(_ sample: Case, _ path: Path, seed: UInt64) throws -> String {
        let (output, counts) = try AddressModelTests.scrub(sample.prose, path, seed: seed)
        let label = "[\(path) seed \(seed)] \(output.debugDescription)"
        let found = try #require(sample.standIn(in: output), "lines and context kept: \(label)")
        #expect(found.1, "lines around it as written: \(label)")
        #expect(SpreadTests.gone(sample.words, from: found.0).isEmpty, "\(SpreadTests.gone(sample.words, from: found.0)) left: \(label)")
        #expect(counts["ADDRESS", default: 0] >= 1, "\(counts) \(label)")
        return found.0
    }

    /// Each postcode-like token's shape: digits as 9, letters as A.
    static func postcodeShapes(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).filter { word in word.contains(where: \.isNumber) && word.count >= 3 }
            .map { String($0.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 }) }.suffix(2)
    }
}
