import Foundation

/// A passport's, ID card's or visa's machine-readable zone (ICAO 9303): two
/// lines of 44 characters (TD3, a passport), two of 36 (TD2) or three of 30
/// (TD1, an ID card), in capitals, digits and the filler "<". It writes the
/// holder's name, document number, nationality, birth date, sex and expiry,
/// each number followed by a check digit, so a stand-in rewrites the parts
/// that name the holder and computes the check digits again.
enum MachineZone {
    /// What a line holds, by its length and what it starts with.
    enum Line: Equatable {
        /// The holder's names from this offset on: TD3 and TD2's first line, TD1's third.
        case names(from: Int)
        /// TD3 or TD2's second line: number, nationality, birth date, sex, expiry, then optional data.
        case data
        /// TD1's first line: document number, then optional data.
        case cardFirst
        /// TD1's second line: birth date, sex, expiry, nationality, optional data, and a check over both.
        case cardSecond
    }

    /// An ID card's first line stored alone ("mrz1"): it is rewritten before any
    /// second line, whose check over both lines needs what changed in it.
    static func opensCard(_ text: String) -> Bool { layout(split(text).lines) == [.cardFirst] }

    static func value(_ character: Character) -> Int {
        if let digit = character.wholeNumberValue, character.isASCII { return digit }
        if let ascii = character.asciiValue, (65...90).contains(ascii) { return Int(ascii) - 55 }
        return 0
    }
    static func check<S: Sequence>(_ characters: S) -> Character where S.Element == Character {
        Character(String(weighted(characters) % 10))
    }
    private static func zoneCharacter(_ c: Character) -> Bool { c == "<" || c.isASCII && (c.isNumber || c.isUppercase) }

    /// The lines of a zone and what separates them: a line break, an escaped
    /// one as a pasted JSON string writes it ("\n"), or a space.
    static func split(_ text: String) -> (lines: [String], separators: [String]) {
        var lines: [String] = [], separators: [String] = [], current = "", gap = ""
        var characters = Array(text)[...]
        while let c = characters.first {
            if zoneCharacter(c) {
                if !gap.isEmpty, !current.isEmpty { lines.append(current); separators.append(gap); current = "" }
                gap = ""
                current.append(c)
                characters = characters.dropFirst()
            } else if c == "\\", characters.dropFirst().first.map({ $0 == "n" || $0 == "r" }) == true {
                gap += String(characters.prefix(2)); characters = characters.dropFirst(2)
            } else {
                gap.append(c); characters = characters.dropFirst()
            }
        }
        if !current.isEmpty { lines.append(current) }
        return (lines, separators)
    }

    /// What each line holds; nil where the lines read as no zone.
    static func layout(_ lines: [String]) -> [Line]? {
        guard !lines.isEmpty, lines.count <= 3, lines.allSatisfy({ [30, 36, 44].contains($0.count) && $0.allSatisfy(zoneCharacter) }) else { return nil }
        func namesLine(_ line: String, from: Int) -> Bool {
            let rest = line.dropFirst(from)
            return line.first?.isLetter == true && !rest.contains(where: \.isNumber) && rest.contains("<<") && rest.first != "<"
        }
        func dataLine(_ line: String) -> Bool {
            let c = Array(line)
            return c.count >= 36 && c[13..<19].allSatisfy(\.isNumber) && c[21..<27].allSatisfy(\.isNumber) && "MFX<".contains(c[20])
        }
        return lines.map { line -> Line? in
            switch line.count {
            case 44, 36:
                if namesLine(line, from: 5) { return .names(from: 5) }
                return dataLine(line) ? .data : nil
            default:
                let c = Array(line)
                if "ACI".contains(c[0]), c[2..<5].allSatisfy({ $0.isLetter || $0 == "<" }), c[5..<14].contains(where: \.isNumber) { return .cardFirst }
                if c[0..<6].allSatisfy(\.isNumber), c[8..<14].allSatisfy(\.isNumber), "MFX<".contains(c[7]) { return .cardSecond }
                if namesLine(line, from: 0) { return .names(from: 0) }
                return nil
            }
        }.reduce(into: [Line]?([])) { result, line in
            if let line { result?.append(line) } else { result = nil }
        }
    }

