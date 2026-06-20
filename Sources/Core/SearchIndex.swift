import Foundation

struct SearchResult: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    let occurrence: Int          // which match within the chapter (0-based)
    let snippet: String          // context around the match
    let matchRange: Range<String.Index>   // the match inside `snippet`
}

/// Whole-book text search. Extracts each chapter's <body> text the same way the
/// in-page JS walks text nodes, so the per-chapter occurrence index lines up with
/// what `gotoMatch` re-finds in the live DOM.
final class SearchIndex {
    private let epub: ParsedEpub
    private var cache: [Int: String] = [:]

    init(epub: ParsedEpub) { self.epub = epub }

    /// ё/е- and case-insensitive normalization, length-preserving so offsets stay
    /// aligned. Must match the in-page JS `nz()` exactly so occurrence indexes agree.
    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    func text(for chapter: Int) -> String {
        if let t = cache[chapter] { return t }
        guard epub.spine.indices.contains(chapter) else { return "" }
        let url = epub.fileURL(forHref: epub.spine[chapter].href)
        let t = (try? Data(contentsOf: url)).flatMap { BodyTextExtractor.extract(from: $0) } ?? ""
        cache[chapter] = t
        return t
    }

    func search(_ rawQuery: String) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let needle = Self.normalize(query)
        var results: [SearchResult] = []

        for chapter in epub.spine.indices {
            let original = text(for: chapter)
            guard !original.isEmpty else { continue }
            let hay = Self.normalize(original)
            let origChars = Array(original)
            let hayChars = Array(hay)
            let needleChars = Array(needle)
            var occ = 0
            var i = 0
            while i <= hayChars.count - needleChars.count {
                if matches(hayChars, needleChars, at: i) {
                    let snippet = makeSnippet(origChars, matchStart: i, matchLen: needleChars.count)
                    results.append(SearchResult(chapterIndex: chapter, occurrence: occ,
                                                snippet: snippet.text, matchRange: snippet.range))
                    occ += 1
                    i += needleChars.count
                } else {
                    i += 1
                }
                if results.count > 500 { return results }   // safety cap
            }
        }
        return results
    }

    private func matches(_ hay: [Character], _ needle: [Character], at i: Int) -> Bool {
        for j in 0..<needle.count where hay[i + j] != needle[j] { return false }
        return true
    }

    private func makeSnippet(_ chars: [Character], matchStart: Int, matchLen: Int) -> (text: String, range: Range<String.Index>) {
        let pad = 32
        let lo = max(0, matchStart - pad)
        let hi = min(chars.count, matchStart + matchLen + pad)
        var prefix = String(chars[lo..<matchStart])
        let match = String(chars[matchStart..<matchStart + matchLen])
        var suffix = String(chars[(matchStart + matchLen)..<hi])
        prefix = prefix.replacingOccurrences(of: "\n", with: " ")
        suffix = suffix.replacingOccurrences(of: "\n", with: " ")
        if lo > 0 { prefix = "…" + prefix }
        if hi < chars.count { suffix += "…" }
        let snippet = prefix + match + suffix
        let start = snippet.index(snippet.startIndex, offsetBy: prefix.count)
        let end = snippet.index(start, offsetBy: match.count)
        return (snippet, start..<end)
    }
}

/// Extracts visible <body> text in document order, skipping <head>, <script>, <style>.
/// Mirrors a DOM text-node walk so occurrence counts match the in-page JS.
private final class BodyTextExtractor: NSObject, XMLParserDelegate {
    private var out = ""
    private var inBody = false
    private var skipDepth = 0

    static func extract(from data: Data) -> String {
        let p = BodyTextExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        parser.parse()
        // FB2 has no <body> wrapper recognized as html body; fall back to all text.
        return p.out.isEmpty ? p.fallback : p.out
    }

    private var fallback = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = elementName.lowercased()
        if name == "body" { inBody = true }
        if name == "script" || name == "style" { skipDepth += 1 }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "script" || name == "style", skipDepth > 0 { skipDepth -= 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        fallback += string
        if inBody { out += string }
    }
}
