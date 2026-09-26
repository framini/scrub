import Foundation

public final class Job {
    public let detector = Detector()
    private let standIns = StandIns()
    private(set) var gazetteer: [String: Set<String>] = [:]
    private(set) var replacements: [Replacement] = []
    private var emitted: Set<String> = []
    public private(set) var counts: [String: Int] = [:]
    public init() {}
    public func associate(first: String?, last: String?, email: String?) {
        standIns.people.associate(first: first, last: last, email: email)
    }
    public func observe(_ fields: [(text: String, key: String?)]) -> [[Span]] {
        var found = fields.map { detector.find($0.text, key: $0.key) }
        let identified = zip(fields, found).flatMap { field, spans in
            spans.map { ($0.entity, TextRanges.substring(field.text, $0.range)) }
        }
        let first = identified.first { $0.0 == "FIRST_NAME" }?.1
        let last = identified.first { $0.0 == "LAST_NAME" }?.1
        let email = identified.first { $0.0 == "EMAIL_ADDRESS" }?.1
        if first != nil && last != nil { associate(first: first, last: last, email: email) }
        for (field, spans) in zip(fields, found) {
            for span in spans where ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER"].contains(span.entity) {
                let value = TextRanges.substring(field.text, span.range)
                gazetteer[span.entity, default: []].insert(value)
                if span.entity == "PERSON" { _ = standIns.people.registerFull(value) }
            }
        }
        found = fields.map { detector.find($0.text, key: $0.key, gazetteer: gazetteer) }
        return found
    }
    public func replacement(for entity: String, original: String) -> String {
        let actual = entity == "LOCATION" && standIns.people.knows(original) ? "PERSON" : entity
        let fake = standIns.replace(actual, original)
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
    func isEmitted(_ value: String) -> Bool { emitted.contains(value.lowercased()) }
    public func apply(_ text: String, spans: [Span]) throws -> (String, [Mark]) {
        var output = text
        var marks: [Mark] = []
        for (index, span) in spans.reversed().enumerated() {
            if index.isMultiple(of: 64) { try Scrubber.checkCancellation() }
            let fake = replacement(for: span.entity, original: TextRanges.substring(text, span.range))
            output = TextRanges.replace(output, span.range, with: fake)
            let delta = (fake as NSString).length - span.range.count
            marks = marks.map { Mark(range: ($0.range.lowerBound + delta)..<($0.range.upperBound + delta), entity: $0.entity) }
            marks.append(Mark(range: span.range.lowerBound..<(span.range.lowerBound + (fake as NSString).length), entity: span.entity))
        }
        return (output, marks.sorted { $0.range.lowerBound < $1.range.lowerBound })
    }
}
