import SwiftUI
import UniformTypeIdentifiers

/// "Мои книги" — eBoox-style: purple header, a "recently read" hero card,
/// Книги/Полки switch and a list of books with cover, author and progress.
struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var serverConfig: ServerConfig
    @State private var showPairing = false
    @State private var showImporter = false
    @State private var openBook: Book?
    @State private var tab: Section = .books
    @State private var openRowID: UUID?     // the one row currently swiped open
    @State private var infoBook: Book?
    @State private var shelfBook: Book?
    @State private var openShelf: ShelfRef?
    @State private var openSmart: SmartShelf?
    @State private var showNewSmart = false
    @State private var showNewShelf = false
    @State private var newShelfName = ""

    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var searching = false
    @State private var query = ""
    @State private var sort: SortOrder = .added
    @State private var batchShelf = false
    @State private var confirmBatchDelete = false

    struct ShelfRef: Identifiable { let id = UUID(); let name: String }

    enum SortOrder: String, CaseIterable, Identifiable {
        case added = "Дата добавления", title = "Название", author = "Автор", progress = "Прогресс"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .added: return "calendar"
            case .title: return "textformat"
            case .author: return "person"
            case .progress: return "chart.bar"
            }
        }
    }

    /// Library-wide search folds Russian ё→е (so ёлка ↔ елка) + case.
    private func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "е").lowercased()
    }

    /// Saved quotes across the whole library matching the query (book + highlight).
    private var matchingQuotes: [(book: Book, hl: Highlight)] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard q.count >= 2 else { return [] }
        var out: [(Book, Highlight)] = []
        for b in store.books {
            for h in b.highlights where fold(h.text + " " + h.note).contains(q) {
                out.append((b, h))
            }
        }
        return out
    }

    /// Books after search filtering + the chosen sort order.
    private var visibleBooks: [Book] {
        var b = store.books
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        if !q.isEmpty {
            b = b.filter { fold($0.title).contains(q) || fold($0.author ?? "").contains(q) }
        }
        switch sort {
        case .added:    b.sort { $0.addedAt > $1.addedAt }
        case .title:    b.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:   b.sort { ($0.author ?? "").localizedCaseInsensitiveCompare($1.author ?? "") == .orderedAscending }
        case .progress: b.sort { $0.progress > $1.progress }
        }
        return b
    }

    enum Section: String, CaseIterable { case books = "Книги", shelves = "Полки" }

    private var recent: Book? {
        store.books.filter { $0.lastReadAt != nil }
            .max { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header

                    if searching {
                        searchField.padding(.horizontal, 16).padding(.top, 8)
                    }

                    HStack(spacing: 10) {
                        if tab == .books { sortMenu }
                        Picker("", selection: $tab) {
                            ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if selecting && tab == .books { batchBar }

                    if tab == .books {
                        booksList
                    } else {
                        shelvesList
                    }
                }
                .padding(.bottom, 90)   // clear the floating tab bar
            }
            .ignoresSafeArea(edges: .top)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: BookParser.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { try? store.importBook(from: url) }
            }
        }
        .fullScreenCover(item: $openBook) { book in
            ReaderScreen(book: book)
        }
        .sheet(isPresented: $showPairing) { PairingView() }
        .sheet(item: $infoBook) { BookInfoView(book: $0) }
        .sheet(item: $shelfBook) { ShelfAssignSheet(book: $0) }
        .sheet(item: $openShelf) { ref in
            ShelfDetailView(shelfName: ref.name) { book in
                openShelf = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openBook = book }
            }
        }
        .sheet(item: $openSmart) { shelf in
            SmartShelfDetailView(shelf: shelf) { book in
                openSmart = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openBook = book }
            }
        }
        .sheet(isPresented: $showNewSmart) { NewSmartShelfSheet() }
        .alert("Новая полка", isPresented: $showNewShelf) {
            TextField("Название", text: $newShelfName)
            Button("Создать") { store.createShelf(newShelfName); newShelfName = "" }
            Button("Отмена", role: .cancel) { newShelfName = "" }
        }
        .sheet(isPresented: $batchShelf) {
            BatchShelfSheet(bookIDs: selected) { exitSelect() }
        }
        .confirmationDialog("Удалить выбранные книги?", isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("Удалить (\(selected.count))", role: .destructive) { batchDelete() }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: - Select / sort / search helpers

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск по библиотеке", text: $query)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
        .transition(.opacity)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Сортировка", selection: $sort) {
                ForEach(SortOrder.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body).foregroundStyle(theme.accent)
                .frame(width: 38, height: 30)
                .background(theme.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var batchBar: some View {
        HStack(spacing: 16) {
            Text("Выбрано: \(selected.count)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button { batchShelf = true } label: { Label("На полку", systemImage: "books.vertical") }
                .disabled(selected.isEmpty)
            Button(role: .destructive) { confirmBatchDelete = true } label: { Label("Удалить", systemImage: "trash") }
                .disabled(selected.isEmpty)
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private func toggleSelect() {
        withAnimation { selecting.toggle(); if !selecting { selected.removeAll() } }
    }
    private func exitSelect() { selected.removeAll(); selecting = false }
    private func togglePick(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func batchDelete() {
        for b in store.books where selected.contains(b.id) { store.delete(b) }
        exitSelect()
    }

    // MARK: - Header + hero

    private var header: some View {
        ZStack(alignment: .top) {
            theme.headerGradient
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .frame(height: recent == nil ? 120 : 230)
                .padding(.horizontal, -2)

            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Button { toggleSelect() } label: {
                        Text(selecting ? "Готово" : "Выбрать")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    }
                    Spacer()
                    Text("Мои книги").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button { withAnimation { searching.toggle(); if !searching { query = "" } } } label: {
                        Image(systemName: searching ? "xmark" : "magnifyingglass").foregroundStyle(.white)
                    }
                    Button { withAnimation { theme.toggle() } } label: {
                        Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill")
                            .foregroundStyle(.white)
                    }
                    Button { showPairing = true } label: {
                        Image(systemName: serverConfig.isLinked ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.white)
                    }
                    Button { showImporter = true } label: {
                        Image(systemName: "plus").foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 58)

                if let recent {
                    heroCard(recent)
                        .padding(.horizontal, 14)
                }
            }
        }
    }

    private func heroCard(_ book: Book) -> some View {
        Button { openBook = book } label: {
            HStack(spacing: 14) {
                CoverView(book: book)
                    .frame(width: 84, height: 120)
                    .shadow(radius: 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ВЫ НЕДАВНО ЧИТАЛИ:")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    Text(book.title)
                        .font(.title3.weight(.bold)).foregroundStyle(.white)
                        .lineLimit(2)
                    if book.isFinished {
                        HStack {
                            Spacer()
                            Label("ПРОЧИТАНА", systemImage: "flag.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    } else {
                        HStack {
                            Text("\(Int(book.progress * 100))%")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Text("ПРОДОЛЖИТЬ ›")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        ProgressView(value: book.progress).tint(.white)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lists

    private var booksList: some View {
        LazyVStack(spacing: 0) {
            if store.books.isEmpty {
                emptyState.padding(.top, 60)
            } else if visibleBooks.isEmpty && matchingQuotes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Ничего не найдено").foregroundStyle(.secondary)
                }
                .padding(.top, 50)
            } else {
                if searching && !matchingQuotes.isEmpty { quotesSection }
                ForEach(visibleBooks) { book in
                    if selecting {
                        selectRow(book)
                    } else {
                        SwipeBookRow(
                            book: book, openID: $openRowID,
                            onOpen:   { openRowID = nil; openBook = book },
                            onInfo:   { infoBook = book },
                            onShelf:  { shelfBook = book },
                            onDelete: { store.delete(book) })
                    }
                    Divider().padding(.leading, 86)
                }
            }
        }
        .padding(.top, 4)
    }

    private var quotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ЦИТАТЫ · \(matchingQuotes.count)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 6)
            ForEach(Array(matchingQuotes.enumerated()), id: \.offset) { _, item in
                Button { openBook = item.book } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.hl.text).font(.subheadline).foregroundStyle(.primary)
                            .lineLimit(3).multilineTextAlignment(.leading)
                        Text(item.book.title).font(.caption2).foregroundStyle(Brand.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
            Divider().padding(.leading, 16).padding(.vertical, 6)
        }
    }

    private func selectRow(_ book: Book) -> some View {
        let on = selected.contains(book.id)
        return HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(on ? theme.accent : Color.secondary)
                .padding(.leading, 14)
            BookRow(book: book)
        }
        .contentShape(Rectangle())
        .onTapGesture { togglePick(book.id) }
    }

    private var shelvesList: some View {
        VStack(spacing: 14) {
            // Smart (dynamic) shelves — books computed live from a rule
            HStack {
                Text("Умные полки").font(.subheadline.weight(.semibold))
                Spacer()
                Button { showNewSmart = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .tint(theme.accent)
            }
            .padding(.horizontal, 16)

            if store.smartShelves.isEmpty {
                Text("Динамическая полка по правилу: не начатые / читаю сейчас / прочитанные.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)], spacing: 18) {
                    ForEach(store.smartShelves) { s in
                        ShelfCard(name: s.name, books: store.books(matching: s.rule))
                            .contentShape(Rectangle())
                            .onTapGesture { openSmart = s }
                            .contextMenu {
                                Button(role: .destructive) { store.deleteSmartShelf(s.id) } label: {
                                    Label("Удалить умную полку", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }

            Divider().padding(.horizontal, 16).padding(.top, 2)

            Button { newShelfName = ""; showNewShelf = true } label: {
                Label("Новая полка", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(theme.accent.opacity(0.14))
                    .clipShape(Capsule())
            }
            .tint(theme.accent)
            .padding(.horizontal, 16)

            if store.shelves.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Полок пока нет").foregroundStyle(.secondary)
                    Text("Создайте полку или добавьте книгу на полку свайпом.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 50).padding(.horizontal, 30)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)], spacing: 18) {
                    ForEach(store.shelves, id: \.self) { name in
                        ShelfCard(name: name, books: store.books(onShelf: name))
                            .contentShape(Rectangle())
                            .onTapGesture { openShelf = ShelfRef(name: name) }
                            .contextMenu {
                                Button(role: .destructive) { store.deleteShelf(name) } label: {
                                    Label("Удалить полку", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Библиотека пуста").font(.headline)
            Button { showImporter = true } label: {
                Label("Добавить книгу", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
        }
    }
}

private struct BookRow: View {
    let book: Book
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        HStack(spacing: 14) {
            CoverView(book: book)
                .frame(width: 56, height: 80)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.body.weight(.medium)).lineLimit(2)
                if let author = book.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let shelf = book.shelf {
                    Label(shelf, systemImage: "books.vertical")
                        .font(.caption2).foregroundStyle(theme.accent).lineLimit(1)
                }
                if book.isFinished {
                    Label("Прочитана", systemImage: "flag.fill")
                        .font(.caption2.weight(.medium)).foregroundStyle(.green)
                } else {
                    ProgressView(value: book.progress).tint(theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A book row that reveals О книге / На полку / Удалить when swiped left (eBoox-style).
/// Custom (not List.swipeActions) so it lives inside the scrolling library layout and
/// shows the full-height three-button panel like the reference.
private struct SwipeBookRow: View {
    let book: Book
    @Binding var openID: UUID?
    var onOpen: () -> Void
    var onInfo: () -> Void
    var onShelf: () -> Void
    var onDelete: () -> Void

    @State private var drag: CGFloat = 0
    private let btnW: CGFloat = 92
    private var panelW: CGFloat { btnW * 3 }
    private var isOpen: Bool { openID == book.id }
    private var offset: CGFloat { min(0, max(-panelW, (isOpen ? -panelW : 0) + drag)) }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                action("info.circle", "О книге", Color(.systemGray)) { close(); onInfo() }
                action("books.vertical", "На полку", .blue) { close(); onShelf() }
                action("trash", "Удалить", .red) { close(); onDelete() }
            }
            .frame(width: panelW)

            BookRow(book: book)
                .background(Color(.systemBackground))
                .offset(x: offset)
                .onTapGesture { isOpen ? close() : onOpen() }
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            drag = v.translation.width
                        }
                        .onEnded { v in
                            let projected = offset + (v.predictedEndTranslation.width - v.translation.width)
                            withAnimation(.easeOut(duration: 0.2)) {
                                openID = projected < -panelW / 2 ? book.id : nil
                                drag = 0
                            }
                        }
                )
        }
        .clipped()
    }

    private func close() { withAnimation(.easeOut(duration: 0.2)) { openID = nil; drag = 0 } }

    private func action(_ icon: String, _ label: String, _ tint: Color,
                        _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 19))
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(tint)
        }
        .buttonStyle(.plain)
    }
}

/// "О книге" — cover + metadata (format, size, dates, progress, annotations, shelf).
private struct BookInfoView: View {
    let book: Book
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var format: String {
        (book.fileName as NSString).pathExtension.uppercased()
    }
    private var fileSize: String {
        let n = (try? FileManager.default.attributesOfItem(atPath: book.fileURL.path)[.size] as? Int) ?? nil
        guard let bytes = n else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    private func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        CoverView(book: book)
                            .frame(width: 96, height: 138)
                            .shadow(radius: 4)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.title).font(.title3.weight(.bold)).lineLimit(4)
                            if let author = book.author {
                                Text(author).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text("\(Int(book.progress * 100))% прочитано")
                                .font(.footnote).foregroundStyle(theme.accent)
                                .padding(.top, 2)
                            ProgressView(value: book.progress).tint(theme.accent)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(spacing: 0) {
                        infoRow("Формат", format)
                        Divider()
                        infoRow("Размер", fileSize)
                        Divider()
                        infoRow("Полка", book.shelf ?? "—")
                        Divider()
                        infoRow("Добавлена", date(book.addedAt))
                        Divider()
                        infoRow("Последнее чтение", date(book.lastReadAt))
                        Divider()
                        infoRow("Закладки", "\(book.bookmarks.count)")
                        Divider()
                        infoRow("Выделения", "\(book.highlights.count)")
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button {
                        store.setFinished(book, !book.isFinished); dismiss()
                    } label: {
                        Label(book.isFinished ? "Отметить непрочитанной" : "Отметить прочитанной",
                              systemImage: book.isFinished ? "flag.slash" : "flag.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.accent)

                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Удалить книгу", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(16)
            }
            .navigationTitle("О книге")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .confirmationDialog("Удалить «\(book.title)»?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { store.delete(book); dismiss() }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// "На полку" — pick an existing shelf, create a new one, or take the book off a shelf.
private struct ShelfAssignSheet: View {
    let book: Book
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var newShelf = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(theme.accent)
                        TextField("Новая полка", text: $newShelf)
                            .submitLabel(.done)
                            .onSubmit(create)
                        if !newShelf.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Создать", action: create).font(.subheadline.weight(.semibold))
                        }
                    }
                }
                if !store.shelfNames.isEmpty {
                    Section("Полки") {
                        ForEach(store.shelfNames, id: \.self) { name in
                            Button { store.setShelf(book, to: name); dismiss() } label: {
                                HStack {
                                    Image(systemName: "books.vertical")
                                    Text(name).foregroundStyle(.primary)
                                    Spacer()
                                    if book.shelf == name {
                                        Image(systemName: "checkmark").foregroundStyle(theme.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                if book.shelf != nil {
                    Section {
                        Button(role: .destructive) { store.setShelf(book, to: nil); dismiss() } label: {
                            Label("Убрать с полки", systemImage: "minus.circle")
                        }
                    }
                }
            }
            .navigationTitle("На полку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = newShelf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.setShelf(book, to: name)
        dismiss()
    }
}

/// A shelf tile: a fanned stack of up to three covers + name + count (eBoox-style).
private struct ShelfCard: View {
    let name: String
    let books: [Book]
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground))
                if books.isEmpty {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 34)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: -20) {
                        ForEach(Array(books.prefix(3).enumerated()), id: \.element.id) { idx, b in
                            CoverView(book: b)
                                .frame(width: 54, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                                .rotationEffect(.degrees(Double(idx - 1) * 5))
                                .zIndex(Double(3 - idx))
                        }
                    }
                }
            }
            .frame(height: 118)
            Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(books.count) кн.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Books filed on one shelf. Tap opens a book; swipe removes from shelf or deletes.
private struct ShelfDetailView: View {
    let shelfName: String
    var onOpen: (Book) -> Void
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var books: [Book] { store.books(onShelf: shelfName) }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(.secondary)
                        Text("На этой полке пока нет книг").foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(books) { b in
                            Button { onOpen(b) } label: { BookRow(book: b) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets())
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { store.delete(b) } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                    Button { store.setShelf(b, to: nil) } label: {
                                        Label("Снять", systemImage: "minus.circle")
                                    }.tint(.orange)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(shelfName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

/// Create a dynamic shelf: a name + a rule.
private struct NewSmartShelfSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var rule: SmartRule = .reading

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField(rule.title, text: $name)
                }
                Section("Правило") {
                    Picker("Правило", selection: $rule) {
                        ForEach(SmartRule.allCases) { r in
                            Label(r.title, systemImage: r.icon).tag(r)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Умная полка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Создать") {
                        store.createSmartShelf(name.isEmpty ? rule.title : name, rule: rule)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Books matching a smart shelf's rule (computed live). Tap opens a book.
private struct SmartShelfDetailView: View {
    let shelf: SmartShelf
    var onOpen: (Book) -> Void
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var books: [Book] { store.books(matching: shelf.rule) }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: shelf.rule.icon).font(.largeTitle).foregroundStyle(.secondary)
                        Text("Под правило пока ничего не подходит").foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(books) { b in
                            Button { onOpen(b) } label: { BookRow(book: b) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(shelf.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

/// Assign a whole selection of books to a shelf at once (or take them off shelves).
private struct BatchShelfSheet: View {
    let bookIDs: Set<UUID>
    var onDone: () -> Void
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var newShelf = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(theme.accent)
                        TextField("Новая полка", text: $newShelf)
                            .submitLabel(.done).onSubmit(create)
                        if !newShelf.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Создать", action: create).font(.subheadline.weight(.semibold))
                        }
                    }
                }
                if !store.shelfNames.isEmpty {
                    Section("Полки") {
                        ForEach(store.shelfNames, id: \.self) { name in
                            Button { apply(name) } label: {
                                HStack {
                                    Image(systemName: "books.vertical")
                                    Text(name).foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(role: .destructive) { apply(nil) } label: {
                        Label("Снять с полок", systemImage: "minus.circle")
                    }
                }
            }
            .navigationTitle("На полку (\(bookIDs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply(_ shelf: String?) {
        for b in store.books where bookIDs.contains(b.id) { store.setShelf(b, to: shelf) }
        onDone(); dismiss()
    }
    private func create() {
        let n = newShelf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        apply(n)
    }
}
