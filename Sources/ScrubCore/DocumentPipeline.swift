import Foundation

struct DocumentLeaf {
    let text: String
    let key: String?
    let records: [Int]
    let contextWords: Set<String>

    init(_ text: String, key: String? = nil, records: [Int] = [], contextWords: Set<String> = []) {
        self.text = text
        self.key = key
        self.records = records
        self.contextWords = contextWords
    }
}

struct DocumentValue {
    let text: String
    let marks: [Mark]
    let unresolved: [Mark]
}

enum DocumentPipeline {
    private static let identityHints: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME"]

    static func run(_ leaves: [DocumentLeaf], job: Job) throws -> [DocumentValue] {
        var recordFields: [Int: [String: String]] = [:]
        for leaf in leaves {
            guard let record = leaf.records.last, let hint = KeyHints.hint(leaf.key), identityHints.contains(hint), !leaf.text.isEmpty else { continue }
            recordFields[record, default: [:]][hint] = leaf.text
        }
        var owners: [Int: Persona] = [:]
        for record in recordFields.keys.sorted() {
            guard let fields = recordFields[record] else { continue }
            owners[record] = job.associateRecord(first: fields["FIRST_NAME"], last: fields["LAST_NAME"], full: fields["PERSON"], email: fields["EMAIL_ADDRESS"])
        }
        var spans = leaves.map { job.detector.find($0.text, key: $0.key, contextWords: $0.contextWords) }
        job.observeSpans(zip(leaves, spans).map { ($0.text, $1) })
        spans = leaves.map { job.detector.find($0.text, key: $0.key, gazetteer: job.gazetteer, contextWords: $0.contextWords) }
        job.recordOriginals(zip(leaves, spans).map { ($0.text, $1) })
        var values: [DocumentValue] = []
        for (leaf, found) in zip(leaves, spans) {
            try Scrubber.checkCancellation()
            let owner = identityHints.contains(KeyHints.hint(leaf.key) ?? "") ? leaf.records.reversed().compactMap { owners[$0] }.first : nil
            let (text, marks) = try job.apply(leaf.text, spans: found, owner: owner)
            values.append(DocumentValue(text: text, marks: marks, unresolved: []))
        }
        for index in values.indices {
            try Scrubber.checkCancellation()
            let (text, marks, unresolved) = try Correction.run(values[index].text, marks: values[index].marks, job: job)
            values[index] = DocumentValue(text: text, marks: marks, unresolved: unresolved)
        }
        return values
    }
}
