import CryptoKit
import Foundation
import os

/// First names given in the US since 1930 and surnames held in 2010, from the
/// government's own counts, with the ones that are also ordinary English
/// words marked ("Rose", "Will", "Hunter"), the ordinary words themselves,
/// and which first names are clearly a woman's or a man's.
/// Tools/NameLists/derive.py writes the file; its sources are in
/// THIRD_PARTY_NOTICES.md.
///
/// A list only supports other evidence. Knowing a word is a surname says
/// nothing on its own ("Long", "Price"); a capitalised word the lists know
/// after a title, in a greeting or beside a known first name is a name. A
/// name that is also an ordinary word counts only where nothing else could
/// explain it.
enum NameLists {
    static let checksum = "de82406ab0b7990d69d719893c164b3eb5a99ecb521e3cd19c99e1c02e6d65b1"
    private static let log = Logger(subsystem: "Scrub", category: "NameLists")

    struct Lists: Sendable {
        var first: Set<String> = []
        var surname: Set<String> = []
        var wordlike: Set<String> = []
        var ordinary: Set<String> = []
        /// First names clearly given to girls, or to boys (see `gender(ofFirst:)`).
        var female: Set<String> = []
        var male: Set<String> = []
    }

    /// Empty when the file is missing or altered, so Scrub then finds what it
    /// found without the lists.
    static let shared: Lists = load() ?? Lists()

    static func load() -> Lists? {
        guard let url = ModelResources.bundle?.url(forResource: "NameLists", withExtension: "txt"), let data = try? Data(contentsOf: url) else {
            log.error("Name lists not loaded: resource missing")
            return nil
        }
        return parse(data)
    }

    static func parse(_ data: Data, checksum: String = checksum) -> Lists? {
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
            log.error("Name lists not loaded: they do not match the expected checksum")
            return nil
        }
        var lists = Lists()
        var section = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { section = String(line.dropFirst().dropLast()); continue }
            let word = String(line)
            switch section {
            case "first": lists.first.insert(word)
            case "surname": lists.surname.insert(word)
            case "wordlike": lists.wordlike.insert(word)
            case "ordinary": lists.ordinary.insert(word)
            case "female": lists.female.insert(word)
            case "male": lists.male.insert(word)
            default: break
            }
        }
        return lists
    }

    private static func folded(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".'’"))
    }

    static func isFirst(_ word: String) -> Bool { shared.first.contains(folded(word)) || Names.firstFolded.contains(folded(word)) }
    static func isSurname(_ word: String) -> Bool { shared.surname.contains(folded(word)) || Names.lastFolded.contains(folded(word)) }
    /// A name that is also an ordinary word or a date: "Rose", "Will", "June".
    static func isWordlike(_ word: String) -> Bool {
        let word = folded(word)
        return shared.wordlike.contains(word) || Names.ambiguousFirst.contains(word)
    }
    /// A first name or surname that is no ordinary word: "Emma", "Okafor".
    static func isName(_ word: String) -> Bool { (isFirst(word) || isSurname(word)) && !isWordlike(word) }

    /// "female" or "male" for a first name clearly given to one: at least 200
    /// people born since 1930 had it and 95 in 100 of them were of that sex
    /// ("Mateus", "Siobhan"). Nil for a name given to either ("Jordan",
    /// "Quinn"), a short form of names of both ("Alex" for Alexander and
    /// Alexandra, "Sam", "Chris"), an initial, or a name the lists don't know.
    static func gender(ofFirst name: String) -> String? {
        let word = folded(name)
        guard word.count >= 2 else { return nil }
        let female = shared.female.contains(word), male = shared.male.contains(word)
        guard female != male else { return nil }
        let other = female ? shared.male : shared.female
        if Nicknames.variants(of: word).contains(where: other.contains) { return nil }
        return female ? "female" : "male"
    }

    /// A word a dictionary holds that no list of names does ("refund",
    /// "kestrel"). Old books seldom write some everyday words, so the books'
    /// list misses them; read as a name, such a word is far more likely a
    /// word that opened a sentence than someone's surname.
    static func isUnlistedWord(_ word: String) -> Bool {
        guard let model = ContextModel.shared, !isFirst(word), !isSurname(word), word.count >= 2, word.allSatisfy(\.isLetter) else { return false }
        return ContextGate.known(word, model: model)
    }
    /// A word any list Scrub holds calls ordinary: the books' words, names
    /// that are also words, the context model's commonest words, or a
    /// dictionary's entries that no list of names holds.
    static func isWord(_ word: String) -> Bool {
        isOrdinary(word) || isWordlike(word) || isUnlistedWord(word)
    }

    private static let endings: [(String, String)] = [("s", ""), ("es", ""), ("ies", "y"), ("ed", ""), ("ed", "e"), ("d", ""), ("ing", ""), ("ing", "e"), ("er", ""), ("ers", ""), ("ly", "")]
    /// An ordinary English word, inflected or not ("advisers", "shippers"),
    /// whether or not it is also a name ("rose"). The context model's
    /// commonest words cover what old books never wrote ("database", "online").
    static func isOrdinary(_ word: String) -> Bool {
        let lower = folded(word)
        guard lower.count >= 2, lower.allSatisfy(\.isLetter) else { return false }
        let common = ContextModel.shared?.common ?? []
        func known(_ value: String) -> Bool { shared.ordinary.contains(value) || common.contains(value) }
        if known(lower) { return true }
        return endings.contains { end, add in
            lower.hasSuffix(end) && lower.count - end.count >= 3 && known(String(lower.dropLast(end.count)) + add)
        }
    }
}
