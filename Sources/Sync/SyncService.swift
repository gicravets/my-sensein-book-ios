import Foundation

/// Two-way sync of reading state (overall progress / finished / lastReadAt)
/// between the local library and the server. Books are matched by title+author.
/// Newest-wins by lastReadAt. Precise chapter position + annotations: later.
enum SyncService {
    struct Result { var matched = 0; var pushed = 0; var pulled = 0; var annotations = 0; var uploaded = 0 }

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
                // pull: server is newer. Use the native locator for precise resume
                // when it came from a same-engine (iOS) client; else just overall %.
                let loc = decode(r.readProgress?.clientLocator)
                store.applyRemoteState(
                    bookID: local.id,
                    progress: r.readProgress?.totalProgression ?? local.progress,
                    isFinished: r.readProgress?.completed ?? local.isFinished,
                    lastReadAt: remoteTime == .distantPast ? nil : remoteTime,
                    chapterIndex: loc?["c"].map { Int($0) },
                    chapterFraction: loc?["f"]
                )
                result.pulled += 1
            } else if local.lastReadAt != nil || local.progress > 0 || local.isFinished {
                // push: local is newer (or server has nothing yet)
                try await client.putProgression(
                    id: r.id, totalProgression: local.progress,
                    completed: local.isFinished, deviceName: device,
                    clientLocator: encode(["c": local.chapterIndex, "f": local.chapterFraction])
                )
                result.pushed += 1
            }

            // --- highlights: two-way (dedup by text) ---
            let remoteHL = (try? await client.getHighlights(bookID: r.id)) ?? []
            let remoteHLTexts = Set(remoteHL.compactMap { $0.text })
            let localHLTexts = Set(local.highlights.map { $0.text })
            for h in local.highlights where !remoteHLTexts.contains(h.text) {        // push
                try? await client.createHighlight(bookID: r.id, text: h.text,
                    color: colorName(h.colorHex), note: h.note,
                    locatorValue: encode(["c": h.chapterIndex, "o": h.occurrence]))
                result.annotations += 1
            }
            for ra in remoteHL where ra.locator?.type == "msb-ios"                    // pull (iOS-origin only)
                && !localHLTexts.contains(ra.text ?? "") {
                guard let text = ra.text, let loc = decode(ra.locator?.value) else { continue }
                store.addHighlight(bookID: local.id, Highlight(
                    chapterIndex: loc["c"].map { Int($0) } ?? 0, text: text,
                    occurrence: loc["o"].map { Int($0) } ?? 0,
                    colorHex: colorHex(ra.color ?? "yellow"), note: ra.note ?? ""))
                result.annotations += 1
            }

            // --- bookmarks: two-way (dedup by label) ---
            let remoteBM = (try? await client.getBookmarks(bookID: r.id)) ?? []
            let remoteBMLabels = Set(remoteBM.compactMap { $0.label })
            let localBMLabels = Set(local.bookmarks.map { $0.label })
            for b in local.bookmarks where !remoteBMLabels.contains(b.label) {        // push
                try? await client.createBookmark(bookID: r.id, label: b.label,
                    locatorValue: encode(["c": b.chapterIndex, "f": b.fraction]), progression: b.fraction)
                result.annotations += 1
            }
            for ra in remoteBM where ra.locator?.type == "msb-ios"                    // pull
                && !localBMLabels.contains(ra.label ?? "") {
                guard let label = ra.label, let loc = decode(ra.locator?.value) else { continue }
                store.addBookmark(bookID: local.id, Bookmark(
                    chapterIndex: loc["c"].map { Int($0) } ?? 0,
                    fraction: loc["f"] ?? 0, label: label))
                result.annotations += 1
            }
        }

        // library file sync: upload local books not yet on the server (server dedups by hash)
        for local in store.books where local.serverID == nil {
            let url = local.fileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let up = try? await client.uploadBook(fileURL: url, fileName: url.lastPathComponent) {
                store.setServerInfo(bookID: local.id, serverID: up.id, fileHash: up.fileHash)
                result.uploaded += 1
            }
        }

        // reader preferences (theme / font / mode) — newest-wins, applied on next reader open
        await PreferencesSync.run(client: client)
        return result
    }

    private static func encode(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    private static func decode(_ s: String?) -> [String: Double]? {
        guard let s, let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var out: [String: Double] = [:]
        for (k, v) in obj { if let n = v as? NSNumber { out[k] = n.doubleValue } }
        return out
    }

    private static let palette: [(String, String)] = [
        ("yellow", "#eab308"), ("green", "#22c55e"), ("blue", "#3b82f6"),
        ("pink", "#ec4899"), ("orange", "#f97316"),
    ]
    private static func colorHex(_ name: String) -> String {
        palette.first { $0.0 == name }?.1 ?? "#eab308"
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
