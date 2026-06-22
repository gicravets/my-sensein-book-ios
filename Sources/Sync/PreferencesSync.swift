import Foundation

/// Reader settings that sync across devices via GET/PUT /api/v1/preferences.
/// All optional so the server's partial/empty object decodes cleanly; nil fields are
/// omitted on encode (Swift synthesises encodeIfPresent), so a PUT never nulls a key.
struct RemotePrefs: Codable {
    var theme: String?       // canonical: light | sepia | dark | black
    var fontPct: Int?        // == iOS fontScale (percent)
    var readingMode: String? // slide | curl | scroll (iOS-only; web ignores)
    var updatedAt: String?   // RFC3339 — newest-wins stamp
}

/// Two-way sync of reader preferences (theme / font / mode). Newest-wins by `updatedAt`,
/// the same discipline the book sync uses. Server values are written to UserDefaults and
/// take effect the next time a reader is opened. UserDefaults keys are the bridge:
/// `readerTheme` (ReaderTheme rawValue), `fontScale` (Int), `readingMode`, `prefs.updatedAt`.
enum PreferencesSync {
    static let kTheme = "readerTheme", kFont = "fontScale", kMode = "readingMode", kStamp = "prefs.updatedAt"

    /// Call after any local settings change so the next sync pushes it.
    static func stamp() { UserDefaults.standard.set(iso(Date()), forKey: kStamp) }

    // iOS ReaderTheme rawValue uses "night"; the canonical/web name is "dark".
    static func toCanonical(_ raw: String) -> String { raw == "night" ? "dark" : raw }
    static func fromCanonical(_ c: String) -> String { c == "dark" ? "night" : c }

    @MainActor
    static func run(client: APIClient) async {
        let d = UserDefaults.standard
        guard let server = try? await client.getPreferences() else { return }

        if let stampStr = server.updatedAt, parse(stampStr) > parse(d.string(forKey: kStamp)) {
            // server is newer -> apply (effective on next reader open)
            if let t = server.theme, ReaderTheme(rawValue: fromCanonical(t)) != nil {
                d.set(fromCanonical(t), forKey: kTheme)
            }
            if let f = server.fontPct { d.set(f, forKey: kFont) }
            if let m = server.readingMode, ReadingMode(rawValue: m) != nil { d.set(m, forKey: kMode) }
            d.set(stampStr, forKey: kStamp)
            return
        }

        // local is newer (or server empty) -> push what we have
        let theme = d.string(forKey: kTheme)
        let font = d.object(forKey: kFont) as? Int
        let mode = d.string(forKey: kMode)
        guard theme != nil || font != nil || mode != nil else { return }
        let stamp = d.string(forKey: kStamp) ?? iso(Date())
        d.set(stamp, forKey: kStamp)
        try? await client.putPreferences(
            RemotePrefs(theme: theme.map(toCanonical), fontPct: font, readingMode: mode, updatedAt: stamp))
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func parse(_ s: String?) -> Date {
        guard let s, let date = ISO8601DateFormatter().date(from: s) else { return .distantPast }
        return date
    }
}
