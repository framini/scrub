import Foundation

/// A person's own edits to the values of a finished scrub: a value read as
/// another kind, and a replacement typed in place of its stand-in. Each is
/// kept by finding, and a value marked by hand by its finding's id, which is
/// negative (see `Marks`). They apply on top of the scrub as made, as marks
/// do (see `ScrubResult.applying(_:marks:edits:)`), and live with the result
/// only; nothing about them is written anywhere.
public struct Edits: Sendable, Equatable {
    /// The kind each of Scrub's findings is read as instead. A mark changes
    /// kind by being marked again (see `Marks.add`).
    public private(set) var kinds: [Finding.ID: String] = [:]
    /// The replacement typed for each finding or mark, written in place of its stand-in.
    public private(set) var replacements: [Finding.ID: String] = [:]

    public init() {}

    public var isEmpty: Bool { kinds.isEmpty && replacements.isEmpty }
    public func touches(_ id: Finding.ID) -> Bool { kinds[id] != nil || replacements[id] != nil }
    /// Reads a finding as `entity`; nil reads it as Scrub did.
    public mutating func setKind(_ entity: String?, of id: Finding.ID) { kinds[id] = entity }
    /// Writes `text` in place of a finding's or a mark's stand-in; nil writes its own again.
    public mutating func setReplacement(_ text: String?, of id: Finding.ID) { replacements[id] = text }
}

/// Why a typed replacement is refused. Nothing of a refused one is written.
public enum Refusal: Error, Sendable, Equatable {
    case empty
    /// It is, or holds, the value it would replace.
    case original
    /// It holds another value Scrub found or the person marked, as written here.
    case other(String)
    /// The value is a bare number in the file (a JSON number), which only digits may replace.
    case number
}

/// Who each name, and each email, username or initials built from one, was
/// given a stand-in for: the scrub's own link between a person's variants,
/// kept so a name typed for one reaches the others (see `Review.revisions`).
struct PersonLinks: Sendable {
    /// A person's stand-in first and last names.
    struct Names: Sendable, Equatable {
        let first: String
        let last: String
    }
    /// Each original and its stand-in, in lowercase, and the person they are.
    private(set) var pairs: [String: Int] = [:]
    /// Each original in lowercase, and the first person it was drawn for.
    private(set) var originals: [String: Int] = [:]
    /// Each person's stand-in names, by their number.
    var names: [Names] = []

    var isEmpty: Bool { pairs.isEmpty }

    private static func key(_ original: String, _ standIn: String) -> String { original.lowercased() + "\u{0}" + standIn.lowercased() }

    mutating func link(_ original: String, _ fake: String, to person: Int) {
        let key = Self.key(original, fake)
        if pairs[key] == nil { pairs[key] = person }
        if originals[original.lowercased()] == nil { originals[original.lowercased()] = person }
    }

    /// The person a finding is, read as it was drawn: plainly, without hidden
    /// characters or markup, or decoded from a link.
    func person(original: String, standIn: String) -> Int? {
        if let found = pairs[Self.key(original, standIn)] { return found }
        let plain = (Visible.plain(original), Visible.plain(standIn))
        if let found = pairs[Self.key(plain.0, plain.1)] { return found }
        func decoded(_ value: String) -> String { value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value }
        return pairs[Self.key(decoded(plain.0), decoded(plain.1))]
    }
}

/// What one of Scrub's findings is written as once edits revise it: its kind,
/// its stand-in, and the stand-in it had as made.
struct Revision: Sendable, Equatable {
    let entity: String
    let standIn: String
    let was: String
}

extension Review {
    /// A person's new first and last names, from a name typed for them; nil
    /// where the typed name says nothing of that part.
    struct Renaming: Equatable {
        var first: String?
        var last: String?
        func merged(_ other: Renaming) -> Renaming { Renaming(first: other.first ?? first, last: other.last ?? last) }
    }

