import Foundation

public final class Job {
    public let detector = Detector()
    private let standIns: StandIns
    private(set) var gazetteer: [String: Set<String>] = [:]
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
        let matcher = GazetteerMatcher(gazetteer)
        return zip(fields, bases).map { detector.combined($1, text: $0.text, matcher: matcher) }
    }
    func observeSpans<S: Sequence>(_ fields: S) where S.Element == (String, [Span]) {
        for (text, spans) in fields {
            for span in spans where GazetteerMatcher.supportedEntities.contains(span.entity) {
                let value = TextRanges.substring(text, span.range)
                gazetteer[span.entity, default: []].insert(value)
                if span.entity == "PERSON" { _ = standIns.people.registerFull(value) }
            }
        }
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
    func replacement(for entity: String, original: String, persona: Persona?) -> String {
        let actual = entity == "LOCATION" && standIns.people.knows(original) ? "PERSON" : entity
        let fake = standIns.replace(actual, original, persona: persona)
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
    func reserveNumeric(_ original: String, entity: String) {
        _ = standIns.numericLexeme(original, entity: entity)
    }
    func numericLexeme(_ original: String, entity: String) -> String {
        let fake = standIns.numericLexeme(original, entity: entity)
        if recordsReplacements { replacements.append(Replacement(original: original, fake: fake, entity: entity)) }
        emitted.insert(fake.lowercased())
        counts[entity, default: 0] += 1
        return fake
    }
    @discardableResult
    func associateRecord(first: String?, last: String?, full: String?, email: String?) -> Persona? {
        if let full {
            let person = standIns.people.registerFull(full, emailSafe: email != nil).0
            standIns.people.associate(person, email: email)
            return person
        }
        if first != nil || last != nil {
            associate(first: first, last: last, email: email)
            return standIns.people.register(first, last)
        }
        return nil
    }
    func isEmitted(_ value: String) -> Bool { emitted.contains(value.lowercased()) }
    public func apply(_ text: String, spans: [Span]) throws -> (String, [Mark]) {
        try apply(text, spans: spans, owner: nil)
    }
    func apply(_ text: String, spans: [Span], owner: Persona?) throws -> (String, [Mark]) {
        let ordered = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var fakes = Array(repeating: "", count: ordered.count)
        // Stand-ins are drawn last span first, as seeded runs have always done.
        for (count, index) in ordered.indices.reversed().enumerated() {
            if count.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            fakes[index] = replacement(for: ordered[index].entity, original: TextRanges.substring(text, ordered[index].range), persona: owner)
        }
        let (output, placed) = TextRanges.apply(zip(ordered, fakes).map { (range: $0.range, value: $1) }, to: text)
        return (output, zip(placed, ordered).map { Mark(range: $0, entity: $1.entity) })
    }
    func scrubValue(_ text: String, key: String? = nil, owner: Persona? = nil, contextWords: Set<String> = []) throws -> (String, [Mark], [Mark]) {
        let spans = observe([(text, key)], contextWords: contextWords)[0]
        let (initial, marks) = try apply(text, spans: spans, owner: owner)
        return try Correction.run(initial, marks: marks, job: self, matcher: OriginalMatcher(self), gazetteer: GazetteerMatcher(gazetteer))
    }
}
