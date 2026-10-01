import Foundation

public final class Job {
    public let detector = Detector()
    private let standIns: StandIns
    private(set) var gazetteer: [String: Set<String>] = [:]
    private(set) var nameParts: Set<String> = []
    private(set) var replacements: [Replacement] = []
    private(set) var sensitiveOriginals: [SensitiveOriginal] = []
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
        let matcher = GazetteerMatcher(gazetteer, nameParts: nameParts)
        return zip(fields, bases).map { detector.combined($1, text: $0.text, matcher: matcher) }
    }
    func observeSpans<S: Sequence>(_ fields: S) where S.Element == (String, [Span]) {
        for (text, spans) in fields {
            for span in spans { standIns.avoid(TextRanges.substring(text, span.range)) }
            for span in spans where GazetteerMatcher.supportedEntities.contains(span.entity) {
                let value = TextRanges.substring(text, span.range)
                // Replaced wherever it appears, so a name must at least have letters.
                if span.entity != "PHONE_NUMBER", !value.contains(where: \.isLetter) { continue }
                gazetteer[span.entity, default: []].insert(value)
                if span.entity == "PERSON" {
                    _ = standIns.people.registerFull(value)
                    rememberParts(of: value)
                }
            }
        }
    }
    // "Thanks, Maria" after "Maria Gonzalez" is the same person. Each end of a
    // full name is matched on its own, but only where it is written with a
    // capital, so a surname like "Hunt" still leaves the verb alone. A known
    // first name is no English word, so "thanks daniel" counts too, and so do
    // handles like "daniel.okafor".
    private func rememberParts(of name: String) {
        let tokens = (People.naturalOrder(name) ?? name).split { $0.isWhitespace || $0 == "," }.map(String.init)
        guard tokens.count >= 2, let first = tokens.first, let last = tokens.last else { return }
        let parts = [first, last].filter { part in
            part.count >= 2 && part.first?.isUppercase == true
                && part.allSatisfy({ $0.isLetter || "'’-".contains($0) }) && !Names.ambiguousFirst.contains(part.lowercased())
        }
        for part in parts {
            gazetteer["PERSON", default: []].insert(part)
            if part != first || !Names.unambiguousFirst.contains(part.lowercased()) { nameParts.insert(part) }
        }
        guard parts.count == 2 else { return }
        for separator in [".", "_"] { gazetteer["PERSON", default: []].insert(first + separator + last) }
    }
    func recordOriginals<S: Sequence>(_ fields: S) where S.Element == (String, [Span]) {
        for (text, spans) in fields {
            for span in spans {
                let original = TextRanges.substring(text, span.range)
                sensitiveOriginals.append(SensitiveOriginal(original: original, entity: span.entity))
            }
        }
    }
    public func replacement(for entity: String, original: String) -> String {
        replacement(for: entity, original: original, persona: nil)
    }
    func replacement(for entity: String, original: String, persona: Persona?, address: AddressParts? = nil) -> String {
        let actual = entity == "LOCATION" && standIns.people.knows(original) ? "PERSON" : entity
        let fake = standIns.replace(actual, original, persona: persona, address: address)
        if fake == original { return fake }
        if recordsReplacements { replacements.append(Replacement(original: original, fake: fake, entity: actual)) }
        emitted.insert(fake.lowercased())
        counts[actual, default: 0] += 1
        return fake
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
        let fake = standIns.numericLexeme(original, entity: entity, address: address)
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
        let placed = DocumentPipeline.associateAddresses(leaves)
        let people = DocumentPipeline.associateOwners(leaves, job: self)
        let loose = spans.indices.filter { leafOf[$0] == nil }
        let nearAddresses = Self.addresses(in: text, loose.map { spans[$0] })
        let nearPeople = identities(in: text, loose.map { spans[$0] })
        var addresses = [AddressParts?](repeating: nil, count: spans.count), owners = [Persona?](repeating: nil, count: spans.count)
        for (position, index) in loose.enumerated() { addresses[index] = nearAddresses[position]; owners[index] = nearPeople[position] }
        for index in spans.indices {
            guard let leaf = leafOf[index] else { continue }
            addresses[index] = placed[leaf]
            if ["FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME", "INITIALS"].contains(spans[index].entity) { owners[index] = leaves[leaf].owner(in: people) }
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
            if fields["PERSON"] != nil || fields["FIRST_NAME"] != nil && fields["LAST_NAME"] != nil, members.count >= 2,
               let person = associateRecord(first: fields["FIRST_NAME"], last: fields["LAST_NAME"], full: fields["PERSON"], email: fields["EMAIL_ADDRESS"], gender: gender(near: members.map { spans[$0].range }, in: text)) {
                for member in members where spans[member].entity != "PERSON" { result[member] = person }
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
        let ordered = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var fakes = Array(repeating: "", count: ordered.count)
        var addresses: [AddressParts?], owners: [Persona?]
        if address == nil && owner == nil, let structured = records(in: text, ordered) {
            (addresses, owners) = structured
        } else {
            addresses = address.map { [AddressParts?](repeating: $0, count: ordered.count) } ?? Self.addresses(in: text, ordered)
            owners = owner.map { [Persona?](repeating: $0, count: ordered.count) } ?? identities(in: text, ordered)
        }
        // Stand-ins are drawn last span first, as seeded runs have always done,
        // and an age or last four digits after what they are read from.
        let later = { (index: Int) in StandIns.derived.contains(ordered[index].entity) || StandIns.isMasked(TextRanges.substring(text, ordered[index].range)) }
        for span in ordered where span.entity == "LAST_DIGITS" { standIns.noteEnding(TextRanges.substring(text, span.range)) }
        let drawOrder = ordered.indices.reversed().filter { !later($0) } + ordered.indices.reversed().filter(later)
        for (count, index) in drawOrder.enumerated() {
            if count.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            fakes[index] = replacement(for: ordered[index].entity, original: TextRanges.substring(text, ordered[index].range), persona: owners[index], address: addresses[index])
        }
        let (output, placed) = TextRanges.apply(zip(ordered, fakes).map { (range: $0.range, value: $1) }, to: text)
        // An age with no birth date to follow is left as it was, and unmarked.
        return (output, zip(placed, zip(ordered, fakes)).compactMap { range, pair in
            pair.1 == TextRanges.substring(text, pair.0.range) && (StandIns.derived.contains(pair.0.entity) || pair.0.entity == "TIME_ZONE") ? nil : Mark(range: range, entity: pair.0.entity)
        })
    }
    func scrubValue(_ text: String, key: String? = nil, owner: Persona? = nil, contextWords: Set<String> = []) throws -> (String, [Mark], [Mark]) {
        let spans = observe([(text, key)], contextWords: contextWords)[0]
        let (initial, marks) = try apply(text, spans: spans, owner: owner)
        return try Correction.run(initial, marks: marks, job: self, matcher: OriginalMatcher(self), gazetteer: GazetteerMatcher(gazetteer, nameParts: nameParts))
    }
}
