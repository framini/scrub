import Accelerate
import CryptoKit
import Foundation
import os
import Synchronization

/// A small network that reads text around candidate lines and marks the
/// postal addresses there, each as one unit: its unit and building lines,
/// street, locality, postcode and country. It catches what the street pattern
/// and the system detector miss: a signature's address in another country's
/// format, a flat over its street, a street in prose with no postcode.
///
/// Scrub reads with two of them and keeps what either finds. `shared`, the
/// first, reads the lines with a number. `wide`, trained later, also reads
/// addresses written all in lowercase and addresses with no number ("Flat B,
/// The Old Rectory, Little Hadham", "Hauptstraße, Berlin-Mitte"); together
/// they miss less than either alone, and the first's findings stay as they were.
/// Tools/AddressModel trains them; this mirrors model.py exactly, so change both together.
final class AddressModel: Sendable {
    static let shared: AddressModel? = load(Weights.first)
    static let wide: AddressModel? = load(Weights.wide)
    /// How likely a token must be to sit inside an address, as the summed
    /// probability of beginning and continuing one.
    static let threshold: Float = 0.5
    /// Below every rule's score, and below the review line: an address only
    /// the model read is shown for review before sharing.
    static let score = 0.6
    /// Off only inside a test's `withValue` scope, to show what Scrub finds
    /// without the model. A detector reads it when it is made, so a scrub
    /// started in that scope runs without the model on every thread, and
    /// every other scrub runs with it. Only debug builds can turn it off.
    #if DEBUG
    @TaskLocal static var active = true
    #else
    static var active: Bool { true }
    #endif

    /// A weight file and the SHA-256 it must hash to. A file that differs is
    /// not loaded: Scrub then runs without that model, and says why in the log.
    struct Weights: Sendable {
        let name: String
        let checksum: String
        /// Whether it reads lines with no number and addresses with none.
        let numberless: Bool

        static let first = Weights(name: "AddressModel", checksum: "68a0742d13a305b93762ffab2f076b956de7cfa8f8b805fa2cd81a18b7b07d59", numberless: false)
        static let wide = Weights(name: "AddressModelWide", checksum: "eda633faf260ec950798faf4458914484796edec0a6b5f0f03a0c2b307e8cbdf", numberless: true)
    }

    /// The postal addresses either model reads in `text`, in UTF-16 offsets,
    /// those that overlap joined into one.
    static func find(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        read(text, isCancelled: isCancelled).spans
    }
    /// What `find` finds, and the single pieces with no number that read as a
    /// street or a house ("I live on Ahornweg now", "moved to Pear Tree
    /// Cottage"): sentences that only name a street look the same, so these
    /// are never replaced on their own, only put to a person in review.
    static func read(_ text: String, isCancelled: () -> Bool = { false }) -> (spans: [Span], doubtful: [Span]) {
        let readings = [shared, wide].compactMap { $0?.read(text, isCancelled: isCancelled) }
        let found = readings.flatMap(\.spans).sorted { $0.range.lowerBound < $1.range.lowerBound }
        var doubtful: [Span] = []
        for span in readings.flatMap(\.doubtful).sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where !found.contains(where: { $0.range.overlaps(span.range) }) {
            if let last = doubtful.last, last.range.overlaps(span.range) { continue }
            doubtful.append(span)
        }
        var joined: [Span] = []
        for span in found {
            if let last = joined.last, span.range.lowerBound < last.range.upperBound {
                joined[joined.count - 1] = Span(range: last.range.lowerBound..<max(last.range.upperBound, span.range.upperBound), entity: "ADDRESS", score: score)
            } else {
                joined.append(span)
            }
        }
        return (joined, doubtful)
    }
    /// Below the review line, so a person decides; nothing else reads these.
    static let doubtScore = 0.4

    private let buckets: Int
    private let embed: Int
    private let hidden: Int
    private let kernel: Int
    private let shapes: Int
    private let labels: Int
    private let dilations: [Int]
    private let scales: [Float]
    private let table: [Int8]
    private let project: [Float]
    private let projectBias: [Float]
    private let convs: [[Float]]
    private let convBiases: [[Float]]
    private let out: [Float]
    private let outBias: [Float]
    /// Features by word, shared across calls, keyed by its exact scalars (see `NameModel`).
    private let known = Mutex<[[UInt32]: [Float]]>([:])
    private static let knownLimit = 100_000

    /// Whether it reads lines with no number and addresses with none (see `Weights`).
    let numberless: Bool
    private static let log = Logger(subsystem: "Scrub", category: "AddressModel")

    private static func load(_ weights: Weights) -> AddressModel? {
        guard let url = ModelResources.bundle?.url(forResource: weights.name, withExtension: "bin"), let data = try? Data(contentsOf: url) else {
            log.error("Address model \(weights.name, privacy: .public) not loaded: resource missing")
            return nil
        }
        return verified(data, weights: weights)
    }

    /// The model in `data`, or nil when its bytes are not the ones the weights' checksum names.
    static func verified(_ data: Data, weights: Weights = .first, checksum: String? = nil) -> AddressModel? {
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum ?? weights.checksum else {
            log.error("Address model \(weights.name, privacy: .public) not loaded: its weights do not match the expected checksum")
            return nil
        }
        return AddressModel(data, numberless: weights.numberless)
    }