    /// Whether text is a zone, or a line of one: zone characters only, of a
    /// zone's lengths, with each number's check digit right. A data line filled
    /// to its end with no "<" ("YB44172030ITA8109231F3104172…") is one only
    /// where its check over the whole line adds up too.
    static func isZone(_ text: String) -> Bool {
        let (lines, _) = split(text)
        guard let layout = layout(lines) else { return false }
        let filled = !lines.joined().contains("<")
        if filled, !layout.contains(.data) { return false }
        for (line, kind) in zip(lines, layout) {
            let c = Array(line)
            switch kind {
            case .data:
                guard checked(c, 0..<9, 9) && checked(c, 13..<19, 19) && checked(c, 21..<27, 27) else { return false }
                if filled, rechecked(c, kind: .data) != c { return false }
            case .cardFirst: guard checked(c, 5..<14, 14) else { return false }
            case .cardSecond: guard checked(c, 0..<6, 6) && checked(c, 8..<14, 14) else { return false }
            case .names: break
            }
        }
        return true
    }
    /// Whether text is laid out as a zone, whatever its check digits say.
    static func isShaped(_ text: String) -> Bool {
        let (lines, _) = split(text)
        return layout(lines) != nil && (lines.joined().contains("<") || isZone(text))
    }
    private static func checked(_ c: [Character], _ range: Range<Int>, _ at: Int) -> Bool {
        c[at] == check(c[range]) || c[range].allSatisfy { $0 == "<" } && (c[at] == "<" || c[at] == "0")
    }

    /// A name part as a zone writes it: capitals without accents, apostrophes
    /// dropped, spaces and hyphens as fillers.
    static func fold(_ name: String) -> String {
        String(name.folding(options: .diacriticInsensitive, locale: nil).uppercased().compactMap { c -> Character? in
            if c == " " || c == "-" { return "<" }
            return c.isASCII && c.isLetter ? c : nil
        })
    }
    /// The surname and given names a names line writes, as words.
    static func names(_ field: Substring) -> (last: String, given: [String]) {
        let halves = field.components(separatedBy: "<<")
        let last = halves.first?.split(separator: "<").joined(separator: " ") ?? ""
        let given = halves.dropFirst().joined(separator: "<").split(separator: "<").map(String.init)
        return (last, given)
    }
    /// A field's text, cut or filled with "<" to its width.
    static func fit(_ text: String, _ width: Int) -> String {
        let cut = String(text.prefix(width))
        return cut + String(repeating: "<", count: width - cut.count)
    }
    /// Characters' weighted sum as a check digit counts it, from a position of the checked text on.
    static func weighted<S: Sequence>(_ characters: S, from start: Int = 0) -> Int where S.Element == Character {
        var sum = 0
        for (index, character) in characters.enumerated() { sum += value(character) * [7, 3, 1][(start + index) % 3] }
        return sum
    }
    /// What a card's second line adds to the check over both lines, which reads the
    /// first line's last 25 characters and then these.
    static func cardSum(_ line: [Character]) -> Int {
        weighted(line[0..<7], from: 25) + weighted(line[8..<15], from: 32) + weighted(line[18..<29], from: 39)
    }
    /// A check digit moved by a change in the sum it covers.
    static func moved(_ digit: Character, by change: Int) -> Character {
        Character(String(((value(digit) + change) % 10 + 10) % 10))
    }
    /// The check digits of a data line, or of a card's two lines, computed again.
    static func rechecked(_ line: [Character], kind: Line, first: [Character]? = nil) -> [Character] {
        var c = line
        func set(_ range: Range<Int>, _ at: Int) {
            if c[range].allSatisfy({ $0 == "<" }) && (c[at] == "<" || c[at] == "0") { return }
            c[at] = check(c[range])
        }
        switch kind {
        case .data:
            set(0..<9, 9); set(13..<19, 19); set(21..<27, 27)
            if c.count == 44 {
                set(28..<42, 42)
                c[43] = check(Array(c[0..<10]) + Array(c[13..<20]) + Array(c[21..<43]))
            } else {
                c[35] = check(Array(c[0..<10]) + Array(c[13..<20]) + Array(c[21..<35]))
            }
        case .cardFirst: set(5..<14, 14)
        case .cardSecond:
            set(0..<6, 6); set(8..<14, 14)
            if let first { c[29] = check(Array(first[5..<30]) + Array(c[0..<7]) + Array(c[8..<15]) + Array(c[18..<29])) }
        case .names: break
        }
        return c
    }
}
