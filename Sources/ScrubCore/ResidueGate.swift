import Foundation
import NaturalLanguage

/// The last pass over a document once every round is done: no part of a
/// person's name Scrub found, replaced or asked about, stays in the output
/// unseen. Each part (a given name, each half of a hyphenated one, a surname's
/// words, a surname joined to its particle, a name from birth) is looked for
/// in every value, in any case and with its accents folded ("Ó" as "o", "ş" as
/// "s", "đ" as "d"): as a word in text, and in a handle, an email's local part
/// or a link's path or query, as a token of its own ("helen.cordero.v") or run
/// into others ("seanobriain", "fxcordero"), four letters or more.
///
/// A part written where a name is (beside that person's stand-in or another
/// part of the name, after a title, in a handle, under a name's key, or as no
/// ordinary word) takes that person's stand-in part, in its own shape. One
/// that is also an ordinary word, anywhere else, is left as written and asked
/// about. Keys and structure are never touched, and it runs once.
enum ResidueGate {
    private static let names: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME"]

    /// A person found: what their name was, and the stand-in written for it, if any.
    private struct Person {
        let original: String
        let fake: String?
        let doubt: Doubt?
    }
    /// A part of someone's name, folded, with the stand-in part it takes.
    private struct Part {
        let person: Int
        let fake: String?
    }

