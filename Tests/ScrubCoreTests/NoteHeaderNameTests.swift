import Foundation
@testable import ScrubCore
import Testing

/// A clinical note's or a case note's header writes the patient "Last, First"
/// beside a column of other fields: the name is one person, the column's label
/// after it ("MRN#") stays, and the name written later alone takes the same
/// given name. A company named for its trade ("Quillmere Telecom") is no one.
@Suite struct NoteHeaderNameTests {
    static let note = """
    PROGRESS NOTE
    Patient: Ferriter, Odalys    MRN#: 31766448
    DOB: 03/21/1953    Sex: F
    Attending: Dr. Brisa Vantongeren

    S: Odalys is a 73-year-old who presents with a productive cough.
    Ins: Quillmere Telecom member ID W053165199.
    """

    @Test func aPatientWrittenLastFirstIsOnePerson() throws {
        let result = try Scrubber.scrub(Data(Self.note.utf8), name: "note.txt", forceFullDetection: false, seed: 9)
        let output = String(decoding: result.output, as: UTF8.self)
        let words = PersonFields.lowerWords(output)
        #expect(!words.contains("odalys") && !words.contains("ferriter"), "\(output)")
        #expect(output.contains("    MRN#: "), "\(output)")
        // Type oracle: "Last, First" is one person: the surname takes a surname's stand-in, the given
        // name a given name's, and the given name alone later is theirs.
        let surname = try #require(result.findings.first { $0.original == "Ferriter" }, "\(result.findings.map(\.original))")
        let given = try #require(result.findings.first { $0.original == "Odalys" }, "\(result.findings.map(\.original))")
        #expect(output.contains("Patient: \(surname.standIn), \(given.standIn)    MRN#"), "\(output)")
        #expect(Names.last.contains(surname.standIn) && Names.first.contains(given.standIn), "\(surname.standIn), \(given.standIn)")
        #expect(given.places.count == 2, "\(given)")
        #expect(output.contains("Quillmere Telecom member"), "\(output)")
    }
}