    /// The findings `edits` revise, by id: each edited one, and each other
    /// finding of a person whose name was typed anew, written with the new
    /// name the way its stand-in was written with the old ("Ms Holt",
    /// "maren.holt@…", "@mholt"). A finding changed to another kind leaves its
    /// person and keeps nothing of theirs; its variants keep their stand-ins.
    /// Every caller holds the lock.
    func revisions(_ edits: Edits) throws -> [Finding.ID: Revision] {
        guard !edits.isEmpty else { return [:] }
        if let known = marking?.revised, known.edits == edits { return known.revisions }
        _ = try prepared()
        var made: [Finding.ID: Revision] = [:]
        var renamings: [Int: Renaming] = [:]
        for id in Set(edits.kinds.keys).union(edits.replacements.keys).filter(findings.indices.contains).sorted() {
            let finding = findings[id]
            let entity = edits.kinds[id] ?? finding.entity
            let typed = edits.replacements[id]
            // A new kind draws a new stand-in, as marking the value as that kind would.
            let standIn = try typed ?? (entity == finding.entity ? finding.standIn : standIn(for: finding.original, entity: entity, fresh: true))
            made[id] = Revision(entity: entity, standIn: standIn, was: finding.standIn)
            guard let typed, Self.names.contains(entity), Self.names.contains(finding.entity), let person = personOf[id], people.names.indices.contains(person),
                  let renaming = Self.renaming(Self.read(finding.standIn), to: typed, names: people.names[person]) else { continue }
            renamings[person] = renamings[person].map { $0.merged(renaming) } ?? renaming
        }
        // The same value written another way, as a link writes it ("Odalys+Ferriter"), is the same value.
        let groups = sameValues()
        for (id, revision) in made.sorted(by: { $0.key < $1.key }) {
            let finding = findings[id]
            for other in groups[Self.matchKey(Self.read(finding.original), entity: finding.entity)] ?? [] where other != id && made[other] == nil && findings[other].entity == finding.entity {
                made[other] = Revision(entity: revision.entity, standIn: revision.standIn, was: Self.read(findings[other].standIn))
            }
        }
        if !renamings.isEmpty {
            for (id, person) in personOf where made[id] == nil {
                guard let renaming = renamings[person], findings.indices.contains(id) else { continue }
                let finding = findings[id]
                // Renamed as it reads: a stand-in written into a link ("Maren+Holt") is written back encoded.
                let read = Self.read(finding.standIn)
                let renamed = Self.renamed(read, entity: finding.entity, names: people.names[person], to: renaming)
                if renamed != read { made[id] = Revision(entity: finding.entity, standIn: renamed, was: read) }
            }
        }
        var byStandIn: [String: [Finding.ID]] = [:]
        for id in made.keys.sorted() { byStandIn[made[id]?.standIn.lowercased() ?? "", default: []].append(id) }
        marking?.revised = (edits, made, byStandIn)
        return made
    }

    /// The findings of each value as it reads, by its match key: one original
    /// written plainly and inside a link is one value. Every caller holds the lock.
    func sameValues() -> [String: [Finding.ID]] {
        if let known = marking?.sameValues { return known }
        var groups: [String: [Finding.ID]] = [:]
        for finding in findings { groups[Self.matchKey(Self.read(finding.original), entity: finding.entity), default: []].append(finding.id) }
        marking?.sameValues = groups
        return groups
    }

    /// The revisions `edits` make, read under the lock.
    func revised(_ edits: Edits) -> [Finding.ID: Revision] {
        guard !edits.isEmpty else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        return (try? revisions(edits)) ?? [:]
    }

    /// A revised stand-in written where `current` stands in a value's text,
    /// as that place writes one: encoded inside a link's part, around the
    /// markup and hidden characters the place keeps, and in its case. Nil
    /// where it cannot stand: a bare JSON number takes only digits.
    func written(_ revision: Revision, over current: String, value: Int, range: Range<Int>) -> String? {
        if let component = links(value).first(where: { $0.range.lowerBound <= range.lowerBound && range.upperBound <= $0.range.upperBound }) {
            let read = URLs.decode(current, component.part)
            return URLs.encode(Self.cased(revision.standIn, like: read, was: revision.was), like: current, component.part)
        }
        let made = Visible.rewrite(current, with: Self.cased(revision.standIn, like: Visible.plain(current), was: revision.was))
        if numeric.contains(value), !made.allSatisfy({ $0.isASCII && $0.isNumber }) { return nil }
        return made
    }

