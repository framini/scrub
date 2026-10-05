import Foundation
@testable import ScrubCore
import Testing

/// A birth date's month and day written in fields of their own take that
/// part of the record's stand-in birth date, whatever order the fields come
/// in and however they are written: a month is never taken for a day, and
/// neither keeps the real value once the date has changed.
@Suite struct BirthPartTests {
    enum Shape: String, CaseIterable, Sendable { case json, csv, xml }
    /// How the parts are written: as numbers, zero-padded, or the month by name.
    enum Style: String, CaseIterable, Sendable { case number, padded, named }

    struct Person {
        let name: String, year: Int, month: Int, day: Int
        var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    }
    // Month and day alike, and apart, so a month taken for a day shows.
    static let people = [
        Person(name: "Odalys Ferriter", year: 1990, month: 3, day: 3),
        Person(name: "Bram Quillmere", year: 1984, month: 11, day: 4),
        Person(name: "Ysolde Varrick", year: 1977, month: 7, day: 21),
    ]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    static func month(_ person: Person, _ style: Style) -> String {
        switch style {
        case .number: String(person.month)
        case .padded: String(format: "%02d", person.month)
        case .named: months[person.month - 1]
        }
    }
    static func day(_ person: Person, _ style: Style) -> String { style == .number ? String(person.day) : String(format: "%02d", person.day) }

    static func input(_ shape: Shape, _ style: Style, partsFirst: Bool) -> (name: String, data: Data) {
        let quoted = style != .number
        let text: String
        switch shape {
        case .json:
            let rows = people.map { p in
                let m = quoted ? "\"\(month(p, style))\"" : month(p, style), d = quoted ? "\"\(day(p, style))\"" : day(p, style)
                let parts = #""birth_month": \#(m), "birth_day": \#(d)"#, date = #""date_of_birth": "\#(p.iso)""#
                let name = #""name": "\#(p.name)""#
                return "{" + name + ", " + (partsFirst ? parts + ", " + date : date + ", " + parts) + "}"
            }
            text = #"{"patients": ["# + rows.joined(separator: ", ") + "]}"
        case .csv:
            let header = partsFirst ? "name,birth_month,birth_day,date_of_birth" : "name,date_of_birth,birth_month,birth_day"
            text = ([header] + people.map { p in partsFirst ? "\(p.name),\(month(p, style)),\(day(p, style)),\(p.iso)" : "\(p.name),\(p.iso),\(month(p, style)),\(day(p, style))" }).joined(separator: "\n") + "\n"
        case .xml:
            text = "<patients>" + people.map { p in
                let parts = "<birthMonth>\(month(p, style))</birthMonth><birthDay>\(day(p, style))</birthDay>", date = "<dob>\(p.iso)</dob>"
                return "<patient><name>\(p.name)</name>" + (partsFirst ? parts + date : date + parts) + "</patient>"
            }.joined() + "</patients>"
        }
        return ("patients." + shape.rawValue, Data(text.utf8))
    }

    /// Each record's stand-in date, month and day, as the output writes them.
    static func records(_ output: Data, _ shape: Shape) throws -> [(date: String, month: String, day: String)] {
        switch shape {
        case .json:
            let root = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
            let rows = try #require(root["patients"] as? [[String: Any]])
            return rows.map { ("\($0["date_of_birth"] ?? "")", "\($0["birth_month"] ?? "")", "\($0["birth_day"] ?? "")") }
        case .csv:
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            let header = try #require(lines.first)
            let date = try #require(header.firstIndex(of: "date_of_birth")), month = try #require(header.firstIndex(of: "birth_month")), day = try #require(header.firstIndex(of: "birth_day"))
            return lines.dropFirst().map { ($0[date], $0[month], $0[day]) }
        case .xml:
            let document = try XMLDocument(data: output, options: [])
            return try document.nodes(forXPath: "//patient").map { node in
                func text(_ name: String) throws -> String { try node.nodes(forXPath: name).first?.stringValue ?? "" }
                return (try text("dob"), try text("birthMonth"), try text("birthDay"))
            }
        }
    }

    /// A month as a number, read from digits or a name.
    static func monthNumber(_ written: String) -> Int? { Int(written) ?? months.firstIndex { $0.lowercased() == written.lowercased() }.map { $0 + 1 } }

