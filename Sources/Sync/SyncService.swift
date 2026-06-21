import Foundation

/// Two-way sync of reading state (overall progress / finished / lastReadAt)
/// between the local library and the server. Books are matched by title+author.
/// Newest-wins by lastReadAt. Precise chapter position + annotations: later.
enum SyncService {
    struct Result { var matched = 0; var pushed = 0; var pulled = 0; var annotations = 0 }

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

            // push annotations (text/note/color shared; iOS locator encoded), dedup by text/label
            if !local.highlights.isEmpty {
                let existing = Set((try? await client.getHighlights(bookID: r.id))?.compactMap { $0.text } ?? [])
                for h in local.highlights where !existing.contains(h.text) {
                    let loc = encode(["c": h.chapterIndex, "o": h.occurrence])
                    try? await client.createHighlight(bookID: r.id, text: h.text,
                        color: colorName(h.colorHex), note: h.note, locatorValue: loc)
                    result.annotations += 1
                }
            }
            if !local.bookmarks.isEmpty {
                let existing = Set((try? await client.getBookmarks(bookID: r.id))?.compactMap { $0.label } ?? [])
                for b in local.bookmarks where !existing.contains(b.label) {
                    let loc = encode(["c": b.chapterIndex, "f": b.fraction])
                    try? await client.createBookmark(bookID: r.id, label: b.label,
                        locatorValue: loc, progression: b.fraction)
                    result.annotations += 1
                }
            }
        }
        return result
    }

    private static func encode(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    /// Map an iOS highlight hex to the server's named palette (yellow/green/blue/pink/orange).
    private static func colorName(_ hex: String) -> String {
        let h = hex.lowercased().replacingOccurrences(of: "#", with: "")
        guard h.count >= 6, let r = Int(h.prefix(2), radix: 16),
              let g = Int(h.dropFirst(2).prefix(2), radix: 16),
              let b = Int(h.dropFirst(4).prefix(2), radix: 16) else { return "yellow" }
        let palette: [(String, Int, Int, Int)] = [
            ("yellow", 234, 179, 8), ("green", 34, 197, 94), ("blue", 59, 130, 246),
            ("pink", 236, 72, 153), ("orange", 249, 115, 22),
        ]
        return palette.min { a, c in
            let da = (a.1-r)*(a.1-r)+(a.2-g)*(a.2-g)+(a.3-b)*(a.3-b)
            let dc = (c.1-r)*(c.1-r)+(c.2-g)*(c.2-g)+(c.3-b)*(c.3-b)
            return da < dc
        }!.0
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
