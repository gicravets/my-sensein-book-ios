import SwiftUI

@main
struct MySenseinBookApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var theme = ThemeManager()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(theme)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
