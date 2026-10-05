import Foundation

/// Whether any part of a personal value survives a scrub, judged from the
/// generator's own ground truth alone: it calls nothing in ScrubCore.
///
/// A whole value gone is not enough: "Odalys Ferriter" → "Kathryn Ferriter"
/// still leaks the surname. So each planted value is broken into the parts
/// that identify on their own:
/// - each word of a name of three letters or more;
/// - an email's local part, and its words of three letters or more;
/// - the digits of a number of five digits or more, with any separators;
/// - the last four digits of a number of seven digits or more;
/// - a handle, ID or secret written as one token.
///
/// A part leaks when the output holds it more often than the input does
/// outside every planted value: a word the document also uses as an ordinary
/// word ("Will", "Rose", "item") may stay where it stood as one.
public enum ComponentLeaks {
    public enum Kind: Equatable, Sendable { case name, email, number, other }

    public struct Planted: Hashable, Sendable {
        public let value: String
        public let kind: Kind
        public init(_ value: String, kind: Kind? = nil) {
            self.value = value
            self.kind = kind ?? ComponentLeaks.kind(of: value)
        }
    }

    /// A value's kind by what it is made of, for generators that keep none.
    public static func kind(of value: String) -> Kind {
        if value.contains("@"), value.split(separator: "@").count == 2 { return .email }
        let digits = value.filter(\.isNumber).count, letters = value.filter(\.isLetter).count
        if digits >= 5 && digits >= letters * 2 { return .number }
        let words = value.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
        if !words.isEmpty, digits == 0, words.allSatisfy({ $0.first?.isUppercase == true }) { return .name }
        return .other
    }

    public enum Part: Hashable, CustomStringConvertible {
        case word(String), token(String), digits(String), ending(String)
        public var description: String {
            switch self {
            case .word(let word), .token(let word): word
            case .digits(let digits): digits
            case .ending(let ending): "…" + ending
            }
        }
    }

    public static func parts(_ planted: Planted) -> Set<Part> {
        var parts: Set<Part> = []
        let digits = planted.value.filter { $0.isASCII && $0.isNumber }
        switch planted.kind {
        case .name:
            for word in words(planted.value) where word.count >= 3 { parts.insert(.word(word)) }
        case .email:
            let local = String(planted.value.split(separator: "@").first ?? "")
            if local.count >= 3 { parts.insert(.word(local)) }
            for word in words(local) where word.count >= 3 { parts.insert(.word(word)) }
        case .number:
            if digits.count >= 5 { parts.insert(.digits(digits)) }
            if digits.count >= 7 { parts.insert(.ending(String(digits.suffix(4)))) }
        case .other:
            // A handle, ID or secret is one token: the token itself, and its digits.
            if !planted.value.contains(where: \.isWhitespace), planted.value.count >= 6 { parts.insert(.token(planted.value)) }
            if digits.count >= 5 { parts.insert(.digits(digits)) }
        }
        return parts
    }

    /// The parts of `planted` the output holds more often than the input outside them.
    public static func leaks(_ planted: [Planted], input: String, output: String) -> [String] {
        // The input with every planted value blanked: what is left is the document's own.
        var rest = input
        for value in Set(planted.map(\.value)).sorted(by: { $0.count > $1.count }) where !value.isEmpty {
            rest = rest.replacingOccurrences(of: value, with: " ", options: .caseInsensitive)
        }
        var leaked: Set<String> = []
        // A part the input never wrote cannot leak: a stand-in that happens to
        // equal a planted value this rendering left out ("Maria") is no leak.
        for part in Set(planted.flatMap(parts)) where count(part, in: input) > 0 {
            if count(part, in: output) > count(part, in: rest) { leaked.insert(part.description) }
        }
        return leaked.sorted()
    }

    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    public static func count(_ part: Part, in text: String) -> Int {
        let pattern: String
        switch part {
        case .word(let word):
            // A word on its own, in any case: not inside a longer word.
            pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}])"#
        case .token(let token):
            pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: token) + #"(?![\p{L}\p{N}_])"#
        case .digits(let digits):
            pattern = #"(?<!\d)"# + digits.map(String.init).joined(separator: #"[\s\-.()/]?"#) + #"(?!\d)"#
        case .ending(let ending):
            // Four digits alone or after a mask ("ends in 1234", "***-**-1234"), not a longer number's tail
            // nor an IPv6 address's first group ("2001:db8::").
            pattern = #"(?<!\d)(?<!\d[\-. ])"# + ending + #"(?!\d)(?!:[0-9A-Fa-f:])"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}
