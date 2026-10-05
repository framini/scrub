import Foundation

public final class Job {
    public let detector = Detector()
    private let standIns: StandIns
    private(set) var gazetteer: [String: Set<String>] = [:]
    private(set) var nameParts: Set<String> = []
    /// Parts that are also ordinary words, and short forms: someone only where written as a name (see `NameCues.position`).
    private(set) var cuedParts: Set<String> = []
    private(set) var replacements: [Replacement] = []
    private(set) var sensitiveOriginals: [SensitiveOriginal] = []
    /// How sure the detectors that found each original were, by its lowercase
    /// form: the surest finding of it anywhere in the document. A name found
    /// again by the gazetteer or the sweep for originals is as sure as where it was learned.
    private var confidences: [String: Double] = [:]
    func note(_ original: String, confidence: Double) {
        let key = original.lowercased()
        if confidences[key].map({ $0 < confidence }) ?? true { confidences[key] = min(confidence, 1) }
    }
    func confidence(of original: String) -> Double? { confidences[original.lowercased()] }
    /// How sure Scrub is of one place: what a detector read there, or for a
    /// value found again by the name lists or the sweep for originals, as
    /// sure as where it was learned. Review takes a finding's least sure place.
    func here(_ span: Span, _ original: String) -> Double {
        let learned = span.score == GazetteerMatcher.score || span.score > 1
        return min(learned ? confidence(of: original) ?? span.score : span.score, 1)
    }
    /// What each original was surest read as anywhere in the document: a login
    /// under its key is a username, though a model reads it in a note as a
    /// secret. Ties go to a whole field, then to the first reading.
    private var kinds: [String: (entity: String, score: Double, whole: Bool)] = [:]
    /// Names and places take their stand-ins from a person or an address, and
    /// these from what they are read off; each keeps the kind it was read as.
    private static let ownKinds: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "INITIALS", "LOCATION", "REGION", "POSTAL_CODE", "ADDRESS", "LATITUDE", "LONGITUDE", "COORDINATES", "AGE", "LAST_DIGITS", "TIME_ZONE"]
    private func noteKind(_ original: String, _ span: Span, whole: Bool) {
        guard !Self.ownKinds.contains(span.entity) else { return }
        if let known = kinds[original], known.score > span.score || known.score == span.score && (known.whole || !whole) { return }
        kinds[original] = (span.entity, span.score, whole)
    }
    /// The one kind an original is replaced as, so it has one stand-in wherever it is written.
    /// A place that is a known person's name ("Brightwater" read as a town) is that person.
    func kind(of original: String, read entity: String) -> String {
        if entity == "LOCATION" && standIns.people.knows(original) { return "PERSON" }
        guard !Self.ownKinds.contains(entity), let known = kinds[original]?.entity else { return entity }
        return known
    }
    private var emitted: Set<String> = []
    private var recordsReplacements = true
    func setReplacementRecording(_ enabled: Bool) { recordsReplacements = enabled }
    public private(set) var counts: [String: Int] = [:]
    public init() { standIns = StandIns() }
    init(seed: UInt64) { standIns = StandIns(rng: SeededGenerator(seed: seed)) }
    func reserveNames(_ names: [String]) { standIns.people.reserve(names) }
    public func associate(first: String?, last: String?, email: String?) {
        standIns.people.associate(first: first, last: last, email: email)
    }
    public func observe(_ fields: [(text: String, key: String?)]) -> [[Span]] {
        observe(fields, contextWords: [])
    }
    func observe(_ fields: [(text: String, key: String?)], contextWords: Set<String>) -> [[Span]] {
        let bases = fields.map { detector.base($0.text, key: $0.key, contextWords: contextWords) }
        let found = bases.map(Detector.resolve)
        let identified = zip(fields, found).flatMap { field, spans in
            spans.map { ($0.entity, TextRanges.substring(field.text, $0.range)) }
        }
        let first = identified.first { $0.0 == "FIRST_NAME" }?.1
        let last = identified.first { $0.0 == "LAST_NAME" }?.1
        let email = identified.first { $0.0 == "EMAIL_ADDRESS" }?.1
        if first != nil && last != nil { associate(first: first, last: last, email: email) }
        observeSpans(zip(fields, found).map { ($0.text, $1) })
        let matcher = GazetteerMatcher(gazetteer, nameParts: nameParts, cuedParts: cuedParts)
        return zip(fields, bases).map { detector.combined($1, text: $0.text, matcher: matcher) }
    }
    /// Kinds whose words are someone's name: an ID that starts with one is theirs.
    private static let naming: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "USERNAME"]
    func observeSpans<S: Sequence>(_ fields: S) where S.Element == (String, [Span]) {
        for (text, spans) in fields {
            let length = (text as NSString).length
            for span in spans {
                // A link's part is the value it spells: "Odalys+Ferriter" is Odalys Ferriter.
                let value = span.url.map { URLs.decode(TextRanges.substring(text, span.range), $0) } ?? TextRanges.substring(text, span.range)
                standIns.avoid(value)
                if span.entity == "PHONE_NUMBER" { standIns.notePhone(value) }
                if Self.naming.contains(span.entity) { standIns.noteName(value) }
                note(value, confidence: span.score)
                noteKind(value, span, whole: span.range == 0..<length)
            }
            for span in spans where GazetteerMatcher.supportedEntities.contains(span.entity) {
                let value = span.url.map { URLs.decode(TextRanges.substring(text, span.range), $0) } ?? TextRanges.substring(text, span.range)
                // Replaced wherever it appears, so a name must at least have letters.
                if span.entity != "PHONE_NUMBER", !value.contains(where: \.isLetter) { continue }
                gazetteer[span.entity, default: []].insert(value)
                if span.entity == "PERSON" {
                    _ = standIns.people.registerFull(value)
                    rememberParts(of: value, confidence: span.score)
                }
            }
        }
    }
    // "Thanks, Maria" after "Maria Gonzalez" is the same person, and so are
    // "Gonzalez's", "GONZALEZ", "M. Gonzalez", "Gonzalez, Maria" and handles
    // like "maria.gonzalez". A part no English word could be ("Okafor") is
    // matched however it is written, so "thanks okafor" counts too; a short
    // one only with its capital. A part that is also a word ("Hunt", "Will")
    // and a short form ("Bob" for "Robert") are someone only where written as
    // a name: with a capital, and mid-sentence, after a title or greeting, or
    // before "said".
    private func rememberParts(of name: String, confidence: Double) {
        // What a name teaches is as sure as the name.
        func learn(_ literal: String) {
            gazetteer["PERSON", default: []].insert(literal)
            note(literal, confidence: confidence)
        }
        // A title before a name ("Ms E. Okafor") is part of no one's name, nor a suffix after it.
        let tokens = (People.naturalOrder(name) ?? name).split { $0.isWhitespace || $0 == "," }.map(String.init).drop { People.isTitle($0) }.filter { !People.isSuffix($0) }
        guard tokens.count >= 2, let first = tokens.first, let last = tokens.last else { return }
        func usable(_ part: String) -> Bool { part.count >= 2 && part.first?.isUppercase == true && part.allSatisfy({ $0.isLetter || "'’-".contains($0) }) }
        // "Refund" read as a surname ("Saoirse⏎Refund approved") is a word: a dictionary
        // holds it and no list of names does, so it too counts only where written as a name.
        func wordlike(_ part: String) -> Bool { Names.ambiguousFirst.contains(part.lowercased()) || NameLists.isWordlike(part) || NameLists.isOrdinary(part) || NameLists.isUnlistedWord(part) }
        let parts = [first, last].filter(usable)
        for part in parts {
            learn(part)
            if wordlike(part) { cuedParts.insert(part); nameParts.insert(part) }
            else if part.count < 4 && !(part == first && Names.unambiguousFirst.contains(part.lowercased())) { nameParts.insert(part) }
        }
        // Each part of a hyphenated surname alone ("Jones" after "Brisa Smith-Jones") is
        // theirs too, where written as a name.
        if parts.contains(last) {
            let pieces = last.split(whereSeparator: { "-‐‑–".contains($0) }).map(String.init)
            for piece in pieces where pieces.count == 2 && piece.count >= 3 && usable(piece) {
                learn(piece)
                cuedParts.insert(piece)
                nameParts.insert(piece)
            }
        }
        guard parts.count == 2 else { return }
        for separator in [".", "_"] { learn(first + separator + last) }
        // Written with an initial, last name first, or with a short form of the first name.
        let initial = String(first.prefix(1))
        for form in [initial + ". " + last, last + ", " + first, last + ", " + initial + "."] { learn(form) }
        // "A Long" without its full stop is how "a long time" begins.
        if !wordlike(last) {
            learn(initial + " " + last)
            nameParts.insert(initial + " " + last)
        }
        for short in Nicknames.variants(of: first) {
            let written = short.prefix(1).uppercased() + short.dropFirst()
            learn(written + " " + last)
            learn(written)
            cuedParts.insert(written)
            nameParts.insert(written)
        }
    }
    func recordOriginals<S: Sequence>(_ fields: S) where S.Element == (String, [Span]) {
        for (text, spans) in fields {
            for span in spans {
                let original = TextRanges.substring(text, span.range)
                sensitiveOriginals.append(SensitiveOriginal(original: original, entity: span.entity))
                // Written plainly elsewhere, a link's value is found by what it spells.
                if let part = span.url, case let plain = URLs.decode(original, part), plain != original { sensitiveOriginals.append(SensitiveOriginal(original: plain, entity: span.entity)) }
            }
        }
    }
    public func replacement(for entity: String, original: String) -> String {
        replacement(for: entity, original: original, persona: nil)
    }
    /// Where the value being scrubbed sits: its index among the document's
    /// values and the records around it, innermost first (see `StandIns.scopes`).
    private var spot: (value: String, records: [String], part: KeyHints.DatePart?)?
    private var looseValues = 0
    /// `part`: the part of a birth date the value is, when its key says so ("birth_month").
    /// `object`: the object a flattened header names within the innermost record
    /// ("applicant" of "applicant.dob"), a scope of its own inside that record, so
    /// two people in one row each keep their own birth date's parts.
    func enter(value: Int, records: [Int], part: KeyHints.DatePart? = nil, object: String = "") {
        var scopes = records.map { "r\($0)" }
        if let innermost = scopes.first, !object.isEmpty {
            // "applicant.birth" sits in "applicant" too: innermost first, each a scope of the record.
            let names = object.split(separator: ".")
            scopes.insert(contentsOf: names.indices.reversed().map { innermost + "/" + names[...$0].joined(separator: ".") }, at: 0)
        }
        spot = ("v\(value)", scopes, part)
    }
    /// The key of the value being scrubbed, or a fresh one outside a document.
    private func valueKey() -> String {
        if let spot { return spot.value }
        looseValues += 1
        return "v-\(looseValues)"
    }
    /// Where each place in the text of the value being scrubbed sits.
    func spots(_ text: String) -> Spots { Spots(text, value: valueKey()) }
    /// Whether the last stand-in drawn was read off one of several values
    /// that disagree (an age two birth dates fit), so review should ask.
    private(set) var lastUnclear = false
    /// `local` names where in its value the original sits (see `Spots`).
    func replacement(for entity: String, original: String, persona: Persona?, address: AddressParts? = nil, local: [String] = []) -> String {
        let actual = kind(of: original, read: entity)
        standIns.scopes = local + (spot?.records ?? [])
        standIns.unclear = false
        standIns.part = spot?.part
        defer { standIns.part = nil }
        let fake = standIns.replace(actual, original, persona: persona, address: address)
        lastUnclear = standIns.unclear
        if fake == original { return fake }
        if let owner = standIns.owner { link(original, fake, to: owner) }
        if recordsReplacements { replacements.append(Replacement(original: original, fake: fake, entity: actual)) }
        emitted.insert(fake.lowercased())
        counts[actual, default: 0] += 1
        return fake
    }
    /// A variant of a replaced value, written with the stand-in its original
    /// got (see `LeakGate`): counted and recorded as any replacement.
    func variant(_ original: String, fake: String, entity: String, source: String? = nil) -> String {
        // "@odalysf" is the handle of whoever "Odalys Ferriter" is.
        if let source, let person = people.originals[source.lowercased()] { people.link(original, fake, to: person) }
        if recordsReplacements { replacements.append(Replacement(original: original, fake: fake, entity: entity)) }
        emitted.insert(fake.lowercased())
        counts[entity, default: 0] += 1
        return fake
    }
    /// Which person each name, and each email, username or initials built
    /// from one, was given a stand-in for, so a name typed in its place later
    /// reaches them all (see `Edits`).
    private(set) var people = PersonLinks()
    private var personIDs: [ObjectIdentifier: Int] = [:]
    private var personas: [Persona] = []
    private func link(_ original: String, _ fake: String, to persona: Persona) {
        let id: Int
        if let known = personIDs[ObjectIdentifier(persona)] { id = known } else {
            id = personas.count
            personIDs[ObjectIdentifier(persona)] = id
            personas.append(persona)
        }
        people.link(original, fake, to: id)
    }
    /// The people linked so far, with the stand-in names each was given.
    func personLinks() -> PersonLinks {
        var links = people
        // Read without fixing a first name no stand-in has shown yet.
        links.names = personas.map { PersonLinks.Names(first: $0.drawn, last: $0.last) }
        return links
    }
    /// The stand-in a value left as written would take if a person chooses to
    /// replace it: drawn as any other, but neither counted nor recorded. Nil
    /// when its kind keeps it as written (a time zone with no address beside it).
    func proposal(for entity: String, original: String) -> String? {
        let fake = standIns.replace(kind(of: original, read: entity), original)
        return fake == original ? nil : fake
    }
    public func digits(_ original: String) -> String {
        let fake = standIns.number(original)
        if recordsReplacements { replacements.append(Replacement(original: original, fake: fake, entity: "ID_NUMBER")) }
        emitted.insert(fake.lowercased())
        counts["ID_NUMBER", default: 0] += 1
        return fake
    }
    func number(_ original: String, entity: String) -> String {
        let negative = original.hasPrefix("-")
        let digits = negative ? String(original.dropFirst()) : original
        let fake = (negative ? "-" : "") + standIns.number(digits)
        counts[entity, default: 0] += 1
        if recordsReplacements { replacements.append(Replacement(original: original, fake: fake, entity: entity)) }
        return fake
    }
    /// A number found in the document is never another's stand-in; its own is
    /// drawn later, once the address beside it is known.
    func reserveNumeric(_ original: String, entity: String) {
        standIns.avoid(original)
        if entity == "LAST_DIGITS" { standIns.noteEnding(original) }
    }
    func numericLexeme(_ original: String, entity: String, address: AddressParts? = nil) -> String {
        standIns.scopes = (spot.map { [$0.value] } ?? []) + (spot?.records ?? [])
        standIns.unclear = false
        standIns.part = spot?.part
        defer { standIns.part = nil }
        let fake = standIns.numericLexeme(original, entity: entity, address: address)
        lastUnclear = standIns.unclear
        if fake == original { return fake }
        if recordsReplacements { replacements.append(Replacement(original: original, fake: fake, entity: entity)) }
        emitted.insert(fake.lowercased())
        counts[entity, default: 0] += 1
        return fake
    }
    @discardableResult
    func associateRecord(first: String?, last: String?, full: String?, email: String?, gender: String? = nil) -> Persona? {
        if let full {
            let person = standIns.people.registerFull(full, emailSafe: email != nil, gender: gender).0
            standIns.people.associate(person, email: email)
            return person
        }
        if first != nil || last != nil {
            let person = standIns.people.register(first, last, emailSafe: email != nil, gender: gender)
            standIns.people.associate(person, email: email)
            return person
        }
        return nil
    }
    /// Parts of one address written close together in text ("Tacoma, WA 98402",
    /// or a pasted object's "city", "state" and "zip") share a place: a part
    /// joins the address before it unless that address already has one.
    static func addresses(in text: String, _ spans: [Span]) -> [AddressParts?] {
        var result = [AddressParts?](repeating: nil, count: spans.count)
        var members: [Int] = []
        var parts = AddressParts()
        var end = 0
        func close() {
            for member in members where !parts.isEmpty { result[member] = parts }
            members = []
            parts = AddressParts()
        }
        var coordinates: Set<String> = []
        var phoned = false
        for (index, span) in spans.enumerated() where ["LOCATION", "REGION", "POSTAL_CODE", "LATITUDE", "LONGITUDE", "COORDINATES", "PHONE_NUMBER", "TIME_ZONE"].contains(span.entity) {
            let value = TextRanges.substring(text, span.range)
            let taken: Bool
            switch span.entity {
            case "LOCATION": taken = parts.city != nil
            case "REGION": taken = parts.region != nil
            case "POSTAL_CODE": taken = parts.postal != nil
            case "PHONE_NUMBER", "TIME_ZONE": taken = phoned && span.entity == "PHONE_NUMBER"
            default: taken = coordinates.contains(span.entity)
            }
            if taken || span.range.lowerBound - end > 160 { close(); coordinates = []; phoned = false }
            switch span.entity {
            case "LOCATION": parts.city = value
            case "REGION": parts.region = value
            case "POSTAL_CODE": parts.postal = value
            case "PHONE_NUMBER": phoned = true
            case "TIME_ZONE": break
            default:
                coordinates.insert(span.entity)
                if parts.coordinates == nil || span.entity == "LATITUDE" { parts.coordinates = value }
            }
            members.append(index)
            end = span.range.upperBound
        }
        close()
        return result
    }
    private static let related: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME", "INITIALS", "LOCATION", "REGION", "POSTAL_CODE", "ADDRESS", "LATITUDE", "LONGITUDE", "COORDINATES", "PHONE_NUMBER", "TIME_ZONE"]
    /// Values pasted as JSON, YAML or code sit in objects as a file's do, so
    /// they are tied together the same way: an address's parts and the person
    /// a name, email and username belong to, by the object each sits in.
    /// Values in prose between them fall back to what is written close by.
    func records(in text: String, _ spans: [Span]) -> ([AddressParts?], [Persona?])? {
        guard spans.contains(where: { Self.related.contains($0.entity) }) else { return nil }
        let structure = KeyedValues.scan(text)
        guard structure.parents.count > 1 || !structure.fields.isEmpty else { return nil }
        var byStart: [Int: (key: String, range: Range<Int>, level: Int)] = [:]
        for field in structure.fields { byStart[field.range.lowerBound] = field }
        var leaves: [DocumentLeaf] = []
        var leafOf = [Int?](repeating: nil, count: spans.count)
        var covered: Set<Int> = []
        for (index, span) in spans.enumerated() {
            guard let field = byStart[span.range.lowerBound], field.range.upperBound >= span.range.upperBound else { continue }
            leafOf[index] = leaves.count
            covered.insert(field.range.lowerBound)
            leaves.append(DocumentLeaf(TextRanges.substring(text, span.range), key: field.key, records: structure.ancestry(field.level)))
        }
        guard !leaves.isEmpty else { return nil }
        // What personal values should fit: a country, a gender or title, a time zone.
        for field in structure.fields where !covered.contains(field.range.lowerBound) && KeyHints.hint(field.key) == nil {
            let last = KeyHints.words(field.key).last ?? ""
            guard ["country", "code", "gender", "sex", "title", "honorific", "salutation", "pronouns", "timezone", "tz", "zone"].contains(last) else { continue }
            leaves.append(DocumentLeaf(TextRanges.substring(text, field.range), key: field.key, records: structure.ancestry(field.level)))
        }
        leaves = DocumentPipeline.byPerson(leaves)
        let placed = DocumentPipeline.associateAddresses(leaves)
        // Cut short when cancelled; the caller stops before reading anything.
        guard placed.count == leaves.count else { return nil }
        let people = DocumentPipeline.associateOwners(leaves, job: self)
        let loose = spans.indices.filter { leafOf[$0] == nil }
        let nearAddresses = Self.addresses(in: text, loose.map { spans[$0] })
        let nearPeople = identities(in: text, loose.map { spans[$0] })
        var addresses = [AddressParts?](repeating: nil, count: spans.count), owners = [Persona?](repeating: nil, count: spans.count)
        for (position, index) in loose.enumerated() { addresses[index] = nearAddresses[position]; owners[index] = nearPeople[position] }
        for index in spans.indices {
            guard let leaf = leafOf[index] else { continue }
            addresses[index] = placed[leaf]
            if ["FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME", "INITIALS", "MRZ"].contains(spans[index].entity) { owners[index] = people.of(leaves[leaf]) }
        }
        return (addresses, owners)
    }
    /// The person a text's name, email, username and initials belong to when
    /// written together, as in a pasted record: the parts before a part repeats
    /// are one person's, and need a full name or a first and last name.
    func identities(in text: String, _ spans: [Span]) -> [Persona?] {
        var result = [Persona?](repeating: nil, count: spans.count)
        var members: [Int] = []
        var fields: [String: String] = [:]
        var end = 0
        func close() {
            // An address built from another known person's name ("odalys.ferriter@…"
            // beside "ask oluwaseun") is that person's, wherever it is written.
            let named = fields["EMAIL_ADDRESS"].flatMap(standIns.people.find(email:))
            if fields["PERSON"] != nil || fields["FIRST_NAME"] != nil && fields["LAST_NAME"] != nil, members.count >= 2,
               let person = associateRecord(first: fields["FIRST_NAME"], last: fields["LAST_NAME"], full: fields["PERSON"], email: named == nil ? fields["EMAIL_ADDRESS"] : nil, gender: gender(near: members.map { spans[$0].range }, in: text)) {
                for member in members where spans[member].entity != "PERSON" {
                    if spans[member].entity == "EMAIL_ADDRESS", let named, named !== person { continue }
                    result[member] = person
                }
            }
            members = []
            fields = [:]
        }
        for (index, span) in spans.enumerated() where ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME", "INITIALS"].contains(span.entity) {
            if fields[span.entity] != nil || span.range.lowerBound - end > 800 { close() }
            fields[span.entity] = TextRanges.substring(text, span.range)
            members.append(index)
            end = span.range.upperBound
        }
        close()
        return result
    }
    private static let genderField = TextPattern(#"(?i)["']?\b(?:gender|sex|title|salutation|honorific|pronouns)["']?\s*[:=]\s*["']?([A-Za-z./]+)"#)
    /// A "gender" or "title" written among a person's fields.
    private func gender(near ranges: [Range<Int>], in text: String) -> String? {
        guard let low = ranges.map(\.lowerBound).min(), let high = ranges.map(\.upperBound).max() else { return nil }
        let length = (text as NSString).length
        let window = max(0, low - 200)..<min(length, high + 200)
        let slice = TextRanges.substring(text, window)
        for match in TextRanges.matches(Self.genderField, in: slice) {
            if let gender = People.gender((slice as NSString).substring(with: match.range(at: 1))) { return gender }
        }
        return nil
    }
    func isEmitted(_ value: String) -> Bool { emitted.contains(value.lowercased()) }
    public func apply(_ text: String, spans: [Span]) throws -> (String, [Mark]) {
        try apply(text, spans: spans, owner: nil)
    }
    func apply(_ text: String, spans: [Span], owner: Persona?, address: AddressParts? = nil) throws -> (String, [Mark]) {
        var held: [Mark] = []
        return try apply(text, spans: spans, owner: owner, address: address, held: &held)
    }
    /// `held` marks places left as written in `text`; they come back where
    /// they stand in the output, without any a replacement covers.
    func apply(_ text: String, spans: [Span], owner: Persona?, address: AddressParts? = nil, held: inout [Mark]) throws -> (String, [Mark]) {
        let ordered = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var fakes = Array(repeating: "", count: ordered.count)
        var addresses: [AddressParts?], owners: [Persona?]
        if address == nil && owner == nil, let structured = records(in: text, ordered) {
            (addresses, owners) = structured
        } else {
            addresses = address.map { [AddressParts?](repeating: $0, count: ordered.count) } ?? Self.addresses(in: text, ordered)
            owners = owner.map { [Persona?](repeating: $0, count: ordered.count) } ?? identities(in: text, ordered)
        }
        // Stand-ins are drawn last span first, as seeded runs have always done;
        // a username after the email and name it may follow ("user quillpen77"
        // below "quillpen77@…"), and an age or last four digits after what they are read from.
        let later = { (index: Int) in StandIns.derived.contains(ordered[index].entity) || ordered[index].entity == "MRZ" || StandIns.isMasked(TextRanges.substring(text, ordered[index].range)) }
        let handle = { (index: Int) in ordered[index].entity == "USERNAME" && !later(index) }
        for span in ordered where span.entity == "LAST_DIGITS" { standIns.noteEnding(TextRanges.substring(text, span.range)) }
        // Zones last, in the text's order, an ID card's first lines stored alone before any second line (see `MachineZone.opensCard`).
        let zone = { (index: Int) in ordered[index].entity == "MRZ" }
        let opens = { (index: Int) in zone(index) && MachineZone.opensCard(TextRanges.substring(text, ordered[index].range)) }
        let drawOrder = ordered.indices.reversed().filter { !later($0) && !handle($0) } + ordered.indices.reversed().filter(handle) + ordered.indices.reversed().filter { later($0) && !zone($0) }
            + ordered.indices.filter(opens) + ordered.indices.filter { zone($0) && !opens($0) }
        // Numbers, birth dates and what is read off them note where they sit.
        let spots = ordered.contains { StandIns.anchored($0.entity) } ? self.spots(text) : nil
        var unclear: Set<Int> = []
        for (count, index) in drawOrder.enumerated() {
            if count.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            let local = StandIns.anchored(ordered[index].entity) ? spots?.scopes(at: ordered[index].range.lowerBound) ?? [] : []
            let written = TextRanges.substring(text, ordered[index].range)
            // A link's part is replaced as what it spells, and written back encoded the same way;
            // a value with hidden characters or markup inside, as what it reads (see `Visible`).
            let shown = Visible.plain(ordered[index].url.map { URLs.decode(written, $0) } ?? written)
            let fake = replacement(for: ordered[index].entity, original: shown, persona: owners[index], address: addresses[index], local: local)
            fakes[index] = ordered[index].url.map { URLs.encode(fake, like: written, $0) } ?? Visible.rewrite(written, with: fake)
            if lastUnclear { unclear.insert(index) }
        }
        let edits = zip(ordered, fakes).map { (range: $0.range, value: $1) }
        let (output, placed) = TextRanges.apply(edits, to: text)
        if !held.isEmpty { held = TextRanges.shift(held, by: edits) }
        // An age with no birth date to follow is left as it was, and unmarked.
        return (output, zip(placed, ordered.indices).compactMap { range, index in
            let span = ordered[index], original = TextRanges.substring(text, span.range)
            if fakes[index] == original && (StandIns.derived.contains(span.entity) || span.entity == "TIME_ZONE") { return nil }
            let sure = here(span, Visible.plain(span.url.map { URLs.decode(original, $0) } ?? original))
            return unclear.contains(index) ? Mark(range: range, entity: kind(of: original, read: span.entity), original: original, confidence: min(sure, Doubt.unclearOwner.confidence), doubt: .unclearOwner)
                : Mark(range: range, entity: kind(of: original, read: span.entity), original: original, confidence: sure)
        })
    }
    func scrubValue(_ text: String, key: String? = nil, owner: Persona? = nil, contextWords: Set<String> = []) throws -> (String, [Mark], [Mark]) {
        let spans = observe([(text, key)], contextWords: contextWords)[0]
        let (initial, marks) = try apply(text, spans: spans, owner: owner)
        var gate = LeakGate()
        gate.add(marks, in: initial)
        return try Correction.run(initial, marks: marks, job: self, matcher: OriginalMatcher(self), gazetteer: GazetteerMatcher(gazetteer, nameParts: nameParts, cuedParts: cuedParts), gate: gate)
    }
}
