import Foundation

/// Two-way sync of reading state (overall progress / finished / lastReadAt)
/// between the local library and the server. Books are matched by title+author.
/// Newest-wins by lastReadAt. Precise chapter position + annotations: later.
enum SyncService {
    struct Result { var matched = 0; var pushed = 0; var pulled = 0 }

    @MainActor
    static func sync(store: LibraryStore, config: ServerConfig) async throws -> Result {
        guard let base = config.serverURL, let key = config.deviceKey else {
            throw APIError.transport("Устройство не привязано")
        }
        let client = APIClient(baseURL: base, apiKey: key)
        let device = config.deviceName ?? "iOS"
        let remote = try await client.getBooks()
        var byKey: [String: RemoteBook] = [:]
        for r in remote { byKey[matchKey(title: r.title, author: r.authors.first)] = r }

        var result = Result()
        for local in store.books {
            guard let r = byKey[matchKey(title: local.title, author: local.author)] else { continue }
            result.matched += 1

            let localTime = local.lastReadAt ?? .distantPast
            let remoteTime = parse(r.readProgress?.lastReadAt)

            if remoteTime > localTime {
                // pull: server is newer
                store.applyRemoteState(
                    bookID: local.id,
                    progress: r.readProgress?.totalProgression ?? local.progress,
                    isFinished: r.readProgress?.completed ?? local.isFinished,
                    lastReadAt: remoteTime == .distantPast ? nil : remoteTime
                )
                result.pulled += 1
            } else if local.lastReadAt != nil || local.progress > 0 || local.isFinished {
                // push: local is newer (or server has nothing yet)
                try await client.putProgression(
                    id: r.id, totalProgression: local.progress,
                    completed: local.isFinished, deviceName: device
                )
                result.pushed += 1
            }
        }
        return result
    }

    private static func matchKey(title: String, author: String?) -> String {
        func norm(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return norm(title) + "|" + norm(author ?? "")
    }

    private static let iso = ISO8601DateFormatter()
    private static func parse(_ s: String?) -> Date {
        guard let s, let d = iso.date(from: s) else { return .distantPast }
        return d
    }
}