    init?(_ data: Data, numberless: Bool = false) {
        self.numberless = numberless
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("SAM1".utf8) else { return nil }
        let sizes = (0..<7).map { _ in Int(reader.uint32()) }
        (buckets, embed, hidden, kernel, shapes, labels) = (sizes[0], sizes[1], sizes[2], sizes[3], sizes[5], sizes[6])
        guard buckets > 0, embed > 0, hidden > 0, kernel > 0, labels == 3, sizes[4] <= 16 else { return nil }
        dilations = (0..<sizes[4]).map { _ in Int(reader.uint32()) }
        scales = reader.floats(buckets)
        table = reader.int8s(buckets * embed)
        project = reader.floats((embed + shapes) * hidden)
        projectBias = reader.floats(hidden)
        var convs: [[Float]] = [], convBiases: [[Float]] = []
        for _ in dilations {
            convs.append(reader.floats(kernel * hidden * hidden))
            convBiases.append(reader.floats(hidden))
        }
        (self.convs, self.convBiases) = (convs, convBiases)
        out = reader.floats(hidden * labels)
        outBias = reader.floats(labels)
        // The token's own shape, and three or four of its line's (the wide model reads whether its line has a capital).
        guard reader.isValid, reader.offset == data.count, [Self.shapeCount + 3, Self.shapeCount + 4].contains(shapes) else { return nil }
    }

    // MARK: Finding addresses

    /// Postal addresses in `text`, in UTF-16 offsets. Only the lines around
    /// a candidate line are read (see `windows`): text with no digit and no
    /// kind of street, building or unit costs a scan of its words.
    func find(_ text: String, isCancelled: () -> Bool = { false }) -> [Span] {
        read(text, isCancelled: isCancelled).spans
    }
    /// What `find` finds, and, for the model that reads numberless lines, the
    /// single pieces it reads as an address that `accepts` must turn down (see `AddressModel.read`).
    func read(_ text: String, isCancelled: () -> Bool = { false }) -> (spans: [Span], doubtful: [Span]) {
        guard !isCancelled() else { return ([], []) }
        var spans: [Span] = [], doubtful: [Span] = []
        for window in Self.windows(text, numberless: numberless) {
            if isCancelled() { return ([], []) }
            let part = TextRanges.substring(text, window)
            let tokens = NameModel.tokens(part)
            guard tokens.contains(where: \.isWord) else { continue }
            let probabilities = self.probabilities(tokens, isCancelled: isCancelled)
            guard probabilities.count == tokens.count else { return ([], []) }
            for range in Self.decode(tokens, probabilities, numberless: numberless).compactMap({ Self.refined($0, tokens) }) {
                let value = TextRanges.substring(part, range)
                let before = (part as NSString).substring(to: range.lowerBound)
                guard !Self.misread(value), !Self.machineNumbers(value, before: before), Self.accepts(value) || Self.cued(value, before: before) else { continue }
                spans.append(Span(range: (range.lowerBound + window.lowerBound)..<(range.upperBound + window.lowerBound), entity: "ADDRESS", score: Self.score))
            }
            guard numberless else { continue }
            for range in Self.decodeSingle(tokens, probabilities) where Self.doubtful(TextRanges.substring(part, range), before: (part as NSString).substring(to: range.lowerBound)) {
                doubtful.append(Span(range: (range.lowerBound + window.lowerBound)..<(range.upperBound + window.lowerBound), entity: "ADDRESS", score: Self.doubtScore))
            }
        }
        return (spans, doubtful)
    }

    /// The stretches worth reading: every candidate line with the two lines
    /// either side (a city or a country on a line of its own), joined where
    /// they meet. A line is a candidate when it holds a decimal digit and a
    /// word of two letters, or, with no digit, a cue only an address line has
    /// (`numberlessCue`).
    static func windows(_ text: String, numberless: Bool = true) -> [Range<Int>] {
        let ns = text as NSString
        var lines: [(range: Range<Int>, candidate: Bool)] = []
        var start = 0
        while start < ns.length {
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            let range = line.location..<NSMaxRange(line)
            lines.append((range, candidate(ns, range, numberless: numberless)))
            start = NSMaxRange(line)
        }
        var windows: [Range<Int>] = []
        for (index, line) in lines.enumerated() where line.candidate {
            let from = lines[max(0, index - 2)].range.lowerBound, to = lines[min(lines.count - 1, index + 2)].range.upperBound
            if let last = windows.last, last.upperBound >= from {
                windows[windows.count - 1] = last.lowerBound..<max(last.upperBound, to)
            } else {
                windows.append(from..<to)
            }
        }
        return windows
    }

    private static func candidate(_ ns: NSString, _ range: Range<Int>, numberless: Bool) -> Bool {
        var digit = false, letters = 0, best = 0
        for index in range {
            let unit = ns.character(at: index)
            if (48...57).contains(unit) { digit = true; letters = 0; continue }
            if let scalar = Unicode.Scalar(unit), scalar.properties.isAlphabetic { letters += 1; best = max(best, letters) } else if !(0xD800...0xDFFF).contains(unit) { letters = 0 }
            if digit && best >= 2 { return true }
        }
        if digit { return best >= 2 }
        return numberless && best >= 3 && numberlessCue(ns.substring(with: NSRange(location: range.lowerBound, length: range.count)))
    }