    /// `typed` in the case a place wrote its stand-in in: "HOLT" where the
    /// stand-in was "Holt" is typed in capitals, and "holt" in lowercase.
    static func cased(_ typed: String, like read: String, was standIn: String) -> String {
        guard read != standIn else { return typed }
        let letters = read.filter(\.isLetter), made = standIn.filter(\.isLetter)
        if letters.count >= 2, letters == letters.uppercased(), letters != letters.lowercased(), made != made.uppercased() { return typed.uppercased() }
        if !letters.isEmpty, letters == letters.lowercased(), made != made.lowercased() { return typed.lowercased() }
        return typed
    }

    /// A stand-in as it reads: without hidden characters or markup, and decoded where a link wrote it.
    static func read(_ standIn: String) -> String {
        let plain = Visible.plain(standIn)
        guard plain.contains("%") || plain.contains("+") else { return plain }
        return plain.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? plain
    }

    private static let locale = Locale(identifier: "en_US_POSIX")
    static func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale) }

    /// What a name typed for a stand-in says of its person's names: "Jane
    /// Roe" for "Maren Holt" renames both, "Roe" for "Holt" or "Ms Roe" for
    /// "Ms Holt" the surname alone.
    static func renaming(_ standIn: String, to typed: String, names: PersonLinks.Names) -> Renaming? {
        func words(_ value: String) -> [String] {
            value.split { $0.isWhitespace || $0 == "," }.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                .filter { !$0.isEmpty && !People.isTitle($0) && !People.isSuffix($0) }
        }
        let made = words(standIn), wanted = words(typed)
        guard !made.isEmpty, !wanted.isEmpty, wanted.allSatisfy({ $0.contains(where: \.isLetter) }) else { return nil }
        func same(_ word: String, _ name: String) -> Bool { fold(word) == fold(name) }
        var renaming = Renaming()
        if made.count == 2, wanted.count >= 2, same(made[0], names.first), same(made[1], names.last) {
            renaming = Renaming(first: wanted[0], last: wanted[wanted.count - 1])
        } else if made.count == wanted.count {
            for (word, new) in zip(made, wanted) {
                if same(word, names.first) { renaming.first = new } else if same(word, names.last) { renaming.last = new }
            }
        }
        return renaming.first == nil && renaming.last == nil ? nil : renaming
    }

    /// A stand-in of a person written again with their new names, the way it
    /// was written with the old: a name word for word, an email's local part
    /// and a username piece by piece ("maren.holt", "mholt", "holtm"),
    /// initials letter by letter. An email keeps its stand-in domain.
    static func renamed(_ standIn: String, entity: String, names: PersonLinks.Names, to renaming: Renaming) -> String {
        let first = fold(names.first).filter(\.isLetter), last = fold(names.last).filter(\.isLetter)
        func letters(_ name: String?) -> String? { name.map { fold($0).filter(\.isLetter) }.flatMap { $0.isEmpty ? nil : $0 } }
        let newFirst = letters(renaming.first) ?? first, newLast = letters(renaming.last) ?? last
        guard !first.isEmpty, !last.isEmpty else { return standIn }
        func casedRun(_ new: String, like run: String) -> String {
            if run.count >= 2, run == run.uppercased() { return new.uppercased() }
            if run.first?.isUppercase == true { return new.prefix(1).uppercased() + new.dropFirst() }
            return new
        }
        // A handle's runs of letters, each read as a part of the name, the two joined, or an initial beside the other.
        func handle(_ local: String) -> String {
            var runs: [(text: String, letters: Bool)] = []
            for character in local {
                if let previous = runs.last, previous.letters == character.isLetter { runs[runs.count - 1].text.append(character) } else { runs.append((String(character), character.isLetter)) }
            }
            let read = runs.map { $0.letters ? fold($0.text) : "" }
            let (fi, li, nfi, nli) = (String(first.prefix(1)), String(last.prefix(1)), String(newFirst.prefix(1)), String(newLast.prefix(1)))
            let forms = [(first + last, newFirst + newLast), (last + first, newLast + newFirst), (fi + last, nfi + newLast), (last + fi, newLast + nfi), (first + li, newFirst + nli), (first, newFirst), (last, newLast)]
            return runs.indices.map { index -> String in
                guard runs[index].letters else { return runs[index].text }
                var new = forms.first { $0.0 == read[index] }?.1
                if new == nil, read[index].count == 1 {
                    if read[index] == fi, read.contains(last) { new = nfi } else if read[index] == li, read.contains(first) { new = nli }
                }
                return new.map { casedRun($0, like: runs[index].text) } ?? runs[index].text
            }.joined()
        }
        switch entity {
        case "EMAIL_ADDRESS":
            guard let at = standIn.firstIndex(of: "@") else { return standIn }
            return handle(String(standIn[..<at])) + standIn[at...]
        case "USERNAME":
            return standIn.hasPrefix("@") ? "@" + handle(String(standIn.dropFirst())) : handle(standIn)
        case "INITIALS":
            let shown = standIn.filter(\.isLetter).map { fold(String($0)) }
            guard shown.count >= 2, shown.first == String(first.prefix(1)), shown.last == String(last.prefix(1)) else { return standIn }
            var seen = 0
            return String(standIn.map { character -> Character in
                guard character.isLetter else { return character }
                seen += 1
                if seen == 1 { return Character(newFirst.prefix(1).uppercased()) }
                if seen == shown.count { return Character(newLast.prefix(1).uppercased()) }
                return character
            })
        default:
            let hasLast = standIn.split(separator: " ").contains { fold(String($0.prefix { $0.isLetter })) == last }
            return standIn.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
                let word = String(piece), core = String(word.prefix { $0.isLetter }), rest = String(word.dropFirst(core.count))
                func written(_ new: String) -> String {
                    if core.count >= 2, core == core.uppercased() { return new.uppercased() + rest }
                    if core == core.lowercased() { return new.lowercased() + rest }
                    return new + rest
                }
                let folded = fold(core)
                if folded == first, let name = renaming.first { return written(name) }
                if folded == last, let name = renaming.last { return written(name) }
                // "M. Holt": an initial beside the surname.
                if core.count == 1, folded == String(first.prefix(1)), hasLast, let name = renaming.first { return written(String(name.prefix(1)).uppercased()) }
                return word
            }.joined(separator: " ")
        }
    }

    /// Why `typed` may not replace `edited`, or nil when it may: it is
    /// empty, holds the value it replaces (in any case, with or without
    /// accents), stands where only a number may, or holds, as a word of
    /// three letters or more, another value Scrub found or `marks` hold.
    func refusal(_ typed: String, for edited: [Finding], marks: Marks) -> Refusal? {
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let folded = Self.fold(typed)
        let own = Set(edited.map { Self.fold($0.original) })
        if own.contains(where: { !$0.isEmpty && folded.contains($0) }) { return .original }
        lock.lock()
        defer { lock.unlock() }
        if !typed.allSatisfy({ $0.isASCII && $0.isNumber }), edited.contains(where: { finding in
            finding.id >= 0 && finding.places.contains { spots.indices.contains($0.id) && numeric.contains(spots[$0.id].value) }
        }) { return .number }
        if marking?.folded == nil {
            var seen: Set<String> = []
            marking?.folded = findings.compactMap { finding in
                let key = Self.fold(finding.original)
                return seen.insert(key).inserted ? (key, finding.original) : nil
            }
        }
        let others = (marking?.folded ?? findings.map { (Self.fold($0.original), $0.original) }) + marks.entries.map { (Self.fold($0.text), $0.text) }
        for (other, written) in others where other.count >= 3 && !own.contains(other) && Self.holds(folded, other) { return .other(written) }
        return nil
    }

    /// Whether `text` holds `word` as a whole word: no letter or digit right before or after it.
    static func holds(_ text: String, _ word: String) -> Bool {
        var from = text.startIndex
        while from < text.endIndex, let found = text.range(of: word, range: from..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            func joins(_ character: Character?) -> Bool { character.map { $0.isLetter || $0.isNumber } ?? false }
            if !joins(before), !joins(after) { return true }
            from = text.index(after: found.lowerBound)
        }
        return false
    }
}

