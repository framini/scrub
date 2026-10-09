import Foundation
@testable import ScrubCore

/// A card as issuing and payment APIs return it, and a screening result as
/// watchlist APIs return it: the shapes that carry a card's expiry, a person's
/// other names in other scripts, a birth year in a record of its own, and a
/// person named inside a link or a court case's name.
extension PayloadGen {
    static let otherScripts = ["Тобиас Хальворсен", "Ρόμπερτ Λινάρης", "ทาเคชิ ยามาดะ", "Йоана Петрова"]

    /// A card: its expiry written whole, in parts or in an object of its own; a
    /// token's or a session's expiry beside it is no one's and stays.
    mutating func cardRecord() -> PNode {
        let p = person()
        let last4 = String(p.card.filter(\.isNumber).suffix(4))
        let month = gen.int(1...12), year = gen.int(2027...2033)
        let expiry: (String, PNode)
        switch gen.int(0...3) {
        case 0: expiry = (key(["expiry"]), leaf(String(format: "%02d/%02d", month, year % 100), .pii(.expiry)))
        case 1: expiry = (key(["expiration", "date"]), leaf(String(format: "%04d-%02d-%02d", year, month, gen.int(1...28)), .pii(.expiry)))
        case 2: expiry = (key(["expiration"]), .object([(key(["month"]), leaf(String(format: "%02d", month), .pii(.expiry))), (key(["year"]), leaf(String(year), .pii(.expiry)))]))
        default: expiry = (key(["expiration"]), leaf(String(format: "%02d%02d", month, year % 100), .pii(.expiry)))
        }
        let card: PNode = .object([
            (key(["id"]), keep(id("card"))), (key(["brand"]), keep(gen.choose(["visa", "mastercard"]))),
            (key(["last", "four"]), linked(leaf(last4, .pii(.lastDigits)), p.link("card"))), expiry,
            (key(["cardholder", "name"]), linked(leaf(p.full, .pii(.fullName)), p.link("name"))),
            (key(["status"]), keep(gen.choose(["active", "inactive", "frozen"]))),
        ])
        let session: PNode = .object([(key(["token"]), leaf(id("ses"), .ignore)), (key(["expires", "at"]), timestamp())])
        return .object([(key(["data"]), .array([card], item: "card")), (key(["session"]), session), (key(["has", "more"]), .bool(false))])
    }

    /// A screening hit: the person's names, others in other scripts, a birth
    /// record typed as one, the search that found them, a link to their page
    /// and a court case naming them.
    mutating func screening() -> PNode {
        let p = person()
        let slug = [p.first, p.last].map { $0.folding(options: .diacriticInsensitive, locale: nil).lowercased().filter(\.isLetter) }.joined(separator: "-")
        let birth = String(p.dob.year!)
        let aka: [PNode] = [.object([(key(["name"]), linked(leaf(gen.choose(Self.otherScripts), .pii(.fullName)), p.link("aka")))]),
                            .object([(key(["name"]), leaf(p.last, .pii(.lastName)))])]
        return .object([
            (key(["id"]), leaf(id("hit"), .keepSoft)),
            (key(["first", "name"]), linked(leaf(p.first, .pii(.firstName)), p.link("name"))),
            (key(["last", "name"]), linked(leaf(p.last, .pii(.lastName)), p.link("name"))),
            (key(["aka"]), .array(aka, item: "aka")),
            (key(["events"]), .array([.object([(key(["type"]), keep("BIRTH")), (key(["year"]), leaf(birth, .pii(.dobYear), number: gen.int(0...1) == 0))])], item: "event")),
            (key(["search", "term"]), .object([(key(["name"]), leaf(p.full, .pii(.fullName))), (key(["year"]), leaf(birth, .pii(.dobYear)))])),
            (key(["profile", "url"]), leaf("https://lists.example.org/summaries/individual/\(slug)", .ignore)),
            (key(["case", "name"]), leaf("NORTHWIND RECOVERY LLC VS \(p.full.uppercased())", .ignore)),
            (key(["match", "score"]), keep(String(gen.int(70...100)), number: true)),
        ])
    }
}
