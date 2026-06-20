import SwiftUI
import UniformTypeIdentifiers

/// "Добавить книги" — link field + ways to add books, eBoox-style.
struct AddBooksView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var theme: ThemeManager
    @State private var link = ""
    @State private var showImporter = false
    @State private var showHowTo = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        theme.headerGradient
                            .clipShape(RoundedRectangle(cornerRadius: 28))
                            .frame(height: 150)
                        VStack(spacing: 12) {
                            Text("Добавить книги").font(.headline).foregroundStyle(.white)
                            HStack {
                                Image(systemName: "link").foregroundStyle(.white.opacity(0.7))
                                TextField("", text: $link, prompt: Text("Введите ссылку")
                                    .foregroundColor(.white.opacity(0.6)))
                                    .foregroundStyle(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            .padding(12)
                            .background(.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                    }
                    .ignoresSafeArea(edges: .top)

                    VStack(spacing: 0) {
                        row("book", "Как загружать книги") { showHowTo = true }
                        Divider().padding(.leading, 56)
                        row("arrow.down.circle", "Добавить из Файлов") { showImporter = true }
                        Divider().padding(.leading, 56)
                        row("heart", "Избранное") {}
                    }
                    .padding(.top, 8)

                    Text("В избранном ничего нет")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
                .padding(.bottom, 90)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: BookParser.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { try? store.importBook(from: url) }
            }
        }
        .sheet(isPresented: $showHowTo) { HowToView() }
    }

    private func row(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                Text(title).font(.body.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }
}

private struct HowToView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Label("Откройте книгу из приложения «Файлы» или из почты через «Поделиться → Books».", systemImage: "folder")
                Label("Или нажмите «Добавить из Файлов» и выберите книги.", systemImage: "arrow.down.circle")
                Label("Поддерживаются форматы EPUB и FB2.", systemImage: "doc")
            }
            .navigationTitle("Как загружать книги")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}
