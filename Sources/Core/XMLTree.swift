import Foundation

/// Minimal DOM-style tree built on top of Foundation's event-based XMLParser.
/// Good enough to query EPUB's container.xml / OPF / NCX / nav documents.
/// Ordered mixed content (text interleaved with child elements) — needed to render
/// FB2 inline markup (`<p>Hello <emphasis>world</emphasis>!</p>`) in the right order.
enum XMLContent {
    case text(String)
    case node(XMLNode)
}

final class XMLNode {
    let name: String
    var attributes: [String: String]
    var children: [XMLNode] = []
    var content: [XMLContent] = []
    weak var parent: XMLNode?
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Local name without namespace prefix (e.g. "dc:title" -> "title").
    var localName: String {
        guard let last = name.split(separator: ":").last else { return name }
        return String(last)
    }

    /// All descendants (any depth) whose local name matches `tag`.
    func descendants(_ tag: String) -> [XMLNode] {
        var result: [XMLNode] = []
        for child in children {
            if child.localName == tag { result.append(child) }
            result.append(contentsOf: child.descendants(tag))
        }
        return result
    }

    func firstChild(_ tag: String) -> XMLNode? {
        children.first { $0.localName == tag }
    }
}

final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private var root: XMLNode?
    private var stack: [XMLNode] = []

    func parse(_ data: Data) -> XMLNode? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        node.parent = stack.last
        stack.last?.children.append(node)
        stack.last?.content.append(.node(node))
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
        stack.last?.content.append(.text(string))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