extension ScrubResult {
    /// The edits this result was written with.
    public var edits: Edits { edited ?? Edits() }

    /// `finding` as this result writes it: with the kind and the stand-in a
    /// person gave it, or, for a person whose name was typed anew, the new name.
    public func revised(_ finding: Finding) -> Finding {
        guard finding.id >= 0, let revision = review?.revised(edits)[finding.id] else { return finding }
        func excerpt(_ excerpt: Excerpt) -> Excerpt { Excerpt(before: excerpt.before, standIn: revision.standIn, after: excerpt.after) }
        let places = finding.places.map { Occurrence(id: $0.id, record: $0.record, confidence: $0.confidence, excerpt: $0.excerpt.map(excerpt)) }
        return Finding(id: finding.id, entity: revision.entity, original: finding.original, standIn: revision.standIn, confidence: finding.confidence, places: places,
                       excerpts: finding.excerpts.map(excerpt), suspected: finding.suspected, doubt: finding.doubt)
    }

    /// Every value as this result writes it: Scrub's findings, each as
    /// edits revise it, then the values marked by hand.
    public var current: [Finding] {
        let revisions = review?.revised(edits) ?? [:]
        let revisedFindings = revisions.isEmpty ? findings : findings.map { revisions[$0.id] == nil ? $0 : revised($0) }
        return revisedFindings + byHand
    }

