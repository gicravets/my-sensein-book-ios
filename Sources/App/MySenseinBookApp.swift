import SwiftUI

@main
struct MySenseinBookApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var theme = ThemeManager()
    @StateObject private var serverConfig = ServerConfig()
    @Environment(\.scenePhase) private var scenePhase
    @State private var autoSyncing = false

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(theme)
                .environmentObject(serverConfig)
                .preferredColorScheme(theme.colorScheme)
                .task { await autoSync() }                       // on launch
                .onChange(of: scenePhase) { phase in
                    if phase == .active || phase == .background { // on return / after reading (backgrounding)
                        Task { await autoSync() }
                    }
                }
        }
    }

    @MainActor private func autoSync() async {
        guard serverConfig.isLinked, !autoSyncing else { return }
        autoSyncing = true
        defer { autoSyncing = false }
        _ = try? await SyncService.sync(store: store, config: serverConfig)
    }
}
