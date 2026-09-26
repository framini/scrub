import Foundation

struct Matcher {
    struct Match {
        let range: Range<Int>
        let index: Int
    }

    private struct Node {
        var edges: [UInt16: Int] = [:]
        var failure = 0
        var outputs: [Int] = []
    }

    let literals: [String]
    private let lengths: [Int]
    private let nodes: [Node]

    init(_ literals: [String]) {
        self.literals = literals
        let folded = literals.map(Self.fold)
        lengths = folded.map(\.count)
        var trie = [Node()]
        for (index, units) in folded.enumerated() where !units.isEmpty {
            var state = 0
            for unit in units {
                if let next = trie[state].edges[unit] {
                    state = next
                } else {
                    trie.append(Node())
                    let next = trie.count - 1
                    trie[state].edges[unit] = next
                    state = next
                }
            }
            trie[state].outputs.append(index)
        }
        var queue: [Int] = []
        for child in trie[0].edges.values { queue.append(child) }
        var head = 0
        while head < queue.count {
            let state = queue[head]
            head += 1
            for (unit, child) in trie[state].edges {
                var fallback = trie[state].failure
                while fallback != 0 && trie[fallback].edges[unit] == nil { fallback = trie[fallback].failure }
                trie[child].failure = trie[fallback].edges[unit] ?? 0
                trie[child].outputs += trie[trie[child].failure].outputs
                queue.append(child)
            }
        }
        nodes = trie
    }

    func matches(in text: String) -> [Match] {
        var result: [Match] = []
        var state = 0
        for (offset, unit) in Self.fold(text).enumerated() {
            if offset.isMultiple(of: 4096) && Task.isCancelled { return result }
            while state != 0 && nodes[state].edges[unit] == nil { state = nodes[state].failure }
            state = nodes[state].edges[unit] ?? 0
            for index in nodes[state].outputs {
                result.append(Match(range: (offset + 1 - lengths[index])..<(offset + 1), index: index))
            }
        }
        return result
    }

    static func fold(_ text: String) -> [UInt16] {
        text.utf16.map { unit in
            if (65...90).contains(unit) { return unit + 32 }
            if unit < 128 { return unit }
            let lower = String(decoding: [unit], as: UTF16.self).lowercased().utf16
            return lower.count == 1 ? lower.first ?? unit : unit
        }
    }
}
