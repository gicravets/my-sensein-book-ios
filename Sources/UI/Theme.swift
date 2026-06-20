import SwiftUI

/// How pages advance in the reader.
enum ReadingMode: String, CaseIterable, Identifiable {
    case slide, curl, scroll
    var id: String { rawValue }
    var title: String {
        switch self {
        case .slide:  return "Слайд"
        case .curl:   return "Загиб"
        case .scroll: return "Прокрутка"
        }
    }
    var icon: String {
        switch self {
        case .slide:  return "rectangle.righthalf.inset.filled.arrow.right"
        case .curl:   return "book.pages"
        case .scroll: return "arrow.up.arrow.down"
        }
    }
}

/// Bottom counter display: percent, page X / Y, or hidden.
enum CounterFormat: String, CaseIterable {
    case percent, pages, off
    func next() -> CounterFormat {
        switch self {
        case .percent: return .pages
        case .pages:   return .off
        case .off:     return .percent
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light, sepia, night, black
    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "День"
        case .sepia: return "Сепия"
        case .night: return "Ночь"
        case .black: return "AMOLED"
        }
    }

    /// CSS color strings injected into the WKWebView.
    var bgHex: String {
        switch self {
        case .light: return "#FFFFFF"
        case .sepia: return "#F4ECD8"
        case .night: return "#2B2E3B"
        case .black: return "#000000"
        }
    }
    var fgHex: String {
        switch self {
        case .light: return "#1A1A1A"
        case .sepia: return "#4A3F2C"
        case .night: return "#CBCDD6"
        case .black: return "#B0B0B0"
        }
    }
    var linkHex: String {
        switch self {
        case .light: return "#2A6FB0"
        case .sepia: return "#8A5A2B"
        case .night: return "#7FA8E8"
        case .black: return "#6E9BD6"
        }
    }

    var bgColor: Color { Color(hex: bgHex) }
    var fgColor: Color { Color(hex: fgHex) }
    var isDark: Bool { self == .night || self == .black }
}

/// eBoox-style brand palette with a dark (purple) and light (coral) variant.
enum Brand {
    static let purple = Color(hex: "#5B2A86")
    static let purpleDark = Color(hex: "#34194F")
    static let accent = Color(hex: "#B14EE0")
    static let surface = Color(hex: "#1B1B22")

    static let coral = Color(hex: "#E85C7A")
    static let coralDark = Color(hex: "#B23A56")
    static let coralAccent = Color(hex: "#D63A6A")
    static let surfaceLight = Color(hex: "#FFFFFF")

    static func headerGradient(dark: Bool) -> LinearGradient {
        LinearGradient(colors: dark ? [purple, purpleDark] : [coral, coralDark],
                       startPoint: .top, endPoint: .bottom)
    }
    static func accent(dark: Bool) -> Color { dark ? accent : coralAccent }

    /// Back-compat default (dark).
    static var headerGradient: LinearGradient { headerGradient(dark: true) }
}

/// App-level light/dark chrome theme (separate from the 4 reader paper themes).
final class ThemeManager: ObservableObject {
    @Published var isDark: Bool {
        didSet { UserDefaults.standard.set(isDark, forKey: "appDark") }
    }
    init() { isDark = (UserDefaults.standard.object(forKey: "appDark") as? Bool) ?? true }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var headerGradient: LinearGradient { Brand.headerGradient(dark: isDark) }
    var accent: Color { Brand.accent(dark: isDark) }
    func toggle() { isDark.toggle() }
}

extension View {
    /// iOS 26 Liquid Glass when available, material fallback otherwise.
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, fallback: Material = .ultraThinMaterial) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        let r = Double((v & 0xFF0000) >> 16) / 255
        let g = Double((v & 0x00FF00) >> 8) / 255
        let b = Double(v & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
