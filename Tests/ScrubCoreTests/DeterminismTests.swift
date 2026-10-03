import Foundation
@testable import ScrubCore
import Synchronization
import Testing

/// The same input with the same seed gives the same output, byte for byte,
/// however busy the machine is, however many scrubs run at once, and whether
/// or not a cancel arrives. Stand-ins are drawn afresh for each scrub in the
/// app (no seed), so this is about everything else: what is found, which
/// stand-in each value gets, and in what order they are drawn.
@Suite(.serialized)
struct DeterminismTests {
    /// Keeps every core busy, allocating hash tables, until stopped.
    final class Load: Sendable {
        private let running = Atomic(true)
        init(threads: Int = ProcessInfo.processInfo.activeProcessorCount) {
            for index in 0..<threads {
                Thread.detachNewThread { [self] in
                    var sink = 0
                    while self.running.load(ordering: .relaxed) {
                        var table = Set<String>()
                        for value in 0..<(300 + index * 17) { table.insert("w\(value)") }
                        sink &+= table.count
                    }
                    _ = sink
                }
            }
        }
        func stop() { running.store(false, ordering: .relaxed) }
    }

    /// Everything a scrub hands back that a person sees.
    static func fingerprint(_ result: ScrubResult) -> String {
        let counts = result.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let marks: String
        switch result.preview {
        case .text(_, let found, _): marks = found.map { "\($0.range)\($0.entity)\($0.original ?? "")\($0.confidence ?? -1)" }.joined(separator: ";")
        case .table(_, _, _, let found): marks = found.map { "\($0.row):\($0.column)\($0.range)\($0.entity)" }.joined(separator: ";")
        }
        let findings = result.findings.map { "\($0.entity)|\($0.original)|\($0.standIn)|\($0.confidence)|\($0.occurrences)" }.joined(separator: ";")
        return counts + "\n" + marks + "\n" + findings + "\n" + String(decoding: result.output, as: UTF8.self)
    }

    /// Records, payloads and long notes on every input path, with names,
    /// addresses, IDs and secrets, and prose the context model reads.
    static func documents() -> [(name: String, data: Data, seed: UInt64)] {
        var documents: [(String, Data, UInt64)] = []
        var gen = Gen(seed: 6_021)
        for (index, format) in ["json", "csv", "xml", "txt"].enumerated() {
            if let doc = try? gen.document(format: format, capitalized: index == 1) { documents.append(("record.\(format)", doc.data, UInt64(index) + 3)) }
        }
        for (index, shape) in ["applicant", "employee", "patient"].enumerated() {
            var payloads = PayloadGen(seed: 4_400 + UInt64(index))
            let payload = payloads.payload(shape)
            for rendering in [Rendering.json, .xml, .csv, .curl, .yaml, .prose] {
                guard let rendered = Render.render(payload, as: rendering, gen: &payloads.gen) else { continue }
                documents.append(("\(shape)-\(rendering.rawValue)-\(rendering.filename)", Data(rendered.text.utf8), UInt64(index) + 11))
            }
        }
        var sentences: [String] = []
        for (position, category) in PIIGapCategory.allCases.enumerated() {
            var cases = PIIGapCaseGen(seed: 210 &+ UInt64(position))
            for _ in 0..<3 { sentences.append(cases.make(category).prose) }
        }
        for (position, category) in GapCategory.allCases.enumerated() {
            var cases = GapCaseGen(seed: 310 &+ UInt64(position))
            for _ in 0..<3 { sentences.append(cases.make(category).prose) }
        }
        var shuffle = Gen(seed: 77)
        // A name in another script inside English text is the context model's alone; it is
        // always in the note, however many sentences the categories above give.
        let note = ((0..<60).map { _ in shuffle.choose(sentences) } + ["Our new tenant Дмитрий Волков moved into the flat above the bakery last week."]).joined(separator: "\n")
        documents.append(("note.txt", Data(note.utf8), 21))
        for path in PIIGaps.InputPath.allCases where path != .text {
            let (data, name) = PIIGaps.wrap(note, path)
            documents.append(("note-\(name)", data, 22))
        }
        return documents
    }

