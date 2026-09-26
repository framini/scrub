import Foundation

struct Matcher {
    struct Match {
        let range: Range<Int>
        let index: Int
    }

    let literals: [String]
    private let units: [UInt16]
    private let offsets: [Int32]
    private let prefixes: [UInt64: Int32]
    private let nextCandidate: [Int32]
    private let shortLengths: Set<Int>

    init(_ literals: [String]) {
        self.literals = literals
        var allUnits: [UInt16] = []
        var starts: [Int32] = []
        var buckets: [UInt64: Int32] = [:]
        var links: [Int32] = []
        var short: Set<Int> = []
        starts.reserveCapacity(literals.count)
        for (index, literal) in literals.enumerated() {
            let folded = Self.fold(literal)
            let width = folded.count
            starts.append(Int32(allUnits.count))
            links.append(-1)
            guard width > 0 else { continue }
            let prefixLength = min(8, width)
            let key = Self.hash(folded.prefix(prefixLength))
            allUnits.append(contentsOf: folded)
            links[index] = buckets[key] ?? -1
            buckets[key] = Int32(index)
            if width < 8 { short.insert(width) }
        }
        starts.append(Int32(allUnits.count))
        units = allUnits
        offsets = starts
        prefixes = buckets
        nextCandidate = links
        shortLengths = short
    }

    func matches(in text: String, accepting: (Range<Int>) -> Bool = { _ in true }) -> [Match] {
        var result: [Match] = []
        var folded: [UInt16] = []
        var starts: [Int] = []
        var ends: [Int] = []
        var scalarStart = 0
        for scalar in text.unicodeScalars {
            let sourceLength = scalar.utf16.count
            for unit in Self.fold(scalar) {
                folded.append(unit)
                starts.append(scalarStart)
                ends.append(scalarStart + sourceLength)
            }
            scalarStart += sourceLength
        }
        guard !folded.isEmpty else { return [] }
        for position in folded.indices {
            if position.isMultiple(of: 4096) && Task.isCancelled { return result }
            if position > 0 && starts[position] == starts[position - 1] { continue }
            var hash: UInt64 = 0xcbf29ce484222325
            var matchedEnds: [Int] = []
            for prefixLength in 1...min(8, folded.count - position) {
                hash = (hash ^ UInt64(folded[position + prefixLength - 1])) &* 0x100000001b3
                if prefixLength < 8 && !shortLengths.contains(prefixLength) { continue }
                var candidate = prefixes[hash] ?? -1
                while candidate >= 0 {
                    let index = Int(candidate)
                    candidate = nextCandidate[index]
                    let width = Int(offsets[index + 1] - offsets[index])
                    let end = position + width
                    guard width >= prefixLength, end <= folded.count,
                        end == folded.count || ends[end - 1] != ends[end] else { continue }
                    let offset = Int(offsets[index])
                    guard folded[position..<end].elementsEqual(units[offset..<(offset + width)]) else { continue }
                    let range = starts[position]..<ends[end - 1]
                    if !matchedEnds.contains(end) && accepting(range) {
                        matchedEnds.append(end)
                        result.append(Match(range: range, index: index))
                    }
                }
            }
        }
        return result
    }

    private static func hash(_ values: ArraySlice<UInt16>) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for value in values { hash = (hash ^ UInt64(value)) &* 0x100000001b3 }
        return hash
    }

    private static func fold(_ scalar: Unicode.Scalar) -> [UInt16] {
        if scalar.value < 128 {
            let value = UInt16(scalar.value)
            return [(65...90).contains(value) ? value + 32 : value]
        }
        return Array(String(scalar).folding(options: [.caseInsensitive], locale: nil).utf16)
    }

    static func fold(_ text: String) -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(text.utf16.count)
        for scalar in text.unicodeScalars { result.append(contentsOf: fold(scalar)) }
        return result
    }
}
