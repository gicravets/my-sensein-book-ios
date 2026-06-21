import Foundation
import Combine

/// Holds the linked server URL + device key. URL in UserDefaults, key in Keychain.
@MainActor
final class ServerConfig: ObservableObject {
    @Published private(set) var serverURL: String?
    @Published private(set) var deviceName: String?

    private let keyKeychain = "msb.deviceKey"
    private let urlKey = "msb.serverURL"
    private let nameKey = "msb.deviceName"

    var deviceKey: String? { Keychain.get(keyKeychain) }
    var isLinked: Bool { serverURL != nil && deviceKey != nil }

    init() {
        serverURL = UserDefaults.standard.string(forKey: urlKey)
        deviceName = UserDefaults.standard.string(forKey: nameKey)
    }

    func link(url: String, key: String, deviceName: String) {
        let trimmed = url.trimmingCharacters(in: .init(charactersIn: "/ "))
        Keychain.set(key, for: keyKeychain)
        UserDefaults.standard.set(trimmed, forKey: urlKey)
        UserDefaults.standard.set(deviceName, forKey: nameKey)
        self.serverURL = trimmed
        self.deviceName = deviceName
    }

    func unlink() {
        Keychain.delete(keyKeychain)
        UserDefaults.standard.removeObject(forKey: urlKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
        serverURL = nil
        deviceName = nil
    }
}
