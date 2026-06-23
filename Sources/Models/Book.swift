import Foundation

/// A saved reading position the user can jump back to.
/// Located by chapter + fraction (0...1 within the chapter) so it survives reflow.
struct Bookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var chapterIndex: Int
    var fraction: Double
    var label: String          // snippet of the line shown in the list
    var createdAt = Date()
}

/// A colored highlight. Located by chapter + the exact selected text + which
/// occurrence of that text in the chapter (robust across reflow / font changes).
struct Highlight: Identifiable, Codable, Equatable {
    var id = UUID()
    var chapterIndex: Int
    var text: String
    var occurrence: Int        // 0-based index among identical substrings in the chapter
    var colorHex: String
    var note: String = ""
    var createdAt = Date()
}

/// A book the user has imported. Persisted as JSON; the book file itself
/// lives in Documents/Books and the cover thumbnail in Documents/Covers.
struct Book: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var author: String?
    var series: String? = nil     // multi-volume series name (from EPUB metadata)
    var fileName: String          // file inside Documents/Books
    var coverFileName: String?    // file inside Documents/Covers
    var addedAt: Date

    // Reading position
    var chapterIndex: Int = 0
    var chapterFraction: Double = 0   // 0...1 within the current chapter (reflow-safe)
    var progress: Double = 0          // 0...1 across the whole book
    var lastReadAt: Date?

    // Organisation
    var shelf: String? = nil          // name of the shelf this book is filed under
    var isFinished: Bool = false      // user marked it read, or read to the end

    // Annotations
    var bookmarks: [Bookmark] = []
    var highlights: [Highlight] = []

    // Library sync (file synced to the server)
    var serverID: String? = nil       // id of this book on the server (set after upload)
    var fileHash: String? = nil       // server's content hash (dedup / reconcile)

    var fileURL: URL { AppPaths.books.appendingPathComponent(fileName) }
    var coverURL: URL? { coverFileName.map { AppPaths.covers.appendingPathComponent($0) } }
}

extension Book {
    // Custom init kept in an extension so the memberwise initializer is preserved.
    // Uses decodeIfPresent for every defaulted/optional field so adding new fields
    // never breaks decoding of older library.json files (forward-migration safe).
    private enum CodingKeys: String, CodingKey {
        case id, title, author, series, fileName, coverFileName, addedAt
        case chapterIndex, chapterFraction, progress, lastReadAt
        case shelf, isFinished, bookmarks, highlights
        case serverID, fileHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        series = try c.decodeIfPresent(String.self, forKey: .series)
        fileName = try c.decode(String.self, forKey: .fileName)
        coverFileName = try c.decodeIfPresent(String.self, forKey: .coverFileName)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        chapterIndex = try c.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 0
        chapterFraction = try c.decodeIfPresent(Double.self, forKey: .chapterFraction) ?? 0
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        lastReadAt = try c.decodeIfPresent(Date.self, forKey: .lastReadAt)
        shelf = try c.decodeIfPresent(String.self, forKey: .shelf)
        isFinished = try c.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID)
        fileHash = try c.decodeIfPresent(String.self, forKey: .fileHash)
    }
}

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var books: URL { ensure(documents.appendingPathComponent("Books", isDirectory: true)) }
    static var covers: URL { ensure(documents.appendingPathComponent("Covers", isDirectory: true)) }
    static var libraryFile: URL { documents.appendingPathComponent("library.json") }
    static var shelvesFile: URL { documents.appendingPathComponent("shelves.json") }
    static var smartShelvesFile: URL { documents.appendingPathComponent("smart-shelves.json") }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
