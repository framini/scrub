import Foundation
@testable import ScrubCore
import Testing

/// False alarms with a general cause, each written the way real mail, chat
/// and court text writes it, and run through a text file, a JSON field and a
/// CSV cell. Every case also holds a real person, so it checks both sides:
/// the person is replaced by a person, and what names no one stays.
struct RuleRegressions {
    struct Case {
        let prose: String
        /// Gone from the output, replaced by a stand-in of `entity`.
        var gone: [String] = []
        var entity = "PERSON"
        /// Written exactly as before, as whole words, as often as before.
        var kept: [String] = []
    }

    static func check(_ sample: Case, seeds: Range<UInt64> = 0..<3) throws {
        for seed in seeds {
            for path in PIIGaps.InputPath.allCases {
                let (data, name) = PIIGaps.wrap(sample.prose, path)
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let output = PIIGaps.readable(result.output, path)
                let shown = "[\(path.rawValue) seed \(seed)] \(output)"
                for word in sample.gone {
                    #expect(!PIIGaps.contains(output, word: word), "kept \(word): \(shown)")
                }
                if !sample.gone.isEmpty { #expect(result.counts[sample.entity, default: 0] > 0, "no \(sample.entity) in \(result.counts): \(shown)") }
                for word in sample.kept {
                    #expect(occurrences(word, in: output) == occurrences(word, in: sample.prose), "changed \(word): \(shown)")
                }
            }
        }
    }

    static func occurrences(_ word: String, in text: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])")
        return pattern.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: Links

    @Test func noWordInsideALinkIsANameOrHandle() throws {
        // "t.co" was read as a handle and the link broken. A person's name that
        // is a whole segment of a link's path is theirs, and takes their stand-in
        // in place; the rest of the link stays as written (see `URLs`).
        try Self.check(Case(prose: "Clip from Thursday's call is up http://t.co/Qx7mPvL2 and Ama Okafor walks through it. Slides: https://www.corvane.test/team/ama-okafor/slides, mirror at files.corvane.test/okafor/deck.pdf",
                            gone: ["Okafor"], kept: ["http://t.co/Qx7mPvL2", "https://www.corvane.test/team", "slides", "files.corvane.test", "deck.pdf"]))
        try Self.check(Case(prose: "lol this is fab!! http://t.co/rT4kWb9Z via @tamsin_vale", kept: ["http://t.co/rT4kWb9Z"]))
        // A handle in a profile link is the person's, and so is the same handle in the text.
        try Self.check(Case(prose: "Ping marisol.quent42 about the refund, her profile is https://social.corvane.test/u/marisol.quent42 if you need it",
                            gone: ["marisol.quent42"], entity: "USERNAME", kept: ["https://social.corvane.test/u", "Ping", "refund"]))
    }

    @Test func linksAreFoundWhereverTheyAreWritten() {
        let text = "see http://t.co/Ab12, www.corvane.test/a?b=c. and mail.corvane.com; not ama@corvane.com or Mr.Okafor"
        let found = Links.ranges(in: text).map { TextRanges.substring(text, $0) }
        #expect(found == ["http://t.co/Ab12", "www.corvane.test/a?b=c", "mail.corvane.com"])
    }

    // MARK: Citations, roles and sentence words

    @Test func articlesOfAConventionAreNoNames() throws {
        // The name model read "Article" and "art." before a number as a person.
        try Self.check(Case(prose: "The applicant, Mr Teodor Valemir, relied on Article 32 § 1 and Article 47 (art. 32-1, art. 47). Rule 52 § 1 of the Rules of Court applied.",
                            gone: ["Valemir"], kept: ["Article", "art", "Rule"]))
    }

    @Test func theWordForWhoseRecordItIsIsNoPartOfTheName() throws {
        // "Customer" opening a sentence was read as the first of the name after it.
        try Self.check(Case(prose: "Customer Tomasz O'Sullivan called twice about the refund. Patient Odalys Ferriter was seen today.",
                            gone: ["Tomasz", "Sullivan", "Odalys", "Ferriter"], kept: ["Customer", "Patient"]))
        try Self.check(Case(prose: "Tenant Tavish Quillmere paid late again; Customer Service called him back on Monday.",
                            gone: ["Tavish", "Quillmere"], kept: ["Tenant", "Customer", "Service"]))
        // A first name that is also a word stays part of the name.
        try Self.check(Case(prose: "Rose Ferriter called twice. Hunter Quillmere signed the lease.", gone: ["Rose", "Ferriter", "Hunter", "Quillmere"]))
    }