    /// Whether a line with no number holds a cue only an address line has:
    /// a word ending in a compound kind of street ("Hauptstraße", "Kerkstraat",
    /// "Strandvejen"), a foreign kind of street opening a name ("rue des
    /// Lilas", "calle Mayor"; "Via", "Avenue" and the like before a capital),
    /// a capitalised kind of street or building after a capitalised word
    /// ("Mill Lane", "The Old Rectory"), or a unit with a letter ("Flat B").
    /// Pairs count only when spaces alone part them. It passes about one
    /// prose line in a thousand (Tools/AddressModel/prefilter.py mirrors it).
    static func numberlessCue(_ line: String) -> Bool {
        var words: [(text: String, start: String.Index, end: String.Index)] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index].isLetter else { index = line.index(after: index); continue }
            var end = line.index(after: index)
            while end < line.endIndex {
                if line[end].isLetter { end = line.index(after: end); continue }
                let next = line.index(after: end)
                if "'’".contains(line[end]), next < line.endIndex, line[next].isLetter { end = next; continue }
                break
            }
            words.append((String(line[index..<end]), index, end))
            index = end
        }
        func joined(_ a: Int, _ b: Int) -> Bool { line[words[a].end..<words[b].start].allSatisfy(\.isWhitespace) }
        func capital(_ word: String) -> Bool { word.first?.isUppercase == true }
        for (position, word) in words.enumerated() {
            let lower = word.text.lowercased()
            if !notSuffixed.contains(lower), cueSuffixes.contains(where: { lower.hasSuffix($0) && lower.count > $0.count + 2 }) { return true }
            let next = position + 1 < words.count && joined(position, position + 1) ? words[position + 1].text : nil
            if let next, leadKinds.contains(lower), !leadBeforeCapital.contains(lower) || capital(next) { return true }
            if cueKinds.contains(lower), capital(word.text), position > 0, joined(position - 1, position), capital(words[position - 1].text) { return true }
            if let next, cueUnits.contains(lower), next.count == 1, next.uppercased() == next, next.lowercased() != next { return true }
        }
        return false
    }
    private static let cueSuffixes = ["straße", "strasse", "gasse", "platz", "allee", "ufer", "damm", "steig", "pfad", "straat", "laan", "gracht", "plein", "kade", "singel",
                                      "dijk", "steeg", "gatan", "vägen", "gränd", "torget", "gade", "gaden", "vej", "vejen", "stræde", "torvet", "veien", "vegen", "gata", "katu",
                                      "kuja", "polku", "weg"]
    /// Words ending so that are no street.
    private static let notSuffixed: Set<String> = ["brigade", "brigades", "renegade", "renegades", "escapade", "promenade"]
    private static let leadKinds: Set<String> = ["rue", "allée", "impasse", "chemin", "quai", "viale", "piazza", "piazzale", "vicolo", "strada", "calle", "avenida", "paseo", "rua",
                                                 "travessa", "praça", "estrada", "alameda", "ulica", "aleja", "carrer", "chaussée", "rambla", "largo", "corso", "camino", "ronda", "via",
                                                 "avenue", "boulevard", "plaza", "place", "route"]
    private static let leadBeforeCapital: Set<String> = ["via", "avenue", "boulevard", "plaza", "place", "route", "largo", "corso", "camino", "ronda"]
    private static let cueKinds: Set<String> = ["street", "road", "lane", "avenue", "drive", "close", "crescent", "way", "place", "terrace", "court", "highway", "square", "gardens",
                                                "grove", "mews", "rise", "walk", "parade", "quay", "row", "hill", "view", "green", "vale", "chase", "wharf", "boulevard", "circle",
                                                "trail", "parkway", "esplanade", "yard", "path", "alley", "house", "cottage", "lodge", "farm", "barn", "manor", "rectory", "vicarage",
                                                "granary", "forge", "mill", "hall", "mansions", "tower", "building", "estate", "park"]
    private static let cueUnits: Set<String> = ["flat", "apt", "apartment", "unit", "suite", "appt", "bâtiment", "escalier", "piso", "wohnung", "top"]

    /// Address spans from per-token probabilities of O, B and I, in the
    /// window's UTF-16 offsets. A run of tokens inside an address is one, split
    /// where a token is likelier to begin an address than continue it; its
    /// ends lose punctuation and line breaks, but a closing bracket whose
    /// opening one is inside stays. An address holds two words and a digit,
    /// or two pieces a comma, semicolon or line break parts ("Hauptstraße, Berlin-Mitte").
    static func decode(_ tokens: [NameModel.Token], _ probabilities: [[Float]], numberless: Bool = false) -> [Range<Int>] {
        var runs: [(Int, Int)] = [], current: (Int, Int)?
        for (index, p) in probabilities.enumerated() {
            let inside = p[1] + p[2] >= threshold
            if inside, current != nil, p[1] > p[2], p[1] > p[0] {
                runs.append(current!)
                current = nil
            }
            if inside {
                current = current.map { ($0.0, index) } ?? (index, index)
            } else if let run = current {
                runs.append(run)
                current = nil
            }
        }
        if let current { runs.append(current) }
        var result: [Range<Int>] = []
        for (start, end) in runs {
            var first = start, last = end
            while first <= last, !tokens[first].isWord { first += 1 }
            while last >= first, !tokens[last].isWord {
                if tokens[last].scalars == [")"], tokens[first..<last].contains(where: { $0.scalars == ["("] }) { break }
                last -= 1
            }
            guard first <= last else { continue }
            let span = tokens[first...last]
            guard span.filter({ $0.scalars.contains(where: isLetter) }).count >= 2, span.contains(where: { $0.scalars.contains(where: isDigit) }) || numberless && parted(span) else { continue }
            result.append(tokens[first].range.lowerBound..<tokens[last].range.upperBound)
        }
        return result
    }

    /// The runs `decode` turns down for having no number and one piece: a
    /// street or a house named on its own, in the window's UTF-16 offsets.
    static func decodeSingle(_ tokens: [NameModel.Token], _ probabilities: [[Float]]) -> [Range<Int>] {
        var result: [Range<Int>] = [], current: (Int, Int)?
        func close() {
            guard let (start, end) = current else { return }
            current = nil
            var first = start, last = end
            while first <= last, !tokens[first].isWord { first += 1 }
            while last >= first, !tokens[last].isWord { last -= 1 }
            guard first <= last else { return }
            let span = tokens[first...last]
            guard !span.contains(where: { $0.scalars.contains(where: isDigit) }), !parted(span), span.contains(where: \.isWord) else { return }
            result.append(tokens[first].range.lowerBound..<tokens[last].range.upperBound)
        }
        for (index, p) in probabilities.enumerated() {
            if p[1] + p[2] >= threshold { current = current.map { ($0.0, index) } ?? (index, index) } else { close() }
        }
        close()
        return result
    }
    /// Words that say an address follows: "moved to", "lives at", "address:",
    /// "send it to", "wohne in der".
    private static let addressCue = TextPattern(#"(?i)(?:\b(?:moved|moving|move|relocated|relocating)\s+(?:in\s+)?to|\b(?:live|lives|living|lived|stay|stays|staying|based|located|reside|resides)\s+(?:(?:now|still)\s+)?(?:at|on|in)(?:\s+the)?|\b(?:address(?:\s+is)?|adresse|anschrift|dirección|indirizzo|adres)\s*[:\-]?|\b(?:send|ship|deliver|post|mail|forward)\b[^.!?\n]{0,24}?\bto|\bwohne\s+(?:jetzt\s+)?(?:in\s+der|in|am|an\s+der)|\bhabite\s+(?:au|à|a)|\bvivo\s+en|\bwoon\s+(?:nu\s+)?(?:op|aan|in))\s*$"#)
    /// A lowercase address `accepts` turns down for want of a postcode, a unit
    /// or a known place, with a second cue instead: words before it that say
    /// an address follows ("she moved to 12 rue des lilas"). It must still
    /// hold a number and a kind of street, so "moved to 3 new projects" is none.
    static func cued(_ value: String, before: String) -> Bool {
        guard value.contains(where: \.isNumber), !value.contains(where: \.isUppercase), !value.contains(where: \.isNewline) else { return false }
        let pieces = AddressBlock.pieces(value)
        guard pieces.contains(where: { AddressBlock.isStreet($0) || AddressBlock.namesStreet($0) }) else { return false }
        return !TextRanges.matches(addressCue, in: String(before.suffix(40))).isEmpty
    }
    /// A single piece worth asking about: capitalised, one to four words, a
    /// street's or a house's name ("Ahornweg", "Mill Lane", "Pear Tree
    /// Cottage"), after words that say someone lives there or post goes
    /// there (`addressCue`): "We met on Bay Street" is no one's address.
    static func doubtful(_ value: String, before: String) -> Bool {
        let words = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard (1...4).contains(words.count), !value.contains(where: \.isNewline), words.allSatisfy({ $0.first?.isUppercase == true || $0.count <= 3 }),
              AddressBlock.namesStreet(value) || AddressBlock.namesBuilding(value) else { return false }
        return !TextRanges.matches(addressCue, in: String(before.suffix(40))).isEmpty
    }
    /// A street or a house named on its own, as no town is: "Mill Lane",
    /// "Pear Tree Cottage", "Ahornweg". Read as a place, it is asked about as
    /// an address rather than given a town's stand-in (see `Detector`).
    static func streetAlone(_ value: String) -> Bool {
        let words = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let last = words.last?.lowercased(), words.count <= 4, !value.contains(where: { $0.isNumber || $0.isNewline || $0 == "," }),
              words.allSatisfy({ $0.first?.isUppercase == true || $0.count <= 3 }), !AddressBlock.knownPlace(value) else { return false }
        if words.count >= 2 { return aloneKinds.contains(last) }
        return !notSuffixed.contains(last) && cueSuffixes.contains { last.hasSuffix($0) && last.count > $0.count + 2 }
    }
    /// Last words that end a street's or a house's name and seldom a town's ("Mountain View" and "Notting Hill" are both).
    private static let aloneKinds: Set<String> = ["street", "st", "road", "rd", "lane", "ln", "avenue", "ave", "drive", "close", "crescent", "terrace", "mews",
                                                  "gardens", "boulevard", "blvd", "cottage", "rectory", "vicarage", "farmhouse", "manor"]

    /// An address without the ordinary words the model let run into it: a
    /// lowercase word or two before it ("be Apt 1205, …"), or after its last
    /// number or capitalised word ("… 44100 Nantes s'il", "… QLD 4006 shortly").
    /// A street written in lowercase ("12 rue de la paix") keeps its words: only
    /// a piece that holds a capitalised word loses a lowercase tail.
    static func refined(_ range: Range<Int>, _ tokens: [NameModel.Token]) -> Range<Int>? {
        guard var first = tokens.firstIndex(where: { $0.range.lowerBound == range.lowerBound }),
              var last = tokens.lastIndex(where: { $0.range.upperBound == range.upperBound }) else { return range }
        func text(_ index: Int) -> String { String(String.UnicodeScalarView(tokens[index].scalars)) }
        func lowercaseWord(_ index: Int) -> Bool { tokens[index].isWord && tokens[index].scalars.allSatisfy { isLetter($0) || $0 == "'" || $0 == "’" } && tokens[index].scalars.first?.properties.isLowercase == true }
        func marked(_ index: Int) -> Bool { tokens[index].scalars.contains(where: isDigit) || tokens[index].scalars.first?.properties.isUppercase == true }
        // A postcode's city ends the address before a full stop and the sentence after it ("…, 50674 Köln. Der Vogel …").
        if let stop = (first...last).first(where: { index in
            guard text(index) == ".", index + 1 <= last, index - 2 > first, tokens[index + 1].range.lowerBound > tokens[index].range.upperBound,
                  tokens[index + 1].scalars.first?.properties.isUppercase == true else { return false }
            var city = index - 1
            while city > first, tokens[city].isWord, tokens[city].scalars.first?.properties.isUppercase == true, !tokens[city].scalars.contains(where: isDigit), index - city <= 3 { city -= 1 }
            return city < index - 1 && city > first && (4...5).contains(tokens[city].scalars.count) && tokens[city].scalars.allSatisfy(isDigit)
        }) { last = stop - 1 }
        // The last piece: what follows the last comma or line break.
        var pieceStart = ((first...last).last { [",", "\n", ";"].contains(text($0)) }).map { $0 + 1 } ?? first
        // In a written address, a last piece of lowercase words alone is the sentence going on
        // ("Via Garibaldi, Torino, davanti al bar").
        if pieceStart - 2 >= first, (first..<pieceStart).contains(where: { tokens[$0].scalars.first?.properties.isUppercase == true }),
           (pieceStart...last).allSatisfy({ lowercaseWord($0) || !tokens[$0].isWord && text($0) != "\n" }) {
            last = pieceStart - 2
            while last > first, !tokens[last].isWord { last -= 1 }
            pieceStart = ((first...last).last { [",", "\n", ";"].contains(text($0)) }).map { $0 + 1 } ?? first
        }
        if let anchor = (pieceStart...last).last(where: marked), anchor < last,
           (anchor + 1...last).allSatisfy({ lowercaseWord($0) || !tokens[$0].isWord && text($0) != "\n" }),
           (pieceStart...anchor).contains(where: { tokens[$0].scalars.first?.properties.isUppercase == true }) {
            last = anchor
        }
        // A time's minutes are no house number: "10:15 in Room 2.07" is no address.
        if first >= 2, text(first - 1) == ":" || text(first - 1) == ".", tokens[first - 2].scalars.contains(where: isDigit), tokens[first].scalars.first.map(isDigit) == true,
           tokens[first - 1].range.lowerBound == tokens[first - 2].range.upperBound, tokens[first].range.lowerBound == tokens[first - 1].range.upperBound { return nil }
        // Written all in lowercase, only the sentence's small words before it go ("der gartenstraße 3, …", "nu kerkstraat 41, …").
        let cased = tokens[first...last].contains { $0.scalars.contains { $0.properties.isUppercase } }
        while first < last, lowercaseWord(first), !leadWords.contains(text(first).lowercased()), cased || leadInWords.contains(text(first).lowercased()), (first + 1...last).contains(where: marked) {
            first += 1
            while first < last, !tokens[first].isWord { first += 1 }
        }
        // ")" closes "(FI)"; "." ends "St." only when the model kept it, which decode never does.
        while last > first, !tokens[last].isWord, text(last) != ")" { last -= 1 }
        // All in lowercase, no capital marks where it ends: it ends with its last
        // piece's postcode, number or known place, and the words after that are the sentence's
        // ("… 10115 berlin seit märz", "… 31000 toulouse la semaine dernière"); a last
        // piece of such words alone (", danke") is none of it.
        if first <= last, !tokens[first...last].contains(where: { $0.scalars.contains { $0.properties.isUppercase } }) {
            func lastPiece() -> Int { ((first...last).last { [",", "\n", ";"].contains(text($0)) }).map { $0 + 1 } ?? first }
            var start = lastPiece()
            while start - 2 >= first, start <= last, (start...last).allSatisfy({ !tokens[$0].isWord || tailWords.contains(text($0)) }) {
                last = start - 2
                while last > first, !tokens[last].isWord { last -= 1 }
                start = lastPiece()
            }
            if start <= last, let anchor = (start...last).last(where: { tokens[$0].scalars.contains(where: isDigit) || knownPlaceEnd($0, tokens, from: start) }), anchor < last {
                var end = anchor
                // A city after its postcode ("10115 berlin", "3511 lx utrecht"): the words up to the first that only a sentence holds.
                if tokens[anchor].scalars.contains(where: isDigit) {
                    while end + 1 <= last, tokens[end + 1].isWord, !tailWords.contains(text(end + 1)), end - anchor < 3 { end += 1 }
                }
                if end < last, (end + 1...last).contains(where: { tokens[$0].isWord && tailWords.contains(text($0)) }) { last = end }
            }
        }
        // One that opens on its street's kind ("Tce, Fremantle WA 2601") takes the name and house number before it: "289 Coolabah Tce".
        if AddressBlock.englishKinds.contains(text(first).lowercased()) {
            var start = first, names = 0
            while start - 1 >= 0, names < 3, tokens[start - 1].isWord, tokens[start - 1].scalars.first?.properties.isUppercase == true, !tokens[start - 1].scalars.contains(where: isDigit) { start -= 1; names += 1 }
            if names > 0, start - 1 >= 0, !tokens[start - 1].scalars.isEmpty, tokens[start - 1].scalars.allSatisfy(isDigit) { first = start - 1 }
        }
        let words = tokens[first...last].filter { $0.scalars.contains(where: isLetter) }
        guard words.count >= 2, tokens[first...last].contains(where: { $0.scalars.contains(where: isDigit) }) || parted(tokens[first...last]) else { return nil }
        return tokens[first].range.lowerBound..<tokens[last].range.upperBound
    }

    /// Whether a comma, semicolon or line break parts the tokens into pieces.
    static func parted(_ tokens: ArraySlice<NameModel.Token>) -> Bool {
        tokens.contains { $0.scalars == [","] || $0.scalars == [";"] || $0.scalars == ["\n"] }
    }

    /// Whether the token ends a place Scrub knows by name, of up to three words, within the piece.
    private static func knownPlaceEnd(_ index: Int, _ tokens: [NameModel.Token], from start: Int) -> Bool {
        guard tokens[index].isWord else { return false }
        var words: [String] = [], position = index
        while position >= start, words.count < 3, tokens[position].isWord {
            words.insert(String(String.UnicodeScalarView(tokens[position].scalars)), at: 0)
            if AddressBlock.isKnownPlace(words.joined(separator: " ")) { return true }
            position -= 1
        }
        return false
    }
    /// Small words that lead a sentence into an address written in lowercase.
    private static let leadInWords: Set<String> = ["der", "die", "das", "den", "dem", "an", "in", "im", "am", "zu", "nach", "at", "to", "on", "is", "nu", "naar", "op", "aan",
                                                   "au", "à", "a", "en", "na", "no", "em", "para", "alla", "il", "på", "til", "till", "i", "w", "from"]
    /// Words that carry on a sentence after an address, never a place's name.
    private static let tailWords: Set<String> = ["seit", "ab", "bis", "bitte", "danke", "und", "la", "le", "les", "depuis", "dès", "svp", "merci", "et", "desde", "gracias", "y",
                                                 "dal", "dalla", "dopo", "grazie", "vanaf", "sinds", "bedankt", "en", "från", "fra", "tack", "tak", "och", "og", "from", "since", "until",
                                                 "after", "before", "on", "at", "is", "was", "the", "and", "pls", "please", "thx", "thanks", "asap", "fyi", "for", "last", "next", "tomorrow",
                                                 "today", "now", "jetzt", "nu", "not", "but", "so", "if", "c'est", "est", "é", "è", "es", "ist", "er", "a", "à"]

    /// The rules a span the model read must meet. One with no number needs a
    /// kind of street, a building or a unit in one piece and another piece
    /// beside it ("Flat B, The Old Rectory, Little Hadham"); in lowercase, a
    /// place Scrub knows besides. One written all in lowercase needs a
    /// postcode, a unit or box with its number, or a place Scrub knows
    /// ("14 rookery lane, leeds ls6 2ab"), so "take bus 14 to market street" stays.
    static func accepts(_ value: String) -> Bool {
        let digit = value.contains(where: \.isNumber), lower = !value.contains(where: \.isUppercase)
        let pieces = AddressBlock.pieces(value)
        if !digit {
            guard pieces.count >= 2, pieces.allSatisfy({ $0.contains(where: \.isLetter) && $0.split(separator: " ").count <= 6 }),
                  pieces.contains(where: { AddressBlock.isStreet($0) || AddressBlock.namesStreet($0) || AddressBlock.namesBuilding($0) || AddressBlock.isUnit($0) }) else { return false }
            return !lower || pieces.contains(where: AddressBlock.knownPlace)
        }
        guard lower else { return true }
        return !TextRanges.matches(lowercasePostcode, in: value).isEmpty || !TextRanges.matches(numberedUnit, in: value).isEmpty || pieces.contains(where: AddressBlock.knownPlace)
    }
    private static let writtenDate = TextPattern("(?i)(?<![\\p{L}\\p{N}])" + ProseLabels.day + "[ \\t]+(?:(?:de|of|del)[ \\t]+)?" + ProseLabels.month
                                                  + "(?:,?[ \\t]+(?:(?:de|del|of)[ \\t]+)?" + ProseLabels.year + ")?(?![\\p{L}\\p{N}])")
    /// A date written out ("el 14 de febrero de 1988", "15. März 1980") is when, not where, whatever cue is
    /// before it: a span with no number but the date's is no address. Nor is one a bracket opens or closes
    /// alone, which runs over the text around an address.
    static func misread(_ value: String) -> Bool {
        let dates = TextRanges.matches(writtenDate, in: value)
        if !dates.isEmpty, !dates.reversed().reduce(value, { rest, match in (rest as NSString).replacingCharacters(in: match.range, with: " ") }).contains(where: \.isNumber) { return true }
        // "sierpnia 1971 r.": a month's name in any language Scrub reads, and a year with at most a day, is a date too.
        if WrittenDates.yearAlone(value), value.split(whereSeparator: { !$0.isLetter }).contains(where: { WrittenDates.months[$0.lowercased()] != nil }) { return true }
        return value.filter { $0 == "(" }.count != value.filter { $0 == ")" }.count || value.filter { $0 == "[" }.count != value.filter { $0 == "]" }.count
    }
    /// A port, a timeout or a limit named before a number, or a unit of time or size after it, in the languages
    /// Scrub reads: "na porcie 5432", "limit czasu 30000 ms", "timeout po 5000 ms", "on port 8443". A machine's number, never a house's.
    static let machineBefore = #"(?i)(?<![\p{L}\p{N}])(?:ports?|porcie|portu|portem|poort|portti|portissa|portul|timeout|time-out|timed out|ttl|limit|limitu|limite|límite|limiet|zeitlimit|czasu|délai|tempo limite|tiempo de espera)[ \t]*[:=#]?[ \t]*(?:(?:po|of|after|nach|von|de|di|na|en|w|z|=)[ \t]+)?$"#
    private static let machineNumber = TextPattern(#"(?i)(?<![\p{L}\p{N}])\d+(?:[.,]\d+)?(?:[ \t]*(?:ms|msec|millis\p{L}*|s|sec|secs|seconds?|sek|sekund\p{L}*|segund\p{L}*|secondes?|minut\p{L}*|min|kb|mb|gb|tb|kib|mib|gib|bytes?|bajt\p{L}*|hz|khz|mhz|ghz|rpm|rps|qps)(?![\p{L}\p{N}/])|[ \t]*%)"#)
    private static let number = TextPattern(#"\d+(?:[.,]\d+)?"#)
    /// Whether every number of a span is a machine's, by the words before it or the unit after it.
    static func machineNumbers(_ value: String, before: String) -> Bool {
        guard value.contains(where: \.isNumber) else { return false }
        let ns = value as NSString
        var rest = value as NSString
        for match in TextRanges.matches(machineNumber, in: value).reversed() { rest = rest.replacingCharacters(in: match.range, with: String(repeating: " ", count: match.range.length)) as NSString }
        let numbers = TextRanges.matches(number, in: rest as String)
        return numbers.allSatisfy { match in
            let lead = String((before + ns.substring(to: match.range.location)).suffix(32))
            return lead.range(of: machineBefore, options: .regularExpression) != nil
        }
    }
    private static let lowercasePostcode = TextPattern(AddressBlock.postcode.regex?.pattern ?? "$^", options: .caseInsensitive)
    private static let numberedUnit = TextPattern(#"(?i)(?<![\p{L}])(?:flat|apt|apartment|unit|suite|ste|room|floor|level|appt|piso|wohnung|top|p\.?\s?o\.?\s?box|box|postfach|postbus|apartado)\.?\s*#?\s*\d"#)
    /// Lowercase words that open an address: a kind of street or a box.
    private static let leadWords: Set<String> = ["rue", "avenue", "allée", "chemin", "impasse", "quai", "place", "route", "boulevard", "via", "viale", "piazza", "corso",
                                                 "calle", "avenida", "rua", "travessa", "ul", "al", "os", "pl", "po", "p", "box", "c", "flat", "apt", "suite", "unit",
                                                 "rang", "chaussée", "plaza", "paseo", "camino", "largo", "vicolo", "strada", "alameda", "estrada", "praça", "postfach", "postbus"]

    // MARK: The network

    /// Softmax probabilities of O, B and I for each token.
    func probabilities(_ tokens: [NameModel.Token], isCancelled: () -> Bool = { false }) -> [[Float]] {
        logits(tokens, isCancelled: isCancelled).map { row in
            let top = row.max() ?? 0
            let exps = row.map { Foundation.exp($0 - top) }
            let sum = exps.reduce(0, +)
            return exps.map { $0 / sum }
        }
    }

    /// Three logits per token, in windows that overlap by more than the
    /// network's reach, so a long text scores as one pass would.
    func logits(_ tokens: [NameModel.Token], isCancelled: () -> Bool = { false }) -> [[Float]] {
        let reach = dilations.reduce(0) { $0 + $1 * (kernel / 2) }
        let margin = reach + 2
        let step = 2048
        var result = [[Float]](repeating: [], count: tokens.count)
        let lines = Self.lineShapes(tokens).map { Array($0.prefix(shapes - Self.shapeCount)) }
        var start = 0
        while start < tokens.count {
            if isCancelled() { return [] }
            let from = max(0, start - margin), to = min(tokens.count, start + step + margin)
            let window = run(tokens[from..<to], lines: lines[from..<to])
            for index in start..<min(tokens.count, start + step) {
                result[index] = Array(window[(index - from) * labels..<(index - from + 1) * labels])
            }
            start += step
        }
        return result
    }

    private func run(_ tokens: ArraySlice<NameModel.Token>, lines: ArraySlice<[Float]>) -> [Float] {
        let count = tokens.count, width = embed + shapes
        var input = [Float](repeating: 0, count: count * width)
        let keys = tokens.map { $0.scalars.map(\.value) }
        var found = known.withLock { cache in keys.map { cache[$0] } }
        var fresh: [[UInt32]: [Float]] = [:]
        for (row, token) in tokens.enumerated() where found[row] == nil {
            let features = fresh[keys[row]] ?? self.features(token.scalars)
            fresh[keys[row]] = features
            found[row] = features
        }
        if !fresh.isEmpty {
            known.withLock { cache in
                if cache.count + fresh.count > Self.knownLimit { cache.removeAll(keepingCapacity: true) }
                cache.merge(fresh) { old, _ in old }
            }
        }
        for (row, line) in zip(0..<count, lines) {
            input.replaceSubrange(row * width..<(row * width + width - line.count), with: found[row]!)
            input.replaceSubrange((row * width + width - line.count)..<(row + 1) * width, with: line)
        }
        var state = [Float](repeating: 0, count: count * hidden)
        vDSP_mmul(input, 1, project, 1, &state, 1, vDSP_Length(count), vDSP_Length(hidden), vDSP_Length(width))
        let biases = Self.tiled(projectBias, rows: count)
        vDSP_vadd(state, 1, biases, 1, &state, 1, vDSP_Length(count * hidden))
        Self.relu(&state)
        var product = [Float](repeating: 0, count: count * hidden)
        for (layer, dilation) in dilations.enumerated() {
            var sum = Self.tiled(convBiases[layer], rows: count)
            for tap in 0..<kernel {
                let shift = (tap - kernel / 2) * dilation
                let rows = count - abs(shift)
                guard rows > 0 else { continue }
                let source = max(0, shift), target = max(0, -shift)
                state.withUnsafeBufferPointer { from in
                    convs[layer].withUnsafeBufferPointer { weights in
                        product.withUnsafeMutableBufferPointer { into in
                            vDSP_mmul(from.baseAddress! + source * hidden, 1, weights.baseAddress! + tap * hidden * hidden, 1,
                                      into.baseAddress!, 1, vDSP_Length(rows), vDSP_Length(hidden), vDSP_Length(hidden))
                        }
                    }
                }
                sum.withUnsafeMutableBufferPointer { into in
                    product.withUnsafeBufferPointer { from in
                        vDSP_vadd(into.baseAddress! + target * hidden, 1, from.baseAddress!, 1, into.baseAddress! + target * hidden, 1, vDSP_Length(rows * hidden))
                    }
                }
            }
            Self.relu(&sum)
            vDSP_vadd(state, 1, sum, 1, &state, 1, vDSP_Length(count * hidden))
        }
        var result = Self.tiled(outBias, rows: count)
        var scores = [Float](repeating: 0, count: count * labels)
        vDSP_mmul(state, 1, out, 1, &scores, 1, vDSP_Length(count), vDSP_Length(labels), vDSP_Length(hidden))
        vDSP_vadd(result, 1, scores, 1, &result, 1, vDSP_Length(count * labels))
        return result
    }

    private static func tiled(_ row: [Float], rows: Int) -> [Float] {
        var result = [Float](repeating: 0, count: row.count * rows)
        for index in 0..<rows { result.replaceSubrange(index * row.count..<(index + 1) * row.count, with: row) }
        return result
    }

    private static func relu(_ values: inout [Float]) {
        var zero: Float = 0
        let count = vDSP_Length(values.count)
        values.withUnsafeMutableBufferPointer { buffer in
            vDSP_vthres(buffer.baseAddress!, 1, &zero, buffer.baseAddress!, 1, count)
        }
    }

    // MARK: Features

    /// The token's embedding (the mean of its hashed pieces' rows) followed by its shape.
    private func features(_ scalars: [Unicode.Scalar]) -> [Float] {
        let rows = Self.buckets(scalars, count: buckets)
        var result = [Float](repeating: 0, count: embed)
        var unpacked = [Float](repeating: 0, count: embed)
        table.withUnsafeBufferPointer { table in
            for row in rows {
                vDSP_vflt8(table.baseAddress! + row * embed, 1, &unpacked, 1, vDSP_Length(embed))
                var scale = scales[row] / Float(rows.count)
                vDSP_vsma(unpacked, 1, &scale, result, 1, &result, 1, vDSP_Length(embed))
            }
        }
        return result + Self.shape(scalars)
    }

    /// Pieces of the word lowercased, with every decimal digit read as 0: the
    /// whole word and its 2-, 3- and 4-grams, two rows each.
    static func buckets(_ scalars: [Unicode.Scalar], count: Int) -> [Int] {
        var marked: [Unicode.Scalar] = ["<"]
        for scalar in scalars {
            if isDigit(scalar) { marked.append("0") } else { marked.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars) }
        }
        marked.append(">")
        var rows: [Int] = []
        func add(_ piece: ArraySlice<Unicode.Scalar>) {
            var hash: UInt32 = 0x811C_9DC5
            for scalar in piece {
                for byte in UTF8.encode(scalar)! { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
            }
            rows.append(Int(hash % UInt32(count)))
            rows.append(Int((hash >> 16) % UInt32(count)))
        }
        add(marked[...])
        for size in 2...4 where marked.count >= size {
            for start in 0...(marked.count - size) { add(marked[start..<(start + size)]) }
        }
        return rows
    }

    /// The token's own shape; three or four more features, of its line, follow (see `lineShapes`).
    static let shapeCount = 15
    static func shape(_ scalars: [Unicode.Scalar]) -> [Float] {
        let letters = scalars.filter(isLetter)
        let upper = letters.filter(\.properties.isUppercase)
        let digits = scalars.filter(isDigit).count
        let length = scalars.count
        func flag(_ value: Bool) -> Float { value ? 1 : 0 }
        return [
            flag(scalars.first?.properties.isUppercase == true),
            flag(letters.count > 1 && upper.count == letters.count),
            flag(!letters.isEmpty && upper.isEmpty),
            flag(digits > 0),
            flag(digits > 0 && digits == length),
            flag((1...2).contains(digits)),
            flag(digits == 3),
            flag(digits == 4),
            flag(digits == 5),
            flag(digits >= 6),
            flag(digits > 0 && !letters.isEmpty),
            flag(scalars == ["\n"]),
            flag(length == 1 && !NameModel.isWord(scalars[0]) && scalars[0] != "\n"),
            Float(min(length, 20)) / 20,
            flag(letters.contains { $0.value > 127 }),
        ]
    }

    /// For each token: whether it opens its line, whether its line holds a
    /// digit, a comma, and a capital letter (in text written all in
    /// lowercase, a lowercase word tells nothing). A line ends with its newline token.
    static func lineShapes(_ tokens: [NameModel.Token]) -> [[Float]] {
        var result = [[Float]](repeating: [0, 0, 0, 0], count: tokens.count)
        var start = 0
        while start < tokens.count {
            var end = start
            while end < tokens.count, tokens[end].scalars != ["\n"] { end += 1 }
            let last = min(end, tokens.count - 1)
            let words = tokens[start..<min(end, tokens.count)]
            let digit: Float = words.contains { $0.scalars.contains(where: isDigit) } ? 1 : 0
            let comma: Float = words.contains { $0.scalars == [","] } ? 1 : 0
            let capital: Float = words.contains { $0.scalars.contains { $0.properties.isUppercase } } ? 1 : 0
            for index in start...last {
                result[index] = [index == start && tokens[index].scalars != ["\n"] ? 1 : 0, digit, comma, capital]
            }
            start = end + 1
        }
        return result
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .decimalNumber }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        var isValid = true

        mutating func bytes(_ count: Int) -> Data {
            guard count >= 0, offset + count <= data.count else { isValid = false; return Data() }
            defer { offset += count }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }

        mutating func uint32() -> UInt32 {
            bytes(4).withUnsafeBytes { $0.count == 4 ? UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) : 0 }
        }

        mutating func floats(_ count: Int) -> [Float] {
            let raw = bytes(count * 4)
            guard raw.count == count * 4 else { return [] }
            // The file is little-endian, as is every Mac Scrub runs on.
            return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
                initialized = count
            }
        }

        mutating func int8s(_ count: Int) -> [Int8] {
            let raw = bytes(count)
            guard raw.count == count else { return [] }
            return [Int8](unsafeUninitializedCapacity: count) { buffer, initialized in
                _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
                initialized = count
            }
        }
    }
}