    @Test(arguments: Shape.allCases, Style.allCases)
    func thePartsAgreeWithTheStandInDate(_ shape: Shape, _ style: Style) throws {
        for partsFirst in [false, true] {
            for seed in UInt64(0)..<6 {
                let input = Self.input(shape, style, partsFirst: partsFirst)
                let result = try Scrubber.scrub(input.data, name: input.name, forceFullDetection: false, seed: seed)
                let rows = try Self.records(result.output, shape)
                try #require(rows.count == Self.people.count, "\(shape): \(String(decoding: result.output, as: UTF8.self))")
                for (person, row) in zip(Self.people, rows) {
                    let context = "\(shape) \(style) partsFirst=\(partsFirst) seed \(seed): \(row)"
                    // Type oracle: an ISO date, a month of the year, a day of the month, each written as the original was.
                    let parts = row.date.split(separator: "-").compactMap { Int($0) }
                    try #require(parts.count == 3 && row.date.count == 10, "\(context)")
                    let month = try #require(Self.monthNumber(row.month), "\(context)")
                    let day = try #require(Int(row.day), "\(context)")
                    #expect((1...12).contains(month) && (1...31).contains(day), "\(context)")
                    #expect(style != .number || !row.month.hasPrefix("0") && !row.day.hasPrefix("0"), "\(context)")
                    #expect(style != .named || Self.months.contains(row.month), "\(context)")
                    #expect(style != .padded || (Self.month(person, style).first != "0" || row.month.count == 2) && (Self.day(person, style).first != "0" || row.day.count == 2), "\(context)")
                    // The parts are the stand-in date's own.
                    #expect(month == parts[1] && day == parts[2], "\(context)")
                    // And none is the real one.
                    #expect(row.date != person.iso && month != person.month && day != person.day, "\(context)")
                }
            }
        }
    }

    /// A date written as an object of its parts beside the full date: each part is the stand-in date's.
    @Test func aDateObjectsPartsFollowTheDateBesideIt() throws {
        for seed in UInt64(0)..<8 {
            let input = #"{"patient": {"name": "Odalys Ferriter", "dob": {"month": 3, "day": 3, "year": 1990}, "date_of_birth": "1990-03-03"}}"#
            let result = try Scrubber.scrub(Data(input.utf8), name: "patient.json", forceFullDetection: false, seed: seed)
            let root = try #require(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
            let patient = try #require(root["patient"] as? [String: Any])
            let dob = try #require(patient["dob"] as? [String: Any])
            let date = try #require(patient["date_of_birth"] as? String).split(separator: "-").compactMap { Int($0) }
            try #require(date.count == 3)
            #expect(dob["year"] as? Int == date[0] && dob["month"] as? Int == date[1] && dob["day"] as? Int == date[2], "seed \(seed): \(dob) vs \(date)")
            #expect(date != [1990, 3, 3] && dob["month"] as? Int != 3 && dob["day"] as? Int != 3, "seed \(seed): \(date)")
        }
    }

    /// With no full date to follow, a record's parts are still replaced, each
    /// drawn once for the record: the same month in two records may differ.
    @Test(arguments: Shape.allCases)
    func partsWithNoDateAreStillReplaced(_ shape: Shape) throws {
        let text: String
        switch shape {
        case .json: text = #"[{"name": "Odalys Ferriter", "birth_year": 1990, "birth_month": 3, "birth_day": 3}, {"name": "Bram Quillmere", "birth_year": 1984, "birth_month": 11, "birth_day": 4}]"#
        case .csv: text = "name,birth_year,birth_month,birth_day\nOdalys Ferriter,1990,3,3\nBram Quillmere,1984,11,4\n"
        case .xml: text = "<people><person><name>Odalys Ferriter</name><birth_year>1990</birth_year><birth_month>3</birth_month><birth_day>3</birth_day></person><person><name>Bram Quillmere</name><birth_year>1984</birth_year><birth_month>11</birth_month><birth_day>4</birth_day></person></people>"
        }
        for seed in UInt64(0)..<6 {
            let result = try Scrubber.scrub(Data(text.utf8), name: "people." + shape.rawValue, forceFullDetection: false, seed: seed)
            let output = String(decoding: result.output, as: UTF8.self)
            let numbers = output.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            // Two years, two months and two days, none the real one in its place.
            #expect(numbers.count == 6, "\(output)")
            guard numbers.count == 6 else { continue }
            let (first, second) = (Array(numbers[0..<3]), Array(numbers[3..<6]))
            #expect(first[0] != 1990 && first[1] != 3 && first[2] != 3 && (1...12).contains(first[1]) && (1...28).contains(first[2]), "seed \(seed): \(output)")
            #expect(second[0] != 1984 && second[1] != 11 && second[2] != 4 && (1...12).contains(second[1]) && (1...28).contains(second[2]), "seed \(seed): \(output)")
        }
    }

    @Test func aKeyNamesTheDatePartItHolds() {
        #expect(KeyHints.datePart("birth_month") == .month && KeyHints.datePart("monthOfBirth") == .month && KeyHints.datePart("dob_month") == .month)
        #expect(KeyHints.datePart("birth_day") == .day && KeyHints.datePart("dayOfBirth") == .day && KeyHints.datePart("dobDay") == .day)
        #expect(KeyHints.datePart("birth_year") == .year && KeyHints.datePart("yob") == .year)
        #expect(KeyHints.datePart("birthday") == nil && KeyHints.datePart("dob") == nil && KeyHints.datePart("date_of_birth") == nil)
        #expect(KeyHints.datePart(KeyHints.resolve("month", parent: "dob")) == .month)
        #expect(KeyHints.datePart(KeyHints.header("dob.dd")) == .day)
        #expect(KeyHints.fits("birth_month", "March") && !KeyHints.fits("date_of_birth", "March"))
    }
}
