import Foundation

/// A dynamic shelf: its books are computed by applying `rule` to the library
/// (no explicit membership). Mirrors the server's smart shelves.
enum SmartRule: String, Codable, CaseIterable, Identifiable {
    case unread, reading, finished
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unread:   return "Не начатые"
        case .reading:  return "Читаю сейчас"
        case .finished: return "Прочитанные"
        }
    }
    var icon: String {
        switch self {
        case .unread:   return "book.closed"
        case .reading:  return "book"
        case .finished: return "checkmark.circle"
        }
    }
}

struct SmartShelf: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var rule: SmartRule
}
