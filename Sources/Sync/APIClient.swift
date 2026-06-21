import Foundation

/// Payload encoded in the server QR code.
struct PairPayload: Codable {
    let url: String
    let t: String
}

struct ClaimResponse: Codable {
    let deviceId: String
    let deviceName: String
    let key: String
}

enum APIError: Error, LocalizedError {
    case badResponse(Int)
    case transport(String)
    var errorDescription: String? {
        switch self {
        case .badResponse(let c): return "Сервер вернул код \(c)"
        case .transport(let m): return m
        }
    }
}

/// Talks to the my-sensein-book Go backend. Auth via X-API-Key.
struct APIClient {
    let baseURL: String
    let apiKey: String?

    init(baseURL: String, apiKey: String? = nil) {
        self.baseURL = baseURL.trimmingCharacters(in: .init(charactersIn: "/ "))
        self.apiKey = apiKey
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: baseURL + path)!)
        r.httpMethod = method
        if let key = apiKey { r.setValue(key, forHTTPHeaderField: "X-API-Key") }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.timeoutInterval = 15
        return r
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw APIError.badResponse(code) }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    /// Exchange a pairing token (from the QR) for a persistent device key.
    static func claim(payload: PairPayload, deviceName: String) async throws -> (baseURL: String, resp: ClaimResponse) {
        let client = APIClient(baseURL: payload.url)
        let body = try JSONSerialization.data(withJSONObject: ["token": payload.t, "name": deviceName])
        let req = client.request("/api/v1/auth/pair/claim", method: "POST", body: body)
        let resp = try await client.send(req, as: ClaimResponse.self)
        return (client.baseURL, resp)
    }

    /// Connectivity check: number of books on the server (proves the key works).
    func booksCount() async throws -> Int {
        struct Page: Decodable { let totalElements: Int }
        return try await send(request("/api/v1/books?size=1"), as: Page.self).totalElements
    }

    /// Full server catalog (for sync matching).
    func getBooks() async throws -> [RemoteBook] {
        struct Page: Decodable { let content: [RemoteBook] }
        return try await send(request("/api/v1/books?size=1000"), as: Page.self).content
    }

    /// Push overall reading state to the server.
    func putProgression(id: String, totalProgression: Double, completed: Bool, deviceName: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "progression": totalProgression,
            "totalProgression": totalProgression,
            "page": Int((totalProgression * 100).rounded()),
            "totalPages": 100,
            "completed": completed,
            "deviceName": deviceName,
        ])
        let req = request("/api/v1/books/\(id)/progression", method: "PUT", body: body)
        _ = try await URLSession.shared.data(for: req)
    }

    // --- annotations ---

    func getHighlights(bookID: String) async throws -> [RemoteAnnotation] {
        struct Resp: Decodable { let content: [RemoteAnnotation] }
        return try await send(request("/api/v1/highlights?bookId=\(bookID)"), as: Resp.self).content
    }

    func createHighlight(bookID: String, text: String, color: String, note: String, locatorValue: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "bookId": bookID, "text": text, "color": color, "note": note,
            "locator": ["type": "msb-ios", "value": locatorValue, "progression": 0],
        ])
        _ = try await URLSession.shared.data(for: request("/api/v1/highlights", method: "POST", body: body))
    }

    func getBookmarks(bookID: String) async throws -> [RemoteAnnotation] {
        struct Resp: Decodable { let content: [RemoteAnnotation] }
        return try await send(request("/api/v1/bookmarks?bookId=\(bookID)"), as: Resp.self).content
    }

    func createBookmark(bookID: String, label: String, locatorValue: String, progression: Double) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "bookId": bookID, "label": label,
            "locator": ["type": "msb-ios", "value": locatorValue, "progression": progression],
        ])
        _ = try await URLSession.shared.data(for: request("/api/v1/bookmarks", method: "POST", body: body))
    }
}

struct RemoteLocator: Codable {
    var type: String?
    var value: String?
    var progression: Double?
}

struct RemoteAnnotation: Codable {
    let id: String
    var text: String?
    var label: String?
    var color: String?
    var note: String?
    var locator: RemoteLocator?
}

// Server DTOs (subset of the my-sensein-book contract used for sync).
struct RemoteProgress: Codable {
    var totalProgression: Double
    var completed: Bool
    var lastReadAt: String?
}

struct RemoteBook: Codable {
    let id: String
    let title: String
    let authors: [String]
    let readProgress: RemoteProgress?
}