    @Test func sameInputSameOutputUnderLoadAndConcurrency() throws {
        #expect(ContextModel.shared != nil && NameModel.shared != nil && AddressModel.shared != nil && AddressModel.wide != nil, "every model must be active for this test to mean anything")
        let contextOn = ContextStage.enabled.load(ordering: .relaxed)
        #expect(contextOn)
        let documents = Self.documents()
        // A reference for each, made one at a time on a quiet machine.
        let reference = try documents.map { try Self.fingerprint(Scrubber.scrub($0.data, name: $0.name, forceFullDetection: false, seed: $0.seed)) }
        // The context model's findings show in the note: its non-Latin name is gone from the
        // output (the fingerprint lists originals, so the output itself is what is read).
        let note = documents[documents.firstIndex { $0.name == "note.txt" }!]
        let noteOutput = String(decoding: try Scrubber.scrub(note.data, name: note.name, forceFullDetection: false, seed: note.seed).output, as: UTF8.self)
        #expect(noteOutput.contains("Our new tenant ") && !noteOutput.contains("Дмитрий"))
        let load = Load()
        defer { load.stop() }
        let copies = 4
        let differing = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: documents.count * copies) { run in
            let document = documents[run % documents.count]
            let again = (try? Scrubber.scrub(document.data, name: document.name, forceFullDetection: false, seed: document.seed)).map(Self.fingerprint)
            if again != reference[run % documents.count] { differing.withLock { $0.append(document.name) } }
        }
        #expect(differing.withLock { $0 }.isEmpty, "\(differing.withLock { $0 })")
    }

    /// The models' scores, bit for bit, read alone or on every core at once.
    @Test func modelScoresAreTheSameBitForBitUnderLoad() throws {
        let context = try #require(ContextModel.shared)
        let names = try #require(NameModel.shared)
        let addresses = try #require(AddressModel.shared)
        let wide = try #require(AddressModel.wide)
        let text = (0..<12).map { "Mr Corentin Vasquelle of 14 Pellow Street, Wexcombe, told the clinic on 3 May 2004 that claim no. 55123/04 was filed by Ifeoma Castellane, who works at Lowmarch Supply (\($0))." }.joined(separator: " ")
        let windows = context.windows(context.tokenizer.pieces(text, isCancelled: { false }))
        let tokens = NameModel.tokens(text)
        let reference = windows.map { context.logits($0.ids).map(\.bitPattern) }
        let nameReference = names.logits(tokens).map(\.bitPattern)
        let addressReference = addresses.logits(tokens).flatMap { $0.map(\.bitPattern) }
        let wideReference = wide.logits(tokens).flatMap { $0.map(\.bitPattern) }
        let load = Load()
        defer { load.stop() }
        let differing = Atomic(0)
        DispatchQueue.concurrentPerform(iterations: windows.count * 4) { run in
            if context.logits(windows[run % windows.count].ids).map(\.bitPattern) != reference[run % windows.count] { differing.add(1, ordering: .relaxed) }
            if run.isMultiple(of: 4), names.logits(tokens).map(\.bitPattern) != nameReference { differing.add(1, ordering: .relaxed) }
            if run.isMultiple(of: 4), addresses.logits(tokens).flatMap({ $0.map(\.bitPattern) }) != addressReference { differing.add(1, ordering: .relaxed) }
            if run.isMultiple(of: 4), wide.logits(tokens).flatMap({ $0.map(\.bitPattern) }) != wideReference { differing.add(1, ordering: .relaxed) }
        }
        #expect(differing.load(ordering: .relaxed) == 0)
    }

    /// A cancel stops a scrub: it throws, or, arriving after the work is done,
    /// leaves the result exactly as an uncancelled scrub's. Never a scrub that
    /// stopped looking partway and still handed back an output.
    @Test func aCancelStopsAScrubAndNeverChangesIt() async throws {
        let note = (0..<40).map { index in
            ["Called Odalys Ferriter about the refund; odalys.ferriter@corvane.test confirmed her new address, 4821 Juniper Hollow Rd, Tacoma, WA 98402.",
             "Ms Ferriter said her passport no. 553901274 expires soon and her login is oferriter74.",
             "Later, Bram Oyelaran rang back from +1 (415) 555-0132 and asked for Odalys by name."][index % 3]
        }.joined(separator: " ")
        let documents: [(Data, String)] = [(Data(note.utf8), "note.txt"), PIIGaps.wrap(note, .json), PIIGaps.wrap(note, .csv),
                                           (Data("<tickets><ticket><owner>Odalys Ferriter</owner><note>\(note)</note></ticket></tickets>".utf8), "tickets.xml")]
        for (data, name) in documents {
            let start = ContinuousClock.now
            let reference = try Self.fingerprint(Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 5))
            let took = start.duration(to: .now)
            var stopped = 0
            for step in 0..<12 {
                let task = Task.detached { try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: 5) }
                try await Task.sleep(for: took * (Double(step) / 10))
                task.cancel()
                switch await task.result {
                case .success(let result): #expect(Self.fingerprint(result) == reference, "\(name) step \(step)")
                case .failure(let error): #expect(error as? ScrubError == .cancelled); stopped += 1
                }
            }
            #expect(stopped > 0, "\(name): no cancel arrived in time")
        }
    }

    /// An age as close to two birth years goes by the one in its own record, and
    /// one as close to two in the document by the first met, in every run.
    /// The two were held in a dictionary, whose order changes from one run to the next.
    @Test func anAgeBetweenTwoBirthYearsIsReadTheSameEachRun() throws {
        let now = Calendar(identifier: .gregorian).component(.year, from: Date())
        let (older, younger) = (now - 41, now - 39)
        let json = """
        {"household": [{"name": "Corentin Vasquelle", "date_of_birth": "\(older)-03-02"}, {"name": "Ifeoma Castellane", "date_of_birth": "\(younger)-05-06", "age": 40}]}
        """
        let csv = "name,date_of_birth,age\nCorentin Vasquelle,\(older)-03-02,\nIfeoma Castellane,\(younger)-05-06,40\n"
        let xml = "<household><member><name>Corentin Vasquelle</name><date_of_birth>\(older)-03-02</date_of_birth></member><member><name>Ifeoma Castellane</name><date_of_birth>\(younger)-05-06</date_of_birth><age>40</age></member></household>"
        for (text, name) in [(json, "household.json"), (csv, "household.csv"), (xml, "household.xml")] {
            var outputs: Set<String> = []
            for _ in 0..<24 {
                let result = try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 9)
                let output = String(decoding: result.output, as: UTF8.self)
                outputs.insert(output)
                // Type oracle: the age is still a whole number, moved as far as the birth year in its own record moved.
                let years = output.matches(of: /(\d{4})-\d\d-\d\d/).map { Int($0.output.1)! }
                let age = try #require(output.matches(of: /(?:"age": |,|<age>)(\d{1,3})(?:<|\n|\}|$)/).last.map { Int($0.output.1)! }, "\(name): \(output)")
                #expect(years.count == 2 && years[1] != younger && age == 40 + younger - years[1], "\(name): \(output)")
            }
            #expect(outputs.count == 1, "\(name): \(outputs.count) different outputs")
        }
    }

    /// Element names that hold a person's name are rewritten in a fixed order.
    /// Two people whose names run into each other in one element name
    /// ("WillHunterRose" for Will Hunter and Hunter Rose) were rewritten in a
    /// set's order, so the name came out differently from run to run.
    @Test func elementNamesHoldingNamesAreRenamedTheSameEachRun() throws {
        let xml = """
        <contacts><owner>Will Hunter</owner><manager>Hunter Rose</manager><WillHunterRoseThread><subject>Quarterly review</subject><status>open</status></WillHunterRoseThread></contacts>
        """
        // A set's order follows the seed of this process and where its table
        // lands in memory, so the runs go on many threads at once, each
        // keeping a different amount of memory in use.
        let results = Mutex<[Data]>([])
        DispatchQueue.concurrentPerform(iterations: 48) { run in
            let ballast = (0..<(run % 7)).map { Set((0..<($0 * 13 + run)).map(String.init)) }
            if let result = try? Scrubber.scrub(Data(xml.utf8), name: "contacts.xml", forceFullDetection: false, seed: 4) { results.withLock { $0.append(result.output) } }
            _ = ballast.count
        }
        var outputs: Set<String> = []
        for data in results.withLock({ $0 }) {
            let output = String(decoding: data, as: UTF8.self)
            // Type oracle: still XML, the non-personal values as written, both people replaced in their fields.
            #expect(try XMLFile.parses(data))
            #expect(output.contains("<subject>Quarterly review</subject>") && output.contains("<status>open</status>"))
            #expect(!output.contains("Hunter"), "\(output)")
            outputs.insert(output)
        }
        #expect(results.withLock { $0.count } == 48)
        #expect(outputs.count == 1, "\(outputs.count) different outputs: \(outputs)")
    }

    /// The recheck reads the output, stand-ins and all. An ordinary word the
    /// tagger takes for a name only beside a stand-in ("Later" after "Quinn
    /// Ramos") was no name in the original, so it stays: which words survive
    /// must not hang on which stand-ins were drawn.
    @Test func aWordReadAsANameOnlyBesideStandInsStays() throws {
        let text = "Quinn Ramos called. Later, quinn ramos replied."
        let marks = [Mark(range: 0..<11, entity: "PERSON", original: "Robert Mitchell", confidence: 0.85),
                     Mark(range: 27..<38, entity: "PERSON", original: "robert mitchell", confidence: 0.95)]
        // The tagger does read "Later" as a name here.
        #expect(Detector().find(text).contains { TextRanges.substring(text, $0.range) == "Later" })
        // A note, a JSON field and a CSV cell all go through this one recheck.
        let (output, after, _) = try Correction.run(text, marks: marks, job: Job(seed: 2))
        #expect(output == text, "\(output)")
        #expect(after == marks)
        // And whole scrubs keep it on every path, whichever stand-ins are drawn.
        for seed in UInt64(0)..<40 {
            for path in PIIGaps.InputPath.allCases {
                let (data, name) = PIIGaps.wrap("Robert Mitchell called. Later, robert mitchell replied.", path)
                let output = PIIGaps.readable(try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed).output, path)
                #expect(output.contains(" called. Later, ") && output.hasSuffix(" replied.") && !output.contains("Mitchell"), "\(path) \(seed): \(output)")
            }
        }
    }
}
