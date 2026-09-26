import Foundation

// Bound the tree before Foundation allocates or recursively releases a DOM.
private final class DepthDelegate: NSObject, XMLParserDelegate {
    var depth = 0
    var tooDeep = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth > 64 { tooDeep = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
}

enum XMLDepth {
    static func check(_ data: Data) throws {
        let delegate = DepthDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        if delegate.tooDeep { throw ScrubError.unsupported("too_deep") }
    }
}
