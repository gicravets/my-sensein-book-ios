import Foundation

struct SpineItem {
    let href: String          // relative to the OPF directory
}

struct TocEntry: Identifiable {
    let id = UUID()
    let title: String
    let href: String          // relative to the OPF directory (may contain a #fragment)
    let level: Int
}

/// A fully parsed, unzipped EPUB ready to render.
struct ParsedEpub {
    let title: String
    let author: String?
    let coverHref: String?    // relative to the OPF directory
    let rootDir: URL          // unzipped archive root (WKWebView read-access scope)
    let opfDir: URL           // directory the OPF lives in (base for all hrefs)
    let spine: [SpineItem]
    let toc: [TocEntry]
    let startIndex: Int       // first spine item with real content (skips cover/title pages)

    func fileURL(forHref href: String) -> URL {
        let path = (href.components(separatedBy: "#").first ?? href)
        let decoded = path.removingPercentEncoding ?? path
        return opfDir.appendingPathComponent(decoded)
    }
}

enum EpubError: Error { case badArchive, noOpf }

enum EpubParser {

    static func parse(epubAt url: URL) throws -> ParsedEpub {
        guard let zip = MiniZip(url: url) else { throw EpubError.badArchive }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        zip.extractAll(to: root)

        // 1. META-INF/container.xml -> path to the OPF package document.
        guard
            let containerData = try? Data(contentsOf: root.appendingPathComponent("META-INF/container.xml")),
            let container = XMLTreeBuilder().parse(containerData),
            let opfPath = container.descendants("rootfile").first?.attributes["full-path"]
        else { throw EpubError.noOpf }

        let opfURL = root.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()
        guard
            let opfData = try? Data(contentsOf: opfURL),
            let package = XMLTreeBuilder().parse(opfData)
        else { throw EpubError.noOpf }

        // 2. Metadata.
        let title = package.descendants("title").first?.text.trimmed.nilIfEmpty
            ?? url.deletingPathExtension().lastPathComponent
        let author = package.descendants("creator").first?.text.trimmed.nilIfEmpty

        // 3. Manifest: id -> (href, media-type, properties).
        var manifest: [String: (href: String, type: String, props: String)] = [:]
        var navHref: String?
        var coverHref: String?
        let coverMetaId = package.descendants("meta")
            .first { $0.attributes["name"] == "cover" }?.attributes["content"]

        for item in package.descendants("item") {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            let type = item.attributes["media-type"] ?? ""
            let props = item.attributes["properties"] ?? ""
            manifest[id] = (href, type, props)
            if props.contains("nav") { navHref = href }
            if props.contains("cover-image") { coverHref = href }
            if id == coverMetaId, coverHref == nil { coverHref = href }
        }
        // Fallback: any image item whose id mentions "cover".
        if coverHref == nil {
            coverHref = manifest.first { $0.key.lowercased().contains("cover") && $0.value.type.hasPrefix("image") }?.value.href
        }

        // 4. Spine (reading order) + locate NCX toc.
        var spine: [SpineItem] = []
        var ncxHref: String?
        if let spineNode = package.descendants("spine").first {
            if let tocId = spineNode.attributes["toc"] { ncxHref = manifest[tocId]?.href }
            for itemref in spineNode.descendants("itemref") {
                guard let idref = itemref.attributes["idref"], let m = manifest[idref] else { continue }
                spine.append(SpineItem(href: m.href))
            }
        }

        // 5. Table of contents (EPUB3 nav doc preferred, else EPUB2 NCX).
        var toc: [TocEntry] = []
        if let nav = navHref {
            toc = parseNav(at: opfDir.appendingPathComponent(nav))
        }
        if toc.isEmpty, let ncx = ncxHref {
            toc = parseNcx(at: opfDir.appendingPathComponent(ncx))
        }

        // First spine item with substantial content (skip tiny cover/title/nav pages).
        var startIndex = 0
        for (i, item) in spine.enumerated() {
            let path = (item.href.components(separatedBy: "#").first ?? item.href).removingPercentEncoding ?? item.href
            let url = opfDir.appendingPathComponent(path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 1500 { startIndex = i; break }
        }

        return ParsedEpub(title: title, author: author, coverHref: coverHref,
                          rootDir: root, opfDir: opfDir, spine: spine, toc: toc, startIndex: startIndex)
    }

    // MARK: - TOC parsers

    private static func parseNcx(at url: URL) -> [TocEntry] {
        guard let data = try? Data(contentsOf: url), let tree = XMLTreeBuilder().parse(data) else { return [] }
        var out: [TocEntry] = []
        func walk(_ navPoint: XMLNode, level: Int) {
            let label = navPoint.firstChild("navLabel")?.descendants("text").first?.text.trimmed ?? ""
            let src = navPoint.firstChild("content")?.attributes["src"] ?? ""
            if !label.isEmpty, !src.isEmpty {
                out.append(TocEntry(title: label, href: src, level: level))
            }
            for child in navPoint.children where child.localName == "navPoint" {
                walk(child, level: level + 1)
            }
        }
        if let navMap = tree.descendants("navMap").first {
            for np in navMap.children where np.localName == "navPoint" { walk(np, level: 0) }
        }
        return out
    }

    private static func parseNav(at url: URL) -> [TocEntry] {
        guard let data = try? Data(contentsOf: url), let tree = XMLTreeBuilder().parse(data) else { return [] }
        let navs = tree.descendants("nav")
        let tocNav = navs.first { ($0.attributes["epub:type"] ?? $0.attributes["type"]) == "toc" } ?? navs.first
        guard let ol = tocNav?.descendants("ol").first else { return [] }

        var out: [TocEntry] = []
        func walk(_ ol: XMLNode, level: Int) {
            for li in ol.children where li.localName == "li" {
                if let a = li.descendants("a").first {
                    let title = a.descendants("span").first?.text.trimmed.nilIfEmpty ?? a.text.trimmed
                    if let href = a.attributes["href"], !title.isEmpty {
                        out.append(TocEntry(title: title, href: href, level: level))
                    }
                }
                if let nested = li.firstChild("ol") { walk(nested, level: level + 1) }
            }
        }
        walk(ol, level: 0)
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
