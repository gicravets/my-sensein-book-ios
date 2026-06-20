import SwiftUI

/// Parses the book's EPUB off the main thread, then hands a ready controller to ReaderView.
struct ReaderScreen: View {
    let book: Book
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var controller: ReaderController?
    @State private var failed = false

    var body: some View {
        Group {
            if let controller {
                ReaderView(controller: controller)
            } else if failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("Не удалось открыть книгу")
                    Button("Назад") { dismiss() }
                }
            } else {
                ProgressView("Открываю…")
            }
        }
        .task(id: book.id) {
            guard controller == nil else { return }
            let book = self.book
            let parsed = await Task.detached(priority: .userInitiated) {
                try? BookParser.parse(at: book.fileURL)
            }.value
            if let parsed {
                controller = ReaderController(epub: parsed, book: book, store: store)
            } else {
                failed = true
            }
        }
    }
}
