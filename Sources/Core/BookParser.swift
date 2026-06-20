import Foundation
import UniformTypeIdentifiers

/// Dispatches to the right parser by file type. Both formats produce a `ParsedEpub`.
enum BookParser {
    static func parse(at url: URL) throws -> ParsedEpub {
        switch url.pathExtension.lowercased() {
        case "fb2":
            return try Fb2Parser.parse(at: url)
        case "zip":
            // Could be an .fb2.zip; fall back to EPUB if there's no FB2 inside.
            if let p = try? Fb2Parser.parse(at: url), !p.spine.isEmpty { return p }
            return try EpubParser.parse(epubAt: url)
        default:
            return try EpubParser.parse(epubAt: url)
        }
    }

    /// Content types accepted by the file importers (EPUB + FB2 + zip).
    static var importTypes: [UTType] {
        var types: [UTType] = [.epub, .zip]
        if let fb2 = UTType(filenameExtension: "fb2") { types.append(fb2) }
        return types
    }
}
