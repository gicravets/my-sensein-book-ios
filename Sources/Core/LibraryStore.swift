import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var shelves: [String] = []   // user-created shelf names, in order
    @Published private(set) var smartShelves: [SmartShelf] = []   // dynamic, rule-based shelves
    @Published var importError: String?

    init() {
        load()
        importSampleIfNeeded()
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: AppPaths.libraryFile),
           let decoded = try? JSONDecoder().decode([Book].self, from: data) {
            books = decoded.sorted { $0.addedAt > $1.addedAt }
        }
        if let data = try? Data(contentsOf: AppPaths.shelvesFile),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            shelves = decoded
        }
        if let data = try? Data(contentsOf: AppPaths.smartShelvesFile),
           let decoded = try? JSONDecoder().decode([SmartShelf].self, from: data) {
            smartShelves = decoded
        }
        // Make sure any shelf referenced by a book is also in the list.
        for name in books.compactMap({ $0.shelf }) where !shelves.contains(name) {
            shelves.append(name)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: AppPaths.libraryFile)
        }
        if let data = try? JSONEncoder().encode(shelves) {
            try? data.write(to: AppPaths.shelvesFile)
        }
        if let data = try? JSONEncoder().encode(smartShelves) {
            try? data.write(to: AppPaths.smartShelvesFile)
        }
    }

    // MARK: - Smart shelves (dynamic, rule-based)

    /// Books matching a rule, computed live from the library (no stored membership).
    func books(matching rule: SmartRule) -> [Book] {
        switch rule {
        case .unread:   return books.filter { $0.progress == 0 && !$0.isFinished }
        case .reading:  return books.filter { $0.progress > 0 && !$0.isFinished }
        case .finished: return books.filter { $0.isFinished }
        }
    }

    func createSmartShelf(_ name: String, rule: SmartRule) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        smartShelves.append(SmartShelf(name: n, rule: rule))
        save()
    }

    func deleteSmartShelf(_ id: UUID) {
        smartShelves.removeAll { $0.id == id }
        save()
    }

    /// Record that a book has been uploaded to the server (id + content hash).
    func setServerInfo(bookID: UUID, serverID: String, fileHash: String?) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].serverID = serverID
        books[i].fileHash = fileHash
        save()
    }

    // MARK: - First-run sample

    private func importSampleIfNeeded() {
        let flag = "didImportSample.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        if let fb2 = Bundle.main.url(forResource: "Sample2", withExtension: "fb2") {
            try? importBook(from: fb2)
        }
        if let epub = Bundle.main.url(forResource: "Sample", withExtension: "epub") {
            try? importBook(from: epub)
        }
    }

    // MARK: - Import

    /// Copy an EPUB into the library, parse its metadata and extract a cover.
    @discardableResult
    func importBook(from sourceURL: URL) throws -> Book {
        let needsStop = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsStop { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "epub" : sourceURL.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(ext)"
        let dest = AppPaths.books.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        let parsed = try BookParser.parse(at: dest)

        var coverFileName: String?
        if let cover = parsed.coverHref {
            let coverSrc = parsed.fileURL(forHref: cover)
            if let data = try? Data(contentsOf: coverSrc) {
                let ext = coverSrc.pathExtension.isEmpty ? "img" : coverSrc.pathExtension
                let name = "\(id.uuidString).\(ext)"
                try? data.write(to: AppPaths.covers.appendingPathComponent(name))
                coverFileName = name
            }
        }

        let book = Book(id: id, title: parsed.title, author: parsed.author,
                        fileName: fileName, coverFileName: coverFileName, addedAt: Date())
        books.insert(book, at: 0)
        save()
        return book
    }

    func updateProgress(bookID: UUID, chapter: Int, fraction: Double, progress: Double) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].chapterIndex = chapter
        books[idx].chapterFraction = fraction
        books[idx].progress = progress
        books[idx].lastReadAt = Date()
        if progress >= 0.995 { books[idx].isFinished = true }   // auto-mark when read to the end
        save()
    }

    func setFinished(_ book: Book, _ finished: Bool) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].isFinished = finished
        save()
    }

    /// Apply reading state pulled from the server (overall progress / finished /
    /// lastReadAt + optional precise chapter position from a same-engine client).
    func applyRemoteState(bookID: UUID, progress: Double, isFinished: Bool, lastReadAt: Date?,
                          chapterIndex: Int? = nil, chapterFraction: Double? = nil) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].progress = progress
        books[i].isFinished = isFinished
        if let lastReadAt { books[i].lastReadAt = lastReadAt }
        if let chapterIndex { books[i].chapterIndex = chapterIndex }
        if let chapterFraction { books[i].chapterFraction = chapterFraction }
        save()
    }

    // MARK: - Annotations

    func book(id: UUID) -> Book? { books.first { $0.id == id } }

    func addBookmark(bookID: UUID, _ bookmark: Bookmark) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].bookmarks.append(bookmark)
        save()
    }

    func removeBookmark(bookID: UUID, id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].bookmarks.removeAll { $0.id == id }
        save()
    }

    func addHighlight(bookID: UUID, _ highlight: Highlight) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].highlights.append(highlight)
        save()
    }

    func removeHighlight(bookID: UUID, id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].highlights.removeAll { $0.id == id }
        save()
    }

    func setHighlightNote(bookID: UUID, id: UUID, note: String) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        if let j = books[i].highlights.firstIndex(where: { $0.id == id }) {
            books[i].highlights[j].note = note
            save()
        }
    }

    func delete(_ book: Book) {
        try? FileManager.default.removeItem(at: book.fileURL)
        if let cover = book.coverURL { try? FileManager.default.removeItem(at: cover) }
        books.removeAll { $0.id == book.id }
        save()
    }

    /// All shelf names (user-created order). Alias kept for existing call sites.
    var shelfNames: [String] { shelves }

    func books(onShelf name: String) -> [Book] { books.filter { $0.shelf == name } }

    /// Create an empty shelf. Returns false if the name is blank or already taken.
    @discardableResult
    func createShelf(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !shelves.contains(n) else { return false }
        shelves.append(n)
        save()
        return true
    }

    func renameShelf(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !shelves.contains(n), let i = shelves.firstIndex(of: old) else { return }
        shelves[i] = n
        for j in books.indices where books[j].shelf == old { books[j].shelf = n }
        save()
    }

    /// Remove a shelf; its books stay in the library, just unshelved.
    func deleteShelf(_ name: String) {
        shelves.removeAll { $0 == name }
        for i in books.indices where books[i].shelf == name { books[i].shelf = nil }
        save()
    }

    /// File a book onto a shelf (or pass nil to take it off any shelf).
    func setShelf(_ book: Book, to shelf: String?) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        let trimmed = shelf?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = trimmed, !name.isEmpty {
            books[i].shelf = name
            if !shelves.contains(name) { shelves.append(name) }
        } else {
            books[i].shelf = nil
        }
        save()
    }
}