    static func run(_ values: inout [DocumentValue], leaves: [DocumentLeaf], job: Job) throws {
        var people: [Person] = []
        var known: Set<String> = []
        // A record's given names and surnames written in fields of their own, in order: one person between them.
        var fields: [String: (given: [(String, String)], family: [(String, String)], people: [Int])] = [:]
        var order: [String] = []
        for (value, leaf) in zip(values, leaves) {
            for mark in value.marks where names.contains(mark.entity) {
                guard let original = mark.original, !original.isEmpty else { continue }
                let fake = TextRanges.substring(value.text, mark.range)
                if !leaf.isKey, mark.entity != "PERSON", mark.range == 0..<(value.text as NSString).length, let record = leaf.lastRecord {
                    let key = "\(record)\u{0}\(leaf.objectPath)"
                    if fields[key] == nil { order.append(key) }
                    if mark.entity == "FIRST_NAME" { fields[key, default: ([], [], [])].given.append((original, fake)) } else { fields[key, default: ([], [], [])].family.append((original, fake)) }
                }
                guard known.insert(original + "\u{0}" + fake).inserted else {
                    if let at = people.firstIndex(where: { $0.original == original && $0.fake == fake }), let record = leaf.lastRecord, !leaf.isKey {
                        fields["\(record)\u{0}\(leaf.objectPath)"]?.people.append(at)
                    }
                    continue
                }
                if let record = leaf.lastRecord, !leaf.isKey { fields["\(record)\u{0}\(leaf.objectPath)"]?.people.append(people.count) }
                people.append(Person(original: original, fake: fake, doubt: nil))
            }
            for mark in value.unresolved + value.held where mark.entity == "PERSON" {
                guard let original = mark.original, !original.isEmpty, known.insert(original + "\u{0}").inserted else { continue }
                people.append(Person(original: original, fake: nil, doubt: mark.doubt))
            }
        }
        guard !people.isEmpty else { return }
        // Each person filed under the one their record's name fields make, so their parts are one person's.
        var root = Array(people.indices)
        for key in order {
            guard let record = fields[key], !record.given.isEmpty, !record.family.isEmpty else { continue }
            let named = record.given + record.family
            let whole = Person(original: named.map(\.0).joined(separator: " "), fake: named.map(\.1).joined(separator: " "), doubt: nil)
            root.append(people.count)
            for member in Set(record.people) where root[member] == member { root[member] = people.count }
            people.append(whole)
        }
        var parts: [String: [Part]] = [:]
        for (index, person) in people.enumerated() {
            for (key, fake) in Self.parts(of: person.original, fake: person.fake) where !(parts[key]?.contains { $0.person == root[index] } ?? false) {
                parts[key, default: []].append(Part(person: root[index], fake: fake))
            }
        }
        guard !parts.isEmpty else { return }
        // Three words' initials open a handle made of them ("fxcv" of Francisco Xavier Cordero): asked about.
        var initials: [String: Int] = [:]
        for (index, person) in people.enumerated() where root[index] == index {
            let named = words(person.original).filter { !JoinedNames.particles.contains(fold($0)) }.compactMap { fold($0).first }
            if named.count >= 3, initials[String(named.prefix(3))] == nil { initials[String(named.prefix(3))] = index }
        }
        // Long parts, longest first, for handles that run a name's words together.
        // Filed by their first four letters, so a long document's many people cost one lookup a letter.
        var long: [String: [[Character]]] = [:]
        for key in parts.keys.filter({ $0.count >= 4 }).sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }) { long[String(key.prefix(4)), default: []].append(Array(key)) }
        // Each person's parts, and who a part's first four letters may begin, for handles cut short ("valen" of Valentina).
        var pieces: [Int: [(String, String?)]] = [:], heads: [String: Set<Int>] = [:]
        for (key, found) in parts.sorted(by: { $0.key < $1.key }) where key.allSatisfy(\.isLetter) {
            for part in found {
                pieces[part.person, default: []].append((key, part.fake))
                if key.count >= 4 { heads[String(key.prefix(4)), default: []].insert(part.person) }
            }
        }
        let lookup = Lookup(parts: parts, long: long, initials: initials, pieces: pieces, heads: heads)
        for index in values.indices {
            if index.isMultiple(of: 256) { try Scrubber.checkCancellation() }
            let value = values[index], leaf = leaves[index]
            // A code is no one's words: "TIDAK_ADA_KECOCOKAN" keeps its "ADA".
            guard !leaf.isKey, !leaf.isCode, !value.fullyMarked, !value.text.isEmpty else { continue }
            let hits = Self.hits(in: value, leaf: leaf, lookup)
            guard !hits.isEmpty else { continue }
            job.enter(value: index, records: leaf.enclosing, part: leaf.datePart, object: leaf.objectPath, naming: leaf.naming, kind: leaf.decided)
            let surfaceOnly = leaf.isCode || leaf.nonPersonal
            var edits: [(range: Range<Int>, value: String)] = [], made: [Mark] = [], suspects: [Mark] = []
            let budget = max(64, (value.text as NSString).length / 8)
            for hit in hits {
                let written = TextRanges.substring(value.text, hit.range)
                let person = people[hit.person]
                if hit.replace, !surfaceOnly, edits.count < budget, let fake = Self.standIn(hit, written: written, person: person, job: job) {
                    edits.append((hit.range, fake))
                    let confidence = job.confidence(of: person.original) ?? 1
                    made.append(Mark(range: hit.range, entity: hit.handle ? "USERNAME" : "PERSON", original: written, confidence: min(confidence, 1)))
                } else {
                    let doubt: Doubt? = person.fake == nil && written.lowercased() == person.original.lowercased() ? person.doubt : .nameResidue
                    suspects.append(Mark(range: hit.range, entity: "PERSON", original: written, confidence: LeakGate.suspectConfidence, doubt: doubt))
                }
            }
            let (text, placed) = edits.isEmpty ? (value.text, []) : TextRanges.apply(edits, to: value.text)
            let marks = (TextRanges.shift(value.marks, by: edits) + zip(placed, made).map { $1.moved(to: $0) }).sorted { $0.range.lowerBound < $1.range.lowerBound }
            let unresolved = TextRanges.shift(value.unresolved + suspects, by: edits).sorted { $0.range.lowerBound < $1.range.lowerBound }
            values[index] = DocumentValue(text: text, marks: marks, unresolved: unresolved, proposals: value.proposals, held: TextRanges.shift(value.held, by: edits))
        }
    }

    /// The stand-in for one place: the person's stand-in part written as the
    /// place is, or a name drawn for it; nil when none differs from it.
    private static func standIn(_ hit: Hit, written: String, person: Person, job: Job) -> String? {
        var fake = hit.fake
        if fake == nil {
            let drawn = job.replacement(for: "PERSON", original: written)
            fake = drawn.split(separator: " ").last.map(String.init)
        }
        guard var fake, !fake.isEmpty else { return nil }
        if hit.handle { fake = fold(fake).filter { $0.isLetter } }
        let shaped = LeakGate.cased(fake, like: written)
        guard fold(shaped) != fold(written) else { return nil }
        if hit.fake != nil { _ = job.variant(written, fake: shaped, entity: hit.handle ? "USERNAME" : "PERSON", source: person.original) }
        return shaped
    }

    // MARK: Parts

    /// A name's parts, folded, each with the stand-in part it takes when the
    /// stand-in's words line up with the name's.
    private static func parts(of original: String, fake: String?) -> [(String, String?)] {
        let real = words(original), made = fake.map(words) ?? []
        guard !real.isEmpty, real.count <= 6 else { return [] }
        let named = real.filter { !JoinedNames.particles.contains(fold($0)) && !["o", "ó", "y", "e", "mac", "mc"].contains(fold($0)) }
        func standIn(_ word: String) -> String? {
            guard !made.isEmpty, let at = named.firstIndex(of: word) else { return nil }
            if named.count == made.count { return made[at] }
            if at == 0 { return made.first }
            if at == named.count - 1 { return made.last }
            return nil
        }
        var result: [(String, String?)] = []
        func add(_ key: String, _ fake: String?) {
            guard key.count >= 2, key.allSatisfy(\.isLetter) || key.contains("-") else { return }
            result.append((key, fake))
        }
        for (position, word) in real.enumerated() {
            let key = fold(word).filter { $0 != "'" && $0 != "’" }
            if named.contains(word) {
                let fake = standIn(word)
                add(key, fake)
                // "Min-jun", "O'Brien": each piece, and the word without its marks.
                let pieces = fold(word).split { $0 == "-" || $0 == "'" || $0 == "’" }.map(String.init)
                if pieces.count > 1 {
                    let fakePieces = fake.map { fold($0).split(separator: "-").map(String.init) } ?? []
                    for (at, piece) in pieces.enumerated() {
                        add(piece, fakePieces.count == pieces.count ? fakePieces[at] : nil)
                    }
                    add(pieces.joined(), fake)
                }
            } else if position + 1 < real.count {
                // A surname joined to its particle: "Di Stefano" as "distefano", "Ó Briain" as "obriain".
                let next = real[position + 1]
                add(key + fold(next).filter(\.isLetter), standIn(next))
            }
        }
        return result
    }
    /// A name's words, without titles, suffixes, initials or a possessive.
    private static func words(_ name: String) -> [String] {
        name.split { $0.isWhitespace || $0 == "," || $0 == "/" }.map(String.init)
            .map { $0.hasSuffix("'s") || $0.hasSuffix("’s") ? String($0.dropLast(2)) : $0 }
            .filter { word in
                !People.isTitle(word) && !People.isSuffix(word) && !NameEvidence.titles.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                    && word.filter(\.isLetter).count >= 1 && !(word.hasSuffix(".") && word.count <= 3)
                    && word.allSatisfy { $0.isLetter || "'’-".contains($0) }
            }
    }
    /// Letters as a reader compares them: lowercase, without accents, and the
    /// letters no accent folding reaches written plainly ("đ" as "d", "ı" as "i").
    static func fold(_ text: String) -> String {
        var result = ""
        for character in text { result += fold(character) }
        return result
    }
    private static let plain: [Character: String] = ["đ": "d", "ð": "d", "ı": "i", "ł": "l", "ø": "o", "ß": "ss", "æ": "ae", "œ": "oe", "þ": "th", "ħ": "h", "ŧ": "t"]
    private static func fold(_ character: Character) -> String {
        let lower = String(character).lowercased()
        if let known = lower.first.flatMap({ plain[$0] }), lower.count == 1 { return known }
        return lower.folding(options: [.diacriticInsensitive], locale: nil)
    }

    // MARK: Reading

    private struct Hit {
        let range: Range<Int>
        let person: Int
        let fake: String?
        let handle: Bool
        var replace: Bool
    }
    /// A run of letters in the text, folded, with where each folded letter came from.
    private struct Run {
        let range: Range<Int>
        let folded: [Character]
        let starts: [Int]
        let ends: [Int]
    }

    private static func runs(_ ns: NSString) -> [Run] {
        var result: [Run] = []
        let text = ns as String
        var offset = 0
        var folded: [Character] = [], starts: [Int] = [], ends: [Int] = []
        var start = -1
        func close() {
            if start >= 0, !folded.isEmpty { result.append(Run(range: start..<offset, folded: folded, starts: starts, ends: ends)) }
            folded = []; starts = []; ends = []; start = -1
        }
        for character in text {
            let length = character.utf16.count
            if character.isLetter {
                if start < 0 { start = offset }
                for letter in fold(character) {
                    folded.append(letter); starts.append(offset); ends.append(offset + length)
                }
            } else { close() }
            offset += length
        }
        close()
        return result
    }

    /// What a document's people are looked for by.
    private struct Lookup {
        let parts: [String: [Part]]
        let long: [String: [[Character]]]
        let initials: [String: Int]
        let pieces: [Int: [(String, String?)]]
        let heads: [String: Set<Int>]
    }

    private static func hits(in value: DocumentValue, leaf: DocumentLeaf, _ lookup: Lookup) -> [Hit] {
        let parts = lookup.parts, long = lookup.long, initials = lookup.initials
        let text = value.text, ns = text as NSString
        let runs = Self.runs(ns)
        guard !runs.isEmpty else { return [] }
        // Places already a stand-in or already asked about.
        var taken = IndexSet()
        for mark in value.marks + value.unresolved + value.held where !mark.range.isEmpty { taken.insert(integersIn: mark.range) }
        let named = value.marks.filter { names.contains($0.entity) }.map(\.range)
        let links = text.contains("/") || text.contains("@") ? Links.ranges(in: text) : []
        let components = links.isEmpty ? [] : URLs.components(in: text, links: links)
        let underName = names.contains(KeyHints.hint(leaf.key) ?? "")
        func unit(_ at: Int) -> unichar? { at >= 0 && at < ns.length ? ns.character(at: at) : nil }
        /// The run of non-space characters around a place: a handle, an email or a link.
        func token(_ range: Range<Int>) -> Range<Int> {
            let stops: Set<unichar> = [32, 9, 10, 13, 34, 0x201C, 0x201D, 40, 41, 60, 62, 44, 59, 91, 93, 123, 125]
            var low = range.lowerBound, high = range.upperBound
            while let u = unit(low - 1), !stops.contains(u) { low -= 1 }
            while let u = unit(high), !stops.contains(u) { high += 1 }
            return low..<high
        }
        func isHandle(_ run: Run) -> Bool {
            if links.contains(where: { $0.contains(run.range.lowerBound) }) { return true }
            let around = ns.substring(with: NSRange(location: token(run.range).lowerBound, length: token(run.range).count))
            return around.contains("@") || around.contains("_") || around.contains("/") || around.contains(where: \.isNumber)
                || around.contains(".") && around.trimmingCharacters(in: CharacterSet(charactersIn: ".!?:")).contains(".")
        }
        /// Whether a place is inside a code in capitals joined by underscores ("TIDAK_ADA_KECOCOKAN"): no one's words.
        func inCode(_ range: Range<Int>) -> Bool {
            func codeUnit(_ u: unichar) -> Bool { (65...90).contains(u) || (48...57).contains(u) || u == 95 || (97...122).contains(u) }
            var low = range.lowerBound, high = range.upperBound
            while let u = unit(low - 1), codeUnit(u) { low -= 1 }
            while let u = unit(high), codeUnit(u) { high += 1 }
            guard high - low > range.count else { return false }
            return !TextRanges.matches(code, in: ns.substring(with: NSRange(location: low, length: high - low))).isEmpty
        }
        func host(_ range: Range<Int>) -> Bool {
            links.contains { $0.contains(range.lowerBound) } && !components.contains { $0.range.lowerBound <= range.lowerBound && range.upperBound <= $0.range.upperBound }
        }
        func only(_ found: [Part]) -> Part? {
            guard let first = found.first else { return nil }
            return found.allSatisfy({ $0.person == first.person || $0.fake != nil && $0.fake == first.fake }) ? first : nil
        }

        var hits: [Hit] = []
        var index = 0
        while index < runs.count {
            let run = runs[index]
            let range = run.range
            if taken.intersects(integersIn: range) || inCode(range) { index += 1; continue }
            let handle = isHandle(run)
            // Words joined by a hyphen or an apostrophe, longest first: "Min-jun", "O'Brien".
            var matched = false
            for count in stride(from: min(3, runs.count - index), through: 2, by: -1) where !handle {
                let group = runs[index..<(index + count)]
                guard zip(group, group.dropFirst()).allSatisfy({ $0.range.upperBound + 1 == $1.range.lowerBound && [45, 39, 0x2019, 0x2010].contains(ns.character(at: $0.range.upperBound)) }) else { continue }
                let hyphened = group.map { String($0.folded) }.joined(separator: "-"), joined = group.map { String($0.folded) }.joined()
                let whole = group.first!.range.lowerBound..<group.last!.range.upperBound
                guard !taken.intersects(integersIn: whole), let part = only(parts[hyphened] ?? parts[joined] ?? []) else { continue }
                hits.append(Hit(range: whole, person: part.person, fake: part.fake, handle: false, replace: true))
                index += count
                matched = true
                break
            }
            if matched { continue }
            let word = String(run.folded)
            if let part = only(parts[word] ?? []), word.count >= 3 || !handle || sameToken(run, part.person, runs: runs, parts: parts, token: token) {
                hits.append(Hit(range: range, person: part.person, fake: part.fake, handle: handle, replace: true))
                index += 1
                continue
            }
            // A handle made whole of one person's parts, their first letters and their beginnings ("valen", "valensol", "tobiasl").
            if handle, run.folded.count >= 4, let hit = Self.cut(run, lookup) {
                hits.append(hit)
                index += 1
                continue
            }
            // A name run into a handle or a slug ("seanobriain", "fxcordero"), or written as one word in lowercase.
            let lowercase = ns.substring(with: NSRange(location: range.lowerBound, length: range.count)) == ns.substring(with: NSRange(location: range.lowerBound, length: range.count)).lowercased()
            if run.folded.count >= 5, handle || lowercase && !NameLists.isWord(word) && !NameLists.isFirst(word) && !NameLists.isSurname(word) {
                var found: [Hit] = [], covered = 0, at = 0
                while at < run.folded.count {
                    var step = 1
                    let head = at + 4 <= run.folded.count ? String(run.folded[at..<(at + 4)]) : ""
                    for key in long[head] ?? [] where at + key.count <= run.folded.count && run.folded[at..<(at + key.count)].elementsEqual(key) {
                        guard let part = only(parts[String(key)] ?? []) else { continue }
                        found.append(Hit(range: run.starts[at]..<run.ends[at + key.count - 1], person: part.person, fake: part.fake, handle: true, replace: true))
                        covered += key.count
                        step = key.count
                        break
                    }
                    at += step
                }
                // In plain text, only a word the name's parts fill whole: "bennettshaw", never "Shawnee" or "nhanh" of "Hạnh".
                if !found.isEmpty, handle && !NameLists.isWord(word) || !handle && found.count >= 2 && covered == run.folded.count { hits += found; index += 1; continue }
            }
            if handle, (3...8).contains(run.folded.count), let person = initials[String(run.folded.prefix(3))], !NameLists.isWord(word) {
                hits.append(Hit(range: range, person: person, fake: nil, handle: true, replace: false))
            }
            index += 1
        }
        guard !hits.isEmpty else { return [] }

        // Whether each place is where a name is, or may be a word to ask about.
        let starts = Set(hits.map(\.range.lowerBound)), ends = Set(hits.map(\.range.upperBound))
        func beside(_ range: Range<Int>) -> Bool {
            func gap(_ at: Int, forward: Bool) -> Int? {
                var at = at, spaces = 0
                while let u = unit(forward ? at : at - 1), u == 32 || u == 45 || u == 0x2010 { at += forward ? 1 : -1; spaces += 1 }
                return (1...2).contains(spaces) ? at : nil
            }
            if let after = gap(range.upperBound, forward: true), starts.contains(after) || named.contains(where: { $0.lowerBound == after }) { return true }
            if let before = gap(range.lowerBound, forward: false), ends.contains(before) || named.contains(where: { $0.upperBound == before }) { return true }
            return false
        }
        func afterTitle(_ range: Range<Int>) -> Bool {
            var at = range.lowerBound
            while let u = unit(at - 1), u == 32 || u == 9 { at -= 1 }
            guard at < range.lowerBound else { return false }
            if unit(at - 1) == 46 { at -= 1 }
            var start = at
            while let u = unit(start - 1), let scalar = Unicode.Scalar(u), CharacterSet.letters.contains(scalar) { start -= 1 }
            guard start < at else { return false }
            let word = ns.substring(with: NSRange(location: start, length: at - start))
            return People.isTitle(word) || NameEvidence.titles.contains(word.lowercased())
        }
        var language: NLLanguageBox?
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return hits.compactMap { hit in
            var hit = hit
            let written = ns.substring(with: NSRange(location: hit.range.lowerBound, length: hit.range.count))
            if hit.handle {
                // A link's host stays a host; a word of the language in a handle alone may be the handle's own.
                if host(hit.range) { hit.replace = false }
                else if NameLists.isWord(written) && !sameToken(hit.range, hit.person, hits: hits, token: token) { hit.replace = false }
                return hit
            }
            let ordinary: Bool = {
                if NameLists.isWord(written) || Names.ambiguousFirst.contains(written.lowercased()) { return true }
                if language == nil { language = NLLanguageBox(NameEvidence.language(of: text) ?? .english) }
                return NameEvidence.isLowercaseWord(written, in: language!.value)
            }()
            // The word itself, written as words are: "an", "will", "rose".
            if ordinary, written.first?.isUppercase != true { return nil }
            if !ordinary || beside(hit.range) || afterTitle(hit.range) || underName && whole.count == written.count { return hit }
            hit.replace = false
            return hit
        }
    }
    private static let code = TextPattern(#"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$"#)

    /// A handle cut whole into one person's pieces: parts, beginnings of four letters or more of a longer part, and
    /// first letters, with at least one part or beginning of four letters. Its stand-in is built of the stand-in's
    /// pieces in the same places; one with no stand-in for a piece, or only a beginning that is a word, is asked about.
    private static func cut(_ run: Run, _ lookup: Lookup) -> Hit? {
        let word = run.folded, count = word.count
        var candidates: [Int] = []
        for at in 0...(count - 4) {
            for person in lookup.heads[String(word[at..<(at + 4)])] ?? [] where !candidates.contains(person) { candidates.append(person) }
        }
        for person in candidates.sorted().prefix(8) {
            let own = lookup.pieces[person] ?? []
            // The fewest pieces reaching each place, with the stand-in built so far and whether a strong piece is among them.
            var best: [(pieces: Int, fake: String?, strong: Bool, beginning: Bool)?] = Array(repeating: nil, count: count + 1)
            best[0] = (0, "", false, false)
            for at in 0..<count {
                guard let here = best[at] else { continue }
                func step(_ length: Int, _ fake: String?, strong: Bool, beginning: Bool) {
                    let next = (pieces: here.pieces + 1, fake: here.fake.flatMap { built in fake.map { built + $0 } }, strong: here.strong || strong, beginning: here.beginning || beginning)
                    // A strong piece first, then the fewest pieces.
                    if let old = best[at + length], old.strong && !next.strong || old.strong == next.strong && old.pieces <= next.pieces { return }
                    best[at + length] = next
                }
                for (key, fake) in own {
                    let letters = Array(key), stand = fake.map { fold($0).filter(\.isLetter) }
                    // The whole part.
                    if at + letters.count <= count, word[at..<(at + letters.count)].elementsEqual(letters) { step(letters.count, stand, strong: letters.count >= 4, beginning: false) }
                    // Its beginning, four letters or more.
                    if letters.count > 4 {
                        for length in stride(from: min(letters.count - 1, count - at), through: 4, by: -1) where word[at..<(at + length)].elementsEqual(letters[0..<length]) {
                            step(length, stand, strong: true, beginning: true)
                        }
                    }
                    // Its first letter.
                    if word[at] == letters[0] { step(1, stand.map { String($0.prefix(1)) }, strong: false, beginning: false) }
                }
            }
            guard let whole = best[count], whole.strong, whole.pieces <= 4 else { continue }
            let written = String(word)
            let replace = whole.fake != nil && !(whole.pieces == 1 && whole.beginning && NameLists.isWord(written))
            return Hit(range: run.range, person: person, fake: whole.fake, handle: true, replace: replace)
        }
        return nil
    }
    private final class NLLanguageBox {
        let value: NLLanguage
        init(_ value: NLLanguage) { self.value = value }
    }
    /// Whether a short part sits in one handle with another part of the same name ("trinh.an").
    private static func sameToken(_ run: Run, _ person: Int, runs: [Run], parts: [String: [Part]], token: (Range<Int>) -> Range<Int>) -> Bool {
        let around = token(run.range)
        return runs.contains { other in
            other.range != run.range && around.contains(other.range.lowerBound) && other.folded.count >= 2 && (parts[String(other.folded)]?.contains { $0.person == person } ?? false)
        }
    }
    private static func sameToken(_ range: Range<Int>, _ person: Int, hits: [Hit], token: (Range<Int>) -> Range<Int>) -> Bool {
        let around = token(range)
        return hits.contains { $0.range != range && $0.person == person && around.contains($0.range.lowerBound) }
    }
}
