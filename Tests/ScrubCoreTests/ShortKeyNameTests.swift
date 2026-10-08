import Foundation
@testable import ScrubCore
import Testing

/// Vendors write a person's name under keys of a letter or two, under a type a
/// sibling names, and under a holder's key in capitals: each is replaced whole,
/// and one person's name parts keep one stand-in across the records about them.
struct ShortKeyNameTests {
    static func scrub(_ text: String, _ file: String = "response.json", seed: UInt64 = 5) throws -> (ScrubResult, String, Any?) {
        let result = try Scrubber.scrub(Data(text.utf8), name: file, forceFullDetection: false, seed: seed)
        return (result, String(decoding: result.output, as: UTF8.self), try? JSONSerialization.jsonObject(with: result.output))
    }
    static func words(_ text: String) -> Set<String> { Set(text.lowercased().split { !$0.isLetter }.map(String.init)) }

    /// "N": {"F": …, "L": …} and "nm": "…" beside "em" and "dob".
    @Test func aNameUnderAShortKeyIsReplacedWhole() throws {
        let documents = [
            #"{"RequestId": "c1f0", "Input": {"N": {"F": "Tadeusz", "L": "Wroblewski"}, "Dob": "1988-03-14", "Emails": ["tw88@example.com"]}, "Match": {"Name": "PARTIAL"}}"#,
            #"{"Applicant": {"N": {"F": "Ifeoma", "M": "Adaeze", "L": "Okonkwo"}, "Dob": "1979-11-02"}}"#,
            #"{"results": [{"row": 0, "input": {"nm": "Wiremu Tawhiri", "dob": "19670412", "em": "wtawhiri@example.net"}}, {"row": 1, "input": {"nm": "Zofia Kaczmarczyk", "dob": "1990-06-30", "em": "zofia.k@example.org"}}]}"#,
        ]
        for document in documents {
            let (result, output, parsed) = try Self.scrub(document)
            #expect(parsed != nil, "\(output)")
            for name in ["Tadeusz", "Wroblewski", "Ifeoma", "Adaeze", "Okonkwo", "Wiremu", "Tawhiri", "Zofia", "Kaczmarczyk"] where document.contains(name) {
                #expect(!Self.words(output).contains(name.lowercased()), "\(name) kept: \(output)")
            }
            #expect(!result.findings.contains { $0.suspected }, "\(result.findings.filter(\.suspected).map(\.original))")
        }
        // Under a key of one letter with no name around it, a letter names nothing: "F": "Fahrenheit" stays.
        let (_, output, _) = try Self.scrub(#"{"unit": {"F": "Fahrenheit", "L": "liquid"}, "N": 12}"#)
        #expect(output == #"{"unit": {"F": "Fahrenheit", "L": "liquid"}, "N": 12}"#)
    }

    /// {"attribute": "NAME_FIRST", "text": …}: the sibling names the field its text holds.
    @Test func aTypedPairsTextIsReadAsItsType() throws {
        let document = #"{"session": "s-81", "attributes": [{"attribute": "NAME_LAST", "text": "Adebayo-Coker", "verified": true}, {"attribute": "NAME_FIRST", "text": "Temitope", "verified": false}, {"attribute": "STATUS_NOTE", "text": "Reviewed", "verified": true}]}"#
        let (_, output, parsed) = try Self.scrub(document)
        #expect(parsed != nil)
        #expect(!output.contains("Temitope") && !output.contains("Adebayo") && !output.contains("Coker"), "\(output)")
        #expect(output.contains(#""text": "Reviewed""#), "\(output)")
    }

    /// A card holder's name in capitals, a surname's particle among its words, is replaced whole.
    @Test func aHoldersNameInCapitalsIsReplacedWhole() throws {
        let (_, output, _) = try Self.scrub(#"{"payment": {"card": {"bin": "411111", "last4": "0915", "holder": "MAARTJE VAN DER LINDT"}}}"#)
        #expect(!Self.words(output).contains("maartje") && !Self.words(output).contains("lindt"), "\(output)")
    }

    /// A person's names across an identity graph's records: their first name, written again
    /// with a prior surname, keeps one stand-in, and given names in a name written family
    /// first follow the name they are part of.
    @Test func onePersonsFirstNameKeepsOneStandInAcrossTheirNames() throws {
        let graph = #"{"person_id": "P-1", "names": [{"first": "Saoirse", "last": "Quilligan", "type": "PRIMARY"}, {"first": "Saoirse", "last": "Brennock", "type": "PRIOR_NAME"}], "emails": [{"address": "squilligan@example.net"}]}"#
        for seed: UInt64 in 1...4 {
            let (result, output, _) = try Self.scrub(graph, seed: seed)
            let firsts = Set(result.findings.filter { $0.original == "Saoirse" }.map(\.standIn))
            #expect(firsts.count == 1, "seed \(seed): \(firsts)\n\(output)")
        }
        let familyFirst = #"{"person": {"name": {"given": "Hinata", "family": "Morikawa", "full": "Morikawa Hinata"}, "dob": "1991-09-08"}}"#
        for seed: UInt64 in 1...4 {
            let (_, _, parsed) = try Self.scrub(familyFirst, seed: seed)
            let name = try #require(((parsed as? [String: Any])?["person"] as? [String: Any])?["name"] as? [String: String])
            let given = try #require(name["given"]), family = try #require(name["family"]), full = try #require(name["full"])
            #expect(Set(full.split(separator: " ").map(String.init)) == [given, family], "seed \(seed): \(name)")
        }
    }

    /// {"k": "NAME_FIRST", "v": …}: a field named by a letter's key, its value under another.
    @Test func aKeyValuePairsValueIsReadAsItsKey() throws {
        let document = #"{"attributes": [{"k": "NAME_FIRST", "v": "Rangi", "verified": true}, {"k": "NAME_LAST", "v": "Paewai", "verified": false}, {"k": "CHANNEL", "v": "Mobile", "verified": true}]}"#
        let (_, output, parsed) = try Self.scrub(document)
        #expect(parsed != nil && !output.contains("Rangi") && !output.contains("Paewai"), "\(output)")
        #expect(output.contains(#""v": "Mobile""#), "\(output)")
    }

    /// A credit header's records name one person again and again, each with another name
    /// they are also known by: the person keeps one stand-in in every record, and each other
    /// name its own.
    @Test func aRecordsOtherNamesAreNotItsPersons() throws {
        let document = #"{"Records": [{"seq": 1, "name": "LUCIA MARCHETTI", "dob": "06/07/1950", "aka": ["MARCHETTI, ORNELLA"]}, {"seq": 2, "name": "LUCIA MARCHETTI", "dob": "19500607"}, {"seq": 3, "name": "Marchetti, Lucia", "dob": "06/07/1950", "aka": ["MARCHETTI, SAVERIA"]}]}"#
        for seed: UInt64 in 1...4 {
            let (result, output, _) = try Self.scrub(document, seed: seed)
            let person = Set(result.findings.filter { $0.original.uppercased().contains("LUCIA") }.map { $0.standIn.uppercased().split(whereSeparator: { !$0.isLetter }).sorted() })
            #expect(person.count == 1, "seed \(seed): \(output)")
            let others = result.findings.filter { $0.original.contains("ORNELLA") || $0.original.contains("SAVERIA") }.map { $0.standIn.uppercased().split(whereSeparator: { !$0.isLetter }).sorted() }
            #expect(others.count == 2 && !others.contains { person.contains($0) }, "seed \(seed): \(output)")
        }
    }

    /// A record with no name key of its own writes a person's two names side by side under keys
    /// that only say which part each is: a credit header's request, a household's people, a
    /// screening's subject. Every part goes, in a file and pasted, and the phone beside them too.
    @Test func aNamesTwoPartsSideBySideAreReplaced() throws {
        let documents: [(String, [String])] = [
            (#"{"inquiry": {"ref": "Q-20417", "subj": {"fn": "RADOSLAW", "ln": "KOWALCZYK", "dob": "19811203", "ph": 3125550147}}}"#, ["RADOSLAW", "KOWALCZYK", "3125550147"]),
            (#"{"case": "HH-881", "subject": {"first": "ORLAITH", "last": "DUNPHY", "dob": "03/14/1962"}, "spouse": {"first": "BREANDAN", "last": "DUNPHY"}}"#, ["ORLAITH", "DUNPHY", "BREANDAN"]),
            (#"{"screening": {"id": "scr_5521", "subject": {"given": "Marisol", "family": "Etxeberria", "nationality": "ES"}}}"#, ["Marisol", "Etxeberria"]),
            (#"{"request_id": "rq-7", "applicant": {"first_nm": "Sigrun", "last_nm": "Haldorsen", "dob": "1984-05-09"}}"#, ["Sigrun", "Haldorsen"]),
        ]
        for (document, originals) in documents {
            for file in ["response.json", "Pasted text"] {
                let (result, output, parsed) = try Self.scrub(document, file)
                #expect(parsed != nil, "\(output)")
                for original in originals {
                    #expect(!output.contains(original), "[\(file)] \(original) kept: \(output)")
                }
                // A surname is a name's stand-in, never a place's.
                #expect(!result.findings.contains { originals.contains($0.original) && !["FIRST_NAME", "LAST_NAME", "PERSON", "PHONE_NUMBER"].contains($0.entity) },
                        "[\(file)] \(result.findings.map { "\($0.entity) \($0.original)" })")
            }
        }
    }

    /// The same pairs as an XML subject's attributes or elements and as a bureau export's columns.
    @Test func aNamesTwoPartsSideBySideAreReplacedInXMLAndCSV() throws {
        let documents: [(String, String, [String])] = [
            (#"<inquiry ref="Q-20417"><subj fn="RADOSLAW" ln="KOWALCZYK" dob="19811203"/></inquiry>"#, "inquiry.xml", ["RADOSLAW", "KOWALCZYK"]),
            (#"<case id="HH-881"><spouse><gn>Breandan</gn><sur>Dunphy</sur></spouse></case>"#, "case.xml", ["Breandan", "Dunphy"]),
            ("ref,fn,ln,dob,ph\nQ-20417,RADOSLAW,KOWALCZYK,19811203,3125550147\nQ-20418,Sigrun,Haldorsen,19840509,3125550162\n", "export.csv", ["RADOSLAW", "KOWALCZYK", "3125550147", "Sigrun", "Haldorsen", "3125550162"]),
        ]
        for (document, file, originals) in documents {
            let (_, output, _) = try Self.scrub(document, file)
            for original in originals { #expect(!output.contains(original), "[\(file)] \(original) kept: \(output)") }
        }
        // A report's first and last pages stay.
        let pages = "report,first,last\nR-1,1,9\nR-2,10,14\n"
        #expect(try Self.scrub(pages, "pages.csv").1 == pages)
    }

    /// "first" and "last" say where a page, a range or a week starts and ends as often:
    /// what they hold there is no name, and stays.
    @Test func aPagesOrAWeeksFirstAndLastStay() throws {
        let documents = [
            #"{"page": {"first": 1, "last": 9, "size": 50}}"#,
            #"{"hours": {"first": "Monday", "last": "Friday", "open": "09:00"}}"#,
            #"{"events": {"first": "evt_8KxQ21aa", "last": "evt_9LmR04bb"}}"#,
            #"{"links": {"first": "/v1/checks?page=1", "last": "/v1/checks?page=7"}}"#,
        ]
        for document in documents {
            let (_, output, _) = try Self.scrub(document)
            #expect(output == document, "\(output)")
        }
    }

    /// A name in another script and its transliteration, under keys a script's or a language's code ends
    /// ("nameKanji", "nameKo", "nameLatn") or a transliteration's name ("pinyin", "romaji"), is the
    /// person's: every form is replaced, and with the Latin one beside it takes that one's stand-in.
    @Test func aNameWrittenInAnotherScriptIsReplacedInEveryForm() throws {
        let documents: [(String, [String])] = [
            (#"{"applicant_id": "app_7731", "name": "黄丽华", "pinyin": "HUANG LIHUA", "id_card_type": "resident"}"#, ["HUANG", "LIHUA", "黄丽华"]),
            (#"{"name": "森田 健二", "romaji": "MORITA Kenji", "birth": "1973/02/12"}"#, ["MORITA", "Kenji", "森田"]),
            (#"{"applicant": {"nameKanji": "森田 彩花", "nameKana": "モリタ アヤカ", "nameRomaji": "MORITA AYAKA", "dob": "1995-03-10"}}"#, ["森田", "彩花", "モリタ", "アヤカ", "MORITA", "AYAKA"]),
            (#"{"holder": {"nameKo": "박서윤", "nameRomanized": "Park Seoyun", "phone": "+82 10-5555-0142"}}"#, ["박서윤", "Seoyun"]),
            (#"{"customer": {"nameAr": "خالد الدوسري", "nameLatn": "Khalid Al-Dawsari", "email": "k.dawsari@example.org"}}"#, ["خالد", "الدوسري", "Khalid", "Dawsari"]),
            (#"{"subject": {"full_name": "Daria Volkova", "nameRu": "Дарья Волкова"}}"#, ["Дарья", "Волкова", "Daria", "Volkova"]),
            (#"{"fullName": "Nikos Andreou", "altName": "Νίκος Ανδρέου", "email": "nikos.andreou@example.com"}"#, ["Νίκος", "Ανδρέου", "Nikos", "Andreou"]),
            (#"{"naam": "अनन्या कुलकर्णी", "pita_ka_naam": "विनोद कुलकर्णी", "mobile": "+91 98450 55501"}"#, ["अनन्या", "कुलकर्णी", "विनोद"]),
        ]
        for (document, originals) in documents {
            let (result, output, parsed) = try Self.scrub(document)
            #expect(parsed != nil, "\(output)")
            for original in originals { #expect(!output.contains(original), "\(original) kept: \(output)") }
            #expect(!result.findings.contains { $0.suspected }, "\(result.findings.filter(\.suspected).map(\.original))")
        }
        // The transliteration is the person the name beside it is: one stand-in for both.
        let (_, output, parsed) = try Self.scrub(#"{"applicant": {"nameKanji": "森田 彩花", "nameRomaji": "MORITA AYAKA", "nameKana": "モリタ アヤカ"}}"#)
        let applicant = try #require((parsed as? [String: Any])?["applicant"] as? [String: String], "\(output)")
        #expect(applicant["nameRomaji"] == applicant["nameKanji"]?.uppercased() && applicant["nameKana"] == applicant["nameKanji"], "\(output)")
        // A romanised name written family name first, in capitals, keeps that order.
        let (_, romaji, romajiParsed) = try Self.scrub(#"{"name": "森田 健二", "romaji": "MORITA Kenji", "birth": "1973/02/12"}"#)
        let written = try #require((romajiParsed as? [String: String])?["romaji"]).split(separator: " ")
        #expect(written.count == 2 && written[0] == written[0].uppercased() && written[1] != written[1].uppercased(), "\(romaji)")
        // In a log line too.
        let (_, line, _) = try Self.scrub("2026-10-06 INFO lookup {\"name\":\"黄丽华\",\"pinyin\":\"HUANG LIHUA\"}\n", "lookup.log")
        #expect(!line.contains("HUANG") && !line.contains("LIHUA"), "\(line)")
    }

    /// "given" beside "surname", in a file and in a payload a log line quotes, is the first name.
    @Test func aGivenNameBesideASurnameIsReplaced() throws {
        let (_, output, _) = try Self.scrub(#"{"records": [{"surname": "Thorvaldsen", "given": "Sigrun", "city": "Aalborg"}]}"#)
        #expect(!output.contains("Sigrun") && !output.contains("Thorvaldsen"), "\(output)")
        let (_, line, _) = try Self.scrub("2026-10-06 WARN vendor said: payload={\"surname\":\"Thorvaldsen\",\"given\":\"Sigrun\",\"dob\":\"1997-05-23\"}\n", "worker.log")
        #expect(!line.contains("Sigrun") && !line.contains("Thorvaldsen"), "\(line)")
        let (_, escaped, _) = try Self.scrub(#"{"id": "wh_1", "raw": "{\"surname\": \"Thorvaldsen\", \"given\": \"Sigrun\", \"city\": \"Aalborg\"}"}"#)
        #expect(!escaped.contains("Sigrun") && !escaped.contains("Thorvaldsen"), "\(escaped)")
    }

    /// A relative's name ("nome_mae", "mothersMaidenName", "fatherName") is a person's, someone other
    /// than the record's own: never a city, and never the subject's stand-in surname for another one.
    @Test func aRelativesNameIsAnotherPersons() throws {
        let (result, output, parsed) = try Self.scrub(#"{"nome": "TIAGO MOREIRA DOS SANTOS", "nome_mae": "ROSANGELA MOREIRA", "cpf_status": "REGULAR"}"#)
        let record = try #require(parsed as? [String: String], "\(output)")
        for original in ["TIAGO", "ROSANGELA", "MOREIRA", "SANTOS"] { #expect(!output.contains(original), "\(original) kept: \(output)") }
        #expect(result.findings.first { $0.original == "ROSANGELA MOREIRA" }?.entity == "PERSON", "\(output)")
        // The whole name keeps its four words and its particle.
        let nome = try #require(record["nome"]).split(separator: " ")
        #expect(nome.count == 4 && nome[2] == "DOS", "\(output)")
        let (_, spanish, _) = try Self.scrub(#"{"nombre": "Lucía Fernanda de la Vega", "fecha_nacimiento": "1990-01-02"}"#)
        let nombre = try #require((try JSONSerialization.jsonObject(with: Data(spanish.utf8)) as? [String: String])?["nombre"])
        #expect(nombre.split(separator: " ").count == 5 && nombre.contains(" de la "), "\(spanish)")
        #expect(!spanish.contains("Lucía") && !spanish.contains("Vega") && !spanish.contains("Fernanda"), "\(spanish)")
        let (_, mother, parsedMother) = try Self.scrub(#"{"firstName": "Inés", "lastName": "Cárdenas", "mothersMaidenName": "Villalobos", "fatherName": "Ramiro Cárdenas"}"#)
        let fields = try #require(parsedMother as? [String: String], "\(mother)")
        #expect(fields["mothersMaidenName"] != fields["lastName"] && fields["mothersMaidenName"] != "Villalobos", "\(mother)")
        // The father shares the subject's surname, and so do their stand-ins.
        #expect(fields["fatherName"]?.hasSuffix(" " + (fields["lastName"] ?? "?")) == true && fields["fatherName"]?.hasPrefix("Ramiro") == false, "\(mother)")
    }

    /// Keys a vendor abbreviates or writes in another language: "natId", "doc_no", "ngaySinh", "diaChi",
    /// and an address under a country's code ("addressJP"), each read as the field it names.
    @Test func anAbbreviatedOrForeignKeyIsReadAsItsField() throws {
        let documents: [(String, [String])] = [
            (#"{"nm": "Hessa Al-Mutairi", "natId": "1047392651", "dob": "1988-11-11"}"#, ["1047392651", "Hessa"]),
            (#"{"document": {"type": "passport", "doc_no": "QW4E8R2T6", "issuing_state": "UTO"}, "holder": {"name": "Brigitta Lindqvist"}}"#, ["QW4E8R2T6"]),
            (#"{"hoTen": "Trần Thị Mai", "ngaySinh": "02/11/1992", "diaChi": "45 Đường Hai Bà Trưng, Quận 3, TP. Hồ Chí Minh"}"#, ["02/11/1992", "Hai Bà Trưng"]),
            (#"{"name": "Haruka Ishikawa", "addressJP": "〒530-0001 大阪府大阪市北区梅田3-1-3 グランフロント 12F"}"#, ["梅田3-1-3", "グランフロント"]),
        ]
        for (document, originals) in documents {
            let (_, output, parsed) = try Self.scrub(document)
            #expect(parsed != nil, "\(output)")
            for original in originals { #expect(!output.contains(original), "\(original) kept: \(output)") }
        }
        // A card's number under "doc_no" takes the stand-in its zone's number takes.
        let card = #"{"doc_scan": {"type": "ID_CARD", "mrz_raw": "I<UTOLX4R8T2N61<<<<<<<<<<<<<<<\n9002144F3309173UTO<<<<<<<<<<<6\nBRANDVOLD<<ODA<<<<<<<<<<<<<<<<", "fields": {"last_name": "BRANDVOLD", "first_name": "ODA", "doc_no": "LX4R8T2N6", "dob": "14.02.1990"}}}"#
        let (_, output, parsed) = try Self.scrub(card)
        let scan = try #require((parsed as? [String: Any])?["doc_scan"] as? [String: Any], "\(output)")
        let number = try #require((scan["fields"] as? [String: String])?["doc_no"])
        let zone = try #require(scan["mrz_raw"] as? String)
        #expect(number != "LX4R8T2N6" && !zone.contains("LX4R8T2N6") && zone.hasPrefix("I<UTO" + number), "\(output)")
    }
}
