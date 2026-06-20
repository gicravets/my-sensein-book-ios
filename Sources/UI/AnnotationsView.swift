import SwiftUI

/// Tabbed sheet: Оглавление · Закладки · Выделения.
struct ContentsSheet: View {
    @ObservedObject var controller: ReaderController
    let onPick: () -> Void
    @State private var tab: Tab = .toc

    enum Tab: String, CaseIterable { case toc = "Оглавление", bookmarks = "Закладки", highlights = "Выделения" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    switch tab {
                    case .toc:        tocList
                    case .bookmarks:  bookmarksList
                    case .highlights: highlightsList
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Содержание")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var tocList: some View {
        if controller.epub.toc.isEmpty {
            Text("Оглавление недоступно").foregroundStyle(.secondary)
        } else {
            ForEach(controller.epub.toc) { entry in
                Button {
                    controller.jump(toHref: entry.href); onPick()
                } label: {
                    Text(entry.title)
                        .padding(.leading, CGFloat(entry.level) * 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder private var bookmarksList: some View {
        if controller.bookmarks.isEmpty {
            Text("Закладок пока нет").foregroundStyle(.secondary)
        } else {
            ForEach(controller.bookmarks) { bm in
                Button { controller.go(to: bm); onPick() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bm.label.isEmpty ? "Закладка" : bm.label).lineLimit(2)
                        Text("Глава \(bm.chapterIndex + 1) · \(Int(bm.fraction * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { idx in idx.map { controller.bookmarks[$0] }.forEach(controller.removeBookmark) }
        }
    }

    @ViewBuilder private var highlightsList: some View {
        if controller.allHighlights.isEmpty {
            Text("Выделений пока нет").foregroundStyle(.secondary)
        } else {
            ForEach(controller.allHighlights) { hl in
                Button { controller.go(to: hl); onPick() } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: hl.colorHex)).frame(width: 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hl.text).lineLimit(3)
                            if !hl.note.isEmpty {
                                Text(hl.note).font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text("Глава \(hl.chapterIndex + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: hl.note.isEmpty ? hl.text : "\(hl.text)\n\n— \(hl.note)") {
                            Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { idx in idx.map { controller.allHighlights[$0] }.forEach(controller.removeHighlight) }
        }
    }
}

// MARK: - Search

struct SearchSheet: View {
    @ObservedObject var controller: ReaderController
    let onPick: () -> Void

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List {
                if searched && results.isEmpty {
                    Text("Ничего не найдено").foregroundStyle(.secondary)
                } else if !results.isEmpty {
                    Section("Найдено: \(results.count)") {
                        ForEach(results) { r in
                            Button { controller.open(r); onPick() } label: { snippet(r) }
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Поиск по книге")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Найти в книге")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: query) { new in if new.isEmpty { results = []; searched = false } }
        }
    }

    private func runSearch() {
        results = controller.search(query)
        searched = true
    }

    private func snippet(_ r: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            highlighted(r).font(.subheadline).lineLimit(3)
            Text("Глава \(r.chapterIndex + 1)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func highlighted(_ r: SearchResult) -> Text {
        let s = r.snippet
        let pre = String(s[s.startIndex..<r.matchRange.lowerBound])
        let mid = String(s[r.matchRange])
        let post = String(s[r.matchRange.upperBound...])
        return Text(pre) + Text(mid).bold().foregroundColor(Brand.accent) + Text(post)
    }
}