    @Test func rolesBesideANameAreNoPartOfIt() throws {
        try Self.check(Case(prose: "The Government were represented by Mr H. Varnholt, Ambassador, Under-Secretary for Legal Affairs, and Ms E. Lindqvane and Mr C. Arneby, Advisers.",
                            gone: ["Varnholt", "Lindqvane", "Arneby"], kept: ["Ambassador", "Advisers"]))
        try Self.check(Case(prose: "The Judge Advocate was appointed by the Chief Naval Judge Advocate. Mr Dariusz Kellowan, the applicant, objected.",
                            gone: ["Kellowan"], kept: ["Judge", "Advocate"]))
    }

    @Test func aSentenceEndingInAnInitialLendsNoWordToAName() throws {
        // "S. The" was read as one person, and "The" then replaced throughout.
        try Self.check(Case(prose: "Before the Court of Appeal the claimant asked that counsel H. be replaced by S. The claimant said that Mr Varnholt had stopped answering. The court refused.",
                            gone: ["Varnholt"], kept: ["The", "the", "S"]))
    }

    // MARK: Mail notices and tables

    @Test func noticeWordsAndDatesAreNoNames() throws {
        try Self.check(Case(prose: "For Gas Day March 4, 2002, nominations are due by 11:30 AM. Interruptible capacity for pipeline day Tuesday is 144 MDt/day.\nQuestions to Odalys Ferriter at 713-555-0142.",
                            gone: ["Ferriter"], kept: ["Gas", "Day", "day", "pipeline"]))
        try Self.check(Case(prose: "The interview will happen Thursday, June 22, 2000. Training sessions: June. 8 9:00 - 10:00 AM, room EB560. Nothing was delivered in May and June.\nThanks, Brannagh Ellery",
                            gone: ["Ellery"], kept: ["June", "May", "Thursday"]))
    }

    @Test func aCompanyNamedWithItsSuffixIsNoOne() throws {
        // The suffix sits after the line's end or after a comma: "J. Abernethy & Company⏎", "Pemberton, Inc.".
        try Self.check(Case(prose: "Subject:\tJ. Abernethy & Company\n\nDoes the desk have any physical gas masters with them? Shares in Pemberton, Inc. and Castlemaine & Co. moved too.\nCall Odalys Ferriter about both.",
                            gone: ["Ferriter"], kept: ["Abernethy", "Pemberton", "Castlemaine"]))
    }

    @Test func aTableOfCountsIsNoID() throws {
        let table = "TRADE DATE\tNA GAS\tNA POWER\tTOTAL TRADE CNT\n11/27/2001\t2016\t662\t3834\n11/26/2001\t2093\t655\t3547\n11/25/2001\t14\t22\t36\n11/24/2001\t3604\t1047\t5533\nSent by Odalys Ferriter on behalf of the desk."
        try Self.check(Case(prose: table, gone: ["Ferriter"], kept: ["662", "3834", "2093", "655", "3547", "3604", "1047", "5533"]))
    }

    // MARK: Names that are words

    @Test func aNameThatIsAWordSpreadsOnlyWithItsCapital() throws {
        // "Hunter" is the person; "the hunter" and "will" are not.
        try Self.check(Case(prose: "Mr Will Hunter called about the late fee. Hunter said the hunter in the photo will be cropped, and the long delay will be refunded.",
                            gone: ["Hunter"], kept: ["hunter", "will", "long"]))
        // A surname column teaches the file the surname; lowercase prose keeps its words.
        let csv = "first_name,last_name,notes\nPriya,Long,called twice\nOren,Rose,\"long delay, the rose bed was damaged\"\n"
        let result = try Scrubber.scrub(Data(csv.utf8), name: "people.csv", forceFullDetection: false, seed: 4)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(output.contains("long delay, the rose bed"), "\(output)")
        #expect(!output.contains(",Long,") && !output.contains(",Rose,"), "\(output)")
    }
}
