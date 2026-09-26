import Foundation

public final class Job {
    public let detector = Detector()
    private let standIns = StandIns()
    private(set) var gazetteer: [String: Set<String>] = [:]
    private(set) var replacements: [Replacement] = []
    private(set) var sensitiveOriginals: [String: SensitiveOriginal] = [:]
    private var emitted: Set<String> = []
    public private(set) var counts: [String: Int] = [:]
    public init() {}
    public func associate(first: String?, last: String?, email: String?) {
        standIns.people.associate(first: first, last: last, email: email)
    }
    public func observe(_ fields: [(text: String, key: String?)]) -> [[Span]] {
        observe(fields, contextWords: [])
    }
    func observe(_ fields: [(text: String, key: String?)], contextWords: Set<String>) -> [[Span]] {
        var found = fields.map { detector.find($0.text, key: $0.key, contextWords: contextWords) }
        let identified = zip(fields, found).flatMap { field, spans in
            spans.map { ($0.entity, TextRanges.substring(field.text, $0.range)) }
        }
        let first = identified.first { $0.0 == "FIRST_NAME" }?.1
        let last = identified.first { $0.0 == "LAST_NAME" }?.1
        let email = identified.first { $0.0 == "EMAIL_ADDRESS" }?.1
        if first != nil && last != nil { associate(first: first, last: last, email: email) }
        observeSpans(zip(fields, found).map { ($0.text, $1) })
        let matcher = GazetteerMatcher(gazetteer)
        found = fields.map { detector.find($0.text, key: $0.key, matcher: matcher, contextWords: contextWords) }
        return found
    }
    func observeSpans(_ fields: [(String, [Span])]) {
        for (text, spans) in fields {
            for span in spans where ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER"].contains(span.entity) {
                let value = TextRanges.substring(text, span.range)
                gazetteer[span.entity, default: []].insert(value)
                if span.entity == "PERSON" { _ = standIns.people.registerFull(value) }
            }
        }
    }
    func recordOriginals(_ fields: [(String, [Span])]) {
        for (text, spans) in fields {
            for span in spans {
                let original = TextRanges.substring(text, span.range)
                sensitiveOriginals[original.lowercased()] = SensitiveOriginal(original: original, entity: span.entity)
            }
        }
    }
    public func replacement(for entity: String, original: String) -> String {
        replacement(for: entity, original: original, persona: nil)
    }
    func replacement(for entity: String, original: String, persona: Persona?) -> String {
        let actual = entity == "LOCATION" && standIns.people.knows(original) ? "PERSON" : entity
        let fake = standIns.replace(actual, original, persona: persona)
        replacements.append(Replacement(original: original, fake: fake, entity: actual))
        emitted.insert(fake.lowercased())
        counts[actual, default: 0] += 1
        return fake
    }
    public func digits(_ original: String) -> String {
        let fake = standIns.number(original)
        replacements.append(Replacement(original: original, fake: fake, entity: "ID_NUMBER"))
        emitted.insert(fake.lowercased())
        counts["ID_NUMBER", default: 0] += 1
        return fake
    }
    func number(_ original: String, entity: String) -> String {
        let negative = original.hasPrefix("-")
        let digits = negative ? String(original.dropFirst()) : original
        let fake = (negative ? "-" : "") + standIns.number(digits)
        counts[entity, default: 0] += 1
        replacements.append(Replacement(original: original, fake: fake, entity: entity))
        return fake
    }
    func numericLexeme(_ original: String, entity: String) -> String {
        let digits = original.filter { $0.isASCII && $0.isNumber }
        let substitute = standIns.number(digits)
        var iterator = substitute.makeIterator()
        let fake = String(original.map { character in
            character.isASCII && character.isNumber ? iterator.next() ?? character : character
        })
        replacements.append(Replacement(original: original, fake: fake, entity: entity))
        emitted.insert(fake.lowercased())
        counts[entity, default: 0] += 1
        return fake
    }
    @discardableResult
    func associateRecord(first: String?, last: String?, full: String?, email: String?) -> Persona? {
        if first != nil || last != nil {
            associate(first: first, last: last, email: email)
            return standIns.people.register(first, last)
        }
        else if let full {
            let parts = full.split(separator: " ")
            if parts.count >= 2 {
                let first = String(parts[0]), last = String(parts[parts.count - 1])
                associate(first: first, last: last, email: email)
                return standIns.people.register(first, last)
            }
        }
        return nil
    }
    func isEmitted(_ value: String) -> Bool { emitted.contains(value.lowercased()) }
    public func apply(_ text: String, spans: [Span]) throws -> (String, [Mark]) {
        try apply(text, spans: spans, owner: nil)
    }
    func apply(_ text: String, spans: [Span], owner: Persona?) throws -> (String, [Mark]) {
        var output = text
        var marks: [Mark] = []
        for (index, span) in spans.reversed().enumerated() {
            if index.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            let fake = replacement(for: span.entity, original: TextRanges.substring(text, span.range), persona: owner)
            output = TextRanges.replace(output, span.range, with: fake)
            let delta = (fake as NSString).length - span.range.count
            marks = marks.map { Mark(range: ($0.range.lowerBound + delta)..<($0.range.upperBound + delta), entity: $0.entity) }
            marks.append(Mark(range: span.range.lowerBound..<(span.range.lowerBound + (fake as NSString).length), entity: span.entity))
        }
        return (output, marks.sorted { $0.range.lowerBound < $1.range.lowerBound })
    }
    func scrubValue(_ text: String, key: String? = nil, owner: Persona? = nil, contextWords: Set<String> = []) throws -> (String, [Mark], [Mark]) {
        let spans = observe([(text, key)], contextWords: contextWords)[0]
        let (initial, marks) = try apply(text, spans: spans, owner: owner)
        return try Correction.run(initial, marks: marks, job: self, matcher: OriginalMatcher(self), gazetteer: GazetteerMatcher(gazetteer))
    }
}
