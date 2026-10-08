import Foundation
@testable import ScrubCore
import Testing

@Test(arguments: [
    ("She was born on 1990-01-01 in Ohio.", "1990-01-01", #"\d{4}-\d{2}-\d{2}"#),
    ("maria called about her account, dob 03/14/1985.", "03/14/1985", #"\d{2}/\d{2}/\d{4}"#),
    ("Date of birth: 14.03.1985", "14.03.1985", #"\d{2}\.\d{2}\.\d{4}"#)
])
func birthDatesInFreeText(_ sentence: String, _ original: String, _ shape: String) throws {
    let result = try Scrubber.scrub(Data(sentence.utf8), name: "notes.txt")
    let text = String(decoding: result.output, as: UTF8.self)
    #expect(!text.contains(original))
    if case let .text(preview, marks, _) = result.preview {
        let dates = marks.filter { $0.entity == "DATE_OF_BIRTH" }.map { (preview as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(dates.count == 1)
        #expect(dates.first?.range(of: "^\(shape)$", options: .regularExpression) != nil)
    }
    #expect(result.unresolved.isEmpty)
}

@Test func otherDatesAreKept() throws {
    let result = try Scrubber.scrub(Data("The invoice was issued on 2024-05-01 and paid 05/03/2024.\n".utf8), name: "notes.txt")
    let text = String(decoding: result.output, as: UTF8.self)
    #expect(text.contains("2024-05-01"))
    #expect(text.contains("05/03/2024"))
}

@Test func birthDateFieldsKeepFormat() {
    let job = Job()
    let a = job.replacement(for: "DATE_OF_BIRTH", original: "03/14/1985")
    let b = job.replacement(for: "DATE_OF_BIRTH", original: "1985-03-14")
    #expect(a.range(of: #"^\d{2}/\d{2}/\d{4}$"#, options: .regularExpression) != nil && a != "03/14/1985")
    #expect(b.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil && b != "1985-03-14")
}

/// A support ticket that quotes the birth date two ways round, and again in
/// words: each is the one day, its stand-in the same day in that spelling.
@Test func aBirthDateWrittenAnotherWayInATicketIsTheSameDay() throws {
    let ticket = """
    Ticket #48213 - Identity check stuck in review
    Priority: High   Assignee: support-tier2   Created: 2026-09-14 10:41 UTC

    Hi Ottoline,

    Your verification was flagged because the date of birth you entered, 03/07/1984, didn't match the bureau's 07/03/1984. \
    The old card on file reads 7 March 1984. Could you confirm which is right?

    Best,
    Verification Ops

    """
    let result = try Scrubber.scrub(Data(ticket.utf8), name: "Pasted text")
    let text = String(decoding: result.output, as: UTF8.self)
    for original in ["03/07/1984", "07/03/1984", "7 March 1984"] { #expect(!text.contains(original), "\(original) left: \(text)") }
    #expect(text.contains("Created: 2026-09-14 10:41 UTC"), "\(text)")
    let entered = try #require(text.firstMatch(of: /entered, (\d{2})\/(\d{2})\/(\d{4})/))
    let bureau = try #require(text.firstMatch(of: /bureau's (\d{2})\/(\d{2})\/(\d{4})/))
    #expect(entered.1 == bureau.2 && entered.2 == bureau.1 && entered.3 == bureau.3, "\(text)")
}

/// A chat where the agent asks for the birth date and the customer answers on
/// the next line, with a year of two digits: the answer is the birth date, in
/// its own spelling; a date the chat names otherwise stays.
@Test func aBirthDateGivenInAnswerToTheQuestionIsReplaced() throws {
    let chat = """
    [14:03:05] agent_lena: thanks for waiting. can you confirm your email and dob?
    [14:03:31] customer: ottoline.w@example.com and 12/9/95
    [14:04:10] agent_lena: got it. your parcel from 10/2/26 is still on hold
    [14:05:20] agent_lena: i'll pass this to the risk team

    """
    let result = try Scrubber.scrub(Data(chat.utf8), name: "Pasted text")
    let text = String(decoding: result.output, as: UTF8.self)
    #expect(!text.contains("12/9/95"), "\(text)")
    let answer = try #require(text.firstMatch(of: /example\.\w+ and (\d{1,2})\/(\d{1,2})\/(\d{2})\n/), "\(text)")
    #expect(Int(answer.1).map { (1...12).contains($0) } == true && Int(answer.2).map { (1...31).contains($0) } == true, "\(text)")
    #expect(text.contains("your parcel from 10/2/26 is still on hold"), "\(text)")
}

@Test func aBirthDateWrittenInlineEndsWhereTheLineGoesOn() throws {
    // The value after "DOB:" ran to the line's end, so the stand-in date kept the rest of the line as written,
    // the address and the card numbers after it among them.
    let note = """
    Ottoline Wexcombe, DOB: 1984-03-07, Ticket: 88213, Address: 4821 Juniper Hollow Rd, Tacoma, WA 98402.
    Vaccination record for Tobiah Quennell, DOB: 1961-06-10. Vaccine: MMR, Provider: Dr. Ama Okafor, Larchmont Family Clinic, 9769 Larchmont Ave, Albany, NY 12203.
    **Date of Births**: 1958-08-17 and 1961-02-03 will be retained for 10 years. **Credit Card Numbers**: 4111111111111111 and 5500005555555559 will be stored.
    """
    let text = String(decoding: try Scrubber.scrub(Data(note.utf8), name: "notes.txt").output, as: UTF8.self)
    for gone in ["1984-03-07", "Juniper Hollow", "1961-06-10", "Larchmont Ave", "1958-08-17", "1961-02-03", "4111111111111111", "5500005555555559"] {
        #expect(!text.contains(gone), "\(gone): \(text)")
    }
    for kept in [", Ticket: 88213, Address: ", ". Vaccine: MMR, Provider: Dr. ", " will be retained for 10 years. **Credit Card Numbers**: "] { #expect(text.contains(kept), "\(kept): \(text)") }
    #expect(text.firstMatch(of: /DOB: \d{4}-\d{2}-\d{2}, Ticket/) != nil && text.firstMatch(of: /\*\*Date of Births\*\*: \d{4}-\d{2}-\d{2} and \d{4}-\d{2}-\d{2} will/) != nil, "\(text)")
}

/// A birth date under a key that names one in another language ("naissance", "nascimento", "doğum",
/// "năm sinh") is replaced as one under "date_of_birth" is, not left for review; a birthplace under
/// such a key ("pays_de_naissance", "cidade_nascimento") is a place, not a date.
@Test(arguments: ["json", "csv"])
func birthDatesUnderOtherLanguagesKeysAreReplaced(_ format: String) throws {
    let records: [[(String, String)]] = [
        [("nom", "Lemaire"), ("prenom", "Solène"), ("naissance", "14/02/1986"), ("pays_de_naissance", "Belgique")],
        [("nome", "Thiago Moura"), ("nascimento", "1979-11-03"), ("cidade_nascimento", "Recife"), ("dt_nasc", "03/11/1979")],
        [("ad_soyad", "Elif Aydın"), ("dogum", "21.06.1990"), ("dogum_yeri", "Bursa")],
        [("ho_ten", "Trần Thị Thu"), ("nam_sinh", "1988"), ("noi_sinh", "Huế")],
        [("nombre", "Iker Salazar"), ("nacimiento", "1975-03-09"), ("pais_nacimiento", "Chile")],
        [("nome", "Chiara Bassi"), ("nascita", "07/08/1983"), ("luogo_nascita", "Parma")],
        [("naam", "Daan Smit"), ("geboren", "12-04-1969"), ("geboorteplaats", "Utrecht")],
    ]
    for fields in records {
        let body: String, name: String
        if format == "json" {
            body = "{" + fields.map { #""\#($0.0)": "\#($0.1)""# }.joined(separator: ", ") + "}"; name = "record.json"
        } else {
            body = fields.map(\.0).joined(separator: ",") + "\n" + fields.map(\.1).joined(separator: ",") + "\n"; name = "record.csv"
        }
        let result = try Scrubber.scrub(Data(body.utf8), name: name, forceFullDetection: false, seed: 12)
        let output = String(decoding: result.output, as: UTF8.self)
        for (key, value) in fields where KeyHints.hint(key) == "DATE_OF_BIRTH" {
            #expect(!output.contains(value), "[\(format)] \(key): \(value) left: \(output)")
            let finding = result.findings.first { $0.original == value }
            #expect(finding?.entity == "DATE_OF_BIRTH" && finding?.needsReview == false, "[\(format)] \(key): \(finding.map { "\($0.entity) review \($0.needsReview)" } ?? "none")")
        }
        for (key, value) in fields where ["pays_de_naissance", "cidade_nascimento", "pais_nacimiento", "luogo_nascita"].contains(key) {
            #expect(result.findings.first { $0.original == value }?.entity != "DATE_OF_BIRTH", "[\(format)] \(key): \(value)")
        }
    }
}

/// A birth written as an object of its own under such a key ("naissance": {"date": …}) holds the birth date.
@Test func aBirthObjectUnderAnotherLanguagesKeyHoldsTheDate() throws {
    let bodies = [
        (#"{"titulaire":{"nom":"Lemaire","naissance":{"date":"14/02/1986","lieu":"Namur"}},"conjoint":{"nom":"Lemaire","naissance":"1984-07-30"}}"#, ["14/02/1986", "1984-07-30"]),
        (#"{"cliente":{"nome":"Thiago Moura","nascimento":{"data":"03/11/1979","cidade":"Recife"}},"dependentes":[{"nome":"Davi Moura","nascimento":"2012-05-19"}]}"#, ["03/11/1979", "2012-05-19"]),
        (#"{"musteri":{"ad":"Elif","soyad":"Aydın","dogum":{"tarih":"21.06.1990","yer":"Bursa"}}}"#, ["21.06.1990"]),
    ]
    for (body, dates) in bodies {
        let result = try Scrubber.scrub(Data(body.utf8), name: "record.json", forceFullDetection: false, seed: 5)
        let output = String(decoding: result.output, as: UTF8.self)
        for date in dates {
            #expect(!output.contains(date), "\(date) left: \(output)")
            #expect(result.findings.first { $0.original == date }.map { $0.entity == "DATE_OF_BIRTH" && !$0.needsReview } == true, "\(date): \(result.findings.map { "\($0.entity) \($0.original) \($0.needsReview)" })")
        }
    }
}

/// A place in a birth's own object is a birthplace, whatever language keys it ("naissance": {"lieu": …},
/// "nacimiento": {"lugar": …}, "birth": {"place": …}): replaced, with the birth date beside it.
@Test func aPlaceInABirthObjectIsABirthplace() throws {
    let bodies = [
        (#"{"personne":{"nom":"Dufrasne","prenom":"Agathe","naissance":{"date":"1984-06-12","lieu":"Namur"}}}"#, "Namur"),
        (#"{"solicitante":{"nombre":"Inés Garrido","nacimiento":{"fecha":"1991-02-27","lugar":"Salamanca"}}}"#, "Salamanca"),
        (#"{"applicant":{"name":"Corwin Ashby","birth":{"date":"1977-10-05","place":"Bristol"}}}"#, "Bristol"),
        (#"{"cliente":{"nome":"Davi Moura","nascimento":{"data":"2001-09-14","cidade":"Recife"}}}"#, "Recife"),
    ]
    for (body, place) in bodies {
        let result = try Scrubber.scrub(Data(body.utf8), name: "record.json", forceFullDetection: false, seed: 8)
        let output = String(decoding: result.output, as: UTF8.self)
        #expect(!output.contains(place), "\(place) left: \(output)")
        #expect(result.findings.first { $0.original == place }.map { $0.entity != "DATE_OF_BIRTH" && !$0.needsReview } == true, "\(place): \(result.findings.map { "\($0.entity) \($0.original) \($0.needsReview)" })")
        #expect(try JSONSerialization.jsonObject(with: result.output) is [String: Any])
    }
}
