import Foundation

/// A parsed XML element: local name, attributes (prefix kept, so `xsi:type` and `type` are both
/// reachable), text and children. Enough for vim25 responses; namespaces are ignored on read.
public final class XMLNode: @unchecked Sendable {
    public let name: String
    public let attributes: [String: String]
    public private(set) var text: String
    public private(set) var children: [XMLNode]

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
        self.text = ""
        self.children = []
    }

    func append(text: String) { self.text += text }
    func append(child: XMLNode) { children.append(child) }

    /// The `xsi:type` (or `type`) attribute: the vim25 type of a value or managed object.
    public var xsiType: String? { attributes["xsi:type"] ?? attributes["type"] }

    /// First child with this local name.
    public subscript(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    /// All children with this local name.
    public func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }
    /// Text of the first child with this name, trimmed.
    public func string(_ name: String) -> String? { self[name]?.trimmedText }
    public func int(_ name: String) -> Int? { string(name).flatMap { Int($0) } }
    public func int64(_ name: String) -> Int64? { string(name).flatMap { Int64($0) } }
    public func bool(_ name: String) -> Bool? { string(name).map { $0 == "true" || $0 == "1" } }
    public func date(_ name: String) -> Date? { string(name).flatMap(XMLNode.parseDate) }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Walk down a path of child names: `node.path("returnval", "about", "fullName")`.
    public func path(_ names: String...) -> XMLNode? {
        var node: XMLNode? = self
        for n in names { node = node?[n] }
        return node
    }

    /// Finds the first descendant with this name (depth first).
    public func find(_ name: String) -> XMLNode? {
        for c in children {
            if c.name == name { return c }
            if let found = c.find(name) { return found }
        }
        return nil
    }

    /// Parses ISO 8601 with or without fractional seconds (`2026-10-03T06:36:59.472087Z`).
    public static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Parses a document; throws on malformed input.
    public static func parse(_ data: Data) throws -> XMLNode {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = Builder()
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw VimError.malformedResponse(parser.parserError?.localizedDescription ?? "not XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last { parent.append(child: node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.append(text: string)
        }
    }
}

/// Writes request bodies. Elements are emitted in the order given, which vim25 requires.
public struct XMLOut: Sendable {
    public var elements: [Element]

    public struct Element: Sendable {
        public var name: String
        public var attributes: [(String, String)]
        public var text: String?
        public var children: [Element]

        public init(_ name: String, attributes: [(String, String)] = [], text: String? = nil, children: [Element] = []) {
            self.name = name
            self.attributes = attributes
            self.text = text
            self.children = children
        }

        /// `<name type="Type">value</name>`: a managed object reference.
        public static func ref(_ name: String, _ ref: MoRef) -> Element {
            Element(name, attributes: [("type", ref.type)], text: ref.value)
        }

        public static func text(_ name: String, _ value: String) -> Element { Element(name, text: value) }
        public static func bool(_ name: String, _ value: Bool) -> Element { Element(name, text: value ? "true" : "false") }
        public static func int(_ name: String, _ value: Int) -> Element { Element(name, text: String(value)) }
        public static func int64(_ name: String, _ value: Int64) -> Element { Element(name, text: String(value)) }

        /// A typed data object: `<name xsi:type="Type">…</name>`.
        public static func typed(_ name: String, _ type: String, _ children: [Element]) -> Element {
            Element(name, attributes: [("xsi:type", type)], children: children)
        }

        func render(into out: inout String) {
            out += "<"
            out += name
            for (k, v) in attributes {
                out += " \(k)=\"\(XMLOut.escape(v, attribute: true))\""
            }
            if text == nil && children.isEmpty {
                out += "/>"
                return
            }
            out += ">"
            if let text { out += XMLOut.escape(text, attribute: false) }
            for c in children { c.render(into: &out) }
            out += "</\(name)>"
        }
    }

    public static func escape(_ s: String, attribute: Bool) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\r": out += "&#13;"
            case "\n" where attribute: out += "&#10;"
            case "\t" where attribute: out += "&#9;"
            default:
                // XML 1.0 forbids most C0 controls; drop them rather than fail the request.
                if ch.value < 0x20 && ch != "\n" && ch != "\t" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// A vim25 method call envelope: `<Method xmlns="urn:vim25"><_this type=…>…</_this>…</Method>`.
    public static func envelope(method: String, this: MoRef, arguments: [Element]) -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        out += "<soapenv:Envelope xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\""
        out += " xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        out += "<soapenv:Body>"
        var call = Element(method, attributes: [("xmlns", "urn:vim25")])
        call.children = [.ref("_this", this)] + arguments
        call.render(into: &out)
        out += "</soapenv:Body></soapenv:Envelope>"
        return Data(out.utf8)
    }
}
