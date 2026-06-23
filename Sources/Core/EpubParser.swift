import Foundation

struct SpineItem {
    let href: String                  // relative to the OPF directory
    var mediaOverlayHref: String? = nil  // SMIL for this doc (EPUB3 Media Overlays), if any
}

/// One synced text↔audio clip from a Media Overlay SMIL (<par>).
struct MOClip {
    let fragmentID: String   // id of the <span> in the text doc
    let audioHref: String    // audio file href (relative to the OPF dir)
    let begin: Double        // seconds
    let end: Double
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
    let series: String?       // multi-volume series name, if any
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

    /// True when this chapter ships an EPUB3 Media Overlay (human-narrated audio synced to text).
    func hasMediaOverlay(spine index: Int) -> Bool {
        spine.indices.contains(index) && spine[index].mediaOverlayHref != nil
    }

    /// Parsed <par> clips (fragment id ↔ audio clip times) for a chapter's Media Overlay.
    func mediaOverlayClips(forSpine index: Int) -> [MOClip] {
        guard spine.indices.contains(index), let smilHref = spine[index].mediaOverlayHref,
              let data = try? Data(contentsOf: fileURL(forHref: smilHref)),
              let smil = XMLTreeBuilder().parse(data) else { return [] }
        let smilDir = (smilHref as NSString).deletingLastPathComponent
        var clips: [MOClip] = []
        for par in smil.descendants("par") {
            guard let text = par.descendants("text").first,
                  let audio = par.descendants("audio").first,
                  let src = text.attributes["src"],
                  let audioSrc = audio.attributes["src"] else { continue }
            let fid = src.components(separatedBy: "#").last ?? ""
            let audioHref = smilDir.isEmpty ? audioSrc : (smilDir as NSString).appendingPathComponent(audioSrc)
            clips.append(MOClip(fragmentID: fid, audioHref: audioHref,
                                begin: moClock(audio.attributes["clipBegin"]),
                                end: moClock(audio.attributes["clipEnd"])))
        }
        return clips
    }
}

/// Parse a SMIL clock value ("12.500s" or "00:01:02.5" or "12.5") into seconds.
func moClock(_ s: String?) -> Double {
    guard var v = s?.trimmingCharacters(in: .whitespaces) else { return 0 }
    if v.hasSuffix("s") { v = String(v.dropLast()) }
    if v.contains(":") {
        return v.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }
    return Double(v) ?? 0
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

        // Series: EPUB2 calibre meta, else EPUB3 belongs-to-collection.
        let seriesRaw = package.descendants("meta").first { $0.attributes["name"] == "calibre:series" }?.attributes["content"]
            ?? package.descendants("meta").first { $0.attributes["property"] == "belongs-to-collection" }?.text
        let series = seriesRaw.flatMap { $0.trimmed.nilIfEmpty }

        // 3. Manifest: id -> (href, media-type, properties).
        var manifest: [String: (href: String, type: String, props: String)] = [:]
        var navHref: String?
        var coverHref: String?
        let coverMetaId = package.descendants("meta")
            .first { $0.attributes["name"] == "cover" }?.attributes["content"]

        var itemMO: [String: String] = [:]   // content-item id -> media-overlay (SMIL) item id
        for item in package.descendants("item") {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            let type = item.attributes["media-type"] ?? ""
            let props = item.attributes["properties"] ?? ""
            manifest[id] = (href, type, props)
            if let mo = item.attributes["media-overlay"] { itemMO[id] = mo }
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
                let smilHref = itemMO[idref].flatMap { manifest[$0]?.href }
                spine.append(SpineItem(href: m.href, mediaOverlayHref: smilHref))
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

        return ParsedEpub(title: title, author: author, series: series, coverHref: coverHref,
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
