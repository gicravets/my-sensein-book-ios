import SwiftUI

@main
struct MySenseinBookApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var theme = ThemeManager()
    @StateObject private var serverConfig = ServerConfig()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(theme)
                .environmentObject(serverConfig)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
