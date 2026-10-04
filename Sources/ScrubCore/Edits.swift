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
    /// The findings and marks given a replacement, in the order each was
    /// last typed: a name typed later for a person wins over one typed
    /// before it, part by part (see `Review.revisions`). Only the order is
    /// kept, so the same replacements typed in the same order are the same edits.
    public private(set) var typed: [Finding.ID] = []

    public init() {}

    public var isEmpty: Bool { kinds.isEmpty && replacements.isEmpty }
    public func touches(_ id: Finding.ID) -> Bool { kinds[id] != nil || replacements[id] != nil }
    /// Reads a finding as `entity`; nil reads it as Scrub did.
    public mutating func setKind(_ entity: String?, of id: Finding.ID) { kinds[id] = entity }
    /// Writes `text` in place of a finding's or a mark's stand-in, typed
    /// after every other; nil writes its own again.
    public mutating func setReplacement(_ text: String?, of id: Finding.ID) {
        replacements[id] = text
        typed.removeAll { $0 == id }
        if text != nil { typed.append(id) }
    }
}

/// Why a replacement or a kind is refused. Nothing of a refused one is written.
public enum Refusal: Error, Sendable, Equatable {
    case empty
    /// It is, or holds, the value it would replace.
    case original
    /// It holds another value Scrub found or the person marked, as written here.
    case other(String)
    /// It holds a word of a name Scrub found or the person marked, as written there.
    case part(String)
    /// The value is a bare number in the file (a JSON number), which only a number may replace.
    case number
    /// It would leave a place the value was replaced in as written: this form of it, as the file writes it.
    case uncovered(String)
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
    /// "maren.holt@…", "@mholt"). Names typed for one person apply in the
    /// order typed, the later winning part by part, and a name typed before
    /// the last is written again with the names typed since: "Jane Roe" for
    /// her, then "Alice" for her first name alone, reads "Alice Roe". A
    /// finding changed to another kind leaves its person and keeps nothing of
    /// theirs; its variants keep their stand-ins. A revision that cannot
    /// stand in every place of its value (a word where a JSON number stands)
    /// is written nowhere, and its finding keeps its stand-in (see `blocked`).
    /// Every caller holds the lock.
    func revisions(_ edits: Edits) throws -> [Finding.ID: Revision] {
        guard !edits.isEmpty else { return [:] }
        if let known = marking?.revised, known.edits == edits { return known.revisions }
        _ = try prepared()
        var made: [Finding.ID: Revision] = [:]
        // Each person's names typed anew, in the order typed.
        var typedFor: [Int: [(id: Finding.ID, renaming: Renaming)]] = [:]
        let order = Dictionary(uniqueKeysWithValues: edits.typed.enumerated().map { ($0.element, $0.offset) })
        let edited = Set(edits.kinds.keys).union(edits.replacements.keys).filter(findings.indices.contains)
        for id in edited.sorted(by: { (order[$0] ?? -1, $0) < (order[$1] ?? -1, $1) }) {
            let finding = findings[id]
            let entity = edits.kinds[id] ?? finding.entity
            let typed = edits.replacements[id]
            // A new kind draws a new stand-in, as marking the value as that kind would.
            let standIn = try typed ?? (entity == finding.entity ? finding.standIn : standIn(for: finding.original, entity: entity, fresh: true))
            made[id] = Revision(entity: entity, standIn: standIn, was: finding.standIn)
            guard let typed, Self.names.contains(entity), Self.names.contains(finding.entity), let person = personOf[id], people.names.indices.contains(person),
                  let renaming = Self.renaming(Self.read(finding.standIn), to: typed, names: people.names[person]) else { continue }
            typedFor[person, default: []].append((id, renaming))
        }
        var renamings: [Int: Renaming] = [:]
        for (person, typed) in typedFor {
            var names = people.names[person]
            var typedWith: [(id: Finding.ID, names: PersonLinks.Names)] = []
            for edit in typed {
                names = PersonLinks.Names(first: edit.renaming.first ?? names.first, last: edit.renaming.last ?? names.last)
                typedWith.append((edit.id, names))
                renamings[person] = renamings[person].map { $0.merged(edit.renaming) } ?? edit.renaming
            }
            // The last name typed stays as typed; each before it takes the names typed since.
            let final = Renaming(first: names.first, last: names.last)
            for edit in typedWith.dropLast() {
                guard let typed = edits.replacements[edit.id], let revision = made[edit.id] else { continue }
                made[edit.id] = Revision(entity: revision.entity, standIn: Self.renamed(typed, entity: findings[edit.id].entity, names: edit.names, to: final), was: revision.was)
            }
        }
        // The same value written another way, as a link writes it ("Odalys+Ferriter"), is the same value,
        // when it is the same person's: another person's "Odalys" keeps her own stand-in.
        let groups = sameValues()
        for (id, revision) in made.sorted(by: { $0.key < $1.key }) {
            let finding = findings[id]
            let group = groups[Self.matchKey(Self.read(finding.original), entity: finding.entity)] ?? []
            for other in group where other != id && made[other] == nil && findings[other].entity == finding.entity && sharesValue(id, other, among: group) {
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
        var blocked: Set<Finding.ID> = []
        if !numeric.isEmpty {
            for (id, revision) in made where findings[id].places.contains(where: { !writable(revision, at: $0) }) { blocked.insert(id) }
            for id in blocked { made[id] = nil }
        }
        var byStandIn: [String: [Finding.ID]] = [:]
        for id in made.keys.sorted() { byStandIn[made[id]?.standIn.lowercased() ?? "", default: []].append(id) }
        marking?.revised = (edits, made, byStandIn, blocked)
        return made
    }

    /// The findings whose revision `edits` ask for but cannot be written in
    /// every place of the value, so it is written nowhere (see `revisions`).
    /// Every caller holds the lock.
    func blocked(_ edits: Edits) throws -> Set<Finding.ID> {
        guard !edits.isEmpty else { return [] }
        _ = try revisions(edits)
        return marking?.revised?.blocked ?? []
    }

    /// Whether `revision` can be written at `place`: anywhere but a bare JSON
    /// number, which takes only a number.
    private func writable(_ revision: Revision, at place: Occurrence) -> Bool {
        guard spots.indices.contains(place.id) else { return true }
        let spot = spots[place.id]
        guard numeric.contains(spot.value) else { return true }
        let value = values[spot.value]
        let marks = spot.suspected ? value.unresolved : value.marks
        guard marks.indices.contains(spot.mark) else { return true }
        let range = marks[spot.mark].range
        return written(revision, over: TextRanges.substring(value.text, range), value: spot.value, range: range) != nil
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

    /// Whether `other`, a finding of the same value as `id` (both in
    /// `group`), is the same one to an edit or a kept original: a person's
    /// findings reach only that person's, and one no one owns is reached only
    /// where no other person owns that text. Two people called Odalys keep
    /// their own stand-ins whatever is done to one of them.
    func sharesValue(_ id: Finding.ID, _ other: Finding.ID, among group: [Finding.ID]) -> Bool {
        let mine = personOf[id], theirs = personOf[other]
        if mine == theirs { return true }
        let owners = Set(group.compactMap { personOf[$0] })
        // One of the two is no one's: the same value unless someone else owns the text too.
        if let mine, theirs == nil { return owners == [mine] }
        if let theirs, mine == nil { return owners == [theirs] }
        return false
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
    /// where it cannot stand: a bare JSON number takes only a JSON number.
    func written(_ revision: Revision, over current: String, value: Int, range: Range<Int>) -> String? {
        if let component = links(value).first(where: { $0.range.lowerBound <= range.lowerBound && range.upperBound <= $0.range.upperBound }) {
            let read = URLs.decode(current, component.part)
            return URLs.encode(Self.cased(revision.standIn, like: read, was: revision.was), like: current, component.part)
        }
        let made = Visible.rewrite(current, with: Self.cased(revision.standIn, like: Visible.plain(current), was: revision.was))
        if numeric.contains(value), !Self.isJSONNumber(TextRanges.replace(values[value].text, range, with: made)) { return nil }
        return made
    }

    /// Whether `text` is a number as JSON writes one: an optional minus, no
    /// leading zero, then an optional fraction and exponent ("-0.5e-3").
    /// "0012", "+3", "1." and ".5" are not.
    static func isJSONNumber(_ text: String) -> Bool {
        var units = Array(text.utf8)[...]
        func digits() -> Int {
            var count = 0
            while let unit = units.first, (48...57).contains(unit) { units.removeFirst(); count += 1 }
            return count
        }
        if units.first == 45 { units.removeFirst() }
        guard let lead = units.first, (48...57).contains(lead) else { return false }
        if lead == 48 { units.removeFirst() } else { _ = digits() }
        if units.first == 46 {
            units.removeFirst()
            guard digits() > 0 else { return false }
        }
        if units.first == 101 || units.first == 69 {
            units.removeFirst()
            if units.first == 43 || units.first == 45 { units.removeFirst() }
            guard digits() > 0 else { return false }
        }
        return units.isEmpty
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
    /// empty, holds the value it replaces, stands where only a number may, or
    /// holds what `held` refuses of another value Scrub found or `marks` hold.
    func refusal(_ typed: String, for edited: [Finding], marks: Marks) -> Refusal? {
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        lock.lock()
        defer { lock.unlock() }
        let held = held(typed, own: edited.map(\.original), marks: marks)
        if held == .original { return held }
        if !Self.isJSONNumber(typed), edited.contains(where: { finding in
            finding.id >= 0 && finding.places.contains { spots.indices.contains($0.id) && numeric.contains(spots[$0.id].value) }
        }) { return .number }
        return held
    }

    /// Why edits that were `before` may not become `after`, or nil when they
    /// may. A revision that cannot be written in every place its value
    /// stands (a word where a JSON number stands), or a mark no longer
    /// written in a place it was (a bare number, or one of its forms), is
    /// refused: no place a finding or a mark replaced is left as written by
    /// an edit. A finding's places are its own, so it keeps every one unless
    /// it is `blocked`. With a replacement typed for the
    /// values `typedFor` names, so is any stand-in it would write in their
    /// other forms (an email's local part, "Ms Roe", a handle) that holds
    /// what `held` refuses.
    func refusal(writing after: Edits, marks: Marks, over before: Edits, marks old: Marks, typedFor own: [String]?) throws -> Refusal? {
        lock.lock()
        defer { lock.unlock() }
        let was = try revisions(before), wasBlocked = try blocked(before)
        let will = try revisions(after), blocked = try blocked(after)
        if !blocked.isSubset(of: wasBlocked) { return .number }
        // A mark changed (another kind, or a replacement typed) still stands in every place it stood in:
        // a bare number it cannot be written in is refused as such, and any other form as the form it is.
        var changed: [Marks.Entry] = []
        for entry in marks.entries {
            let id = Self.findingID(entry)
            guard let previous = old.entries.first(where: { Self.matchKey($0.text, entity: $0.entity) == Self.matchKey(entry.text, entity: $0.entity) }),
                  previous != entry || after.replacements[id] != before.replacements[id] else { continue }
            changed.append(entry)
            var kept: [Int: [Range<Int>]] = [:]
            for place in try locate(entry, as: after.replacements[id]).places { kept[place.value, default: []].append(place.range) }
            for place in try locate(previous, as: before.replacements[Self.findingID(previous)]).places
            where !(kept[place.value] ?? []).contains(where: { $0.lowerBound <= place.range.lowerBound && place.range.upperBound <= $0.upperBound }) {
                return numeric.contains(place.value) ? .number : .uncovered(TextRanges.substring(values[place.value].text, place.range))
            }
        }
        guard let own else { return nil }
        for (id, revision) in will.sorted(by: { $0.key < $1.key }) where was[id]?.standIn != revision.standIn {
            if let refusal = held(revision.standIn, own: own + [findings[id].original], marks: marks) { return refusal }
        }
        for entry in changed {
            guard let typed = after.replacements[Self.findingID(entry)] else { continue }
            for place in try locate(entry, as: typed).places {
                if let refusal = held(place.written, own: own + [entry.text], marks: marks) { return refusal }
            }
        }
        return nil
    }

    /// What every original reads as, for `held`: built once for Scrub's
    /// findings, and for a person's marks each time they are asked about.
    struct Readable {
        /// Each original as it reads, folded, with how it is written and whether it is a name.
        var originals: [(read: String, written: String, name: Bool)] = []
        /// Each word of a name of three letters or more, folded, with how it is written.
        var words: [(read: String, written: String)] = []
        /// A name's words joined as a handle is ("odalysferriter", "oferriter"), folded, and the name.
        var joined: [String: String] = [:]
        /// Each original's variants as the leak gate reads them, its originals folded.
        var gate = LeakGate()
        /// How each folded original is written.
        var written: [String: String] = [:]

        init<S: Sequence>(_ values: S) where S.Element == (original: String, entity: String) {
            var seen: Set<String> = [], seenWords: Set<String> = []
            for (original, entity) in values {
                let name = Review.names.contains(entity)
                let reads = Review.readings(original)
                for read in reads where !read.isEmpty && seen.insert(read).inserted {
                    originals.append((read, original, name))
                    written[read] = original
                }
                guard let read = reads.first, !read.isEmpty else { continue }
                // Read with its apostrophes and hyphens left out too, so "osullivan99" is hers as "sullivan99" is.
                for read in [read] + Review.joinings(read).prefix(1) { gate.add([Replacement(original: read, fake: Review.placeholder(read), entity: entity)]) }
                guard name else { continue }
                // A word read with its apostrophe left out or a space for it, as a reading of the text is too:
                // "O’Sullivan" is "osullivan" and "o sullivan". "O" alone is no word of hers.
                let nameWords = Review.nameWords(Visible.plain(original))
                for word in nameWords {
                    let folded = Review.folded(word), joinings = Review.joinings(folded)
                    for read in joinings.isEmpty ? [folded] : joinings where seenWords.insert(read).inserted { words.append((read, word)) }
                }
                // Joined as a mark's handles are; a form with a dot or an underscore holds a word of the name, found above.
                let bare = Visible.plain(original).split(whereSeparator: \.isWhitespace).filter { !People.isTitle(String($0)) && !People.isSuffix(String($0)) }.joined(separator: " ")
                var forms = Review.forms(bare, entity: entity, standIn: bare).map(\.0)
                // Two words of the name side by side written as one: "Smith-Jones" or "Smith Jones" as "SmithJones".
                for (one, two) in zip(nameWords, nameWords.dropFirst()) { forms.append(one + two) }
                for form in forms {
                    let key = Review.joinings(Review.folded(form)).first ?? Review.folded(form)
                    if key.count >= 3, key.allSatisfy(\.isLetter), joined[key] == nil { joined[key] = original }
                }
            }
        }
    }

    /// The readable originals of Scrub's findings, built on first use. Every caller holds the lock.
    private func readable() -> Readable {
        if let known = marking?.readable { return known }
        let made = Readable(findings.lazy.map { (original: $0.original, entity: $0.entity) })
        marking?.readable = made
        return made
    }

    /// What `text`, typed by a person or written by an edit, holds that it
    /// may not, read as a reader reads it (without hidden characters or
    /// in-word markup, in any case, without accents, and decoded where it
    /// decodes): one of the values `own` names (`.original`); another value
    /// found or marked, whole, as a word of three letters or more (`.other`);
    /// a word of a name, three letters or more (`.part`); or a name's words
    /// joined as a handle, an email's local part or a number with other
    /// separators, as the marks and the leak gate find them. Every caller holds the lock.
    func held(_ text: String, own: [String], marks: Marks) -> Refusal? {
        let reads = Self.readings(text)
        let mine = Set(own.flatMap(Self.readings)).subtracting([""])
        // Inside a word too, but a value of one or two letters only as a word of its own.
        if reads.contains(where: { read in mine.contains { $0.count >= 3 ? read.contains($0) : Self.holds(read, $0) } }) { return .original }
        // Each run of letters apart from the digits beside it too, so "ferriter99@example.org" and "@odalys99" hold her names.
        let tokens = Set(reads.flatMap(Self.tokens).flatMap { [$0] + Self.pieces($0) })
        func holds(_ word: String) -> Bool { word.allSatisfy { $0.isLetter || $0.isNumber } ? tokens.contains(word) : reads.contains { Self.holds($0, word) } }
        let sets = [readable(), Readable(marks.entries.map { (original: $0.text, entity: $0.entity) })]
        func whole(names: Bool) -> Refusal? {
            for set in sets {
                for other in set.originals where other.name == names && other.read.count >= 3 && !mine.contains(other.read) && holds(other.read) { return .other(other.written) }
            }
            return nil
        }
        if let refusal = whole(names: false) { return refusal }
        for set in sets {
            for word in set.words where holds(word.read) { return .part(word.written) }
        }
        // A name whole, however short its words ("Bo Li").
        if let refusal = whole(names: true) { return refusal }
        func source(_ name: String) -> Refusal { mine.contains(Self.readings(name).first ?? name) ? .original : .other(name) }
        for set in sets {
            for token in tokens.sorted() { if let name = set.joined[token] { return source(name) } }
            // An address or a handle read as the words it is made of: the gate reads no token with an at sign in it,
            // and an email's local part ("odalys.ferriter@…") is its own variant.
            for read in reads.flatMap({ $0.contains("@") ? [$0, $0.replacingOccurrences(of: "@", with: " ")] : [$0] }) {
                if let leak = set.gate.scan(read, suspects: false, isCancelled: { false }).leaks.first { return source(set.written[leak.source] ?? leak.source) }
            }
        }
        return nil
    }

    /// Name particles, which are no one's name alone.
    private static let particles: Set<String> = ["van", "von", "der", "den", "del", "della", "des", "dos", "das", "bin", "ibn"]

    /// The words of a name worth refusing: three letters or more, each part
    /// of a hyphenated one apart, and no title, suffix or particle.
    static func nameWords(_ name: String) -> [String] {
        name.split { $0.isWhitespace || $0 == "," || hyphens.contains($0) }.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { word in
                word.filter(\.isLetter).count >= 3 && word.allSatisfy { $0.isLetter || $0 == "." || apostrophes.contains($0) }
                    && !People.isTitle(word) && !People.isSuffix(word) && !particles.contains(word.lowercased())
            }
    }

    /// `text` as a reader reads it, folded: without hidden or formatting
    /// characters or in-word markup, then with a plus read as a space, and
    /// percent-decoded where it decodes. A name's apostrophe reads the same
    /// straight, curly or left out ("O'Sullivan", "O’Sullivan", "OSullivan"),
    /// and its hyphen as a space or as nothing ("Smith-Jones", "Smith Jones",
    /// "SmithJones"): each reading is also read with them so. Each reading once.
    static func readings(_ text: String) -> [String] {
        func plain(_ value: String) -> String {
            String(String.UnicodeScalarView(Visible.plain(value).unicodeScalars.filter { $0.properties.generalCategory != .format }))
        }
        let shown = plain(text)
        var reads = [shown]
        if shown.contains("+") { reads.append(shown.replacingOccurrences(of: "+", with: " ")) }
        if shown.contains("%"), let decoded = reads.last?.removingPercentEncoding { reads.append(plain(decoded)) }
        var seen: Set<String> = []
        return reads.map(folded).flatMap { [$0] + joinings($0) }.filter { seen.insert($0).inserted }
    }

    /// Apostrophes as a name writes them: straight, curly, a modifier letter, a prime, an accent.
    static let apostrophes: Set<Character> = ["'", "’", "‘", "ʼ", "′", "`", "´", "ʹ", "‛", "＇"]
    /// Hyphens and dashes as a name writes them.
    private static let hyphens: Set<Character> = ["-", "‐", "‑", "‒", "–", "—", "−", "﹣", "－"]

    /// `text` with each apostrophe and hyphen between two letters left out,
    /// then read as a space; none where it has neither. "o'sullivan-reyes"
    /// reads "osullivanreyes" and "o sullivan reyes".
    static func joinings(_ text: String) -> [String] {
        let characters = Array(text)
        func between(_ index: Int) -> Bool { index > 0 && index + 1 < characters.count && characters[index - 1].isLetter && characters[index + 1].isLetter }
        func joint(_ index: Int) -> Bool { (apostrophes.contains(characters[index]) || hyphens.contains(characters[index])) && between(index) }
        guard characters.indices.contains(where: joint) else { return [] }
        var joined = "", spaced = ""
        for index in characters.indices {
            if joint(index) {
                spaced.append(" ")
                continue
            }
            joined.append(characters[index])
            spaced.append(characters[index])
        }
        return [joined, spaced]
    }

    /// Folded for comparing what a person types: in any case, without accents, and full-width letters as their own.
    static func folded(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale) }

    /// The runs of letters and digits in `text`.
    static func tokens(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// A token's runs of letters and of digits, each apart: "ferriter99" is
    /// "ferriter" and "99". None where it is one run.
    static func pieces(_ token: String) -> [String] {
        var runs: [String] = []
        var letters: Bool?
        for character in token {
            if character.isLetter == letters, !runs.isEmpty { runs[runs.count - 1].append(character) } else { runs.append(String(character)) }
            letters = character.isLetter
        }
        return runs.count > 1 ? runs : []
    }

    /// A stand-in no original is, of the same shape: each letter an "x",
    /// each digit another. The leak gate learns a value's variants from it.
    static func placeholder(_ value: String) -> String {
        String(value.map { $0.isLetter ? "x" : $0.isNumber ? ($0 == "1" ? "2" : "1") : $0 })
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

    /// Why `typed` may not replace `findings`' stand-ins on top of this
    /// result's edits, or nil when it may (see `editing`).
    public func refusal(_ typed: String, for findings: [Finding]) -> Refusal? {
        do {
            _ = try editing(findings, kind: nil, replacement: typed, choices: choices, marks: marks, edits: edits)
            return nil
        } catch {
            return error as? Refusal
        }
    }

    /// The choices, marks and edits that read `targets` as `kind` and write
    /// `replacement` in place of their stand-ins, either left nil to keep it
    /// as it is. Each is replaced again where it was left as written. A mark
    /// changes kind by being marked again, and keeps its typed replacement.
    /// Throws the `Refusal` of an unsafe replacement, or of one, or a kind,
    /// that cannot be written in every place it would stand, or whose
    /// stand-ins in the value's other forms would hold an original; and
    /// changes nothing.
    public func editing(_ targets: [Finding], kind: String?, replacement: String?, choices: Choices, marks: Marks, edits: Edits) throws -> (Choices, Marks, Edits) {
        if let replacement {
            if let review, let refusal = review.refusal(replacement, for: targets, marks: marks) { throw refusal }
            if review == nil, replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Refusal.empty }
        }
        let made = edited(targets, kind: kind, replacement: replacement, choices: choices, marks: marks, edits: edits)
        if let review, let refusal = try review.refusal(writing: made.2, marks: made.1, over: edits, marks: marks, typedFor: replacement.map { _ in targets.map(\.original) }) { throw refusal }
        return made
    }

    /// `editing` without its checks.
    private func edited(_ targets: [Finding], kind: String?, replacement: String?, choices: Choices, marks: Marks, edits: Edits) -> (Choices, Marks, Edits) {
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
