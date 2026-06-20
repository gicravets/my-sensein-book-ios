import Foundation

/// Parses a FictionBook (.fb2 or .fb2.zip) into the same `ParsedEpub` model the
/// reader uses: top-level <section>s become chapter HTML files, <binary> images are
/// decoded to files, and inline markup is converted to HTML.
enum Fb2Parser {

    static func parse(at url: URL) throws -> ParsedEpub {
        let raw = try Data(contentsOf: url)
        // .fb2.zip → take the first .fb2 entry.
        let xmlData: Data
        if let zip = MiniZip(data: raw),
           let name = zip.order.first(where: { $0.lowercased().hasSuffix(".fb2") }),
           let d = zip.data(for: name) {
            xmlData = d
        } else {
            xmlData = raw
        }
        guard let root = XMLTreeBuilder().parse(xmlData) else { throw EpubError.badArchive }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fb2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Metadata
        let titleInfo = root.descendants("title-info").first
        let title = titleInfo?.firstChild("book-title")?.text.trimmed,
            author = authorName(titleInfo?.firstChild("author"))
        let coverId = titleInfo?.firstChild("coverpage")?.descendants("image").first.flatMap(imageHref)

        // Binaries (images, cover)
        var coverHref: String?
        for bin in root.descendants("binary") {
            guard let id = bin.attributes["id"] else { continue }
            let b64 = bin.text.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: b64) else { continue }
            let fname = sanitize(id)
            try? data.write(to: dir.appendingPathComponent(fname))
            if id == coverId { coverHref = fname }
        }

        // Chapters: each top-level <section> of the main <body>.
        let bodies = root.descendants("body")
        let mainBody = bodies.first { $0.attributes["name"] == nil } ?? bodies.first
        let topSections = mainBody?.children.filter { $0.localName == "section" } ?? []

        var spine: [SpineItem] = []
        var toc: [TocEntry] = []

        func writeChapter(_ html: String, index: Int) {
            let file = "ch\(index).html"
            try? wrap(html).data(using: .utf8)?.write(to: dir.appendingPathComponent(file))
            spine.append(SpineItem(href: file))
        }

        if topSections.isEmpty {
            // No sections — render the whole body as one chapter.
            writeChapter(render(mainBody, depth: 0), index: 0)
        } else {
            for (i, sec) in topSections.enumerated() {
                writeChapter(render(sec, depth: 0), index: i)
                if let label = sectionTitle(sec) {
                    toc.append(TocEntry(title: label, href: "ch\(i).html", level: 0))
                }
                for sub in sec.children where sub.localName == "section" {
                    if let label = sectionTitle(sub) {
                        toc.append(TocEntry(title: label, href: "ch\(i).html", level: 1))
                    }
                }
            }
        }

        return ParsedEpub(title: (title?.isEmpty == false ? title! : url.deletingPathExtension().lastPathComponent),
                          author: author, coverHref: coverHref,
                          rootDir: dir, opfDir: dir, spine: spine, toc: toc, startIndex: 0)
    }

    // MARK: - Rendering

    private static func render(_ node: XMLNode?, depth: Int) -> String {
        guard let node else { return "" }
        var out = ""
        for item in node.content {
            switch item {
            case .text(let t): out += escape(t)
            case .node(let n): out += renderNode(n, depth: depth)
            }
        }
        return out
    }

    private static func renderNode(_ n: XMLNode, depth: Int) -> String {
        switch n.localName {
        case "section":      return "<div class=\"section\">\(render(n, depth: depth + 1))</div>"
        case "title":        return "<h\(min(depth + 2, 6)) class=\"fb2title\">\(titleLines(n, depth: depth))</h\(min(depth + 2, 6))>"
        case "subtitle":     return "<h5 class=\"fb2sub\">\(render(n, depth: depth))</h5>"
        case "p":            return "<p>\(render(n, depth: depth))</p>"
        case "empty-line":   return "<br/>"
        case "emphasis", "i": return "<em>\(render(n, depth: depth))</em>"
        case "strong", "b":  return "<strong>\(render(n, depth: depth))</strong>"
        case "strikethrough": return "<s>\(render(n, depth: depth))</s>"
        case "sub":          return "<sub>\(render(n, depth: depth))</sub>"
        case "sup":          return "<sup>\(render(n, depth: depth))</sup>"
        case "code":         return "<code>\(render(n, depth: depth))</code>"
        case "epigraph", "cite": return "<blockquote>\(render(n, depth: depth))</blockquote>"
        case "text-author":  return "<p class=\"author\">\(render(n, depth: depth))</p>"
        case "poem":         return "<div class=\"poem\">\(render(n, depth: depth))</div>"
        case "stanza":       return "<div class=\"stanza\">\(render(n, depth: depth))</div>"
        case "v":            return "<div class=\"v\">\(render(n, depth: depth))</div>"
        case "table":        return "<table>\(render(n, depth: depth))</table>"
        case "tr":           return "<tr>\(render(n, depth: depth))</tr>"
        case "td", "th":     return "<td>\(render(n, depth: depth))</td>"
        case "image":        return imageHref(n).map { "<img src=\"\(sanitize($0))\"/>" } ?? ""
        case "a":            return "<a href=\"\(escape(imageHref(n) ?? "#"))\">\(render(n, depth: depth))</a>"
        default:             return render(n, depth: depth)
        }
    }

    /// Render a <title>'s child <p> lines joined by <br/>.
    private static func titleLines(_ title: XMLNode, depth: Int) -> String {
        var lines: [String] = []
        for item in title.content {
            if case .node(let n) = item, n.localName == "p" {
                lines.append(render(n, depth: depth))
            } else if case .text(let t) = item, !t.trimmed.isEmpty {
                lines.append(escape(t))
            }
        }
        return lines.joined(separator: "<br/>")
    }

    private static func sectionTitle(_ sec: XMLNode) -> String? {
        let t = sec.firstChild("title")?.text.trimmed ?? ""
        return t.isEmpty ? nil : t
    }

    private static func authorName(_ author: XMLNode?) -> String? {
        guard let author else { return nil }
        let parts = [author.firstChild("first-name")?.text.trimmed,
                     author.firstChild("middle-name")?.text.trimmed,
                     author.firstChild("last-name")?.text.trimmed,
                     author.firstChild("nickname")?.text.trimmed]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let name = parts.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static func imageHref(_ n: XMLNode) -> String? {
        let href = n.attributes["l:href"] ?? n.attributes["xlink:href"] ?? n.attributes["href"]
        return href.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
    }

    private static func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func wrap(_ body: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          .fb2title{text-align:center;margin:1.2em 0 0.8em;}
          .fb2sub{text-align:center;font-weight:normal;font-style:italic;margin:0.8em 0;}
          .poem{margin:1em 1.5em;} .stanza{margin:0.8em 0;} .v{text-align:left;}
          .author{text-align:right;font-style:italic;} blockquote{margin:0.8em 1.2em;font-style:italic;}
          p{margin:0 0 0.7em;text-indent:1.2em;}
        </style></head><body>\(body)</body></html>
        """
    }
}
