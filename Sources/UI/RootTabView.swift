import SwiftUI

/// Root container with eBoox-style floating pill tab bar:
/// Мои книги · Добавить книги · Оценить.
struct RootTabView: View {
    @State private var tab: Tab = .library

    enum Tab: Int { case library, add, rate }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .library: LibraryView()
                case .add:     AddBooksView()
                case .rate:    RateView()
                }
            }
            FloatingTabBar(selection: $tab)
        }
        .ignoresSafeArea(.container, edges: .bottom)   // island sits an equal inset from the true bottom edge
    }
}

private struct FloatingTabBar: View {
    @Binding var selection: RootTabView.Tab
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        HStack(spacing: 4) {
            item(.library, "books.vertical.fill", "Мои книги")
            item(.add, "arrow.down.circle.fill", "Добавить книги")
            item(.rate, "birthday.cake.fill", "Оценить")
        }
        .padding(6)
        .glassBackground(in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal, 14)   // equal side + bottom insets from the screen edge
        .padding(.bottom, 14)
    }

    private func item(_ tab: RootTabView.Tab, _ icon: String, _ label: String) -> some View {
        let active = selection == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.secondary))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(active ? theme.accent.opacity(0.16) : .clear)
            )
        }
    }
}
