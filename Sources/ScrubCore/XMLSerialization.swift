import Foundation

enum XMLSerialization {
    // Preserving entity spellings can corrupt decoded values after a numeric
    // character reference. Detection needs the decoded text, not its spelling.
    static let parseOptions: XMLNode.Options = XMLNode.Options.nodePreserveAll
        .subtracting([.nodePreserveEntities, .nodePreserveCharacterReferences])
        .union(.nodeLoadExternalEntitiesNever)

    static func render(_ document: XMLDocument) -> String {
        let prefix = "scrub" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var replacements: [String: String] = [:]
        var saved: [(XMLNode, String)] = []
        func protect(_ node: XMLNode) {
            guard let value = node.stringValue else { return }
            let cdata = node.kind == .text && node.xmlString(options: [.nodePreserveAll]).hasPrefix("<![CDATA[")
            let token = prefix + String(replacements.count) + "end"
            replacements[token] = cdata ? value : escaped(value, attribute: node.kind == .attribute)
            saved.append((node, value))
            node.stringValue = token
        }
        func walk(_ node: XMLNode) {
            if let element = node as? XMLElement {
                for attribute in element.attributes ?? [] { protect(attribute) }
            } else if node.kind == .text { protect(node) }
            for child in node.children ?? [] { walk(child) }
        }
        // Foundation can serialize decoded attribute whitespace literally, and
        // preserved text references can leave ampersands unescaped.
        walk(document)
        let output = document.xmlString(options: [.nodePreserveAll])
        for (node, value) in saved { node.stringValue = value }
        let pattern = TextPattern(prefix + "[0-9]+end")
        let edits = TextRanges.matches(pattern, in: output).compactMap { match -> (range: Range<Int>, value: String)? in
            let range = match.range.location..<(match.range.location + match.range.length)
            guard let value = replacements[TextRanges.substring(output, range)] else { return nil }
            return (range, value)
        }
        return TextRanges.apply(edits, to: output).0
    }

    // Parsers normalise whitespace in attribute values, so only there do tabs
    // and newlines need references; in text they stay literal and readable.
    // A literal CR is folded into LF by any parser, so it is always a reference.
    private static func escaped(_ value: String, attribute: Bool) -> String {
        let text = value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
        guard attribute else { return text }
        return text.replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\t", with: "&#9;")
    }
}