    /// Why `typed` may not replace `findings`' stand-ins, or nil when it may.
    public func refusal(_ typed: String, for findings: [Finding]) -> Refusal? {
        review?.refusal(typed, for: findings, marks: marks) ?? (typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : nil)
    }

    /// The choices, marks and edits that read `targets` as `kind` and write
    /// `replacement` in place of their stand-ins, either left nil to keep it
    /// as it is. Each is replaced again where it was left as written. A mark
    /// changes kind by being marked again, and keeps its typed replacement.
    /// Throws the `Refusal` of an unsafe replacement, and changes nothing.
    public func editing(_ targets: [Finding], kind: String?, replacement: String?, choices: Choices, marks: Marks, edits: Edits) throws -> (Choices, Marks, Edits) {
        if let replacement, let refusal = refusal(replacement, for: targets) { throw refusal }
        var choices = choices, marks = marks, edits = edits
        for target in targets {
            if target.id < 0 {
                guard let entry = marks.entries.first(where: { Review.findingID($0) == target.id }) else { continue }
                var id = target.id
                if let kind, kind != entry.entity {
                    let typed = edits.replacements[id]
                    edits.setReplacement(nil, of: id)
                    id = Review.findingID(marks.add(entry.text, as: kind))
                    edits.setReplacement(typed, of: id)
                }
                if let replacement { edits.setReplacement(replacement, of: id) }
                choices.set(target, leave: false)
            } else {
                let made = findings.indices.contains(target.id) ? findings[target.id] : target
                if let kind { edits.setKind(kind == made.entity ? nil : kind, of: made.id) }
                if let replacement { edits.setReplacement(replacement == made.standIn ? nil : replacement, of: made.id) }
                choices.set(made, leave: false)
            }
        }
        return (choices, marks, edits)
    }

    /// The choices and marks that keep `targets` as written: Scrub's findings
    /// left everywhere, and marks taken off.
    public func keeping(_ targets: [Finding], choices: Choices, marks: Marks) -> (Choices, Marks) {
        var pick = Pick()
        pick.replaced = targets.filter { $0.id >= 0 }
        pick.marked = marks.entries.filter { entry in targets.contains { $0.id == Review.findingID(entry) } }
        return keeping(pick, choices: choices, marks: marks)
    }
}
